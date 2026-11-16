import XCTest
@testable import AccountDock

/// No session is sent, moved or released onto an account without a fresh
/// reading showing room for everything sent there (`freshForArrivals`,
/// `AppState.release`), and an account that refused a request stays at its
/// limit until the reset the refusal states. On the night every account
/// reached its limit, the pause ended at 12:21 am on a belief that cybrio
/// had room, and cybrio refused all thirteen sessions twenty seconds later.
final class FreshArrivalTests: XCTestCase {
    let melbourne: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }()

    /// 12:21:45 am on 17 November in Melbourne.
    var now: Date {
        melbourne.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 0, minute: 21, second: 45))!
    }

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    func testOnlyAFreshReadingLetsSessionsArrive() {
        XCTAssertTrue(AppState.freshForArrivals(readAt: minutes(-2), resetUnconfirmed: false, refused: false, now: now))
        XCTAssertFalse(AppState.freshForArrivals(readAt: minutes(-6), resetUnconfirmed: false, refused: false, now: now),
                       "a reading six minutes old is a belief, not a reading")
        XCTAssertFalse(AppState.freshForArrivals(readAt: nil, resetUnconfirmed: false, refused: false, now: now))
        XCTAssertFalse(AppState.freshForArrivals(readAt: minutes(-1), resetUnconfirmed: true, refused: false, now: now),
                       "a reset no reading confirmed leaves the reading describing the window before it")
        XCTAssertFalse(AppState.freshForArrivals(readAt: minutes(-1), resetUnconfirmed: false, refused: true, now: now),
                       "a refusal since stands over any reading")
    }

    func testARefusalKeepsItsAccountAtItsLimitUntilTheResetItStates() throws {
        let words = "You've hit your session limit · resets 1:30am (Australia/Melbourne)"
        let refusedAt = minutes(-3.0 / 60)
        let until = AppState.refusalHolds(words: words, at: refusedAt, calendar: melbourne)
        XCTAssertEqual(melbourne.component(.hour, from: until), 1)
        XCTAssertEqual(melbourne.component(.minute, from: until), 30)
        XCTAssertEqual(until.timeIntervalSince(now), 68 * 60 + 15, accuracy: 1)
        // With no reset in its words, it stands for `refusalStanding`.
        XCTAssertEqual(AppState.refusalHolds(words: "Usage limit reached.", at: refusedAt, calendar: melbourne),
                       refusedAt.addingTimeInterval(AppState.refusalStanding))
    }

    /// cybrio once its window resets at 1:30 am, as a fresh reading shows
    /// it: an empty Max 5x window at 4.25% per million weighted tokens.
    func freshCybrio(_ id: UUID) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: 0, resetsAt: minutes(300), burnPerHour: 0, baseWeight: 1,
                                        weeklyRemaining: 400, weeklyResetsAt: minutes(5 * 24 * 60), percentPerMillion: 4.25),
            name: "cybrio")
    }

    /// The thirteen sessions held on cybrio, in millions of weighted tokens
    /// an hour, in the order a pause lists them.
    let held: [(id: String, rate: Double)] = [
        ("/slots/run-1", 10), ("/slots/run-2", 10), ("075198d6", 17), ("AccountDock", 18), ("AreaShare", 15),
        ("Mother", 15), ("cf-builder", 32), ("cf-designer", 26), ("continues-field", 30), ("ion-ga", 20),
        ("platform-app", 22), ("platform-engineer", 28), ("platform-execution", 35)]

    func release(on account: CapacityOutlook.Account, fresh: Bool, ledger: inout LaneLedger) -> [String] {
        let holding = Set(held.map(\.id))
        return held.filter { session in
            AppState.release(session.id, tokensPerHour: session.rate * 1_000_000, on: account, fresh: fresh,
                             holding: holding, running: [], ledger: &ledger, now: now, pacer: SessionPacer())
        }.map(\.id)
    }

    func testThePauseReleasesOnlyWhatAFreshReadingHasRoomForTogether() {
        let cybrio = UUID()
        var ledger = LaneLedger(startedAt: now)
        let released = release(on: freshCybrio(cybrio), fresh: true, ledger: &ledger)
        // 21M tokens an hour fit the fresh window with its margin: the two
        // runs; the other eleven keep waiting rather than all resuming.
        XCTAssertEqual(released, ["/slots/run-1", "/slots/run-2"])
        XCTAssertEqual(ledger.charges(on: cybrio).map(\.kind), [.released, .released])
        XCTAssertEqual(ledger.tokensPerHour(on: cybrio, at: now), 20_000_000)
    }

    func testABeliefOfRoomReleasesNothing() {
        var ledger = LaneLedger(startedAt: now)
        XCTAssertEqual(release(on: freshCybrio(UUID()), fresh: false, ledger: &ledger), [],
                       "without a fresh reading the pause does not end on a belief of room")
        XCTAssertTrue(ledger.charges.isEmpty)
    }

    func testASessionNoWindowHoldsStillGoesOnAloneOnAnEmptyAccount() {
        let cybrio = UUID()
        var ledger = LaneLedger(startedAt: now)
        let account = freshCybrio(cybrio)
        XCTAssertTrue(AppState.release("platform-execution", tokensPerHour: 35_000_000, on: account, fresh: true,
                                       holding: ["platform-execution", "cf-builder"], running: [], ledger: &ledger,
                                       now: now, pacer: SessionPacer()),
                      "35M an hour fills the window in 40 minutes, but waiting would never change that")
        XCTAssertFalse(AppState.release("cf-builder", tokensPerHour: 32_000_000, on: account, fresh: true,
                                        holding: ["platform-execution", "cf-builder"], running: [], ledger: &ledger,
                                        now: now, pacer: SessionPacer()),
                       "the second does not join it")
    }

    func testWhatTheCycleAlreadySentThereCountsAgainstARelease() {
        let cybrio = UUID()
        var ledger = LaneLedger(startedAt: now)
        ledger.charge(LaneLedger.Charge(session: "moved", lane: cybrio, tokensPerHour: 15_000_000, arrivalTokens: 1_000_000,
                                        from: now, kind: .placed))
        XCTAssertFalse(AppState.release("AccountDock", tokensPerHour: 18_000_000, on: freshCybrio(cybrio), fresh: true,
                                        holding: ["AccountDock"], running: [], ledger: &ledger, now: now,
                                        pacer: SessionPacer()))
        // The session the cycle itself placed there goes on.
        XCTAssertTrue(AppState.release("moved", tokensPerHour: 15_000_000, on: freshCybrio(cybrio), fresh: false,
                                       holding: ["moved"], running: [], ledger: &ledger, now: now, pacer: SessionPacer()))
    }

    func testAnIdleDestinationIsReadWithinMinutesWhileSessionsWait() {
        let stale = UUID(), recent = UUID()
        let candidates: [(id: UUID, readAt: Date?)] = [(stale, minutes(-6)), (recent, minutes(-2))]
        XCTAssertNil(AppState.idleDestinationDue(candidates, tried: [:], now: now), "fifteen minutes when nothing waits")
        XCTAssertEqual(AppState.idleDestinationDue(candidates, tried: [:], now: now, freshness: AppState.arrivalReadingAge),
                       stale)
    }
}
