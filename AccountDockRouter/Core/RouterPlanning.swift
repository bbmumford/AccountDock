import Foundation

/// The router's decisions for one request, as pure functions of what the
/// request says and what `RouterBrain` knows. `RouterService` asks these,
/// then forwards and reports; the tests cover them directly.
extension RouterLogic {
    /// One attempt to serve a request from one backend, with one credential.
    struct Attempt {
        var backend: RouterBackend
        var account: String?
        var token: String?
        var body: [String: Any]
    }

    /// How a Messages request is to be served: the session it belongs to,
    /// whether it starts a turn, its prompt cache, and the attempts in order.
    struct MessagesPlan {
        var session: String?
        var startsTurn: Bool
        /// The request asks for the one-hour cache in place of its own.
        var extendCache: Bool
        /// The lifetime the request's prompt cache is sent with.
        var cacheLifetime: TimeInterval?
        /// The session's prompt cache has expired, so its next turn is
        /// placed like a new session's.
        var cacheExpired: Bool
        /// The pool account the app asked the session to move to.
        var move: String?
        var streams: Bool
        var attempts: [Attempt]
    }

    /// What the router knows of the pool when it plans: accounts refused
    /// at their limit, sessions per account, and the pushed credentials.
    struct PoolView {
        var unavailable: Set<String>
        var load: [String: Int]
        var token: (String) -> RouterToken?
    }

    /// Plans a Messages request from a trusted client. A route target
    /// serves only sessions within its context cap and before it refused at
    /// its limit; others stay on the primary. A turn finishes on the backend
    /// it began on when the new one would reject its thinking. The fallback,
    /// when it can serve, is tried after the first backend's attempts.
    static func planMessages(
        _ json: [String: Any],
        bodyBytes: Int,
        state: RouterState,
        primary: RouterBackend,
        previous: RouterSessionRecord?,
        lastContext: Int?,
        refusedBackends: Set<String>,
        pool: PoolView,
        now: Date
    ) -> MessagesPlan {
        let session = sessionID(json)
        let turn = Self.startsTurn(json)
        let context = expectedContext(lastMeasured: lastContext, bodyBytes: bodyBytes)
        // A large context asks for the one-hour cache, so an idle spell of
        // over five minutes does not write it all again.
        let extendCache = state.extendedCacheMinimumContext.map { context >= $0 } ?? false
        let requestedLifetime = cacheLifetime(json)
        let lifetime = extendCache ? requestedLifetime.map { _ in TimeInterval(60 * 60) } : requestedLifetime
        // A session whose prompt cache has expired has nothing to lose by
        // moving, so its next turn is placed like a new session's. Expiry
        // is the app's (`SessionSizing.cacheExpiresAt`), so the router
        // re-places exactly the sessions the app's pacing counts as cold.
        let cacheExpired = state.cacheAwareSessions && previous.map {
            now > SessionSizing.cacheExpiresAt(lastServed: $0.lastServed, lifetime: $0.cacheLifetime)
        } ?? false
        let move = session.flatMap { state.moves[$0] }
        func serves(_ candidate: RouterBackend) -> Bool {
            !refusedBackends.contains(candidate.id) && candidate.maxContextTokens.map { context <= $0 } ?? true
        }
        let desired = state.backend(state.route).flatMap { serves($0) ? $0 : nil } ?? primary
        let backendID = backend(
            desired: desired.id,
            turnBackend: previous?.backend,
            startsTurn: turn,
            desiredValidatesThinking: desired.validatesThinkingSignatures
        )
        let chosen = state.backend(backendID).flatMap { $0.id == primary.id || serves($0) ? $0 : nil } ?? primary
        var attempts = chosen.id == primary.id
            ? poolAttempts(json, primary: primary, state: state, previous: previous, startsTurn: turn,
                           pool: pool, move: move, cacheExpired: cacheExpired, now: now)
            : [Attempt(backend: chosen, account: nil, token: nil, body: json)]
        if let fallback = state.backend(state.fallback), fallback.id != chosen.id, serves(fallback) {
            attempts.append(Attempt(backend: fallback, account: nil, token: nil, body: json))
        }
        return MessagesPlan(session: session, startsTurn: turn, extendCache: extendCache, cacheLifetime: lifetime,
                            cacheExpired: cacheExpired, move: move, streams: json["stream"] as? Bool == true,
                            attempts: attempts)
    }

