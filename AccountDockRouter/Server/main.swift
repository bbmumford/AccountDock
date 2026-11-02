import Foundation
import Network

// AccountDockRouter: the local endpoint Claude Code reaches through
// `ANTHROPIC_BASE_URL`. `launchd` keeps it running independently of the
// AccountDock app, so Claude Code sessions keep working when the app quits.

// MARK: - Shared state

final class RouterLog: @unchecked Sendable {
    private let lock = NSLock()
    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        append(Data(line.utf8), to: RouterConfig.logURL)
    }
}

func append(_ data: Data, to url: URL) {
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

/// What the router knows between requests: the app's state, tokens, the
/// issuer of every thinking block it has seen, each session's backend and
/// account, and pool accounts it found refused. The app owns state and
/// tokens; the router appends events, signatures and usage.
final class RouterBrain: @unchecked Sendable {
    private struct Session {
        var backend: String
        var account: String?
        var lastSeen: Date
        var context: Int?
        var cacheLifetime: TimeInterval?
    }

    private let lock = NSLock()
    private var state = RouterState()
    private var stateModified: Date?
    private var issuers: [String: String] = [:]
    private var sessions: [String: Session] = [:]
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
    private(set) var lastRequestAt = Date()

    func noteRequest() {
        lock.lock(); defer { lock.unlock() }
        lastRequestAt = Date()
    }

    init() {
        try? FileManager.default.createDirectory(at: RouterConfig.usageDirectory, withIntermediateDirectories: true)
        if let text = try? String(contentsOf: RouterConfig.signaturesURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line == "! cross-account" { accountsRejectEachOthersThinking = true; continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { issuers[parts[0]] = parts[1] }
            }
        }
    }

    func currentState() -> RouterState {
        lock.lock(); defer { lock.unlock() }
        let modified = (try? RouterConfig.stateURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != stateModified {
            stateModified = modified
            if let data = try? Data(contentsOf: RouterConfig.stateURL),
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
        (try? String(contentsOf: RouterConfig.controlKeyURL, encoding: .utf8))?
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
            try? text.write(to: RouterConfig.signaturesURL, atomically: true, encoding: .utf8)
        } else {
            append(Data(lines.utf8), to: RouterConfig.signaturesURL)
        }
    }

    func noteCrossAccountRejection() {
        lock.lock(); defer { lock.unlock() }
        guard !accountsRejectEachOthersThinking else { return }
        accountsRejectEachOthersThinking = true
        append(Data("! cross-account\n".utf8), to: RouterConfig.signaturesURL)
    }

    func session(_ id: String?) -> (backend: String, account: String?)? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessions[id].map { ($0.backend, $0.account) }
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

    /// When the session's last request was served, and how long it asked
    /// its prompt cache to last.
    func sessionCache(_ id: String?) -> (lastServed: Date, lifetime: TimeInterval?)? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessions[id].map { ($0.lastSeen, $0.cacheLifetime) }
    }

    func setSession(_ id: String?, backend: String, account: String?, cacheLifetime: TimeInterval?) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        sessions[id] = Session(backend: backend, account: account, lastSeen: Date(), cacheLifetime: cacheLifetime)
        if sessions.count > 2_000 {
            let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
            sessions = sessions.filter { $0.value.lastSeen > cutoff }
        }
    }

    /// Sessions served by each pool account in the last ten minutes.
    func poolLoad() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-10 * 60)
        var load: [String: Int] = [:]
        for session in sessions.values where session.lastSeen > cutoff {
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
        let now = Date()
        refused = refused.filter { $0.value > now }
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
        let now = Date()
        refusedBackends = refusedBackends.filter { $0.value > now }
        return Set(refusedBackends.keys)
    }

    func event(_ event: RouterEvent) {
        guard var line = try? RouterConfig.encoder().encode(event) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        append(line, to: RouterConfig.eventsURL)
    }

    func usage(_ observation: RouterUsageObservation) {
        guard let data = try? RouterConfig.encoder().encode(observation) else { return }
        try? data.write(to: RouterConfig.usageDirectory.appendingPathComponent("\(observation.credential).json"), options: .atomic)
    }
}

