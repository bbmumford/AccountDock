import Foundation
import Security

private let routerLog = FileLog("Router")

/// Installs and drives `AccountDockRouter`, the local endpoint the routed
/// provider's CLI (`AIProviderType.routedProvider`) reaches through the base
/// URL variable its `RequestRouterSupport` names.
///
/// - The router runs as a `launchd` agent so the CLI keeps working when the
///   app quits; `launchd` restarts it if it exits.
/// - The CLI's settings file gains the base URL in its `env`; only sessions
///   started afterwards use the router.
/// - The app writes the route and current credentials; the router appends
///   events the app reads back.
enum RequestRouterController {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var client: RequestRouterSupport? { AIProviderType.routedProvider?.capabilities.requestRouter }
    private static var clientName: String { AIProviderType.routedProvider?.rawValue ?? "The CLI" }
    private static var settingsURL: URL? { client.map { home.appendingPathComponent($0.settingsFile) } }
    private static var agentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(RouterConfig.launchAgentLabel).plist")
    }
    private static var configuratorURL: URL {
        home.appendingPathComponent("Library/Application Support/AccountDock/bin/configure-router-env.js")
    }
    static var executableURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AccountDockRouter")
    }

    // MARK: - Status

    /// The CLI's configured base URL, when one is set.
    static func configuredBaseURL() -> String? {
        guard let client, let settingsURL, let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return nil }
        return env[client.baseURLVariable] as? String
    }

    static func isInstalled() -> Bool {
        configuredBaseURL() == RouterConfig.baseURL && FileManager.default.fileExists(atPath: agentURL.path)
    }

    static var agentInstalled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    /// Keeps the router present exactly while a feature needs it.
    ///
    /// Wanted: installed if missing, and restarted when it runs an older
    /// build. Not wanted: the CLI stops using it at once, and the router
    /// itself stops once no request has arrived for `retireAfter`, because
    /// sessions started while it was configured still send their requests to
    /// it until they end.
    static func reconcile(wanted: Bool, retireAfter: TimeInterval = 30 * 60) async throws {
        removeLegacyTokenFiles()
        if wanted {
            if !isInstalled() { try install() } else { await ensureCurrent() }
            return
        }
        if configuredBaseURL() == RouterConfig.baseURL { try configureEnv("uninstall") }
        // Every CLI sent here is pointed back at its provider before the
        // router can be retired.
        ProviderRequestHold.synchronize(enabledFor: [], routerRunning: false)
        apply(RouterState())
        guard agentInstalled else { return }
        let health = await health()
        guard health == nil || TimeInterval(health?.idleSeconds ?? 0) >= retireAfter else { return }
        retire()
    }

    /// Stops and removes the router and every credential file it used.
    static func retire() {
        _ = try? launchctl(["bootout", "gui/\(getuid())/\(RouterConfig.launchAgentLabel)"])
        try? FileManager.default.removeItem(at: agentURL)
        retainTokens([], allowedCredentials: [])
        removeLegacyTokenFiles()
        try? FileManager.default.removeItem(at: RouterConfig.usageDirectory)
        try? FileManager.default.removeItem(at: RouterConfig.controlKeyURL)
        routerLog.info("Router stopped and removed; no feature uses it and no session sent a request for 30 minutes")
    }

    struct Health: Equatable {
        let route: String
        let build: String
        /// Seconds since a client request last arrived.
        let idleSeconds: Int
        /// Credentials the router holds in memory.
        let credentials: Int
    }

    static func health() async -> Health? {
        guard let url = URL(string: RouterConfig.baseURL + "/__accountdock/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Health(
            route: root["route"] as? String ?? RouterBackend.anthropic.id,
            build: root["build"] as? String ?? "",
            idleSeconds: root["idleSeconds"] as? Int ?? 0,
            credentials: root["credentials"] as? Int ?? 0
        )
    }

    /// Modification time of the router bundled with this copy of the app.
    static var bundledBuild: String? {
        guard let path = executableURL?.path,
              let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return nil }
        return String(Int(date.timeIntervalSince1970))
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case missingExecutable
        case conflictingBaseURL(String)
        case launchctl(String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable: "The router is missing from the AccountDock app bundle."
            case .conflictingBaseURL(let url): "\(clientName) already sends its requests to \(url); AccountDock will not replace another gateway."
            case .launchctl(let detail): "The router could not be started: \(detail)"
            }
        }
    }

    static func install() throws {
        guard let executable = executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstallError.missingExecutable
        }
        if let existing = configuredBaseURL(), existing != RouterConfig.baseURL {
            throw InstallError.conflictingBaseURL(existing)
        }
        try FileManager.default.createDirectory(at: RouterConfig.directory, withIntermediateDirectories: true)
        _ = try controlKey()
        removeLegacyTokenFiles()
        try writeAgent(executable: executable)
        try restartAgent()
        try configureEnv("install")
        routerLog.info("Router installed; new \(clientName) sessions send requests through \(RouterConfig.baseURL)")
    }

    /// New sessions stop using the router. The agent keeps running so sessions
    /// started while it was configured continue to work.
    static func removeFromClient() throws {
        try configureEnv("uninstall")
        apply(RouterState())
        retainTokens([], allowedCredentials: [])
    }

    /// Restarts the agent when it runs a router from another build.
    static func ensureCurrent() async {
        guard FileManager.default.fileExists(atPath: agentURL.path), let bundled = bundledBuild else { return }
        if let executable = executableURL, (try? agentProgram()) != executable.path {
            try? writeAgent(executable: executable)
            try? restartAgent()
            return
        }
        let running = await health()
        if running == nil || running?.build != bundled {
            routerLog.info("Restarting router: running build \(running?.build ?? "none"), bundled \(bundled)")
            do {
                try restartInPlace()
            } catch {
                routerLog.warning("Router restart failed: \(error.localizedDescription); reloading the agent")
                try? restartAgent()
            }
        }
    }

    private static func agentProgram() throws -> String? {
        let data = try Data(contentsOf: agentURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (plist?["ProgramArguments"] as? [String])?.first
    }

    private static func writeAgent(executable: URL) throws {
        let plist: [String: Any] = [
            "Label": RouterConfig.launchAgentLabel,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardErrorPath": RouterConfig.logURL.path,
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }

    private static var serviceTarget: String { "gui/\(getuid())/\(RouterConfig.launchAgentLabel)" }

    /// Restarts the loaded agent's process on the binary its definition names,
    /// without unloading it, so the port is free for the shortest time.
    private static func restartInPlace() throws {
        try launchctl(["kickstart", "-k", serviceTarget])
    }

    /// Loads the agent definition afresh, for a new or changed definition.
    /// `bootout` returns before launchd has finished unloading, and a
    /// `bootstrap` issued meanwhile fails, so the unload is awaited and the
    /// load retried.
    private static func restartAgent() throws {
        _ = try? launchctl(["bootout", serviceTarget])
        for _ in 0..<50 where (try? launchctl(["print", serviceTarget])) != nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                try launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
            }
        }
        if let lastError { throw lastError }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw InstallError.launchctl(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    private static func configureEnv(_ action: String) throws {
        try FileManager.default.createDirectory(at: configuratorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(envConfigurator.utf8).write(to: configuratorURL, options: .atomic)
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        guard let client, let settingsURL else { return }
        process.arguments = [
            "-l", "JavaScript", configuratorURL.path, action, settingsURL.path, RouterConfig.baseURL, client.baseURLVariable,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InstallError.launchctl("\(settingsURL.lastPathComponent): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Sets or removes the base URL variable in the settings file's `env`,
    /// touching nothing else; a base URL that is not the router's is never
    /// removed or replaced.
    private static let envConfigurator = #"""
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
        const [action, linkedPath, url, name] = argv;
        const manager = $.NSFileManager.defaultManager;
        const path = ObjC.unwrap($(linkedPath).stringByResolvingSymlinksInPath);
        const exists = manager.fileExistsAtPath(path);
        const before = exists ? modified(path) : 0;
        const text = exists ? readText(path) : "";
        if (exists && !text.trim()) throw new Error("file is empty");
        const settings = text ? JSON.parse(text) : {};
        if (typeof settings !== "object" || settings === null || Array.isArray(settings)) throw new Error("not a JSON object");
        const env = settings.env && typeof settings.env === "object" && !Array.isArray(settings.env) ? settings.env : {};
        if (action === "install") {
            if (env[name] && env[name] !== url) throw new Error("another base URL is configured");
            if (env[name] === url) return;
            env[name] = url;
            settings.env = env;
        } else {
            if (env[name] !== url) return;
            delete env[name];
            if (Object.keys(env).length) settings.env = env; else delete settings.env;
        }
        if (exists) {
            const backup = path + ".accountdock-router-backup";
            if (!manager.fileExistsAtPath(backup)) manager.copyItemAtPathToPathError(path, backup, null);
            if (modified(path) !== before) throw new Error("file changed during update");
        }
        if (!$(JSON.stringify(settings, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
            throw new Error("could not write " + path);
        }
    }
    """#

    // MARK: - State

    static func currentState() -> RouterState? {
        guard let data = try? Data(contentsOf: RouterConfig.stateURL) else { return nil }
        return try? RouterConfig.decoder().decode(RouterState.self, from: data)
    }

    /// Writes the state when anything other than its timestamp changed, so
    /// the router reloads only real changes.
    static func apply(_ state: RouterState) {
        var comparable = currentState()
        comparable?.updatedAt = state.updatedAt
        guard comparable != state else { return }
        var next = state
        next.updatedAt = Date()
        write(next, to: RouterConfig.stateURL)
    }

    // MARK: - Credentials

    /// Credentials the router needs, held in this process and pushed to the
    /// router, which keeps them in memory only; neither writes them to disk.
    private final class CredentialStore: @unchecked Sendable {
        let lock = NSLock()
        var tokens: [String: RouterToken] = [:]
        var allowed: Set<String> = []
        var pushed: RouterCredentials?
        var pushedAt: Date?
    }
    private static let store = CredentialStore()

    static func setToken(_ name: String, token: String, expiresAt: Date) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.tokens[name] = RouterToken(accessToken: token, expiresAt: expiresAt)
    }

    static func token(_ name: String) -> RouterToken? {
        store.lock.lock(); defer { store.lock.unlock() }
        return store.tokens[name]
    }

    /// Keeps only the named credentials and records which client credentials
    /// may use pool accounts and route targets.
    static func retainTokens(_ names: Set<String>, allowedCredentials: Set<String>) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.tokens = store.tokens.filter { names.contains($0.key) }
        store.allowed = allowedCredentials
    }

    /// Sends the credentials when they changed, every five minutes, and
    /// whenever the router reports none, as after a restart.
    static func pushCredentials(force: Bool = false) async {
        let (credentials, due) = store.lock.withLock {
            let credentials = RouterCredentials(tokens: store.tokens, allowedCredentials: store.allowed)
            let due = force || store.pushed != credentials || (store.pushedAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? true)
            return (credentials, due)
        }
        var needed = due
        if !needed, let health = await health(), health.credentials < credentials.tokens.count { needed = true }
        guard needed, let key = try? controlKey(), let url = URL(string: RouterConfig.baseURL + "/__accountdock/credentials"),
              let body = try? RouterConfig.encoder().encode(credentials) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue(key, forHTTPHeaderField: RouterConfig.controlHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        store.lock.withLock {
            store.pushed = credentials
            store.pushedAt = Date()
        }
    }

    /// The control key, created on first use and readable only by the user.
    private static func controlKey() throws -> String {
        if let existing = try? String(contentsOf: RouterConfig.controlKeyURL, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw InstallError.launchctl("could not create the router control key")
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: RouterConfig.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(key.utf8).write(to: RouterConfig.controlKeyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: RouterConfig.controlKeyURL.path)
        return key
    }

    /// Credential files written by earlier builds are deleted.
    static func removeLegacyTokenFiles() {
        try? FileManager.default.removeItem(at: RouterConfig.legacyTokensDirectory)
        try? FileManager.default.removeItem(at: RouterConfig.directory.appendingPathComponent("kimi-token.json"))
        try? FileManager.default.removeItem(at: RouterConfig.directory.appendingPathComponent("kimi-signatures.txt"))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try RouterConfig.encoder().encode(value).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            routerLog.warning("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Router events appended since `offset`, and the offset to read from next.
    static func events(after offset: UInt64) -> ([RouterEvent], UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: RouterConfig.eventsURL) else { return ([], 0) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = offset > end ? 0 : offset
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let decoder = RouterConfig.decoder()
        let events = data.split(separator: 0x0A).compactMap { try? decoder.decode(RouterEvent.self, from: Data($0)) }
        // The file is trimmed once it is large; the app reads it every cycle.
        if end > 4_000_000, let tail = try? Data(contentsOf: RouterConfig.eventsURL).suffix(200_000) {
            try? Data(tail).write(to: RouterConfig.eventsURL, options: .atomic)
            return (events, UInt64(tail.count))
        }
        return (events, end)
    }

    /// Usage the router saw in response headers, one per credential.
    static func usageObservations() -> [RouterUsageObservation] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: RouterConfig.usageDirectory.path)) ?? []
        let decoder = RouterConfig.decoder()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: RouterConfig.usageDirectory.appendingPathComponent(name)) else { return nil }
            return try? decoder.decode(RouterUsageObservation.self, from: data)
        }
    }
}
