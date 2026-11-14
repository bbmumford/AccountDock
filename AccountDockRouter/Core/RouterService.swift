import Foundation

/// Upstream sessions, one per URLSession so each holds its own connection.
/// `UpstreamConnections` decides which serves a request: a Claude Code
/// session keeps its own between turns, and every retry gets a fresh one,
/// so one dropped link fails only the requests of the session that used it.
final class RouterUpstream: @unchecked Sendable {
    private let log: RouterLog
    private let connections: UpstreamConnections<URLSession>

    init(log: RouterLog) {
        self.log = log
        connections = UpstreamConnections<URLSession>(
            idleLimit: 10 * 60,
            make: RouterUpstream.make,
            retire: { $0.finishTasksAndInvalidate() }
        )
    }

    private static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration)
    }

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
    func open(_ request: URLRequest, client: String?) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var attempt = 0
        while true {
            do {
                let (session, oneOff) = connections.connection(for: client, attempt: attempt)
                // A one-off session closes once its request ends, streamed
                // body included.
                defer { if oneOff { session.finishTasksAndInvalidate() } }
                return try await session.bytes(for: request)
            } catch {
                guard Self.isRetryable(error), attempt < Self.retryDelays.count else { throw error }
                log.write("\(request.url?.host ?? "upstream") \(request.url?.path ?? "") attempt \(attempt + 1) failed, retrying on a new connection: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }
}

/// Serves the router's requests: the app's control endpoints, Messages
/// requests from the routed CLI over its pool and route targets, and the
/// passthrough providers' requests. Every decision is `RouterLogic`'s; this
/// forwards, copies replies and reports events. `main.swift` runs one on
/// `RouterEnvironment.standard`; the tests run one on a temporary
/// directory and port.
final class RouterService: @unchecked Sendable {
    let environment: RouterEnvironment
    let brain: RouterBrain
    let log: RouterLog
    let upstream: RouterUpstream
    /// Reported by the health endpoint, which the app compares with its
    /// bundled router's to restart one left running from an older build.
    let buildStamp: String

    init(environment: RouterEnvironment, buildStamp: String = "unknown") {
        self.environment = environment
        self.buildStamp = buildStamp
        log = RouterLog(url: environment.logURL)
        brain = RouterBrain(environment: environment)
        upstream = RouterUpstream(log: log)
    }

    func handle(_ request: HTTPRequest, _ writer: ResponseWriter) async {
        let path = request.target.split(separator: "?").first.map(String.init) ?? request.target
        let state = brain.currentState()
        guard RouterLogic.isLocalClientRequest(request.headers, port: environment.port) else {
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
        let previous = brain.session(session)
        let plan = RouterLogic.planMessages(
            json, bodyBytes: request.body.count, state: state, primary: primary, previous: previous,
            lastContext: brain.sessionContext(session), refusedBackends: brain.refusedBackendIDs(),
            pool: poolView(), now: Date()
        )
        var attempts = plan.attempts
        // The account is recorded once the response is served; refusing at a
        // limit does not assign the session. A route target never gives the
        // final answer: when it refuses, the pool answers after it, so a
        // session out of every option gets Anthropic's own limit reply, whose
        // reset time Claude Code waits for before continuing by itself.
        var index = 0
        var held = false
        while index < attempts.count {
            let attempt = attempts[index]
            let isLast = index == attempts.count - 1 && attempt.backend.id == primary.id
            let outcome = await send(request, attempt: attempt, writer: writer, plan: plan, state: state,
                                     isLast: isLast, retried: false)
            switch outcome {
            case .served:
                return
            case .refusedAtLimit(let headers):
                let action = RouterLogic.refusalAction(
                    attempt: attempt, headers: headers, primary: primary, cacheAware: state.cacheAwareSessions,
                    alreadyHeld: held, streams: plan.streams, previous: previous, cacheLifetime: plan.cacheLifetime,
                    now: Date()
                )
                switch action {
                case .hold(let resumeAt):
                    // The session's own account resets before its prompt
                    // cache expires: the request waits for it and keeps the
                    // cache.
                    held = true
                    brain.event(RouterEvent(kind: .held, at: Date(), session: plan.session, backend: primary.id,
                                            accountID: attempt.account, detail: ISO8601DateFormatter().string(from: resumeAt)))
                    log.write("session \(plan.session ?? "unknown") waits \(Int(resumeAt.timeIntervalSinceNow)) s for account \(attempt.account ?? "") to reset, before its prompt cache expires")
                    guard await waitHeld(until: resumeAt.addingTimeInterval(5), writer: writer) else { return }
                    continue
                case .refuseAccount(let account, let until):
                    brain.refuse(account, until: until)
                    reportRefusal(attempt, plan: plan, until: until)
                case .refuseBackend(let backend, let until):
                    brain.refuseBackend(backend, until: until)
                    reportRefusal(attempt, plan: plan, until: until)
                case .next:
                    reportRefusal(attempt, plan: plan, until: RouterLogic.refusedUntil(headers, now: Date()))
                }
            case .rejected:
                break
            }
            attempts += RouterLogic.primaryAfterRoute(attempts, failedAt: index, primary: primary) {
                RouterLogic.poolAttempts(json, primary: primary, state: state, previous: previous,
                                         startsTurn: plan.startsTurn, pool: poolView(), now: Date())
            }
            index += 1
        }
    }

    private func poolView() -> RouterLogic.PoolView {
        RouterLogic.PoolView(unavailable: brain.refusedAccounts(), load: brain.poolLoad(), token: { [brain] in brain.token($0) })
    }

    private func reportRefusal(_ attempt: RouterLogic.Attempt, plan: RouterLogic.MessagesPlan, until: Date) {
        log.write("\(attempt.backend.id)\(attempt.account.map { " account \($0)" } ?? "") refused at its plan limit; trying the next")
        brain.event(RouterEvent(kind: .replayed, at: Date(), session: plan.session, backend: attempt.backend.id,
                                accountID: attempt.account, detail: ISO8601DateFormatter().string(from: until)))
    }

    /// Keeps a held streamed request open until `date`: the 200 head is
    /// written at once and a comment every 14 seconds. False when the client
    /// went away meanwhile.
    private func waitHeld(until date: Date, writer: ResponseWriter) async -> Bool {
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

    private enum Outcome {
        case served
        case refusedAtLimit([String: String])
        /// A route target rejected the request as invalid; nothing was
        /// written to the client, so the pool answers instead.
        case rejected
    }

    private func send(
        _ request: HTTPRequest,
        attempt: RouterLogic.Attempt,
        writer: ResponseWriter,
        plan: RouterLogic.MessagesPlan,
        state: RouterState,
        isLast: Bool,
        retried: Bool
    ) async -> Outcome {
        let backend = attempt.backend
        let session = plan.session
        let isRouteTarget = backend.id != state.primary
        let issuer = attempt.account.map { "\(backend.id)|\($0)" } ?? backend.id
        // A held request already has its 200 event-stream head; whatever
        // follows, errors included, is written as events.
        let headSent = writer.headWritten
        // Whether the reply is an event stream, where a failure is written
        // as an error event: a truncated stream otherwise reads as complete.
        var eventStream = headSent
        func fail(_ status: Int, _ body: Data) async {
            if headSent {
                await writer.chunk(RouterLogic.streamedError(body, status: status))
                await writer.finish()
            } else {
                await writer.complete(status, json: body)
            }
        }
        guard let prepared = RouterLogic.preparedBody(
            attempt, primaryID: state.primary, extendCache: plan.extendCache, issuers: brain.issuerMap(),
            stripOtherAccounts: brain.accountsRejectEachOthersThinking
        ) else {
            // Claude Code resends the turn whole and keeps the session's
            // requests whole from then on.
            await fail(400, RouterLogic.threadUnsupportedBody(backend: backend.displayName))
            return .served
        }
        if prepared.removedThinking > 0 {
            log.write("removed \(prepared.removedThinking) thinking block(s) \(backend.displayName) would reject")
        }
        let body = prepared.body
        let (headers, fingerprint) = RouterLogic.credentialHeaders(
            request.headers, attempt: attempt, backendToken: brain.token(backend.tokenFile)?.accessToken
        )
        guard let url = backend.messagesURL, let data = try? JSONSerialization.data(withJSONObject: body) else {
            await fail(500, RouterLogic.errorBody(type: "api_error", message: "AccountDock router has an invalid backend \(backend.id)"))
            return .served
        }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = "POST"
        for (name, value) in headers { outgoing.addValue(value, forHTTPHeaderField: name) }
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        outgoing.httpBody = data
        do {
            let (bytes, response) = try await upstream.open(outgoing, client: session)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let responseHeaders = Dictionary(Self.headerList(http), uniquingKeysWith: { a, _ in a })
            if backend.reportsUnifiedUsage, let fingerprint,
               let usage = RouterLogic.unifiedUsage(responseHeaders, credential: fingerprint, accountID: attempt.account, at: Date()) {
                brain.usage(usage)
            }
            var collected = Data()
            if RouterLogic.readsBodyFirst(status: http.statusCode) || (headSent && http.statusCode >= 400) {
                for try await byte in bytes { collected.append(byte); if collected.count > 65_536 { break } }
                bytes.task.cancel()
            }
            switch RouterLogic.replyVerdict(status: http.statusCode, headers: responseHeaders, body: collected, isLast: isLast,
                                            retried: retried, hasAccount: attempt.account != nil, isRouteTarget: isRouteTarget) {
            case .refusedAtLimit:
                return .refusedAtLimit(responseHeaders)
            case .retryWithoutForeignThinking:
                // Thinking another account of this backend signed: earlier
                // turns' thinking is removed and the request sent once more.
                brain.noteCrossAccountRejection()
                var retry = attempt
                retry.body = RouterLogic.cleanedThinking(
                    attempt.body, target: backend.id, account: attempt.account, issuers: brain.issuerMap(),
                    stripOtherAccounts: true, stripUnknownBefore: RouterLogic.turnStartIndex(attempt.body)
                ).0
                return await send(request, attempt: retry, writer: writer, plan: plan, state: state, isLast: isLast, retried: true)
            case .handBack:
                bytes.task.cancel()
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id, detail: "HTTP \(http.statusCode)"))
                let reply = collected.isEmpty ? "" : ": " + String(decoding: collected.prefix(300), as: UTF8.self)
                log.write("\(backend.id) answered \(http.statusCode) (\(RouterLogic.requestShape(body)))\(reply); sending the request to \(state.primary)")
                return .rejected
            case .relay:
                break
            }
            if RouterLogic.readsBodyFirst(status: http.statusCode) || (headSent && http.statusCode >= 400) {
                if headSent {
                    await fail(http.statusCode, collected)
                } else {
                    await writer.head(http.statusCode, Self.headerList(http))
                    await writer.chunk(collected)
                    await writer.finish()
                }
                return .served
            }
            // Only a reply that serves the request places the session on its
            // backend and account; a failed one leaves it where it was.
            if http.statusCode < 400 {
                let before = brain.session(session)?.account
                brain.setSession(session, backend: backend.id, account: attempt.account, cacheLifetime: plan.cacheLifetime)
                for kind in RouterLogic.placementEvents(account: attempt.account, previousAccount: before,
                                                        startsTurn: plan.startsTurn, isRouteTarget: isRouteTarget) {
                    brain.event(RouterEvent(kind: kind, at: Date(), session: session, backend: backend.id,
                                            accountID: kind == .assigned ? attempt.account : nil))
                }
            }
            if !headSent { await writer.head(http.statusCode, Self.headerList(http)) }
            let streaming = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream")
            eventStream = eventStream || streaming
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
                                        outputTokens: tokens.output, cacheLifetime: plan.cacheLifetime.map { Int($0) },
                                        cacheWriteLongTokens: tokens.cacheWriteLong, cacheExtended: prepared.cacheExtended,
                                        startsTurn: plan.startsTurn))
            }
            return .served
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(backend.id) reply")
            return .served
        } catch {
            log.write("\(backend.id) request failed\(writer.headWritten ? " mid-response" : ""): \(error.localizedDescription)")
            if isRouteTarget {
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id, detail: error.localizedDescription))
            }
            // This attempt wrote to the client only if the head was written
            // during it; a held head came before.
            if RouterLogic.handsBackToPool(isRouteTarget: isRouteTarget, status: nil,
                                           wroteReply: writer.headWritten && !headSent) {
                return .rejected
            }
            let reply = RouterLogic.errorBody(type: "overloaded_error", message: "\(backend.displayName) could not be reached through AccountDock: \(error.localizedDescription)")
            if writer.headWritten {
                if eventStream, !writer.clientGone { await writer.chunk(RouterLogic.streamedError(reply, status: 529)) }
                await writer.finish()
            } else {
                await writer.complete(529, json: reply)
            }
            return .served
        }
    }

    /// Requests other than Messages, such as token counting, go to the
    /// primary backend with a pool credential when there is one.
    private func forwardRaw(_ request: HTTPRequest, state: RouterState, writer: ResponseWriter, trusted: Bool) async {
        let primary = state.backend(state.primary) ?? .anthropic
        guard let url = primary.url(request.target) else {
            await writer.complete(400, json: RouterLogic.errorBody(type: "invalid_request_error", message: "Bad request target"))
            return
        }
        let token = RouterLogic.rawForwardToken(pool: state.pool, trusted: trusted, refused: brain.refusedAccounts(),
                                                token: { [brain] in brain.token($0) }, now: Date())
        let (headers, _) = RouterLogic.credentialHeaders(
            request.headers, attempt: RouterLogic.Attempt(backend: primary, account: nil, token: token, body: [:]),
            backendToken: brain.token(primary.tokenFile)?.accessToken
        )
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        for (name, value) in headers { outgoing.addValue(value, forHTTPHeaderField: name) }
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !request.body.isEmpty { outgoing.httpBody = request.body }
        do {
            let (bytes, response) = try await upstream.open(outgoing, client: RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            await writer.head(http.statusCode, Self.headerList(http))
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
    private func passthrough(_ request: HTTPRequest, key: String, rest: String, writer: ResponseWriter) async {
        guard let entry = ProviderPassthrough.entries(at: environment.passthroughURL)[key],
              let url = ProviderPassthrough.upstreamURL(entry, rest: rest) else {
            await writer.complete(502, json: RouterLogic.errorBody(type: "api_error", message: "AccountDock router has no upstream for \(key)"))
            return
        }
        // The router carries no websockets. Codex answers a 426 by using
        // HTTP for the rest of its session.
        if request.header("upgrade")?.lowercased() == "websocket" {
            await writer.complete(426, json: RouterLogic.errorBody(type: "invalid_request_error", message: "AccountDock's router serves this endpoint over HTTP"))
            return
        }
        // A route's backend is paid for by the user's accounts, so it serves
        // only clients holding one of their credentials, as the pool does.
        let trusted = brain.isAllowed(RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
        let route = trusted ? brain.currentState().passthroughRoutes[key] : nil
        let isResponses = request.method == "POST" && ProviderPassthrough.isResponsesPath(rest)
        let responses = route != nil && isResponses
            ? (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] : nil
        let session = ProviderPassthrough.sessionID(request.body, field: entry.sessionField)
            ?? ProviderPassthrough.sessionID(request.headers)
        let streaming = ProviderPassthrough.isStreaming(request.body)
        let pause = environment.pauseDirectory
        var heldStream = false
        if entry.holdsRequests, ProviderPassthrough.isHeld(key: key, session: session, directory: pause),
           !ProviderPassthrough.takeAllowance(key: key, session: session, directory: pause) {
            let marker = ProviderPassthrough.markWaiting(key: key, session: session, directory: pause)
            defer { if let marker { try? FileManager.default.removeItem(at: marker) } }
            log.write("\(key) session \(session ?? "unknown") held while its provider is paused")
            if streaming {
                await writer.head(200, [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")])
                heldStream = true
            }
            var waited: TimeInterval = 0
            while ProviderPassthrough.isHeld(key: key, session: session, directory: pause),
                  !ProviderPassthrough.takeAllowance(key: key, session: session, directory: pause) {
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
        func routeServes(_ route: PassthroughRoute) -> Bool {
            ProviderPassthrough.routeServes(route, refusedBackends: brain.refusedBackendIDs(),
                                            lastContext: brain.sessionContext(ProviderPassthrough.routerSession(key, session)),
                                            bodyBytes: request.body.count)
        }
        var triedRoute = false
        if let route, let responses, route.routed, routeServes(route) {
            triedRoute = true
            if await serveResponses(request, json: responses, route: route, key: key, session: session, writer: writer) { return }
        }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        for (name, value) in request.headers where !RouterLogic.hopHeaders.contains(name.lowercased()) {
            outgoing.addValue(value, forHTTPHeaderField: name)
        }
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !request.body.isEmpty { outgoing.httpBody = request.body }
        do {
            let (bytes, response) = try await upstream.open(outgoing, client: RouterLogic.bearerToken(request.headers).map(RouterLogic.fingerprint))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 429, let route, let responses, route.fallback, !triedRoute, routeServes(route) {
                var refusal = Data()
                for try await byte in bytes { refusal.append(byte); if refusal.count > 65_536 { break } }
                bytes.task.cancel()
                log.write("\(key) refused a request at its limit; serving it from \(route.backend.displayName)")
                brain.event(RouterEvent(kind: .replayed, at: Date(), session: session, backend: key,
                                        detail: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10 * 60)), client: key))
                if await serveResponses(request, json: responses, route: route, key: key, session: session, writer: writer) { return }
                if heldStream {
                    await writer.chunk(ProviderPassthrough.streamError(status: http.statusCode, body: refusal, responses: isResponses))
                } else {
                    await writer.head(http.statusCode, Self.headerList(http))
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
                    await writer.chunk(ProviderPassthrough.streamError(status: http.statusCode, body: body, responses: isResponses))
                }
            } else {
                await writer.head(http.statusCode, Self.headerList(http))
                try await stream(bytes, to: writer, scanner: nil, issuer: key)
            }
            await writer.finish()
        } catch is ClientClosed {
            log.write("client closed its connection; stopped the \(key) reply")
        } catch {
            log.write("\(key) \(request.method) \(rest.split(separator: "?").first ?? "") failed\(writer.headWritten ? " mid-response" : ""): \(error.localizedDescription)")
            if writer.headWritten {
                if heldStream {
                    await writer.chunk(ProviderPassthrough.streamError(status: 502, body: Data(error.localizedDescription.utf8), responses: isResponses))
                }
                await writer.finish()
            } else {
                await writer.complete(502, json: RouterLogic.errorBody(type: "api_error", message: "AccountDock router could not reach \(key): \(error.localizedDescription)"))
            }
        }
    }

    /// Serves a Responses request from the route's Messages backend through
    /// `ResponsesBridge`. False when the backend refused or could not be
    /// reached before anything but a held stream's head was written, so the
    /// provider's own endpoint can answer instead.
    private func serveResponses(
        _ request: HTTPRequest,
        json: [String: Any],
        route: PassthroughRoute,
        key: String,
        session: String?,
        writer: ResponseWriter
    ) async -> Bool {
        let backend = route.backend
        let routerSession = ProviderPassthrough.routerSession(key, session)
        let startsTurn = ResponsesBridge.startsTurn(json)
        let (body, tools) = ResponsesBridge.messagesRequest(json, model: backend.model)
        guard let url = backend.messagesURL, let data = try? JSONSerialization.data(withJSONObject: body),
              let token = brain.token(backend.tokenFile)?.accessToken else {
            log.write("\(backend.id) has no usable credential for \(key) requests")
            return false
        }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = "POST"
        outgoing.setValue(backend.auth == .apiKey ? token : "Bearer \(token)",
                          forHTTPHeaderField: backend.auth == .apiKey ? "x-api-key" : "Authorization")
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        outgoing.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let agent = request.header("user-agent") { outgoing.setValue(agent, forHTTPHeaderField: "User-Agent") }
        outgoing.httpBody = data
        let headSent = writer.headWritten
        do {
            let (bytes, response) = try await upstream.open(outgoing, client: routerSession)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                var reply = Data()
                for try await byte in bytes { reply.append(byte); if reply.count > 65_536 { break } }
                bytes.task.cancel()
                let headers = Dictionary(Self.headerList(http), uniquingKeysWith: { a, _ in a })
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
                await writer.chunk(translator.fail(code: "server_error",
                                                   message: "\(backend.displayName) stopped replying: \(error.localizedDescription)"))
            }
            await writer.finish()
            if case .failed(let code, let message) = translator.outcome {
                // The client has the failure as its reply; the app learns
                // of it here, and a backend at its limit is skipped.
                if code == "rate_limit_exceeded" { brain.refuseBackend(backend.id, until: RouterLogic.refusedUntil([:], now: Date())) }
                brain.event(RouterEvent(kind: .backendFailed, at: Date(), session: session, backend: backend.id,
                                        detail: message, client: key))
                log.write("\(backend.id) failed a \(key) reply mid-stream (\(code)): \(message.prefix(300))")
            }
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

    static func headerList(_ response: HTTPURLResponse) -> [(String, String)] {
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
    private func stream(
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
