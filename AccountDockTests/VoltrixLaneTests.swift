import XCTest
@testable import AccountDock

/// At 18:31 voltrix, a Pro plan (8.96% of its 5-hour window per million
/// weighted tokens), had an empty window resetting at 20:30 and took new
/// sessions, yet no running session moved there. The heavy sessions use
/// 14 to 21M tokens an hour; 19496bb9 used 0.5M over its last hour with
/// 295k of context and had been quiet 43 minutes, 345dc95e 0.4M with 892k
/// and quiet 22. A session its user answers now and then is light but in
/// use, and 19496bb9's move frees more room than its rewrite spends there.
final class VoltrixLaneTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cybrio = UUID(), fluxon = UUID(), voltrix = UUID()

    func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// cybrio and fluxon carry the heavy sessions and reach their limits
    /// shortly before their resets; voltrix has its whole window to 20:30.
    func accounts() -> [SessionPacer.Account] {
        [SessionPacer.Account(id: cybrio, utilization: 70, resetsAt: at(minutes: 50), burnPerHour: 0, baseWeight: 1,
                              weeklyRemaining: 400, weeklyResetsAt: now.addingTimeInterval(3 * 86_400), percentPerMillion: 1.8),
         SessionPacer.Account(id: fluxon, utilization: 80, resetsAt: at(minutes: 45), burnPerHour: 0, baseWeight: 1,
                              weeklyRemaining: 400, weeklyResetsAt: now.addingTimeInterval(3 * 86_400), percentPerMillion: 1.8),
         SessionPacer.Account(id: voltrix, utilization: 0, resetsAt: at(minutes: 119), burnPerHour: 0, baseWeight: 1,
                              weeklyRemaining: 800, weeklyResetsAt: now.addingTimeInterval(6 * 86_400), percentPerMillion: 8.96)]
    }

    /// A session quiet `quiet` minutes whose last hour's rate is `recent`
    /// million tokens an hour; its current rate has faded with the quiet.
    func session(_ id: String, on account: UUID, recent: Double, context: Int, quiet: Double,
                 turnStarted: Double? = nil) -> SessionPacer.Session {
        SessionPacer.Session(id: id, account: account, tokensPerHour: recent * 1_000_000 * exp(-quiet / 20),
                             contextTokens: context, lastSeen: at(minutes: -quiet), cacheLifetime: 3600,
                             lastTurnStart: turnStarted.map { at(minutes: -$0) }, recentTokensPerHour: recent * 1_000_000)
    }

    func sessions(light recent: Double = 0.5) -> [SessionPacer.Session] {
        [session("heavy-21", on: cybrio, recent: 21, context: 600_000, quiet: 1, turnStarted: 30),
         session("heavy-14", on: cybrio, recent: 14, context: 400_000, quiet: 1, turnStarted: 25),
         session("heavy-18", on: fluxon, recent: 18, context: 500_000, quiet: 1, turnStarted: 40),
         session("19496bb9", on: fluxon, recent: recent, context: 295_000, quiet: 43),
         session("345dc95e", on: cybrio, recent: 0.4, context: 892_000, quiet: 22),
         session("1603da04", on: fluxon, recent: 0, context: 300_000, quiet: 180),
         session("5386173b", on: cybrio, recent: 0, context: 200_000, quiet: 240),
         session("075198d6", on: cybrio, recent: 0, context: 611_000, quiet: 300)]
    }

    func spending() -> SessionPacer.RemainderSpending {
        SessionPacer.RemainderSpending(accounts: [voltrix], sessions: Set(sessions().map(\.id)))
    }

    func testALightSessionStillInUseMovesToTheProWindowAndTheLargeContextOneStays() {
        let pacer = SessionPacer()
        XCTAssertTrue(pacer.spends(sessions()[3], now: now), "0.5M over its last hour, quiet 43 minutes")
        XCTAssertFalse(pacer.spends(sessions()[5], now: now), "nothing in its last hour")
        let plan = pacer.plan(accounts: accounts(), sessions: sessions(), now: now, remainders: spending())
        XCTAssertTrue(plan.windowsOpen, "cybrio and fluxon spend what they hold before their resets")
        XCTAssertEqual(plan.moves, ["19496bb9": voltrix])
        // Its rewrite costs 5.3% of voltrix's window and its use until the
        // reset 8.9%: less than twice the rewrite, but 3.6% of room gained.
        let cost = pacer.arrivalCost(295_000, cacheLifetime: 3600, to: accounts()[2])
        XCTAssertEqual(cost, 5.29, accuracy: 0.01)
        XCTAssertTrue(SessionPacer.worthMoving(use: 8.9, cost: cost))
        XCTAssertFalse(SessionPacer.worthMoving(use: 7.1, cost: pacer.arrivalCost(892_000, cacheLifetime: 3600,
                                                                                   to: accounts()[2])),
                       "892k of context is not rewritten to move 0.4M an hour")
    }

    func testASessionThatUsedNothingInItsLastHourStaysWhereItIs() {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(light: 0), now: now, remainders: spending())
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testTheReasonVoltrixTakesNoSessionIsSaid() {
        let pacer = SessionPacer()
        let lane = accounts()[2]
        // With only the large-context session light enough, its rewrite
        // outweighs its use.
        let withoutLight = sessions().filter { $0.id != "19496bb9" }
        guard case .rewriteOutweighsUse(let id, let rewrite, let use) = pacer.laneShortfall(
            lane, room: 99, sessions: withoutLight, windowsOpen: true, now: now) else {
            return XCTFail("expected the rewrite to outweigh the use")
        }
        XCTAssertEqual(id, "345dc95e")
        XCTAssertGreaterThan(rewrite, use)
        // With only heavy sessions between turns, the lightest fills the window in minutes.
        let heavy = [session("heavy-14", on: cybrio, recent: 14, context: 400_000, quiet: 5)]
        XCTAssertEqual(pacer.laneShortfall(lane, room: 99, sessions: heavy, windowsOpen: true, now: now),
                       .fillsTooSoon(session: "heavy-14", minutes: 44))
        XCTAssertEqual(pacer.laneShortfall(lane, room: 99, sessions: sessions(light: 0).filter { $0.id != "345dc95e" },
                                           windowsOpen: true, now: now), .noActiveSession)
        XCTAssertNil(pacer.laneShortfall(lane, room: 99, sessions: sessions(), windowsOpen: true, now: now),
                     "19496bb9 goes")
        XCTAssertEqual(pacer.laneShortfall(lane, room: 99, sessions: sessions(), windowsOpen: false, now: now),
                       .carriersHaveRoom(session: "19496bb9"))
        XCTAssertNil(pacer.laneShortfall(lane, room: 1.5, sessions: sessions(), windowsOpen: true, now: now))
        XCTAssertEqual(AppState.laneShortfallNote(account: "voltrix", shortfall: .fillsTooSoon(session: "heavy-14", minutes: 40),
                                                  session: "session heavy-14"),
                       "voltrix: no running session fits; the lightest active one (session heavy-14) would use its window in 40 min.")
    }

    func testAnIdleAccountWithAnOldReadingIsReadToStayADestination() {
        let old = UUID(), recent = UUID(), tried = UUID()
        let candidates: [(id: UUID, readAt: Date?)] = [(old, at(minutes: -72)), (recent, at(minutes: -5)),
                                                       (tried, at(minutes: -90))]
        XCTAssertEqual(AppState.idleDestinationDue(candidates, tried: [tried: at(minutes: -3)], now: now), old,
                       "the one read longest ago that was not just tried")
        XCTAssertEqual(AppState.idleDestinationDue(candidates, tried: [:], now: now), tried)
        XCTAssertNil(AppState.idleDestinationDue([(recent, at(minutes: -5))], tried: [:], now: now))
    }

    @MainActor
    func testARebalanceCountsALightSessionStillInUseAtItsLastHoursRate() {
        XCTAssertEqual(AppState.rebalanceRate(current: 58_000, recent: 500_000, lastSeen: at(minutes: -43), now: now), 500_000)
        XCTAssertEqual(AppState.rebalanceRate(current: 1_000, recent: 0, lastSeen: at(minutes: -180), now: now), 1_000)
    }
}
