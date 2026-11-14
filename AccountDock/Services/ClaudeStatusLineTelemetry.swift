import Foundation

private let telemetryLog = FileLog("StatusLine")

/// Installs a status-line wrapper that records the live rate limits Claude
/// Code passes to its status-line command after every response, then runs the
/// command that was configured before it with the same input and output.
///
/// The recorded files are read by `PassiveUsageTelemetry`, which lets the
/// failover monitor follow the active Claude account without calling the
/// usage endpoint.
enum ClaudeStatusLineTelemetry {
    static let preferenceKey = "claudeStatusLineTelemetry"
    static let marker = "# accountdock-statusline"

    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock", isDirectory: true)
    }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("bin/accountdock-statusline.sh") }
    static var nextCommandURL: URL { supportDirectory.appendingPathComponent("statusline-next.command") }
    private static var configuratorURL: URL { supportDirectory.appendingPathComponent("bin/configure-statusline.js") }
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command.contains(marker)
    }

    /// Applies the user's preference. Safe to call repeatedly.
    static func synchronize() {
        do {
            if isEnabled {
                try writeScript()
                if !isInstalled() { try runConfigurator("install") }
            } else if isInstalled() {
                try runConfigurator("uninstall")
            }
        } catch {
            telemetryLog.warning("Status-line telemetry update failed: \(error.localizedDescription)")
        }
    }

    private static func writeScript() throws {
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func runConfigurator(_ action: String) throws {
        try Data(configurator.utf8).write(to: configuratorURL, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l", "JavaScript", configuratorURL.path, action,
            settingsURL.path, scriptURL.path, nextCommandURL.path, marker,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ClaudeStatusLineTelemetry",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "status-line configurator exited \(process.terminationStatus)"]
            )
        }
        telemetryLog.info("Status-line telemetry \(action) completed")
    }

    /// Writes only the session's own status-line payload. The payload carries
    /// model, workspace, cost and rate-limit metadata; prompt and transcript
    /// content are not part of it. A session in a one-session slot also
    /// leaves the slot directory it reads (Claude Code's
    /// `SessionSlotSupport.directoryVariable`) beside it, so
    /// `PassiveUsageTelemetry` can name the session of a slot whose process
    /// left no session record.
    private static let script = #"""
    #!/bin/sh
    dir="$HOME/Library/Application Support/AccountDock/Telemetry"
    next_file="$HOME/Library/Application Support/AccountDock/statusline-next.command"
    payload=$(/bin/cat)
    sid=$(printf '%s' "$payload" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' | /usr/bin/head -n 1)
    [ -n "$sid" ] || sid="$PPID"
    /bin/mkdir -p "$dir" 2>/dev/null
    tmp="$dir/.claude-$sid.$$"
    if printf '%s' "$payload" > "$tmp" 2>/dev/null; then
        /bin/mv -f "$tmp" "$dir/claude-$sid.json" 2>/dev/null
    fi
    if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ]; then
        printf '%s' "$CLAUDE_SECURESTORAGE_CONFIG_DIR" > "$dir/claude-$sid.slot" 2>/dev/null
    fi
    pause="$HOME/Library/Application Support/AccountDock/Pause/claude.json"
    if [ -f "$pause" ] && /usr/bin/grep -q "\"$sid\"" "$pause" 2>/dev/null; then
        printf '%s\n' "⏸ Paused by AccountDock: every account is at its usage limit"
    fi
    if [ -s "$next_file" ]; then
        printf '%s' "$payload" | /bin/sh -c "$(/bin/cat "$next_file")"
    fi
    """#

    /// Edits `~/.claude/settings.json` in place with JavaScript so key order
    /// and every unrelated setting are preserved.
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
    function writeText(path, text) {
        if (!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
            throw new Error("could not write " + path);
        }
    }
    function run(argv) {
        const [action, linkedSettingsPath, scriptPath, nextPath, marker] = argv;
        const manager = $.NSFileManager.defaultManager;
        // A symlinked settings file is edited where it lives, so the link survives.
        const settingsPath = ObjC.unwrap($(linkedSettingsPath).stringByResolvingSymlinksInPath);
        const exists = manager.fileExistsAtPath(settingsPath);
        const before = exists ? modified(settingsPath) : 0;
        const text = exists ? readText(settingsPath) : "";
        // An existing file that is empty or does not parse is never replaced.
        if (exists && !text.trim()) throw new Error("settings file is empty");
        const settings = text ? JSON.parse(text) : {};
        if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
            throw new Error("settings file is not a JSON object");
        }
        const current = settings.statusLine && typeof settings.statusLine === "object" ? settings.statusLine : null;
        const installed = current && typeof current.command === "string" && current.command.includes(marker);
        if (action === "install") {
            if (installed) return;
            const backup = settingsPath + ".accountdock-statusline-backup";
            if (text && !manager.fileExistsAtPath(backup)) writeText(backup, text);
            const previous = current && current.type === "command" && typeof current.command === "string"
                ? current.command : "";
            writeText(nextPath, previous);
            settings.statusLine = Object.assign({}, current || {}, {
                type: "command",
                command: "/bin/sh '" + scriptPath.replace(/'/g, "'\\''") + "' " + marker
            });
        } else if (action === "uninstall") {
            if (!installed) return;
            const previous = manager.fileExistsAtPath(nextPath) ? readText(nextPath).trim() : "";
            if (previous) {
                settings.statusLine = Object.assign({}, current, { command: previous });
            } else {
                delete settings.statusLine;
            }
            manager.removeItemAtPathError(nextPath, null);
        }
        // Claude Code may have rewritten its settings meanwhile; its write wins
        // and the change is applied on the next launch instead.
        if (exists && modified(settingsPath) !== before) throw new Error("settings changed during update");
        writeText(settingsPath, JSON.stringify(settings, null, 2) + "\n");
    }
    """#
}