    /// Every pool account in preference order, starting with the session's
    /// own, so a refused account falls through to the next; or, with no
    /// pool account able to serve, the session's own credential. An
    /// account whose token is missing or lasts under 30 seconds is skipped.
    static func poolAttempts(
        _ json: [String: Any],
        primary: RouterBackend,
        state: RouterState,
        previous: RouterSessionRecord?,
        startsTurn: Bool,
        pool: PoolView,
        move: String? = nil,
        cacheExpired: Bool = false,
        now: Date
    ) -> [Attempt] {
        var attempts: [Attempt] = []
        var unavailable = pool.unavailable
        var current = previous?.backend == primary.id ? previous?.account : nil
        while let account = poolAccount(
            current: current, startsTurn: startsTurn, members: state.pool,
            unavailable: unavailable, load: pool.load, followPreferred: state.sessionsFollowPreferred,
            move: attempts.isEmpty ? move : nil, cacheExpired: attempts.isEmpty && cacheExpired
        ) {
            unavailable.insert(account)
            current = nil
            guard let member = state.pool.first(where: { $0.accountID == account }),
                  let token = pool.token(member.tokenFile), token.expiresAt > now.addingTimeInterval(30) else { continue }
            attempts.append(Attempt(backend: primary, account: account, token: token.accessToken, body: json))
        }
        if attempts.isEmpty {
            attempts.append(Attempt(backend: primary, account: nil, token: nil, body: json))
        }
        return attempts
    }

    /// The pool attempts that follow a route target's failure: the
    /// primary's, without the accounts already refused for this request.
    /// Empty while a later attempt is already the primary's.
    static func primaryAfterRoute(
        _ attempts: [Attempt],
        failedAt index: Int,
        primary: RouterBackend,
        pool: () -> [Attempt]
    ) -> [Attempt] {
        guard attempts[index].backend.id != primary.id,
              !attempts[(index + 1)...].contains(where: { $0.backend.id == primary.id }) else { return [] }
        let refusedOwn = Set(attempts.compactMap(\.account))
        return pool().filter { $0.account.map { !refusedOwn.contains($0) } ?? true }
    }

    /// What to do after an attempt was refused at its plan limit.
    enum RefusalAction: Equatable {
        /// Wait for the account's reset, which comes before the session's
        /// prompt cache expires, and send the request there again.
        case hold(until: Date)
        /// Skip the pool account until the given time and try the next.
        case refuseAccount(String, until: Date)
        /// Skip the route target until the given time and try the next.
        case refuseBackend(String, until: Date)
        /// Try the next attempt.
        case next
    }

    /// A refusal holds the request only once, only for a streamed request
    /// of a cache-aware state, and only on the account that last served
    /// the session, whose cache lasts as `SessionSizing` counts it;
    /// otherwise the refused account or route target is skipped until its
    /// reset.
    static func refusalAction(
        attempt: Attempt,
        headers: [String: String],
        primary: RouterBackend,
        cacheAware: Bool,
        alreadyHeld: Bool,
        streams: Bool,
        previous: RouterSessionRecord?,
        now: Date
    ) -> RefusalAction {
        if cacheAware, !alreadyHeld, streams, let account = attempt.account,
           previous?.backend == primary.id, previous?.account == account,
           let resumeAt = holdUntil(headers, lastServed: previous?.lastServed,
                                    cacheLifetime: previous?.cacheLifetime ?? SessionSizing.defaultCacheLifetime, now: now) {
            return .hold(until: resumeAt)
        }
        let until = refusedUntil(headers, now: now)
        if let account = attempt.account { return .refuseAccount(account, until: until) }
        if attempt.backend.id != primary.id { return .refuseBackend(attempt.backend.id, until: until) }
        return .next
    }

    /// The request body as it goes to the attempt's backend: its model, the
    /// one-hour cache on the primary when asked, deferred tools removed for
    /// a backend without them, and thinking the backend would reject
    /// removed. Nil when the backend cannot take the request at all, as a
    /// `thread` request to a backend without server-side conversations.
    struct PreparedBody {
        var body: [String: Any]
        var cacheExtended: Bool
        var removedThinking: Int
    }

    static func preparedBody(
        _ attempt: Attempt,
        primaryID: String,
        extendCache: Bool,
        issuers: [String: String],
        stripOtherAccounts: Bool
    ) -> PreparedBody? {
        let backend = attempt.backend
        if !backend.acceptsMessageThreads, carriesThread(attempt.body) { return nil }
        var body = withModel(attempt.body, backend.model)
        var cacheExtended = false
        if extendCache, backend.id == primaryID { (body, cacheExtended) = withExtendedCache(body) }
        if !backend.acceptsDeferredTools { body = withoutDeferredTools(body) }
        var removed = 0
        if backend.validatesThinkingSignatures {
            (body, removed) = cleanedThinking(body, target: backend.id, account: attempt.account, issuers: issuers,
                                              stripOtherAccounts: stripOtherAccounts)
        }
        return PreparedBody(body: body, cacheExtended: cacheExtended, removedThinking: removed)
    }

    /// What the router does with a backend's reply head.
    enum ReplyVerdict: Equatable {
        /// Refused at the plan limit; the next attempt is tried.
        case refusedAtLimit
        /// The backend rejected thinking another of its accounts signed;
        /// the request is sent once more without earlier turns' thinking.
        case retryWithoutForeignThinking
        /// A route target failed; the pool answers instead.
        case handBack
        /// The reply goes to the client as it is.
        case relay
    }

