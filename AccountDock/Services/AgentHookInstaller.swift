import AppKit
import Foundation

private let hookLog = FileLog("Hooks")

/// Installs, checks and repairs everything AccountDock adds to the agents'
/// own configuration:
/// - lifecycle hooks in the file each provider's `LifecycleHookSupport`
///   names (and each managed Codex home), which record which process runs
///   which session;
/// - the status-line wrapper of a provider with a status-line usage feed
///   (`ClaudeStatusLineTelemetry`);
/// - the pause gate (`AgentPauseGate`) for providers that pause agents;
/// - the request router for the provider it serves.
///
/// The launch check offers to install anything missing, and Settings lists
/// each part with a reinstall action.
enum AgentHookInstaller {
    static let lifecycleMarker = "# accountdock-hook"
    static let promptSuppressedKey = "agentHooksPromptSuppressed"

    /// One part AccountDock adds to a provider CLI's configuration.
    struct Component: Hashable, Identifiable {
        enum Kind: String, CaseIterable {
            case lifecycle, liveUsageFeed, pauseGate, router
        }

        let provider: AIProviderType
        let kind: Kind
        var id: String { "\(provider.rawValue).\(kind.rawValue)" }

        var title: String {
            switch kind {
            case .lifecycle: "\(provider.rawValue) session hooks"
            case .liveUsageFeed: "\(provider.rawValue) live usage (status line)"
            case .pauseGate: "\(provider.rawValue) pause gate"
            case .router: "\(provider.capabilities.displayName) request router"
            }
        }

        var purpose: String {
            switch kind {
            case .lifecycle:
                "Records which session runs where, so sessions can be paused, restarted or recovered after a switch."
            case .liveUsageFeed:
                "Reads usage limits from every \(provider.rawValue) response instead of polling the usage API."
            case .pauseGate:
                "Holds sessions between tool calls when every account is at its limit."
            case .router:
                "Lets \(provider.rawValue)'s requests be served by a route target while every \(provider.capabilities.displayName) account is exhausted, and by several accounts at once."
            }
        }

        /// The components a provider can have, from its capabilities.
        static func offered(by provider: AIProviderType) -> [Component] {
            let capabilities = provider.capabilities
            var kinds: [Kind] = []
            if capabilities.lifecycleHooks != nil { kinds.append(.lifecycle) }
            if capabilities.liveUsageFeed != nil { kinds.append(.liveUsageFeed) }
            if capabilities.pauseGate != nil { kinds.append(.pauseGate) }
            if capabilities.requestRouter != nil { kinds.append(.router) }
            return kinds.map { Component(provider: provider, kind: $0) }
        }

        static var all: [Component] { AIProviderType.implementedProviders.flatMap(offered(by:)) }
    }

