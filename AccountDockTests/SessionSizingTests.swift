import XCTest
@testable import AccountDock

/// The router and the app size sessions by one rule (`SessionSizing`): the
/// same measured context decides whether a route target takes a session
/// and whether the app holds it, the same lifetime decides when its cache
/// is cold, and a move costs the same in the pacer and the turn-cost model.
final class SessionSizingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = UUID()

    private func brain() throws -> RouterBrain {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("router-sizing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = now
        return RouterBrain(environment: RouterEnvironment(directory: directory, port: 1, logURL: directory.appendingPathComponent("log")),
                           now: { now })
    }

    func testTheRouterRoutesExactlyTheSessionsTheAppDoesNotHold() throws {
        let cap = 100_000
        let target = RouterBackend(id: "kimi", displayName: "Kimi", baseURL: "https://kimi.test", auth: .bearer,
                                   tokenFile: "target-kimi", maxContextTokens: cap)
        var state = RouterState()
        state.backends.append(target)
        state.route = "kimi"
        let request: [String: Any] = ["model": "m", "metadata": ["user_id": "u_session_s"],
                                      "messages": [["role": "user", "content": "hi"]]]
        for context in [1, 40_000, 99_999, 100_000, 100_001, 250_000] {
            for bodyBytes in [10, 2_000_000] {
                // The same reply's usage reaches both sides.
                var rates = SessionRates()
                rates.record(session: "s", account: account, context: context, cacheWrite: 0, output: 10, cacheLifetime: 300, at: now)
                let brain = try brain()
                brain.noteContext("s", tokens: context)
                let appHolds = SessionSizing.contextTokens(lastMeasured: rates.entries["s"]?.contextTokens, bodyBytes: 0) > cap
                let plan = RouterLogic.planMessages(
                    request, bodyBytes: bodyBytes, state: state, primary: .anthropic, previous: nil,
                    lastContext: brain.sessionContext("s"), refusedBackends: [],
                    pool: RouterLogic.PoolView(unavailable: [], load: [:], token: { _ in nil }), now: now
                )
                let routerRoutes = plan.attempts.first?.backend.id == "kimi"
                XCTAssertEqual(routerRoutes, !appHolds, "context \(context), body \(bodyBytes)")
                let bridged = ProviderPassthrough.routeServes(PassthroughRoute(backend: target, routed: true), refusedBackends: [],
                                                              lastContext: brain.sessionContext("s"), bodyBytes: bodyBytes)
                XCTAssertEqual(bridged, !appHolds, "bridged context \(context), body \(bodyBytes)")
            }
        }
    }

    func testTheRouterAndTheAppAgreeWhenACacheGoesCold() throws {
        var state = RouterState()
        state.cacheAwareSessions = true
        let request: [String: Any] = ["model": "m", "metadata": ["user_id": "u_session_s"],
                                      "messages": [["role": "user", "content": "hi"]]]
        for lifetime in [nil, 300, 3600] as [TimeInterval?] {
            for elapsed in [200, 400, 3_000, 4_000] as [TimeInterval] {
                var rates = SessionRates()
                rates.record(session: "s", account: account, context: 10_000, cacheWrite: 0, output: 10,
                             cacheLifetime: lifetime, at: now)
                // A later request without cache marks keeps the lifetime
                // on both sides.
                rates.record(session: "s", account: account, context: 10_000, cacheWrite: 0, output: 10,
                             cacheLifetime: nil, at: now)
                let brain = try brain()
                brain.setSession("s", backend: "anthropic", account: nil, cacheLifetime: lifetime)
                brain.setSession("s", backend: "anthropic", account: nil, cacheLifetime: nil)
                let entry = try XCTUnwrap(rates.entries["s"])
                let later = now.addingTimeInterval(elapsed)
                let appCold = later > entry.lastSeen.addingTimeInterval(entry.cacheLifetime ?? SessionPacer.defaultCacheLifetime)
                let plan = RouterLogic.planMessages(
                    request, bodyBytes: 100, state: state, primary: .anthropic, previous: brain.session("s"),
                    lastContext: nil, refusedBackends: [],
                    pool: RouterLogic.PoolView(unavailable: [], load: [:], token: { _ in nil }), now: later
                )
                XCTAssertEqual(plan.cacheExpired, appCold, "lifetime \(String(describing: lifetime)), \(elapsed) s later")
            }
        }
    }

    func testAMoveCostsTheSameInThePacerAndTheTurnCostModel() {
        for (context, ratio) in [(0, 0.5), (180_000, 0.5), (900_000, 4.2), (50_000, 0.02)] {
            let pacer = SessionPacer().moveCost(context, to: SessionPacer.Account(
                id: account, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1, percentPerMillion: ratio))
            var model = TurnCostModel()
            model.percentPerMillion = ratio
            model.recordRequest(session: "s", account: account, context: context, cacheWrite: 0, output: 0, at: now)
            XCTAssertEqual(pacer, SessionSizing.moveCost(context, percentPerMillion: ratio))
            XCTAssertEqual(model.switchCost(sessionsOn: account, now: now), pacer, accuracy: 1e-12)
            XCTAssertEqual(SessionPacer(moveCostFactor: 3).moveCost(context, to: SessionPacer.Account(
                id: account, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1, percentPerMillion: ratio)),
                           SessionSizing.moveCost(context, percentPerMillion: ratio, factor: 3))
        }
        XCTAssertEqual(TurnCostModel.weighted(context: 100_000, cacheWrite: 20_000, output: 1_000, cacheWriteLong: 5_000),
                       SessionSizing.weighted(context: 100_000, cacheWrite: 20_000, output: 1_000, cacheWriteLong: 5_000))
    }

    func testAMeasuredContextOutranksTheBodyEstimate() {
        XCTAssertEqual(SessionSizing.contextTokens(lastMeasured: 50_000, bodyBytes: 4_000_000), 50_000)
        XCTAssertEqual(SessionSizing.contextTokens(lastMeasured: nil, bodyBytes: 4_000), 1_000)
        XCTAssertEqual(SessionSizing.contextTokens(lastMeasured: 0, bodyBytes: 4_000), 1_000)
        XCTAssertEqual(RouterLogic.expectedContext(lastMeasured: 50_000, bodyBytes: 4_000_000), 50_000)
    }
}
