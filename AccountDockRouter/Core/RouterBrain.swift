import Foundation

/// Where one router keeps its files and which port it serves, so a router
/// built for a test runs beside the one the CLIs use. `standard` is the
/// launchd router's (`RouterConfig`); `RouterService` and `RouterBrain`
/// read every path from here.
struct RouterEnvironment: Sendable {
    var directory: URL
    var port: UInt16
    var logURL: URL

    static var standard: RouterEnvironment {
        RouterEnvironment(directory: RouterConfig.directory, port: RouterConfig.port, logURL: RouterConfig.logURL)
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var controlKeyURL: URL { directory.appendingPathComponent("control.key") }
    var usageDirectory: URL { directory.appendingPathComponent("usage", isDirectory: true) }
    var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }
    var signaturesURL: URL { directory.appendingPathComponent("signatures.txt") }
    var passthroughURL: URL { directory.appendingPathComponent("passthrough.json") }
    /// The pause gate's directory, beside the router's.
    var pauseDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("Pause", isDirectory: true) }
}

/// Appends timestamped lines to the router's log file.
final class RouterLog: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL

    init(url: URL) { self.url = url }

    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        RouterFiles.append(Data(line.utf8), to: url)
    }
}

enum RouterFiles {
    /// Appends `data` to the file at `url`, creating it when missing.
    static func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// What a router knows of a session between its requests: the backend and
/// pool account that last served it, when, and how long that request asked
/// its prompt cache to last. Read by `RouterLogic.planMessages`.
struct RouterSessionRecord: Equatable, Sendable {
    var backend: String
    var account: String?
    var lastServed: Date
    var cacheLifetime: TimeInterval?
}

/// What the router knows between requests: the app's state, tokens, the
/// issuer of every thinking block it has seen, each session's backend and
/// account, and pool accounts it found refused. The app owns state and
/// tokens; the router appends events, signatures and usage. `now` is the
/// clock every expiry is judged by.
final class RouterBrain: @unchecked Sendable {
    let environment: RouterEnvironment
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state = RouterState()
    private var stateModified: Date?
    private var issuers: [String: String] = [:]
    private var sessions: [String: RouterSessionRecord] = [:]
    private var refused: [String: Date] = [:]
    private var contexts: [String: Int] = [:]
    private var refusedBackends: [String: Date] = [:]
    private var tokens: [String: RouterToken] = [:]
    private var allowedCredentials: Set<String> = []
    /// Set once Anthropic rejected thinking signed for another of its
    /// accounts; from then on such blocks are removed before sending.
    private(set) var accountsRejectEachOthersThinking = false
    /// Last time a client request arrived, so the app can retire a router no
    /// session uses any more.
    private(set) var lastRequestAt: Date

    init(environment: RouterEnvironment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
        lastRequestAt = now()
        try? FileManager.default.createDirectory(at: environment.usageDirectory, withIntermediateDirectories: true)
        if let text = try? String(contentsOf: environment.signaturesURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line == "! cross-account" { accountsRejectEachOthersThinking = true; continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { issuers[parts[0]] = parts[1] }
            }
        }
    }

    func noteRequest() {
        lock.lock(); defer { lock.unlock() }
        lastRequestAt = now()
    }

    func currentState() -> RouterState {
        lock.lock(); defer { lock.unlock() }
        let url = environment.stateURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != stateModified {
            stateModified = modified
            if let data = try? Data(contentsOf: url),
               let decoded = try? RouterConfig.decoder().decode(RouterState.self, from: data) {
                state = decoded
            } else if modified == nil {
                state = RouterState()
            }
        }
        return state
    }

    func token(_ name: String?) -> RouterToken? {
        guard let name else { return nil }
        lock.lock(); defer { lock.unlock() }
        return tokens[name]
    }

    /// Replaces the credentials the app pushed; they live only in memory.
    func setCredentials(_ credentials: RouterCredentials) {
        lock.lock(); defer { lock.unlock() }
        tokens = credentials.tokens
        allowedCredentials = credentials.allowedCredentials
    }

