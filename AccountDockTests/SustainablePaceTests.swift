import XCTest
@testable import AccountDock

/// Pacing to the resets (`SustainablePace`) on a fixture of the morning of
/// 21 November, when fourteen sessions would have spent Personal's and
/// hexorda's fresh weeks in about four hours and then waited until Monday.
final class SustainablePaceTests: XCTestCase {
    /// Saturday 21 November 2026, 8:22 am in Melbourne: the fixture's
    /// resets are counted from here in hours.
    let now = Date(timeIntervalSince1970: 1_795_209_720)
    let personal = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID(), fluxon = UUID(), voltrix = UUID()
    let backup = UUID(), hstles = UUID()

    /// Window percent per million weighted tokens: a Max 5x percent holds a
    /// quarter of the work of a Max 20x one. The fixture's universe is
    /// scaled so the flat-out rate spends Personal's and hexorda's weeks in
    /// about four hours, as the Outlook read that morning.
    let max20x = 0.09, max5x = 0.36

    func hours(_ value: Double) -> Date { now.addingTimeInterval(value * 3600) }

    /// Hours from the fixture's now to a weekday's time this coming week.
    let monday8am = 47 + 38.0 / 60

    /// An account `windowUsed`% into a 5-hour window resetting in
    /// `windowResetIn` hours (none running when nil), `weeklyUsed`% into a
    /// week renewing in `weeklyResetIn` hours, one weekly percent costing
    /// one window percent.
    func account(_ id: UUID, _ name: String, ratio: Double, windowUsed: Double = 0, windowResetIn: Double? = nil,
                 weeklyUsed: Double, weeklyResetIn: Double,
                 availability: CapacityOutlook.Availability = .serves) -> CapacityOutlook.Account {
        let limit = SessionPacer().limit
        return CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: windowResetIn == nil ? 0 : windowUsed,
                                        resetsAt: windowResetIn.map(hours), burnPerHour: 0, baseWeight: 1,
                                        weeklyRemaining: limit - weeklyUsed, weeklyResetsAt: hours(weeklyResetIn),
                                        percentPerMillion: ratio),
            name: name, sessionPerWeekly: 1, availability: availability)
    }

    /// 21 November, 8:22 am: Personal (Max 20x) 13% into a week renewing
    /// Saturday midnight, hexorda (Max 5x) 4% into one renewing Saturday
    /// 5 am with its 5-hour window not started, and six accounts at 99-100%
    /// of weeks renewing from Monday 8 am (bytrix) to Tuesday 11 pm.
    func november21(hexordaRatio: Double? = nil) -> [CapacityOutlook.Account] {
        [account(personal, "Personal", ratio: max20x, windowUsed: 20, windowResetIn: 2, weeklyUsed: 13,
                 weeklyResetIn: 159 + 38.0 / 60),
         account(hexorda, "hexorda", ratio: hexordaRatio ?? max5x, weeklyUsed: 4, weeklyResetIn: 164 + 38.0 / 60),
         account(bytrix, "bytrix", ratio: max5x, weeklyUsed: 100, weeklyResetIn: monday8am, availability: .atLimit),
         account(cybrio, "cybrio", ratio: max5x, weeklyUsed: 99, weeklyResetIn: 60 + 38.0 / 60),
         account(fluxon, "fluxon", ratio: max5x, weeklyUsed: 100, weeklyResetIn: 62 + 38.0 / 60, availability: .atLimit),
         account(voltrix, "voltrix", ratio: max5x, weeklyUsed: 99, weeklyResetIn: 72 + 38.0 / 60),
         account(backup, "Backup", ratio: max20x, weeklyUsed: 99, weeklyResetIn: 78 + 38.0 / 60),
         account(hstles, "HSTLES", ratio: max5x, weeklyUsed: 100, weeklyResetIn: 86 + 38.0 / 60, availability: .atLimit)]
    }

    /// Fourteen sessions, 302M tokens an hour together: a few heavy ones,
    /// several light ones and one idle.
    let rates: [(String, Double)] = [("cf-builder", 117), ("platform-engineer", 52), ("cf-designer", 28), ("reviewer", 26),
                                     ("docs", 22), ("router", 14), ("tests", 12), ("notes", 10), ("lint", 7),
                                     ("scout", 5), ("sync", 4), ("watch", 3), ("tidy", 2), ("idle", 0)]

    var flatOut: Double { rates.reduce(0) { $0 + $1.1 } * 1_000_000 }

    func target(_ accounts: [CapacityOutlook.Account]? = nil) throws -> SustainablePace.Target {
        try XCTUnwrap(SustainablePace.target(accounts: accounts ?? november21(), flatOut: flatOut, now: now))
    }

    // MARK: - The target

    func testTheTargetOnTheTwentyFirstOfNovemberIsWhatPersonalAndHexordaCarryUntilBytrixsNewWeek() throws {
        XCTAssertEqual(flatOut, 302_000_000)
        let target = try target()
        // Flat out, Personal's and hexorda's weeks (86 and 95 window
        // percent, 956M and 264M tokens) last about four hours.
        XCTAssertEqual(target.flatOutPausedAt.timeIntervalSince(now) / 3600, 4.04, accuracy: 0.1, "about 12:24 pm")
        XCTAssertEqual(target.until, hours(monday8am), "capacity returns with bytrix's new week on Monday at 8 am")
        XCTAssertEqual(target.untilAccount, "bytrix")
        // What they hold, spread over the 47 hours until then.
        XCTAssertEqual(target.tokensPerHour / 1_000_000, 1219.4 / (monday8am - 0.25), accuracy: 0.3)

        // At that rate nothing pauses before Monday; a tenth more pauses
        // everything before it.
        let carried = CapacityOutlook.run(november21(), demand: .init(tokensPerHour: target.tokensPerHour), now: now,
                                          step: SustainablePace.searchStep, horizon: monday8am * 3600, reach: .firstPause)
        XCTAssertNil(carried.allPausedAt.flatMap { $0 < hours(monday8am - 0.25) ? $0 : nil })
        let faster = CapacityOutlook.run(november21(), demand: .init(tokensPerHour: target.tokensPerHour * 1.1), now: now,
                                         step: SustainablePace.searchStep, horizon: monday8am * 3600, reach: .firstPause)
        XCTAssertLessThan(try XCTUnwrap(faster.allPausedAt), hours(monday8am - 1))

        // The flat-out Outlook agrees: paused from about 12:24 pm until
        // Monday 8 am.
        let outlook = CapacityOutlook.project(
            accounts: november21(),
            sessions: rates.map { CapacityOutlook.Session(id: $0.0, label: $0.0, tokensPerHour: $0.1 * 1_000_000) }, now: now)
        XCTAssertEqual(try XCTUnwrap(outlook.allPausedAt).timeIntervalSince(target.flatOutPausedAt), 0, accuracy: 10 * 60)
        XCTAssertEqual(outlook.resume?.at, hours(monday8am))
    }

    func testNothingIsPacedWhenTheAccountsCarryEverySessionOrNoneHasRoom() {
        // Every week has room for the sessions flat out.
        let roomy = november21().map { account -> CapacityOutlook.Account in
            var roomy = account
            roomy.pacer.weeklyRemaining = 99 * 60
            roomy.pacer.percentPerMillion = 0.001
            roomy.availability = .serves
            return roomy
        }
        XCTAssertNil(SustainablePace.target(accounts: roomy, flatOut: flatOut, now: now))
        // No account has room now: the limit pauses hold the sessions.
        let spent = november21().map { account -> CapacityOutlook.Account in
            var spent = account
            spent.availability = .atLimit
            return spent
        }
        XCTAssertNil(SustainablePace.target(accounts: spent, flatOut: flatOut, now: now))
        XCTAssertNil(SustainablePace.target(accounts: november21(), flatOut: 0, now: now))
    }

    func testAnOutlyingTokenCostLowersTheTarget() throws {
        // hexorda read at five times what its plan size makes of the other
        // Max 5x accounts would hold a fifth of the work it does.
        let raw = try target(november21(hexordaRatio: max5x * 5.04))
        let held = try target(november21(hexordaRatio: max5x * sqrt(5.04)))
        let expected = try target()
        XCTAssertLessThan(raw.tokensPerHour, held.tokensPerHour)
        XCTAssertLessThan(held.tokensPerHour, expected.tokensPerHour)
    }

    // MARK: - The projection's demand

    func testADemandThatChangesSplitsTheProjectionWhereItChanges() {
        let accounts = [account(personal, "Personal", ratio: 1, weeklyUsed: 0, weeklyResetIn: 100)]
        // 99 window percent at 1% per million: 99M tokens. 10M an hour for
        // two hours, then 79M an hour spends the other 79M in an hour.
        let run = CapacityOutlook.run(accounts, demand: .init(tokensPerHour: 10_000_000,
                                                              changes: [.init(from: hours(2), tokensPerHour: 79_000_000)]),
                                      now: now, step: 60, horizon: 6 * 3600, reach: .firstPause)
        let paused = run.allPausedAt?.timeIntervalSince(now) ?? 0
        XCTAssertEqual(paused / 3600, 3, accuracy: 0.02)
    }
}