    struct Status: Identifiable, Equatable {
        let component: Component
        /// Whether the current settings and installed agents need this part.
        let required: Bool
        let installed: Bool
        var id: String { component.id }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// The JSON or TOML file a provider's lifecycle hooks go in.
    private static func lifecycleFileURL(_ provider: AIProviderType) -> URL? {
        provider.capabilities.lifecycleHooks.map { home.appendingPathComponent($0.hookFile) }
    }
    private static var managedCodexHomes: [URL] {
        let root = home.appendingPathComponent("Library/Application Support/AccountDock/managed-codex-homes")
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    private static var configuratorURL: URL {
        home.appendingPathComponent("Library/Application Support/AccountDock/bin/configure-hooks.js")
    }


    /// The bundled lifecycle script, addressed where this copy of the app runs.
    private static func lifecycleCommand(_ script: String) -> String? {
        guard let path = Bundle.main.url(forResource: script, withExtension: "sh")?.path else { return nil }
        return "/bin/sh \"\(path)\" \(lifecycleMarker)"
    }

    /// Whether the provider's CLI is installed: its configuration directory
    /// exists.
    private static func cliInstalled(_ provider: AIProviderType) -> Bool {
        FileManager.default.fileExists(atPath: (provider.configDirectory as NSString).expandingTildeInPath)
    }

    /// The wrapper a CLI that runs hooks through a shell calls.
    private static func shellHookScriptURL(_ provider: AIProviderType) -> URL {
        let key = provider.capabilities.pauseGate?.key ?? provider.capabilities.cliExecutableName ?? provider.rawValue
        return home.appendingPathComponent("Library/Application Support/AccountDock/bin/accountdock-\(key)-hook.sh")
    }

    /// A CLI that runs hooks through a shell gets a wrapper that finds the
    /// CLI process above it and records the session with the bundled
    /// recorder.
    private static func writeShellHookScript(_ provider: AIProviderType) throws {
        guard let recorder = Bundle.main.url(forResource: "accountdock-claude-hook", withExtension: "js")?.path,
              let executable = provider.capabilities.cliExecutableName,
              let key = provider.capabilities.pauseGate?.key else { throw missingResource }
        let url = shellHookScriptURL(provider)
        let script = """
        #!/bin/sh
        # AccountDock lifecycle hook for \(provider.rawValue).
        pid="$PPID"; agent="$PPID"; steps=0
        while [ "$pid" -gt 1 ] 2>/dev/null && [ "$steps" -lt 8 ]; do
            name=$(/bin/ps -p "$pid" -o comm= 2>/dev/null)
            case "$name" in */\(executable)|\(executable)) agent="$pid"; break ;; esac
            pid=$(/bin/ps -p "$pid" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')
            steps=$((steps + 1))
        done
        ACCOUNTDOCK_PROVIDER="\(key)" ACCOUNTDOCK_AGENT_PID="$agent" ACCOUNTDOCK_HOST="cli" \\
        exec /usr/bin/osascript -l JavaScript '\(recorder.replacingOccurrences(of: "'", with: "'\\''"))'

        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Further JSON hook files a provider's sessions read: Codex reads the
    /// hooks of the managed home it runs from.
    private static func additionalLifecycleFiles(_ provider: AIProviderType) -> [URL] {
        switch provider {
        case .codex: managedCodexHomes.map { $0.appendingPathComponent("hooks.json") }
        case .claudeCode, .kimi, .gemini: []
        }
    }

    // MARK: - Status

    /// Whether a setting of `provider` needs the router; read from the
    /// stored policy so the check also works off the main actor.
    private static func routes(_ provider: AIProviderType) -> Bool {
        FailoverConfigStore.storedPolicy(for: provider).usesRouter(for: provider)
    }

    static func statuses(pausingProviders: Set<AIProviderType>) -> [Status] {
        Component.all.map { component in
            let provider = component.provider
            let installedCLI = cliInstalled(provider)
            switch component.kind {
            case .lifecycle:
                return Status(component: component, required: installedCLI, installed: lifecycleInstalled(provider))
            case .liveUsageFeed:
                return Status(
                    component: component,
                    required: installedCLI && ClaudeStatusLineTelemetry.isEnabled,
                    installed: ClaudeStatusLineTelemetry.isInstalled()
                )
            case .pauseGate:
                return Status(
                    component: component,
                    required: installedCLI && pausingProviders.contains(provider),
                    installed: pauseGateInstalled(provider)
                )
            case .router:
                return Status(
                    component: component,
                    required: installedCLI && routes(provider),
                    installed: RequestRouterController.isInstalled()
                )
            }
        }
    }

    private static func lifecycleInstalled(_ provider: AIProviderType) -> Bool {
        guard let spec = provider.capabilities.lifecycleHooks, let url = lifecycleFileURL(provider) else { return false }
        switch spec.format {
        case .jsonHooks:
            return hasHooks(at: url, events: spec.events, marker: lifecycleMarker)
        case .tomlHooks:
            return TOMLHookConfig.hasHooks(at: url, events: spec.events, marker: lifecycleMarker)
                && FileManager.default.fileExists(atPath: shellHookScriptURL(provider).path)
        }
    }

    private static func pauseGateInstalled(_ provider: AIProviderType) -> Bool {
        guard let gate = provider.capabilities.pauseGate else { return false }
        let events = AgentPauseGate.gateEvents(provider)
        switch gate.format {
        case .jsonHooks:
            return hasHooks(at: home.appendingPathComponent(gate.hookFile), events: events, marker: AgentPauseGate.marker)
        case .tomlHooks:
            return TOMLHookConfig.hasHooks(at: home.appendingPathComponent(gate.hookFile), events: events, marker: AgentPauseGate.marker)
        }
    }

    static func missing(pausingProviders: Set<AIProviderType>) -> [Status] {
        statuses(pausingProviders: pausingProviders).filter { $0.required && !$0.installed }
    }

    /// Whether every listed event has a hook whose command carries `marker`
    /// and, for lifecycle hooks, still points at a script that exists.
    /// Whether a marked hook exists for every event; with `command` and
    /// `timeout`, each must also run that command with that timeout.
    static func hasHooks(at url: URL, events: [String], marker: String,
                         command expected: String? = nil, timeout: Int? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                    guard let command = hook["command"] as? String, command.contains(marker) else { return false }
                    if let expected, command != expected { return false }
                    if let timeout, (hook["timeout"] as? Int) != timeout { return false }
                    return scriptExists(in: command)
                }
            }
        }
    }

    /// The first quoted path in a hook command must exist; a hook left
    /// pointing at a moved or deleted app is reported as missing.
    private static func scriptExists(in command: String) -> Bool {
        for quote in ["\"", "'"] {
            let parts = command.components(separatedBy: quote)
            if parts.count >= 3, parts[1].hasPrefix("/") {
                return FileManager.default.fileExists(atPath: parts[1])
            }
        }
        return true
    }

    // MARK: - Install

    /// Installs every required part that is missing. With `reinstall`, every
    /// required part is removed and written again, which also repairs hooks
    /// that point at an old location of the app.
    @discardableResult
    static func install(pausingProviders: Set<AIProviderType>, reinstall: Bool = false) -> [Component: String] {
        var failures: [Component: String] = [:]
        for status in statuses(pausingProviders: pausingProviders) where status.required && (reinstall || !status.installed) {
            do {
                try install(status.component, pausingProviders: pausingProviders, reinstall: reinstall)
            } catch {
                failures[status.component] = error.localizedDescription
                hookLog.warning("\(status.component.title) install failed: \(error.localizedDescription)")
            }
        }
        return failures
    }

    private static func install(_ component: Component, pausingProviders: Set<AIProviderType>, reinstall: Bool) throws {
        let provider = component.provider
        switch component.kind {
        case .lifecycle:
            guard let spec = provider.capabilities.lifecycleHooks, let url = lifecycleFileURL(provider) else { return }
            switch spec.format {
            case .jsonHooks:
                guard let script = spec.bundledScript, let command = lifecycleCommand(script) else { throw missingResource }
                for file in [url] + additionalLifecycleFiles(provider) {
                    if reinstall {
                        try configure("uninstall", file, events: spec.events, command: command, timeout: spec.timeout, marker: lifecycleMarker)
                    }
                    try configure("install", file, events: spec.events, command: command, timeout: spec.timeout, marker: lifecycleMarker)
                }
            case .tomlHooks:
                try writeShellHookScript(provider)
                let path = shellHookScriptURL(provider).path.replacingOccurrences(of: "'", with: "'\\''")
                try TOMLHookConfig.install(at: url, events: spec.events, command: "/bin/sh '\(path)' \(lifecycleMarker)",
                                           timeout: spec.timeout, marker: lifecycleMarker)
            }
        case .liveUsageFeed:
            ClaudeStatusLineTelemetry.synchronize()
            if !ClaudeStatusLineTelemetry.isInstalled() {
                throw NSError(domain: "AgentHookInstaller", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The status-line wrapper could not be installed."
                ])
            }
        case .pauseGate:
            // The router runs while a feature of the routed provider uses it;
            // the request hold follows it, and the gate's command follows the hold.
            ProviderRequestHold.synchronize(enabledFor: pausingProviders, routerRunning: RequestRouterController.isInstalled())
            AgentPauseGate.synchronize(enabledFor: pausingProviders, rewrite: reinstall)
        case .router:
            try RequestRouterController.install()
        }
        hookLog.info("\(component.title) \(reinstall ? "reinstalled" : "installed")")
    }

    private static var missingResource: NSError {
        NSError(domain: "AgentHookInstaller", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The hook script is missing from the AccountDock app bundle."
        ])
    }

    /// Adds or removes hooks carrying `marker` for `events` in a JSON hooks
    /// file (`ProviderCapabilities` format `.jsonHooks`).
    static func configure(
        _ action: String,
        _ url: URL,
        events: [String],
        command: String,
        timeout: Int,
        marker: String
    ) throws {
        if action == "uninstall", !FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuratorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(configurator.utf8).write(to: configuratorURL, options: .atomic)
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l", "JavaScript", configuratorURL.path, action, url.path,
            events.joined(separator: ","), command, String(timeout), marker,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "AgentHookInstaller", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(detail.isEmpty ? "configurator exited \(process.terminationStatus)" : detail)"
            ])
        }
    }

    /// Edits a hooks file in place: other settings and their order are kept,
    /// an unreadable, empty or non-object file is never replaced, a symlink is
    /// followed, the first edit keeps a backup, and a file that changed while
    /// being edited is left alone.
    private static let configurator = #"""
    ObjC.import("Foundation");
    function readText(path) {
        const value = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
        if (!value || value.isNil()) throw new Error("could not read " + path);
        return ObjC.unwrap(value);
    }
    function modified(path) {
        const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(path, null);
        return attributes && !attributes.isNil() ? ObjC.unwrap(attributes.fileModificationDate.timeIntervalSince1970) : 0;
    }
    function run(argv) {
        const [action, linkedPath, eventList, command, timeout, marker] = argv;
        const manager = $.NSFileManager.defaultManager;
        const path = ObjC.unwrap($(linkedPath).stringByResolvingSymlinksInPath);
        const exists = manager.fileExistsAtPath(path);
        const before = exists ? modified(path) : 0;
        const text = exists ? readText(path) : "";
        if (exists && !text.trim()) throw new Error("file is empty");
        const settings = text ? JSON.parse(text) : {};
        if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
            throw new Error("file is not a JSON object");
        }
        if (!settings.hooks || typeof settings.hooks !== "object" || Array.isArray(settings.hooks)) settings.hooks = {};
        eventList.split(",").forEach((event) => {
            const groups = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];
            const kept = groups.filter((group) => !(group && Array.isArray(group.hooks) && group.hooks.some(
                (hook) => hook && typeof hook.command === "string" && hook.command.includes(marker))));
            if (action === "install") {
                const hook = { type: "command", command: command };
                if (Number(timeout) > 0) hook.timeout = Number(timeout);
                kept.push({ matcher: "", hooks: [hook] });
            }
            if (kept.length) settings.hooks[event] = kept; else delete settings.hooks[event];
        });
        if (exists) {
            const backup = path + ".accountdock-hooks-backup";
            if (!manager.fileExistsAtPath(backup)) manager.copyItemAtPathToPathError(path, backup, null);
            if (modified(path) !== before) throw new Error("file changed during update");
        }
        if (!$(JSON.stringify(settings, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
            throw new Error("could not write " + path);
        }
    }
    """#

    // MARK: - Launch check

    /// Offers to install missing parts once per launch, unless the user
    /// chose not to be asked again.
    @MainActor
    static func promptIfMissing(pausingProviders: Set<AIProviderType>) {
        guard !UserDefaults.standard.bool(forKey: promptSuppressedKey) else { return }
        let missing = missing(pausingProviders: pausingProviders)
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Install AccountDock's agent hooks?"
        alert.informativeText = "These parts are not installed:\n\n"
            + missing.map { "• \($0.component.title): \($0.component.purpose)" }.joined(separator: "\n")
            + "\n\nYou can reinstall them at any time in Settings."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: promptSuppressedKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        let failures = install(pausingProviders: pausingProviders)
        guard !failures.isEmpty else { return }
        let failed = NSAlert()
        failed.messageText = "Some hooks could not be installed"
        failed.informativeText = failures.map { "• \($0.key.title): \($0.value)" }.joined(separator: "\n")
        failed.runModal()
    }
}