let log = RouterLog()
let brain = RouterBrain()
/// Modification time of this executable, which the app compares with the
/// bundled copy to restart a router left running from an older build.
let buildStamp: String = {
    let path = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
    let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    return date.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
}()
/// Upstream sessions, one per URLSession so each holds its own connection.
/// `UpstreamConnections` decides which serves a request: a Claude Code
/// session keeps its own between turns, and every retry gets a fresh one,
/// so one dropped link fails only the requests of the session that used it.
enum Upstream {
    private static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration)
    }

    private static let connections = UpstreamConnections<URLSession>(
        idleLimit: 10 * 60,
        make: make,
        retire: { $0.finishTasksAndInvalidate() }
    )

    /// Transport failures that happen before any response arrives and that a
    /// fresh connection can cure.
    static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static let retryDelays: [Double] = [0.25, 1, 3]

    /// Sends the request and returns the response head, retrying transport
    /// failures that leave nothing sent to the client.
    static func open(_ request: URLRequest, client: String?) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var attempt = 0
        while true {
            do {
                let (session, oneOff) = connections.connection(for: client, attempt: attempt)
                // A one-off session closes once its request ends, streamed
                // body included.
                defer { if oneOff { session.finishTasksAndInvalidate() } }
                return try await session.bytes(for: request)
            } catch {
                guard isRetryable(error), attempt < retryDelays.count else { throw error }
                log.write("\(request.url?.host ?? "upstream") \(request.url?.path ?? "") attempt \(attempt + 1) failed, retrying on a new connection: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

// MARK: - Routing

/// One attempt to serve a request from one backend, with one credential.
struct Attempt {
    var backend: RouterBackend
    var account: String?
    var token: String?
    var body: [String: Any]
}

enum Router {
    static let hopHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "accept-encoding",
        "keep-alive", "proxy-connection", "upgrade", "te",
    ]

    static func handle(_ request: HTTPRequest, _ writer: ResponseWriter) async {
        let path = request.target.split(separator: "?").first.map(String.init) ?? request.target
        let state = brain.currentState()
        guard RouterLogic.isLocalClientRequest(request.headers, port: RouterConfig.port) else {
            await writer.complete(403, json: RouterLogic.errorBody(type: "permission_error", message: "AccountDock router serves local programs only"))
            return
        }
        if request.method == "GET", path == "/__accountdock/health" {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "version": RouterConfig.version, "route": state.route, "primary": state.primary,
                "pool": state.pool.count, "build": buildStamp, "credentials": brain.credentialCount,
                "idleSeconds": Int(Date().timeIntervalSince(brain.lastRequestAt)),
            ])) ?? Data()
            await writer.complete(200, json: body)
            return
        }
        if request.method == "POST", path == "/__accountdock/credentials" {
            guard let key = brain.controlKey(), !key.isEmpty, request.header(RouterConfig.controlHeader) == key,
                  let credentials = try? RouterConfig.decoder().decode(RouterCredentials.self, from: request.body) else {
                await writer.complete(403, json: RouterLogic.errorBody(type: "permission_error", message: "Invalid control request"))
                return
            }
            brain.setCredentials(credentials)
            await writer.complete(200, json: Data(#"{"ok":true}"#.utf8))
            return
        }
        brain.noteRequest()
        if let (key, rest) = ProviderPassthrough.split(request.target) {
            await passthrough(request, key: key, rest: rest, writer: writer)
            return
        }
        // Pool accounts and route targets serve only clients that already
        // hold one of the user's own account credentials.
        let trusted = brain.isAllowed(RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
        guard request.method == "POST", path == "/v1/messages", trusted,
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let primary = state.backend(state.primary) else {
            await forwardRaw(request, state: state, writer: writer, trusted: trusted)
            return
        }
        let session = RouterLogic.sessionID(json)
        let startsTurn = RouterLogic.startsTurn(json)
        let previous = brain.session(session)
        let requestedContext = RouterLogic.expectedContext(lastMeasured: brain.sessionContext(session), bodyBytes: request.body.count)
        // A large context asks for the one-hour cache, so an idle spell of
        // over five minutes does not write it all again.
        let extendCache = state.extendedCacheMinimumContext.map { requestedContext >= $0 } ?? false
        let requestedLifetime = RouterLogic.cacheLifetime(json)
        let cacheLifetime = extendCache ? requestedLifetime.map { _ in TimeInterval(60 * 60) } : requestedLifetime
        let cache = brain.sessionCache(session)
        // A session whose prompt cache has expired has nothing to lose by
        // moving, so its next turn is placed like a new session's.
        let cacheExpired = state.cacheAwareSessions && cache.map {
            Date().timeIntervalSince($0.lastServed) > ($0.lifetime ?? cacheLifetime ?? 5 * 60)
        } ?? false
        let move = session.flatMap { state.moves[$0] }
        let skipped = brain.refusedBackendIDs()
        let context = requestedContext
        // A route target serves only sessions within its context cap and
        // before it refused at its limit; others stay on the primary.
        func serves(_ candidate: RouterBackend) -> Bool {
            !skipped.contains(candidate.id) && candidate.maxContextTokens.map { context <= $0 } ?? true
        }
        let desired = state.backend(state.route).flatMap { serves($0) ? $0 : nil } ?? primary
        let backendID = RouterLogic.backend(
            desired: desired.id,
            turnBackend: previous?.backend,
            startsTurn: startsTurn,
            desiredValidatesThinking: desired.validatesThinkingSignatures
        )
        let backend = state.backend(backendID).flatMap { $0.id == primary.id || serves($0) ? $0 : nil } ?? primary
        var attempts = backend.id == primary.id
            ? primaryAttempts(json, primary: primary, state: state, previous: previous, startsTurn: startsTurn,
                              move: move, cacheExpired: cacheExpired)
            : [Attempt(backend: backend, account: nil, token: nil, body: json)]
        if let fallback = state.backend(state.fallback), fallback.id != backend.id, serves(fallback) {
            attempts.append(Attempt(backend: fallback, account: nil, token: nil, body: json))
        }
        // The account is recorded once the response is served; refusing at a
        // limit does not assign the session. A route target never gives the
        // final answer: when it refuses, the pool answers after it, so a
        // session out of every option gets Anthropic's own limit reply, whose
        // reset time Claude Code waits for before continuing by itself.
        var index = 0
        var held = false
        let streams = json["stream"] as? Bool == true
        while index < attempts.count {
            let attempt = attempts[index]
            let isLast = index == attempts.count - 1 && attempt.backend.id == primary.id
            let outcome = await send(request, attempt: attempt, writer: writer, session: session, startsTurn: startsTurn,
                                     state: state, isLast: isLast, retried: false, cacheLifetime: cacheLifetime,
                                     extendCache: extendCache)
            switch outcome {
            case .served:
                return
            case .refusedAtLimit(let headers):
                // The session's own account reset before its prompt cache
                // expires: the request waits for it and keeps the cache.
                if state.cacheAwareSessions, !held, streams, let account = attempt.account,
                   previous?.backend == primary.id, previous?.account == account,
                   let resumeAt = RouterLogic.holdUntil(headers, lastServed: cache?.lastServed,
                                                        cacheLifetime: cache?.lifetime ?? cacheLifetime, now: Date()) {
                    held = true
                    brain.event(RouterEvent(kind: .held, at: Date(), session: session, backend: primary.id, accountID: account,
                                            detail: ISO8601DateFormatter().string(from: resumeAt)))
                    log.write("session \(session ?? "unknown") waits \(Int(resumeAt.timeIntervalSinceNow)) s for account \(account) to reset, before its prompt cache expires")
                    guard await waitHeld(until: resumeAt.addingTimeInterval(5), writer: writer) else { return }
                    continue
                }
                let until = RouterLogic.refusedUntil(headers, now: Date())
                if let account = attempt.account {
                    brain.refuse(account, until: until)
                } else if attempt.backend.id != primary.id {
                    brain.refuseBackend(attempt.backend.id, until: until)
                }
                log.write("\(attempt.backend.id)\(attempt.account.map { " account \($0)" } ?? "") refused at its plan limit; trying the next")
                brain.event(RouterEvent(kind: .replayed, at: Date(), session: session, backend: attempt.backend.id, accountID: attempt.account,
                                        detail: ISO8601DateFormatter().string(from: until)))
            case .rejected:
                break
            }
            if attempt.backend.id != primary.id, !attempts[(index + 1)...].contains(where: { $0.backend.id == primary.id }) {
                let refusedOwn = attempts.compactMap(\.account)
                attempts += primaryAttempts(json, primary: primary, state: state, previous: previous, startsTurn: startsTurn)
                    .filter { $0.account == nil || !refusedOwn.contains($0.account!) }
            }
            index += 1
        }
    }

    /// Keeps a held streamed request open until `date`: the 200 head is
    /// written at once and a comment every 14 seconds. False when the client
    /// went away meanwhile.
    private static func waitHeld(until date: Date, writer: ResponseWriter) async -> Bool {
        if !writer.headWritten {
            await writer.head(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")])
        }
        var waited = 0
        while Date() < date {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
            if waited % 14 == 0 { await writer.chunk(RouterLogic.streamKeepAlive) }
            if writer.clientGone { return false }
        }
        return true
    }

    /// Every pool account in preference order, starting with the session's
    /// own, so a refused account falls through to the next; or, with no
    /// pool account able to serve, the session's own credential.
    private static func primaryAttempts(
        _ json: [String: Any],
        primary: RouterBackend,
        state: RouterState,
        previous: (backend: String, account: String?)?,
        startsTurn: Bool,
        move: String? = nil,
        cacheExpired: Bool = false
    ) -> [Attempt] {
        var attempts: [Attempt] = []
        var unavailable = brain.refusedAccounts()
        var current = previous?.backend == primary.id ? previous?.account : nil
        let load = brain.poolLoad()
        while let account = RouterLogic.poolAccount(
            current: current, startsTurn: startsTurn, members: state.pool,
            unavailable: unavailable, load: load, followPreferred: state.sessionsFollowPreferred,
            move: attempts.isEmpty ? move : nil, cacheExpired: attempts.isEmpty && cacheExpired
        ) {
            unavailable.insert(account)
            current = nil
            guard let member = state.pool.first(where: { $0.accountID == account }),
                  let token = brain.token(member.tokenFile), token.expiresAt > Date().addingTimeInterval(30) else { continue }
            attempts.append(Attempt(backend: primary, account: account, token: token.accessToken, body: json))
        }
        if attempts.isEmpty {
            attempts.append(Attempt(backend: primary, account: nil, token: nil, body: json))
        }
        return attempts
    }

    private enum Outcome {
        case served
        case refusedAtLimit([String: String])
        /// A route target rejected the request as invalid; nothing was
        /// written to the client, so the pool answers instead.
        case rejected
    }

    private static func credentialHeaders(_ request: HTTPRequest, attempt: Attempt) -> (headers: [(String, String)], fingerprint: String?) {
        var headers = request.headers.filter { !hopHeaders.contains($0.0.lowercased()) }
        let token: String?
        switch attempt.backend.auth {
        case .passthrough: token = attempt.token
        case .bearer, .apiKey: token = brain.token(attempt.backend.tokenFile)?.accessToken
        }
        if let token {
            headers.removeAll { ["authorization", "x-api-key"].contains($0.0.lowercased()) }
            headers.append(attempt.backend.auth == .apiKey ? ("x-api-key", token) : ("Authorization", "Bearer \(token)"))
        }
        return (headers, RouterLogic.bearerToken(headers).map(RouterLogic.fingerprint))
    }

    private static func send(
        _ request: HTTPRequest,
        attempt: Attempt,
        writer: ResponseWriter,
        session: String?,
        startsTurn: Bool,
        state: RouterState,
        isLast: Bool,
        retried: Bool,
        cacheLifetime: TimeInterval? = nil,
        extendCache: Bool = false
    ) async -> Outcome {
        let backend = attempt.backend
        let issuer = attempt.account.map { "\(backend.id)|\($0)" } ?? backend.id
        // A held request already has its 200 event-stream head; whatever
        // follows, errors included, is written as events.
        let headSent = writer.headWritten
        func fail(_ status: Int, _ body: Data) async {
            if headSent {
                await writer.chunk(RouterLogic.streamedError(body, status: status))
                await writer.finish()
            } else {
                await writer.complete(status, json: body)
            }
        }
        if !backend.acceptsMessageThreads, RouterLogic.carriesThread(attempt.body) {
            // Claude Code resends the turn whole and keeps the session's
            // requests whole from then on.
            await fail(400, RouterLogic.threadUnsupportedBody(backend: backend.displayName))
            return .served
        }
        var body = RouterLogic.withModel(attempt.body, backend.model)
        var cacheExtended = false
        if extendCache, backend.id == state.primary { (body, cacheExtended) = RouterLogic.withExtendedCache(body) }
        if !backend.acceptsDeferredTools { body = RouterLogic.withoutDeferredTools(body) }
        if backend.validatesThinkingSignatures {
            let (cleaned, removed) = RouterLogic.cleanedThinking(
                body, target: backend.id, account: attempt.account, issuers: brain.issuerMap(),
                stripOtherAccounts: brain.accountsRejectEachOthersThinking
            )
            if removed > 0 { log.write("removed \(removed) thinking block(s) \(backend.displayName) would reject") }
            body = cleaned
        }
        let (headers, fingerprint) = credentialHeaders(request, attempt: attempt)
        guard let url = backend.messagesURL, let data = try? JSONSerialization.data(withJSONObject: body) else {
            await fail(500, RouterLogic.errorBody(type: "api_error", message: "AccountDock router has an invalid backend \(backend.id)"))
            return .served
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = "POST"
        for (name, value) in headers { upstream.addValue(value, forHTTPHeaderField: name) }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        upstream.httpBody = data
        do {
            let (bytes, response) = try await Upstream.open(upstream, client: session)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let responseHeaders = Dictionary(headerList(http), uniquingKeysWith: { a, _ in a })
            if backend.reportsUnifiedUsage, let fingerprint,
               let usage = RouterLogic.unifiedUsage(responseHeaders, credential: fingerprint, accountID: attempt.account, at: Date()) {
                brain.usage(usage)
            }
            if http.statusCode == 429 || http.statusCode == 403 || http.statusCode == 400 {
                var collected = Data()
                for try await byte in bytes { collected.append(byte); if collected.count > 65_536 { break } }
                bytes.task.cancel()
                if !isLast, RouterLogic.isPlanLimit(status: http.statusCode, headers: responseHeaders, body: collected) {
                    return .refusedAtLimit(responseHeaders)
                }
                if !retried, attempt.account != nil, RouterLogic.isInvalidThinkingSignature(status: http.statusCode, body: collected) {
                    // Thinking another account of this backend signed: earlier
                    // turns' thinking is removed and the request sent once more.
                    brain.noteCrossAccountRejection()
                    var retry = attempt
                    retry.body = RouterLogic.cleanedThinking(
                        attempt.body, target: backend.id, account: attempt.account, issuers: brain.issuerMap(),
                        stripOtherAccounts: true, stripUnknownBefore: RouterLogic.turnStartIndex(attempt.body)
                    ).0
                    return await send(request, attempt: retry, writer: writer, session: session, startsTurn: startsTurn,
                                      state: state, isLast: isLast, retried: true, cacheLifetime: cacheLifetime,
                                      extendCache: extendCache)
                }
                if backend.id != state.primary {
                    brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id, detail: "HTTP \(http.statusCode)"))
                    if http.statusCode == 400 {
                        let reply = String(decoding: collected.prefix(300), as: UTF8.self)
                        log.write("\(backend.id) rejected a request (\(RouterLogic.requestShape(body))): \(reply); sending it to \(state.primary)")
                        return .rejected
                    }
                }
                if headSent {
                    await fail(http.statusCode, collected)
                } else {
                    await writer.head(http.statusCode, headerList(http))
                    await writer.chunk(collected)
                    await writer.finish()
                }
                return .served
            }
            if headSent, http.statusCode >= 400 {
                var collected = Data()
                for try await byte in bytes { collected.append(byte); if collected.count > 65_536 { break } }
                bytes.task.cancel()
                await fail(http.statusCode, collected)
                return .served
            }
            if http.statusCode >= 400, backend.id != state.primary {
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id, detail: "HTTP \(http.statusCode)"))
            }
            let before = brain.session(session)?.account
            brain.setSession(session, backend: backend.id, account: attempt.account, cacheLifetime: cacheLifetime)
            if let account = attempt.account, before != account {
                brain.event(RouterEvent(kind: .assigned, at: Date(), session: session, backend: backend.id, accountID: account))
            }
            if startsTurn, backend.id != state.primary {
                brain.event(RouterEvent(kind: .servedByRoute, at: Date(), session: session, backend: backend.id))
            }
            if !headSent { await writer.head(http.statusCode, headerList(http)) }
            let streaming = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream")
            let scanner = SSEScanner()
            let whole = try await stream(bytes, to: writer, scanner: streaming ? scanner : nil, issuer: issuer, keepBody: !streaming)
            await writer.finish()
            var tokens: RouterLogic.TokenCounts?
            if streaming {
                brain.record(signatures: scanner.finish(), issuer: issuer)
                tokens = scanner.counts
            } else {
                brain.record(signatures: RouterLogic.signatures(inResponse: whole), issuer: issuer)
                tokens = RouterLogic.usage(inResponse: whole)
            }
            if let tokens, http.statusCode < 400 {
                brain.noteContext(session, tokens: tokens.context)
                brain.event(RouterEvent(kind: .turnUsage, at: Date(), session: session, backend: backend.id, accountID: attempt.account,
                                        detail: fingerprint, contextTokens: tokens.context, cacheWriteTokens: tokens.cacheWrite,
                                        cacheReadTokens: tokens.cacheRead,
                                        outputTokens: tokens.output, cacheLifetime: cacheLifetime.map { Int($0) },
                                        cacheWriteLongTokens: tokens.cacheWriteLong, cacheExtended: cacheExtended,
                                        startsTurn: startsTurn))
            }
            return .served
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(backend.id) reply")
            return .served
        } catch {
            log.write("\(backend.id) request failed\(writer.headWritten ? " mid-response" : ""): \(error.localizedDescription)")
            if backend.id != state.primary {
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id, detail: error.localizedDescription))
            }
            let reply = RouterLogic.errorBody(type: "overloaded_error", message: "\(backend.displayName) could not be reached through AccountDock: \(error.localizedDescription)")
            if headSent, !writer.clientGone {
                await fail(529, reply)
            } else if writer.headWritten {
                await writer.finish()
            } else {
                await writer.complete(529, json: reply)
            }
            return .served
        }
    }

    /// Requests other than Messages, such as token counting, go to the
    /// primary backend with a pool credential when there is one.
    private static func forwardRaw(_ request: HTTPRequest, state: RouterState, writer: ResponseWriter, trusted: Bool) async {
        let primary = state.backend(state.primary) ?? .anthropic
        guard let url = primary.url(request.target) else {
            await writer.complete(400, json: RouterLogic.errorBody(type: "invalid_request_error", message: "Bad request target"))
            return
        }
        var token: String?
        let refused = brain.refusedAccounts()
        for member in state.pool where trusted && !refused.contains(member.accountID) {
            if let candidate = brain.token(member.tokenFile), candidate.expiresAt > Date() { token = candidate.accessToken; break }
        }
        let (headers, _) = credentialHeaders(request, attempt: Attempt(backend: primary, account: nil, token: token, body: [:]))
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        for (name, value) in headers { upstream.addValue(value, forHTTPHeaderField: name) }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !request.body.isEmpty { upstream.httpBody = request.body }
        do {
            let (bytes, response) = try await Upstream.open(upstream, client: RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            await writer.head(http.statusCode, headerList(http))
            try await stream(bytes, to: writer, scanner: nil, issuer: primary.id)
            await writer.finish()
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(primary.id) reply")
        } catch {
            log.write("\(primary.id) \(request.method) \(request.target.split(separator: "?").first ?? "") failed\(writer.headWritten ? " mid-response" : ""): \(error.localizedDescription)")
            if writer.headWritten { await writer.finish() } else {
                await writer.complete(502, json: RouterLogic.errorBody(type: "api_error", message: "AccountDock router could not reach \(primary.displayName): \(error.localizedDescription)"))
            }
        }
    }

    /// Forwards a provider CLI's request unchanged to the provider's own
    /// endpoint (`ProviderPassthrough`), with the client's own credential.
    /// While the provider's pause holds the session the request waits here;
    /// a streamed one is answered with its 200 head at once and kept open
    /// with comments, so the CLI neither times out nor retries, and receives
    /// the provider's reply once the pause ends. With a `PassthroughRoute`,
    /// a Responses request is served by the route's backend instead while
    /// the route is on, or when the provider's endpoint refuses it at its
    /// limit and the route takes the overflow.
    private static func passthrough(_ request: HTTPRequest, key: String, rest: String, writer: ResponseWriter) async {
        guard let entry = ProviderPassthrough.entries()[key], let url = ProviderPassthrough.upstreamURL(entry, rest: rest) else {
            await writer.complete(502, json: RouterLogic.errorBody(type: "api_error", message: "AccountDock router has no upstream for \(key)"))
            return
        }
        // The router carries no websockets. Codex answers a 426 by using
        // HTTP for the rest of its session.
        if request.header("upgrade")?.lowercased() == "websocket" {
            await writer.complete(426, json: RouterLogic.errorBody(type: "invalid_request_error", message: "AccountDock's router serves this endpoint over HTTP"))
            return
        }
        let route = brain.currentState().passthroughRoutes[key]
        let path = rest.split(separator: "?").first.map(String.init) ?? rest
        let responses = route != nil && request.method == "POST" && path == "/responses"
            ? (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] : nil
        let session = ProviderPassthrough.sessionID(request.body, field: entry.sessionField)
            ?? ProviderPassthrough.sessionID(request.headers)
        let streaming = ProviderPassthrough.isStreaming(request.body)
        var heldStream = false
        if ProviderPassthrough.isHeld(key: key, session: session), !ProviderPassthrough.takeAllowance(key: key, session: session) {
            let marker = ProviderPassthrough.markWaiting(key: key, session: session)
            defer { if let marker { try? FileManager.default.removeItem(at: marker) } }
            log.write("\(key) session \(session ?? "unknown") held while its provider is paused")
            if streaming {
                await writer.head(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")])
                heldStream = true
            }
            var waited: TimeInterval = 0
            while ProviderPassthrough.isHeld(key: key, session: session),
                  !ProviderPassthrough.takeAllowance(key: key, session: session) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                waited += 2
                if heldStream, Int(waited) % 14 == 0 { await writer.chunk(ProviderPassthrough.keepAlive) }
                if writer.clientGone { return }
                // Without a stream nothing can be written early; the request
                // goes on before the client's own header timeout.
                if !heldStream, waited >= 240 { break }
            }
            log.write("\(key) session \(session ?? "unknown") released after \(Int(waited)) s")
        }
        var triedRoute = false
        if let route, let responses, route.routed, routeServes(route, key: key, session: session, bodyBytes: request.body.count) {
            triedRoute = true
            if await serveResponses(request, json: responses, route: route, key: key, session: session, writer: writer) { return }
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        for (name, value) in request.headers where !hopHeaders.contains(name.lowercased()) {
            upstream.addValue(value, forHTTPHeaderField: name)
        }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !request.body.isEmpty { upstream.httpBody = request.body }
        do {
            let (bytes, response) = try await Upstream.open(upstream, client: RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 429, let route, let responses, route.fallback, !triedRoute,
               routeServes(route, key: key, session: session, bodyBytes: request.body.count) {
                var refusal = Data()
                for try await byte in bytes { refusal.append(byte); if refusal.count > 65_536 { break } }
                bytes.task.cancel()
                log.write("\(key) refused a request at its limit; serving it from \(route.backend.displayName)")
                brain.event(RouterEvent(kind: .replayed, at: Date(), session: session, backend: key,
                                        detail: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10 * 60)), client: key))
                if await serveResponses(request, json: responses, route: route, key: key, session: session, writer: writer) { return }
                if heldStream {
                    await writer.chunk(ProviderPassthrough.streamError(status: http.statusCode, body: refusal))
                } else {
                    await writer.head(http.statusCode, headerList(http))
                    await writer.chunk(refusal)
                }
                await writer.finish()
                return
            }
            if heldStream {
                if http.statusCode == 200 {
                    try await stream(bytes, to: writer, scanner: nil, issuer: key)
                } else {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    await writer.chunk(ProviderPassthrough.streamError(status: http.statusCode, body: body))
                }
            } else {
                await writer.head(http.statusCode, headerList(http))
                try await stream(bytes, to: writer, scanner: nil, issuer: key)
            }
            await writer.finish()
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(key) reply")
        } catch {
            log.write("\(key) \(request.method) \(rest.split(separator: "?").first ?? "") failed\(writer.headWritten ? " mid-response" : ""): \(error.localizedDescription)")
            if writer.headWritten {
                if heldStream { await writer.chunk(ProviderPassthrough.streamError(status: 502, body: Data(error.localizedDescription.utf8))) }
                await writer.finish()
            } else {
                await writer.complete(502, json: RouterLogic.errorBody(type: "api_error", message: "AccountDock router could not reach \(key): \(error.localizedDescription)"))
            }
        }
    }

    /// The router's own key for a passthrough session, apart from the
    /// routed provider's sessions.
    private static func passthroughSession(_ key: String, _ session: String?) -> String? {
        session.map { "\(key):\($0)" }
    }

    /// Whether the route's backend takes the session now: it has not
    /// refused at its limit, and the session's context is within its cap.
    private static func routeServes(_ route: PassthroughRoute, key: String, session: String?, bodyBytes: Int) -> Bool {
        guard !brain.refusedBackendIDs().contains(route.backend.id) else { return false }
        let context = RouterLogic.expectedContext(lastMeasured: brain.sessionContext(passthroughSession(key, session)), bodyBytes: bodyBytes)
        return route.backend.maxContextTokens.map { context <= $0 } ?? true
    }

    /// Serves a Responses request from the route's Messages backend through
    /// `ResponsesBridge`. False when the backend refused or could not be
    /// reached before anything but a held stream's head was written, so the
    /// provider's own endpoint can answer instead.
    private static func serveResponses(
        _ request: HTTPRequest,
        json: [String: Any],
        route: PassthroughRoute,
        key: String,
        session: String?,
        writer: ResponseWriter
    ) async -> Bool {
        let backend = route.backend
        let routerSession = passthroughSession(key, session)
        let startsTurn = ResponsesBridge.startsTurn(json)
        let (body, tools) = ResponsesBridge.messagesRequest(json, model: backend.model)
        guard let url = backend.messagesURL, let data = try? JSONSerialization.data(withJSONObject: body),
              let token = brain.token(backend.tokenFile)?.accessToken else {
            log.write("\(backend.id) has no usable credential for \(key) requests")
            return false
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = "POST"
        upstream.setValue(backend.auth == .apiKey ? token : "Bearer \(token)",
                          forHTTPHeaderField: backend.auth == .apiKey ? "x-api-key" : "Authorization")
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        upstream.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let agent = request.header("user-agent") { upstream.setValue(agent, forHTTPHeaderField: "User-Agent") }
        upstream.httpBody = data
        let headSent = writer.headWritten
        do {
            let (bytes, response) = try await Upstream.open(upstream, client: routerSession)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                var reply = Data()
                for try await byte in bytes { reply.append(byte); if reply.count > 65_536 { break } }
                bytes.task.cancel()
                let headers = Dictionary(headerList(http), uniquingKeysWith: { a, _ in a })
                if http.statusCode == 429 || RouterLogic.isPlanLimit(status: http.statusCode, headers: headers, body: reply) {
                    brain.refuseBackend(backend.id, until: RouterLogic.refusedUntil(headers, now: Date()))
                }
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id,
                                        detail: "HTTP \(http.statusCode)", client: key))
                log.write("\(backend.id) refused a \(key) request with HTTP \(http.statusCode) (\(RouterLogic.requestShape(body))): \(String(decoding: reply.prefix(300), as: UTF8.self)); sending it to \(key)")
                return false
            }
            if !headSent {
                await writer.head(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")])
            }
            if startsTurn {
                brain.event(RouterEvent(kind: .servedByRoute, at: Date(), session: session, backend: backend.id, client: key))
            }
            brain.setSession(routerSession, backend: backend.id, account: nil, cacheLifetime: nil)
            let translator = ResponsesStreamTranslator(tools: tools)
            var pending = Data()
            do {
                for try await byte in bytes {
                    pending.append(byte)
                    guard byte == 0x0A else { continue }
                    let events = translator.feed(pending)
                    pending.removeAll(keepingCapacity: true)
                    if !events.isEmpty { await writer.chunk(events) }
                    if writer.clientGone {
                        bytes.task.cancel()
                        throw ClientClosed()
                    }
                }
                if !pending.isEmpty { await writer.chunk(translator.feed(pending + Data("\n".utf8))) }
                await writer.chunk(translator.finish())
            } catch is ClientClosed {
                throw ClientClosed()
            } catch {
                log.write("\(backend.id) \(key) reply failed mid-response: \(error.localizedDescription)")
                await writer.chunk(ResponsesBridge.failedEvent(id: "resp_router", code: "server_error",
                                                               message: "\(backend.displayName) stopped replying: \(error.localizedDescription)"))
            }
            await writer.finish()
            let counts = translator.counts
            if counts.context > 0 {
                brain.noteContext(routerSession, tokens: counts.context)
                brain.event(RouterEvent(kind: .turnUsage, at: Date(), session: session, backend: backend.id,
                                        contextTokens: counts.context, cacheWriteTokens: counts.cacheWrite,
                                        cacheReadTokens: counts.cacheRead, outputTokens: counts.output,
                                        cacheWriteLongTokens: counts.cacheWriteLong, startsTurn: startsTurn, client: key))
            }
            return true
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(backend.id) reply to \(key)")
            return true
        } catch {
            log.write("\(backend.id) request for \(key) failed: \(error.localizedDescription); sending it to \(key)")
            brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id,
                                    detail: error.localizedDescription, client: key))
            return false
        }
    }

    private static func headerList(_ response: HTTPURLResponse) -> [(String, String)] {
        response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        }
    }

    /// Copies the upstream body to the client as it arrives. Server-sent
    /// events are flushed per line so streamed output is not delayed. Once
    /// the client is gone the upstream request is cancelled and
    /// `ClientClosed` thrown, so the backend stops producing a reply.
    @discardableResult
    private static func stream(
        _ bytes: URLSession.AsyncBytes,
        to writer: ResponseWriter,
        scanner: SSEScanner?,
        issuer: String,
        keepBody: Bool = false
    ) async throws -> Data {
        var pending = Data()
        var whole = Data()
        for try await byte in bytes {
            pending.append(byte)
            if byte == 0x0A || pending.count >= 32_768 {
                if let scanner { brain.record(signatures: scanner.feed(pending), issuer: issuer) }
                if keepBody { whole.append(pending) }
                await writer.chunk(pending)
                pending.removeAll(keepingCapacity: true)
                if writer.clientGone {
                    bytes.task.cancel()
                    throw ClientClosed()
                }
            }
        }
        if !pending.isEmpty {
            if let scanner { brain.record(signatures: scanner.feed(pending), issuer: issuer) }
            if keepBody { whole.append(pending) }
            await writer.chunk(pending)
        }
        return whole
    }
}

// MARK: - Listener

let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: RouterConfig.port)!)
let listener: NWListener
do {
    listener = try NWListener(using: parameters)
} catch {
    log.write("could not listen on \(RouterConfig.port): \(error.localizedDescription)")
    exit(1)
}
listener.newConnectionHandler = { connection in ClientConnection(connection).start() }
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log.write("listening on \(RouterConfig.baseURL), version \(RouterConfig.version)")
    case .failed(let error):
        log.write("listener failed: \(error.localizedDescription)")
        exit(1)
    default: break
    }
}
listener.start(queue: DispatchQueue(label: "app.accountdock.router.listener"))
dispatchMain()
