import XCTest
@testable import AccountDock

/// A heavy session lane admission leaves waiting (`HeldSessionPlan`): it
/// waits for the earliest lane, its own account or another, moves now only
/// where that serves more, and keeps its cache by waiting when its own
/// account resets first; the slot path for an account that can no longer
/// serve leaves it where admission keeps it.
final class HeldSessionPlanTests: XCTestCase {
    /// 10:10 pm, when platform-execution was refused on bytrix.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bytrix = UUID(), fluxon = UUID(), hexorda = UUID(), cybrio = UUID(), backup = UUID()
    let max5x = 0.25, max20x = 0.0625

    func hours(_ value: Double) -> Date { now.addingTimeInterval(value * 3600) }

    func account(_ id: UUID, _ name: String, ratio: Double, windowUsed: Double, windowResetIn: Double,
                 weeklyUsed: Double, weeklyResetIn: Double,
                 availability: CapacityOutlook.Availability) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: windowUsed, resetsAt: hours(windowResetIn), burnPerHour: 0,
                                        baseWeight: 1, weeklyRemaining: (SessionPacer().limit - weeklyUsed) * 8,
                                        weeklyResetsAt: hours(weeklyResetIn), percentPerMillion: ratio),
            name: name, availability: availability)
    }

    /// bytrix, where the session runs, is at its 5-hour limit until 1:30 am
    /// and its week renews at 1 am; fluxon's window, also at its limit,
    /// resets at 12:50 am; hexorda has 14% of its window left until 1:10 am,
    /// which its own sessions use at 10M tokens an hour; Backup's week is
    /// spent until next week.
    func tonight() -> [CapacityOutlook.Account] {
        [account(bytrix, "bytrix", ratio: max5x, windowUsed: 99.5, windowResetIn: 3 + 20.0 / 60, weeklyUsed: 40,
                 weeklyResetIn: 2 + 50.0 / 60, availability: .atLimit),
         account(fluxon, "fluxon", ratio: max20x, windowUsed: 99.5, windowResetIn: 2 + 40.0 / 60, weeklyUsed: 50,
                 weeklyResetIn: 25, availability: .atLimit),
         account(hexorda, "hexorda", ratio: max5x, windowUsed: 85, windowResetIn: 3, weeklyUsed: 30, weeklyResetIn: 100,
                 availability: .serves),
         account(backup, "Backup", ratio: max20x, windowUsed: 10, windowResetIn: 4, weeklyUsed: 100, weeklyResetIn: 150,
                 availability: .atLimit)]
    }

    /// platform-execution: about 94M weighted tokens an hour with 245k
    /// tokens of context, last heard a minute ago.
    func platformExecution(lastSeenMinutesAgo: Double = 1) -> HeldSessionPlan.Session {
        HeldSessionPlan.Session(id: "583fb354", account: bytrix, tokensPerHour: 94_000_000, contextTokens: 245_000,
                                cacheLifetime: 3600, lastSeen: now.addingTimeInterval(-lastSeenMinutesAgo * 60))
    }

    /// The plan with hexorda's own sessions at 10M tokens an hour.
    func decide(_ accounts: [CapacityOutlook.Account], lanes: Set<UUID>) -> HeldSessionPlan? {
        HeldSessionPlan.decide(platformExecution(), accounts: accounts, base: [hexorda: 10_000_000], lanes: lanes, now: now)
    }

    func testItWaitsForTheEarliestLaneRatherThanItsOwnAccount() throws {
        let plan = try XCTUnwrap(decide(tonight(), lanes: [hexorda]))
        // fluxon's window resets at 12:50 am, 40 minutes before bytrix's;
        // bytrix's new week at 1 am leaves its window at the limit.
        XCTAssertEqual(plan.choice, .wait)
        XCTAssertEqual(plan.lane, fluxon)
        XCTAssertEqual(plan.at.timeIntervalSince(hours(2 + 40.0 / 60)), 0, accuracy: 1)
        XCTAssertEqual(plan.refill, .windowRefill)
        XCTAssertEqual(try XCTUnwrap(plan.ownBack).timeIntervalSince(hours(3 + 20.0 / 60)), 0, accuracy: 1)
        // Moving to hexorda now would fill its last 14% in half an hour and
        // refuse its own sessions until 1:10 am: less work than waiting.
        let moving = try XCTUnwrap(plan.servedMoving)
        XCTAssertLessThan(moving, plan.servedWaiting)
        XCTAssertEqual(plan.servedWaiting, 94_000_000, accuracy: 1_000_000)
        let event = plan.event(session: "platform-execution", now: now)
        XCTAssertTrue(event.hasPrefix("platform-execution waits: no lane carries it for an hour; it resumes on fluxon at "), event)
        XCTAssertTrue(event.hasSuffix(", when fluxon's window resets — 40 min before bytrix's."), event)
        XCTAssertTrue(plan.rowNote(now: now).hasPrefix("resumes on fluxon about "))
    }

    func testItMovesNowWhereALaneServesMoreThanWaiting() throws {
        // cybrio has 24% of its window left for the next 90 minutes and
        // nothing on it: not an hour of the session, but room that would
        // expire unused, and a fresh window after.
        let accounts = tonight() + [account(cybrio, "cybrio", ratio: max5x, windowUsed: 75, windowResetIn: 1.5,
                                            weeklyUsed: 20, weeklyResetIn: 90, availability: .serves)]
        let plan = try XCTUnwrap(decide(accounts, lanes: [hexorda, cybrio]))
        XCTAssertEqual(plan.choice, .move)
        XCTAssertEqual(plan.lane, cybrio)
        XCTAssertEqual(plan.at, now)
        XCTAssertGreaterThan(try XCTUnwrap(plan.servedMoving), plan.servedWaiting)
        let event = plan.event(session: "platform-execution", now: now)
        XCTAssertTrue(event.hasPrefix("platform-execution moved to cybrio: no lane carries it for an hour, but it serves more there before "), event)
        XCTAssertTrue(event.hasSuffix(" than waiting would."), event)
    }

    func testASessionWhoseAccountResetsWithinItsCacheWaitsThere() throws {
        // bytrix resets in 40 minutes, within the hour its cache lasts: it
        // keeps its cache by waiting, however much cybrio could serve.
        var accounts = tonight() + [account(cybrio, "cybrio", ratio: max5x, windowUsed: 75, windowResetIn: 1.5,
                                            weeklyUsed: 20, weeklyResetIn: 90, availability: .serves)]
        accounts[0].pacer.resetsAt = hours(40.0 / 60)
        let plan = try XCTUnwrap(decide(accounts, lanes: [hexorda, cybrio]))
        XCTAssertEqual(plan.choice, .wait)
        XCTAssertEqual(plan.lane, bytrix)
        XCTAssertNil(plan.servedMoving)
        XCTAssertTrue(plan.event(session: "platform-execution", now: now).contains(", when its window resets."))
    }

    func testNoLaneWithinTheWeekLeavesNoPlan() {
        let spent = [account(bytrix, "bytrix", ratio: max5x, windowUsed: 99.5, windowResetIn: 2, weeklyUsed: 100,
                             weeklyResetIn: 24 * 8, availability: .atLimit)]
        XCTAssertNil(decide(spent, lanes: []))
    }

    func testAWaitIsPlacedOnItsLaneOnceItsResetIsConfirmed() throws {
        let plan = try XCTUnwrap(decide(tonight(), lanes: [hexorda]))
        let grace: TimeInterval = 10 * 60
        XCTAssertEqual(HeldSessionPlan.due(plan, destinations: [fluxon], now: hours(2), grace: grace), .replan)
        XCTAssertEqual(HeldSessionPlan.due(plan, destinations: [], now: plan.at.addingTimeInterval(60), grace: grace), .stand)
        XCTAssertEqual(HeldSessionPlan.due(plan, destinations: [fluxon], now: plan.at.addingTimeInterval(60), grace: grace),
                       .place(fluxon))
        XCTAssertEqual(HeldSessionPlan.due(plan, destinations: [], now: plan.at.addingTimeInterval(grace + 60), grace: grace),
                       .replan)
        XCTAssertTrue(plan.same(as: plan))
        var later = plan
        later.at = plan.at.addingTimeInterval(20 * 60)
        XCTAssertFalse(plan.same(as: later))
    }

    func testTheSlotOfASessionAdmissionKeepsStaysUntilAdmissionPlacesIt() {
        let cannotServe: (UUID) -> Bool = { $0 == self.bytrix }
        // Played after admission held it: the path for an account that can
        // no longer serve leaves it on bytrix rather than the pool's choice.
        let kept = AppState.slotChoice(current: bytrix, pinned: nil, requested: nil, balance: nil, cannotServe: cannotServe,
                                       modelSpent: false, byWeight: [hexorda], placed: nil, fallback: hexorda,
                                       heldOn: bytrix)
        XCTAssertEqual(kept.target, bytrix)
        // Admission's own placement, its planned lane once confirmed, wins.
        let placed = AppState.slotChoice(current: bytrix, pinned: nil, requested: nil, balance: nil, cannotServe: cannotServe,
                                         modelSpent: false, byWeight: [hexorda], placed: fluxon, fallback: hexorda,
                                         heldOn: bytrix)
        XCTAssertEqual(placed.target, fluxon)
        // The user's move wins over both.
        let asked = AppState.slotChoice(current: bytrix, pinned: nil, requested: backup, balance: nil,
                                        cannotServe: cannotServe, modelSpent: false, byWeight: [hexorda], placed: fluxon,
                                        fallback: hexorda, heldOn: bytrix)
        XCTAssertEqual(asked.target, backup)
        XCTAssertTrue(asked.requested)
        // Without admission's hold it goes to the pool's choice as before.
        let free = AppState.slotChoice(current: bytrix, pinned: nil, requested: nil, balance: nil, cannotServe: cannotServe,
                                       modelSpent: false, byWeight: [hexorda], placed: nil, fallback: hexorda)
        XCTAssertEqual(free.target, hexorda)
    }
}
