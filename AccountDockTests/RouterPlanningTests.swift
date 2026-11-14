import XCTest
@testable import AccountDock

/// The router's per-request decisions (`RouterLogic.planMessages` and the
/// functions `RouterService` asks after each reply), and the brain's
/// expiry rules on an injected clock.
final class RouterPlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let kimi = RouterBackend(id: "kimi", displayName: "Kimi", baseURL: "https://kimi.test", auth: .bearer,
                                     tokenFile: "target-kimi", maxContextTokens: 100_000)

    private func request(session: String = "s1", turn: Bool = true, stream: Bool = true) -> [String: Any] {
        let last: [String: Any] = turn
            ? ["role": "user", "content": [["type": "text", "text": "hi", "cache_control": ["type": "ephemeral"]]]]
            : ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]
        return ["model": "m", "stream": stream, "metadata": ["user_id": "u_session_\(session)"], "messages": [last]]
    }

    private func state(pool: [RouterPoolMember] = [], route: String = "anthropic", fallback: String? = nil) -> RouterState {
        var state = RouterState()
        state.backends.append(kimi)
        state.pool = pool
        state.route = route
        state.fallback = fallback
        return state
    }

    private func pool(_ tokens: [String: RouterToken], unavailable: Set<String> = [], load: [String: Int] = [:]) -> RouterLogic.PoolView {
        RouterLogic.PoolView(unavailable: unavailable, load: load, token: { tokens[$0] })
    }

    private func token(_ value: String, lasting seconds: TimeInterval = 3600) -> RouterToken {
        RouterToken(accessToken: value, expiresAt: now.addingTimeInterval(seconds))
    }

    func testAPoolSessionTriesEveryUsableAccountInOrderAndSkipsAnExpiringToken() {
        let members = [RouterPoolMember(accountID: "a", tokenFile: "ta"), RouterPoolMember(accountID: "b", tokenFile: "tb"),
                       RouterPoolMember(accountID: "c", tokenFile: "tc", weight: 0)]
        let tokens = ["ta": token("A", lasting: 10), "tb": token("B"), "tc": token("C")]
        let plan = RouterLogic.planMessages(request(), bodyBytes: 100, state: state(pool: members), primary: .anthropic,
                                            previous: nil, lastContext: nil, refusedBackends: [], pool: pool(tokens), now: now)
        XCTAssertEqual(plan.attempts.map(\.account), ["b", "c"], "a's token lasts under 30 seconds")
        XCTAssertEqual(plan.attempts.map(\.token), ["B", "C"])
        XCTAssertEqual(plan.session, "s1")
        XCTAssertTrue(plan.startsTurn)
    }

    func testWithoutAPoolTheClientsOwnCredentialIsTheOnlyAttempt() {
        let plan = RouterLogic.planMessages(request(), bodyBytes: 100, state: state(), primary: .anthropic,
                                            previous: nil, lastContext: nil, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertEqual(plan.attempts.count, 1)
        XCTAssertNil(plan.attempts[0].account)
        XCTAssertNil(plan.attempts[0].token)
    }

    func testARouteServesSessionsWithinItsCapAndOthersStayOnThePrimary() {
        let routed = state(route: "kimi")
        let small = RouterLogic.planMessages(request(), bodyBytes: 100, state: routed, primary: .anthropic,
                                             previous: nil, lastContext: 50_000, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertEqual(small.attempts.first?.backend.id, "kimi")
        let large = RouterLogic.planMessages(request(), bodyBytes: 100, state: routed, primary: .anthropic,
                                             previous: nil, lastContext: 150_000, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertEqual(large.attempts.map(\.backend.id), ["anthropic"])
        let refused = RouterLogic.planMessages(request(), bodyBytes: 100, state: routed, primary: .anthropic,
                                               previous: nil, lastContext: 50_000, refusedBackends: ["kimi"], pool: pool([:]), now: now)
        XCTAssertEqual(refused.attempts.map(\.backend.id), ["anthropic"])
    }

    func testATurnFinishesOnTheBackendThatValidatesItsThinking() {
        var routed = state(route: "kimi")
        routed.backends[1].validatesThinkingSignatures = true
        let previous = RouterSessionRecord(backend: "anthropic", account: nil, lastServed: now, cacheLifetime: nil)
        let plan = RouterLogic.planMessages(request(turn: false), bodyBytes: 100, state: routed, primary: .anthropic,
                                            previous: previous, lastContext: 1_000, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertEqual(plan.attempts.first?.backend.id, "anthropic")
    }

    func testTheFallbackFollowsThePrimaryAttemptsWhenItServes() {
        let plan = RouterLogic.planMessages(request(), bodyBytes: 100, state: state(fallback: "kimi"), primary: .anthropic,
                                            previous: nil, lastContext: 1_000, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertEqual(plan.attempts.map(\.backend.id), ["anthropic", "kimi"])
    }

    func testAnExpiredCacheReplacesTheSessionAndAMoveGoesFirst() {
        var paced = state(pool: [RouterPoolMember(accountID: "a", tokenFile: "ta"), RouterPoolMember(accountID: "b", tokenFile: "tb")])
        paced.cacheAwareSessions = true
        let tokens = ["ta": token("A"), "tb": token("B")]
        let previous = RouterSessionRecord(backend: "anthropic", account: "b", lastServed: now.addingTimeInterval(-600),
                                           cacheLifetime: 300)
        let expired = RouterLogic.planMessages(request(), bodyBytes: 100, state: paced, primary: .anthropic, previous: previous,
                                               lastContext: 1_000, refusedBackends: [], pool: pool(tokens, load: ["a": 0, "b": 3]),
                                               now: now)
        XCTAssertTrue(expired.cacheExpired)
        XCTAssertEqual(expired.attempts.first?.account, "a", "placed again by load")
        paced.moves = ["s1": "b"]
        let moved = RouterLogic.planMessages(request(), bodyBytes: 100, state: paced, primary: .anthropic, previous: nil,
                                             lastContext: 1_000, refusedBackends: [], pool: pool(tokens), now: now)
        XCTAssertEqual(moved.attempts.first?.account, "b")
    }

    func testAnExtendedCacheAsksForAnHourOnThePrimaryOnly() {
        var extended = state()
        extended.extendedCacheMinimumContext = 0
        let plan = RouterLogic.planMessages(request(), bodyBytes: 100, state: extended, primary: .anthropic,
                                            previous: nil, lastContext: nil, refusedBackends: [], pool: pool([:]), now: now)
        XCTAssertTrue(plan.extendCache)
        XCTAssertEqual(plan.cacheLifetime, 3600)
        let primary = RouterLogic.preparedBody(plan.attempts[0], primaryID: "anthropic", extendCache: true, issuers: [:],
                                               stripOtherAccounts: false)
        XCTAssertEqual(primary?.cacheExtended, true)
        let target = RouterLogic.preparedBody(RouterLogic.Attempt(backend: kimi, account: nil, token: nil, body: request()),
                                              primaryID: "anthropic", extendCache: true, issuers: [:], stripOtherAccounts: false)
        XCTAssertEqual(target?.cacheExtended, false)
    }

    func testAThreadRequestCannotGoToABackendWithoutConversations() {
        var body = request()
        body["thread"] = ["id": "t"]
        XCTAssertNil(RouterLogic.preparedBody(RouterLogic.Attempt(backend: kimi, account: nil, token: nil, body: body),
                                              primaryID: "anthropic", extendCache: false, issuers: [:], stripOtherAccounts: false))
        XCTAssertNotNil(RouterLogic.preparedBody(RouterLogic.Attempt(backend: .anthropic, account: nil, token: nil, body: body),
                                                 primaryID: "anthropic", extendCache: false, issuers: [:], stripOtherAccounts: false))
    }

    func testARefusalHoldsOnlyTheSessionsOwnAccountBeforeItsCacheExpires() {
        let reset = now.addingTimeInterval(120)
        let headers = ["anthropic-ratelimit-unified-reset": "\(Int(reset.timeIntervalSince1970))"]
        let attempt = RouterLogic.Attempt(backend: .anthropic, account: "a", token: "A", body: [:])
        let own = RouterSessionRecord(backend: "anthropic", account: "a", lastServed: now, cacheLifetime: 3600)
        XCTAssertEqual(RouterLogic.refusalAction(attempt: attempt, headers: headers, primary: .anthropic, cacheAware: true,
                                                 alreadyHeld: false, streams: true, previous: own, cacheLifetime: nil, now: now),
                       .hold(until: reset))
        if case .refuseAccount("a", _) = RouterLogic.refusalAction(
            attempt: attempt, headers: headers, primary: .anthropic, cacheAware: true, alreadyHeld: true, streams: true,
            previous: own, cacheLifetime: nil, now: now) {} else { XCTFail("held once only") }
        let target = RouterLogic.Attempt(backend: kimi, account: nil, token: nil, body: [:])
        if case .refuseBackend("kimi", _) = RouterLogic.refusalAction(
            attempt: target, headers: [:], primary: .anthropic, cacheAware: false, alreadyHeld: false, streams: true,
            previous: nil, cacheLifetime: nil, now: now) {} else { XCTFail("the route target is skipped") }
    }

    func testRepliesAreJudgedAsTheServerDidBeforeTheMove() {
        let limit = ["anthropic-ratelimit-unified-status": "rejected"]
        XCTAssertEqual(RouterLogic.replyVerdict(status: 429, headers: limit, body: Data(), isLast: false, retried: false,
                                                hasAccount: true, isRouteTarget: false), .refusedAtLimit)
        XCTAssertEqual(RouterLogic.replyVerdict(status: 429, headers: limit, body: Data(), isLast: true, retried: false,
                                                hasAccount: true, isRouteTarget: false), .relay, "the last refusal is the answer")
        let signature = Data(#"{"error":{"message":"Invalid signature in thinking block"}}"#.utf8)
        XCTAssertEqual(RouterLogic.replyVerdict(status: 400, headers: [:], body: signature, isLast: true, retried: false,
                                                hasAccount: true, isRouteTarget: false), .retryWithoutForeignThinking)
        XCTAssertEqual(RouterLogic.replyVerdict(status: 400, headers: [:], body: signature, isLast: true, retried: true,
                                                hasAccount: true, isRouteTarget: false), .relay)
        XCTAssertEqual(RouterLogic.replyVerdict(status: 500, headers: [:], body: Data(), isLast: false, retried: false,
                                                hasAccount: false, isRouteTarget: true), .handBack)
        XCTAssertEqual(RouterLogic.replyVerdict(status: 200, headers: [:], body: Data(), isLast: false, retried: false,
                                                hasAccount: false, isRouteTarget: true), .relay)
    }

    func testARouteTargetsFailureAddsThePoolWithoutAccountsAlreadyRefused() {
        let attempts = [RouterLogic.Attempt(backend: kimi, account: nil, token: nil, body: [:])]
        let added = RouterLogic.primaryAfterRoute(attempts, failedAt: 0, primary: .anthropic) {
            [RouterLogic.Attempt(backend: .anthropic, account: "a", token: "A", body: [:])]
        }
        XCTAssertEqual(added.map(\.account), ["a"])
        let later = attempts + [RouterLogic.Attempt(backend: .anthropic, account: nil, token: nil, body: [:])]
        XCTAssertTrue(RouterLogic.primaryAfterRoute(later, failedAt: 0, primary: .anthropic) { [] }.isEmpty)
    }

    func testPlacementEventsAndRawForwarding() {
        XCTAssertEqual(RouterLogic.placementEvents(account: "a", previousAccount: "b", startsTurn: true, isRouteTarget: false), [.assigned])
        XCTAssertEqual(RouterLogic.placementEvents(account: nil, previousAccount: nil, startsTurn: true, isRouteTarget: true), [.servedByRoute])
        XCTAssertEqual(RouterLogic.placementEvents(account: "a", previousAccount: "a", startsTurn: false, isRouteTarget: false), [])
        let members = [RouterPoolMember(accountID: "a", tokenFile: "ta"), RouterPoolMember(accountID: "b", tokenFile: "tb")]
        let tokens = ["ta": token("A"), "tb": token("B")]
        XCTAssertEqual(RouterLogic.rawForwardToken(pool: members, trusted: true, refused: ["a"], token: { tokens[$0] }, now: now), "B")
        XCTAssertNil(RouterLogic.rawForwardToken(pool: members, trusted: false, refused: [], token: { tokens[$0] }, now: now))
    }

    func testCredentialHeadersReplaceTheClientsCredentialAndDropHopHeaders() {
        let headers = [("Authorization", "Bearer client"), ("Host", "127.0.0.1"), ("anthropic-beta", "x")]
        let pooled = RouterLogic.credentialHeaders(headers, attempt: RouterLogic.Attempt(backend: .anthropic, account: "a", token: "A", body: [:]),
                                                   backendToken: nil)
        XCTAssertEqual(pooled.headers.map { "\($0.0)=\($0.1)" }, ["anthropic-beta=x", "Authorization=Bearer A"])
        XCTAssertEqual(pooled.fingerprint, RouterLogic.fingerprint("A"))
        let own = RouterLogic.credentialHeaders(headers, attempt: RouterLogic.Attempt(backend: .anthropic, account: nil, token: nil, body: [:]),
                                                backendToken: nil)
        XCTAssertEqual(own.fingerprint, RouterLogic.fingerprint("client"))
        var keyed = kimi
        keyed.auth = .apiKey
        let target = RouterLogic.credentialHeaders(headers, attempt: RouterLogic.Attempt(backend: keyed, account: nil, token: nil, body: [:]),
                                                   backendToken: "K")
        XCTAssertTrue(target.headers.contains { $0.0 == "x-api-key" && $0.1 == "K" })
        XCTAssertFalse(target.headers.contains { $0.0 == "Authorization" })
    }

    func testAPassthroughRouteServesWithinItsCapUntilItRefuses() {
        let route = PassthroughRoute(backend: kimi, routed: true)
        XCTAssertTrue(ProviderPassthrough.routeServes(route, refusedBackends: [], lastContext: 90_000, bodyBytes: 10))
        XCTAssertFalse(ProviderPassthrough.routeServes(route, refusedBackends: [], lastContext: 110_000, bodyBytes: 10))
        XCTAssertFalse(ProviderPassthrough.routeServes(route, refusedBackends: ["kimi"], lastContext: nil, bodyBytes: 10))
        XCTAssertEqual(ProviderPassthrough.routerSession("codex", "s"), "codex:s")
    }

    func testTheBrainForgetsRefusalsAndLoadAsItsClockPasses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("router-brain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let brain = RouterBrain(environment: RouterEnvironment(directory: directory, port: 1, logURL: directory.appendingPathComponent("log")),
                                now: { clock.date })
        brain.refuse("a", until: clock.date.addingTimeInterval(60))
        brain.refuseBackend("kimi", until: clock.date.addingTimeInterval(60))
        brain.setSession("s", backend: "anthropic", account: "a", cacheLifetime: 300)
        XCTAssertEqual(brain.refusedAccounts(), ["a"])
        XCTAssertEqual(brain.poolLoad(), ["a": 1])
        XCTAssertEqual(brain.session("s")?.lastServed, clock.date)
        clock.date = clock.date.addingTimeInterval(11 * 60)
        XCTAssertEqual(brain.refusedAccounts(), [])
        XCTAssertEqual(brain.refusedBackendIDs(), [])
        XCTAssertEqual(brain.poolLoad(), [:], "load counts the last ten minutes")
    }
}