    var credentialCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tokens.count
    }

    func isAllowed(_ fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        lock.lock(); defer { lock.unlock() }
        return allowedCredentials.contains(fingerprint)
    }

    /// The control key, read when the app pushes credentials.
    func controlKey() -> String? {
        (try? String(contentsOf: environment.controlKeyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func issuerMap() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return issuers
    }

    func record(signatures new: [String], issuer: String) {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var lines = ""
        for signature in new {
            let key = RouterLogic.signatureKey(signature)
            if issuers[key] == issuer { continue }
            issuers[key] = issuer
            lines += "\(key) \(issuer)\n"
        }
        guard !lines.isEmpty else { return }
        // Signatures matter only while their turns remain in some session's
        // history; the list is rewritten when it grows large.
        if issuers.count > 60_000 {
            issuers = Dictionary(uniqueKeysWithValues: issuers.shuffled().prefix(30_000).map { ($0.key, $0.value) })
            var text = accountsRejectEachOthersThinking ? "! cross-account\n" : ""
            for (key, value) in issuers { text += "\(key) \(value)\n" }
            try? text.write(to: environment.signaturesURL, atomically: true, encoding: .utf8)
        } else {
            RouterFiles.append(Data(lines.utf8), to: environment.signaturesURL)
        }
    }

    func noteCrossAccountRejection() {
        lock.lock(); defer { lock.unlock() }
        guard !accountsRejectEachOthersThinking else { return }
        accountsRejectEachOthersThinking = true
        RouterFiles.append(Data("! cross-account\n".utf8), to: environment.signaturesURL)
    }

    func session(_ id: String?) -> RouterSessionRecord? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    /// Context tokens of the session's last served request, for route
    /// targets that serve sessions only up to a size.
    func sessionContext(_ id: String?) -> Int? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return contexts[id]
    }

    func noteContext(_ id: String?, tokens: Int) {
        guard let id, tokens > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        contexts[id] = tokens
        if contexts.count > 2_000 { contexts = contexts.filter { sessions[$0.key] != nil } }
    }

    func setSession(_ id: String?, backend: String, account: String?, cacheLifetime: TimeInterval?) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        let date = now()
        sessions[id] = RouterSessionRecord(backend: backend, account: account, lastServed: date, cacheLifetime: cacheLifetime)
        if sessions.count > 2_000 {
            let cutoff = date.addingTimeInterval(-6 * 60 * 60)
            sessions = sessions.filter { $0.value.lastServed > cutoff }
        }
    }

    /// Sessions served by each pool account in the last ten minutes.
    func poolLoad() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-10 * 60)
        var load: [String: Int] = [:]
        for session in sessions.values where session.lastServed > cutoff {
            if let account = session.account { load[account, default: 0] += 1 }
        }
        return load
    }

    func refuse(_ account: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        refused[account] = until
    }

    func refusedAccounts() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let date = now()
        refused = refused.filter { $0.value > date }
        return Set(refused.keys)
    }

    /// Route targets that refused at their plan limit are skipped until the
    /// time given, so sessions stop reaching them before the app reacts.
    func refuseBackend(_ backend: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        refusedBackends[backend] = until
    }

    func refusedBackendIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let date = now()
        refusedBackends = refusedBackends.filter { $0.value > date }
        return Set(refusedBackends.keys)
    }

    /// Appends an event for the app, which reads `events.jsonl` back.
    func event(_ event: RouterEvent) {
        guard var line = try? RouterConfig.encoder().encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        RouterFiles.append(line, to: environment.eventsURL)
    }

    func usage(_ observation: RouterUsageObservation) {
        guard let data = try? RouterConfig.encoder().encode(observation) else { return }
        try? data.write(to: environment.usageDirectory.appendingPathComponent("\(observation.credential).json"), options: .atomic)
    }
}