    /// Whether the reply's body must be read before the verdict: refusals
    /// and invalid requests are judged by their text.
    static func readsBodyFirst(status: Int) -> Bool { status == 429 || status == 403 || status == 400 }

    /// The verdict on a reply. `body` is the reply's start when
    /// `readsBodyFirst(status:)`. The last attempt's refusal is the answer.
    static func replyVerdict(
        status: Int,
        headers: [String: String],
        body: Data,
        isLast: Bool,
        retried: Bool,
        hasAccount: Bool,
        isRouteTarget: Bool
    ) -> ReplyVerdict {
        if readsBodyFirst(status: status) {
            if !isLast, isPlanLimit(status: status, headers: headers, body: body) { return .refusedAtLimit }
            if !retried, hasAccount, isInvalidThinkingSignature(status: status, body: body) { return .retryWithoutForeignThinking }
        }
        return handsBackToPool(isRouteTarget: isRouteTarget, status: status, wroteReply: false) ? .handBack : .relay
    }

    /// The events a served reply records: `assigned` when the session's
    /// pool account changed, `servedByRoute` when a route target served a
    /// new turn.
    static func placementEvents(account: String?, previousAccount: String?, startsTurn: Bool,
                                isRouteTarget: Bool) -> [RouterEvent.Kind] {
        var kinds: [RouterEvent.Kind] = []
        if let account, previousAccount != account { kinds.append(.assigned) }
        if startsTurn, isRouteTarget { kinds.append(.servedByRoute) }
        return kinds
    }

    /// The pool credential a request other than Messages is forwarded
    /// with: the first pool account not refused whose token has not
    /// expired, for a trusted client only; nil forwards the client's own.
    static func rawForwardToken(pool: [RouterPoolMember], trusted: Bool, refused: Set<String>,
                                token: (String) -> RouterToken?, now: Date) -> String? {
        guard trusted else { return nil }
        for member in pool where !refused.contains(member.accountID) {
            if let candidate = token(member.tokenFile), candidate.expiresAt > now { return candidate.accessToken }
        }
        return nil
    }

    /// The request headers for an attempt: the client's, without hop-by-hop
    /// headers, with the credential replaced by the attempt's pool token or
    /// the backend's own (`backendToken`), and that credential's fingerprint.
    static func credentialHeaders(_ headers: [(String, String)], attempt: Attempt,
                                  backendToken: String?) -> (headers: [(String, String)], fingerprint: String?) {
        var result = headers.filter { !hopHeaders.contains($0.0.lowercased()) }
        let token: String?
        switch attempt.backend.auth {
        case .passthrough: token = attempt.token
        case .bearer, .apiKey: token = backendToken
        }
        if let token {
            result.removeAll { ["authorization", "x-api-key"].contains($0.0.lowercased()) }
            result.append(attempt.backend.auth == .apiKey ? ("x-api-key", token) : ("Authorization", "Bearer \(token)"))
        }
        return (result, bearerToken(result).map(fingerprint))
    }

    static let hopHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "accept-encoding",
        "keep-alive", "proxy-connection", "upgrade", "te",
    ]
}

extension RouterLogic {
    /// The credentials a bridged request is tried with, in order: for a
    /// backend serving from the pool (`RouterBackend.poolCredentials`) the
    /// pool accounts, the session's own first, as `poolAttempts` orders
    /// them; otherwise, or with no pool account able to serve, the
    /// backend's own token. Empty when there is none.
    static func bridgeCredentials(
        backend: RouterBackend,
        state: RouterState,
        previous: RouterSessionRecord?,
        startsTurn: Bool,
        pool: PoolView,
        ownToken: RouterToken?,
        now: Date
    ) -> [(account: String?, token: String)] {
        if backend.poolCredentials, !state.pool.isEmpty {
            let pooled = poolAttempts([:], primary: backend, state: state, previous: previous, startsTurn: startsTurn,
                                      pool: pool, now: now)
                .compactMap { attempt in attempt.token.map { (account: attempt.account, token: $0) } }
            if !pooled.isEmpty { return pooled }
        }
        guard let ownToken, ownToken.expiresAt > now else { return [] }
        return [(account: nil, token: ownToken.accessToken)]
    }
}

extension ProviderPassthrough {
    /// The router's own key for a passthrough session, apart from the
    /// routed provider's sessions.
    static func routerSession(_ key: String, _ session: String?) -> String? {
        session.map { "\(key):\($0)" }
    }

    /// Whether the route's backend takes the session now: it has not
    /// refused at its limit, and the session's context is within its cap.
    static func routeServes(_ route: PassthroughRoute, refusedBackends: Set<String>, lastContext: Int?,
                            bodyBytes: Int) -> Bool {
        guard !refusedBackends.contains(route.backend.id) else { return false }
        let context = RouterLogic.expectedContext(lastMeasured: lastContext, bodyBytes: bodyBytes)
        return route.backend.maxContextTokens.map { context <= $0 } ?? true
    }
}
