import XCTest
@testable import AccountDock

/// While capacity is scarce, a lane that frees up takes only the waiting
/// sessions it carries until its reset (`SessionPacer.admitToLanes`); the
/// rest wait for their own accounts or the next lane.
final class LaneAdmissionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fluxon = UUID(), hexorda = UUID(), cybrio = UUID(), voltrix = UUID(), big = UUID()

    /// A Max account at its limit, at one percent of its window per million
    /// weighted tokens.
    func spent(_ id: UUID, resetIn hours: Double) -> SessionPacer.Account {
        SessionPacer.Account(id: id, utilization: 100, resetsAt: now.addingTimeInterval(hours * 3600), burnPerHour: 0,
                             baseWeight: 0, weeklyRemaining: 400, weeklyResetsAt: now.addingTimeInterval(3 * 86_400),
                             percentPerMillion: 1)
    }

    /// A Pro account with a fresh window: 8.96% of it per million tokens.
    func pro(_ id: UUID, resetIn hours: Double, used: Double = 0, weeklyResetDays: Double = 4,
             weeklyLeft: Double = 800) -> SessionPacer.Account {
        SessionPacer.Account(id: id, utilization: used, resetsAt: now.addingTimeInterval(hours * 3600), burnPerHour: 0,
                             baseWeight: 1, weeklyRemaining: weeklyLeft,
                             weeklyResetsAt: now.addingTimeInterval(weeklyResetDays * 86_400), percentPerMillion: 8.96)
    }

    func session(_ id: String, on account: UUID, millionsPerHour rate: Double, context: Int,
                 quietMinutes: Double = 1) -> SessionPacer.RebalanceSession {
        SessionPacer.RebalanceSession(id: id, account: account, tokensPerHour: rate * 1_000_000, contextTokens: context,
                                      model: nil, movable: true, cacheLifetime: 3600,
                                      lastSeen: now.addingTimeInterval(-quietMinutes * 60))
    }

    /// Nine sessions wait on two spent Max accounts; cybrio, a Pro plan,
    /// has a fresh window resetting in two hours.
    func waiting() -> [SessionPacer.RebalanceSession] {
        [session("light-1", on: fluxon, millionsPerHour: 0.5, context: 100_000),
         session("light-2", on: hexorda, millionsPerHour: 0.8, context: 150_000)]
            + (1...7).map { session("heavy-\($0)", on: $0 % 2 == 0 ? fluxon : hexorda, millionsPerHour: 14 + Double($0),
                                    context: 300_000 + $0 * 50_000) }
    }

    func testAFreedSmallLaneAdmitsOnlyTheSessionsItCarriesUntilItsReset() throws {
        let accounts = [spent(fluxon, resetIn: 3), spent(hexorda, resetIn: 3.5), pro(cybrio, resetIn: 2)]
        let admission = try XCTUnwrap(SessionPacer().admitToLanes(waiting(), accounts: accounts, running: [],
                                                                  destinations: [cybrio], now: now))
        XCTAssertEqual(admission.placements, ["light-1": cybrio, "light-2": cybrio])
        XCTAssertEqual(admission.waiting.count, 7, "a session at 15M an hour would spend a Pro window in minutes")
        XCTAssertEqual(admission.lanes[cybrio], now.addingTimeInterval(2 * 3600))
        XCTAssertTrue(admission.untilReset.contains(cybrio), "their whole use until the reset fits")
        let event = AppState.laneAdmissionEvent(
            admitted: [(lane: "cybrio", count: 2, until: now.addingTimeInterval(2 * 3600), atReset: true, fresh: true)],
            waiting: 7, total: 9, now: now)
        XCTAssertEqual(event, "Session balancing admitted 2 of 9 waiting session(s) to cybrio's fresh window: they fit until its reset at \(UsageFormat.clock(now.addingTimeInterval(2 * 3600), now: now)); 7 wait for their own accounts.")
    }

    func testTheLaneIsFilledOnlyToItsRoomAndTheNextLaneTakesTheNext() throws {
        // Ten light sessions at 2M an hour with 200k of context: each costs
        // 3.6% to arrive and 17.9% an hour on a Pro window.
        let many = (0..<10).map { session(String(format: "s%02d", $0), on: fluxon, millionsPerHour: 2, context: 200_000) }
        let pacer = SessionPacer()
        let one = try XCTUnwrap(pacer.admitToLanes(many, accounts: [spent(fluxon, resetIn: 3), pro(cybrio, resetIn: 1)],
                                                   running: [], destinations: [cybrio], now: now))
        let taken = one.placements.count
        XCTAssertGreaterThan(taken, 0)
        XCTAssertLessThan(taken, 10)
        // What it took, with each arrival's cache rewrite, fits its room.
        let cost = pacer.arrivalCost(200_000, cacheLifetime: 3600, to: pro(cybrio, resetIn: 1))
        let use = pacer.percent(2_000_000, on: pro(cybrio, resetIn: 1))
        XCTAssertLessThanOrEqual(Double(taken) * (cost + use), 99 * SessionPacer.windowFitShare + 0.001)
        XCTAssertGreaterThan(Double(taken + 1) * (cost + use), 99 * SessionPacer.windowFitShare,
                             "one more would not have fitted")
        // A second lane freeing up takes the next ones.
        let two = try XCTUnwrap(pacer.admitToLanes(many, accounts: [spent(fluxon, resetIn: 3), pro(cybrio, resetIn: 1),
                                                                    pro(voltrix, resetIn: 1)],
                                                   running: [], destinations: [cybrio, voltrix], now: now))
        XCTAssertEqual(two.placements.count, 2 * taken)
        XCTAssertEqual(two.placements.values.filter { $0 == voltrix }.count, taken)
    }

    func testAnAccountWithAmpleRoomLeavesThePlacementToTheUsualSpread() {
        let roomy = SessionPacer.Account(id: big, utilization: 5, resetsAt: now.addingTimeInterval(4 * 3600), burnPerHour: 0,
                                         baseWeight: 1, weeklyRemaining: 2_000,
                                         weeklyResetsAt: now.addingTimeInterval(5 * 86_400), percentPerMillion: 0.2)
        XCTAssertNil(SessionPacer().admitToLanes(waiting(), accounts: [spent(fluxon, resetIn: 3), spent(hexorda, resetIn: 3),
                                                                       roomy, pro(cybrio, resetIn: 2)],
                                                 running: [], destinations: [big, cybrio], now: now),
                     "every waiting session fits, so `place` spreads them as before")
    }

    func testASessionWhoseOwnAccountResetsLaterThanItsCacheGoesFirst() throws {
        // Room for one: the session on the account resetting in 20 minutes
        // keeps its cache by waiting; the one on the account resetting in
        // three hours would lose it anyway.
        let soon = UUID()
        let accounts = [spent(soon, resetIn: 1.0 / 3), spent(fluxon, resetIn: 3), pro(cybrio, resetIn: 1, used: 70)]
        let sessions = [session("waits-briefly", on: soon, millionsPerHour: 1.5, context: 200_000),
                        session("waits-long", on: fluxon, millionsPerHour: 1.5, context: 200_000)]
        let admission = try XCTUnwrap(SessionPacer().admitToLanes(sessions, accounts: accounts, running: [],
                                                                  destinations: [cybrio], now: now))
        XCTAssertEqual(admission.placements, ["waits-long": cybrio])
        XCTAssertEqual(admission.waiting, ["waits-briefly"])
    }

    func testALaneWhoseWeeklyAllowanceExpiresFirstTakesTheSession() throws {
        // Both fit; voltrix's week resets tomorrow with most of it unused.
        let accounts = [spent(fluxon, resetIn: 3), spent(hexorda, resetIn: 3), pro(cybrio, resetIn: 2, used: 30),
                        pro(voltrix, resetIn: 2, used: 30, weeklyResetDays: 1)]
        let sessions = [session("light", on: fluxon, millionsPerHour: 0.5, context: 100_000),
                        session("heavy", on: hexorda, millionsPerHour: 40, context: 900_000)]
        let admission = try XCTUnwrap(SessionPacer().admitToLanes(sessions, accounts: accounts, running: [],
                                                                  destinations: [cybrio, voltrix], now: now))
        XCTAssertEqual(admission.placements["light"], voltrix)
        XCTAssertEqual(admission.waiting, ["heavy"])
    }

    func testTheCacheRewriteCountsInTheLanesRoom() {
        // 0.3M an hour fits a Pro window's last 15% for the hour, but its
        // 900k context costs 16% to arrive.
        let accounts = [spent(fluxon, resetIn: 3), pro(cybrio, resetIn: 1, used: 84)]
        let admission = SessionPacer().admitToLanes([session("big-context", on: fluxon, millionsPerHour: 0.3, context: 900_000)],
                                                    accounts: accounts, running: [], destinations: [cybrio], now: now)
        XCTAssertEqual(admission?.waiting, ["big-context"])
        XCTAssertEqual(admission?.placements, [:])
    }
}
