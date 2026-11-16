import XCTest
@testable import AccountDock

/// The Outlook (`CapacityOutlook.project`): how long a provider's sessions
/// run at their current rates over its accounts' windows, weekly allowances
/// and resets, when they all pause, the bursts a small window brings during
/// the pause, the resume, and what pausing the heaviest session changes.
final class CapacityOutlookTests: XCTestCase {
    /// 9 pm; the fixture's resets are counted from here in hours.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hexorda = UUID(), bytrix = UUID(), cybrio = UUID(), fluxon = UUID(), voltrix = UUID(), backup = UUID()
    let spentWeek = UUID(), atLimit = UUID(), excluded = UUID(), signedOut = UUID()

    /// Window percent per million weighted tokens by plan.
    let max5x = 0.25, max20x = 0.0625, pro = 1.25

    func hours(_ value: Double) -> Date { now.addingTimeInterval(value * 3600) }

    /// An account `windowUsed`% into a 5-hour window resetting in
    /// `windowResetIn` hours (none running when nil), `weeklyUsed`% into a
    /// week renewing in `weeklyResetIn` hours, where one weekly percent costs
    /// `perWeekly` window percent.
    func account(_ id: UUID, _ name: String, ratio: Double, windowUsed: Double, windowResetIn: Double?,
                 weeklyUsed: Double, weeklyResetIn: Double, perWeekly: Double = 1,
                 availability: CapacityOutlook.Availability = .serves) -> CapacityOutlook.Account {
        let limit = SessionPacer().limit
        return CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: windowResetIn == nil ? 0 : windowUsed,
                                        resetsAt: windowResetIn.map(hours), burnPerHour: 0, baseWeight: 1,
                                        weeklyRemaining: (limit - weeklyUsed) * perWeekly,
                                        weeklyResetsAt: hours(weeklyResetIn), percentPerMillion: ratio),
            name: name, sessionPerWeekly: perWeekly, availability: availability)
    }

    /// Tonight: four Max 5x and three Max 20x accounts and a Pro, with
    /// bytrix's week renewing at 1 am, cybrio's at 9 pm tomorrow, fluxon's at
    /// 11 pm tomorrow and Backup's next Monday; two more accounts are spent.
    func tonight() -> [CapacityOutlook.Account] {
        [account(hexorda, "hexorda", ratio: max5x, windowUsed: 15, windowResetIn: 4 + 10.0 / 60,
                 weeklyUsed: 23, weeklyResetIn: 104),
         account(bytrix, "bytrix", ratio: max5x, windowUsed: 46, windowResetIn: 4.5, weeklyUsed: 33, weeklyResetIn: 4),
         account(cybrio, "cybrio", ratio: max5x, windowUsed: 49, windowResetIn: 4.5, weeklyUsed: 31, weeklyResetIn: 24),
         account(fluxon, "fluxon", ratio: max20x, windowUsed: 49, windowResetIn: 3 + 50.0 / 60,
                 weeklyUsed: 53, weeklyResetIn: 26),
         account(voltrix, "voltrix", ratio: pro, windowUsed: 0, windowResetIn: nil, weeklyUsed: 5, weeklyResetIn: 61,
                 perWeekly: 3),
         account(backup, "Backup", ratio: max20x, windowUsed: 0, windowResetIn: nil, weeklyUsed: 89, weeklyResetIn: 155),
         account(spentWeek, "spare", ratio: max5x, windowUsed: 20, windowResetIn: 2, weeklyUsed: 100, weeklyResetIn: 39),
         account(atLimit, "limited", ratio: max5x, windowUsed: 99.5, windowResetIn: 3, weeklyUsed: 99, weeklyResetIn: 80,
                 availability: .atLimit)]
    }

    /// Eight working sessions, the heaviest 113M tokens an hour, and six idle.
    func sessions() -> [CapacityOutlook.Session] {
        let working: [(String, Double)] = [("cf-builder", 113), ("platform-engineer", 52), ("cf-designer", 28),
                                           ("reviewer", 26), ("docs", 22), ("router", 14), ("tests", 12), ("notes", 3)]
        return working.map { CapacityOutlook.Session(id: $0.0, label: $0.0, tokensPerHour: $0.1 * 1_000_000) }
            + (1...6).map { CapacityOutlook.Session(id: "idle-\($0)", label: "idle-\($0)", tokensPerHour: 0) }
    }

    func project(_ accounts: [CapacityOutlook.Account]? = nil,
                 _ sessions: [CapacityOutlook.Session]? = nil) -> CapacityOutlook {
        CapacityOutlook.project(accounts: accounts ?? tonight(), sessions: sessions ?? self.sessions(), now: now)
    }

    func testEverySessionPausesBeforeTheFirstWeekBringsThemBack() throws {
        let outlook = project()
        let paused = try XCTUnwrap(outlook.allPausedAt)
        let resume = try XCTUnwrap(outlook.resume)
        // Every account is spent in the early morning; cybrio's new week at
        // 9 pm tomorrow is the first refill they run on for long.
        XCTAssertGreaterThan(paused, hours(6))
        XCTAssertLessThan(paused, hours(10))
        XCTAssertEqual(resume.kind, .newWeek)
        XCTAssertEqual(resume.name, "cybrio")
        XCTAssertEqual(resume.at.timeIntervalSince(hours(24)), 0, accuracy: 1)
        XCTAssertLessThan(paused, resume.at)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(resume.runs), CapacityOutlook.resumeRun)
        // The pause is listed last among what runs out, and every spent
        // week says when its account is back.
        XCTAssertEqual(outlook.runningOut.last?.kind, .allPaused)
        XCTAssertEqual(outlook.runningOut.last?.at, paused)
        for event in outlook.runningOut where event.kind == .weekSpent {
            XCTAssertNotNil(event.back)
        }
        let backup = try XCTUnwrap(outlook.runningOut.first { $0.name == "Backup" })
        XCTAssertEqual(backup.kind, .weekSpent)
        XCTAssertEqual(try XCTUnwrap(backup.back).timeIntervalSince(hours(155)), 0, accuracy: 1)
        // The timeline runs to just past the resume and is paused between.
        XCTAssertEqual(outlook.segments.first?.start, now)
        XCTAssertTrue(outlook.segments.first?.running ?? false)
        XCTAssertGreaterThan(outlook.spanEnd, resume.at)
        XCTAssertTrue(outlook.segments.last?.running ?? false)
        XCTAssertTrue(outlook.events.allSatisfy { $0.at <= resume.at })
    }

    func testRefillsBeforeThePauseAreInOrder() throws {
        let outlook = project()
        let refills = outlook.refillsBefore
        XCTAssertFalse(refills.isEmpty)
        XCTAssertEqual(refills.map(\.at), refills.map(\.at).sorted())
        let paused = try XCTUnwrap(outlook.allPausedAt)
        XCTAssertTrue(refills.allSatisfy { $0.at < paused })
        // bytrix's week renews at 1 am, before its window does at 1:30.
        let week = try XCTUnwrap(refills.first)
        XCTAssertEqual(week.kind, .newWeek)
        XCTAssertEqual(week.name, "bytrix")
        XCTAssertEqual(week.at.timeIntervalSince(hours(4)), 0, accuracy: 1)
        XCTAssertTrue(refills.contains { $0.name == "bytrix" && $0.kind == .windowRefill && abs($0.at.timeIntervalSince(hours(4.5))) < 1 })
        XCTAssertTrue(refills.contains { $0.name == "cybrio" && $0.kind == .windowRefill })
    }

    func testAllowanceThatWouldExpireUnusedIsSpentFirst() throws {
        // bytrix's week renews at 1 am with more left than its window lets
        // through by then (`SessionPacer.useBy`): it is filled first, to its
        // window's limit, before cybrio, whose week lasts until tomorrow night.
        XCTAssertNotNil(SessionPacer().useBy(tonight()[1].pacer, now: now))
        let outlook = project()
        let spent = try XCTUnwrap(outlook.events.first { $0.kind == .windowSpent || $0.kind == .weekSpent })
        XCTAssertEqual(spent.name, "bytrix")
        XCTAssertEqual(spent.kind, .windowSpent)
        XCTAssertEqual(try XCTUnwrap(spent.back).timeIntervalSince(hours(4.5)), 0, accuracy: 1)
        // Its window's last 53% hold 212M tokens: 47 minutes at 270M an hour.
        XCTAssertEqual(spent.at.timeIntervalSince(now) / 60, 212.0 / 270 * 60, accuracy: 1)
        let cybrio = try XCTUnwrap(outlook.events.first { $0.name == "cybrio" && $0.kind == .windowSpent })
        XCTAssertGreaterThan(cybrio.at, spent.at)
    }

    func testAWindowRefillWithWeeklyRoomLeftRunsAShortBurst() throws {
        let outlook = project()
        let paused = try XCTUnwrap(outlook.allPausedAt)
        let resume = try XCTUnwrap(outlook.resume)
        // voltrix, a Pro plan with most of its week left, refills its small
        // window during the pause: the sessions run on it for minutes.
        let bursts = outlook.bursts
        XCTAssertFalse(bursts.isEmpty)
        for burst in bursts {
            XCTAssertEqual(burst.name, "voltrix")
            XCTAssertEqual(burst.kind, .windowRefill)
            XCTAssertGreaterThan(burst.at, paused)
            XCTAssertLessThan(burst.at, resume.at)
            XCTAssertLessThan(try XCTUnwrap(burst.runs), CapacityOutlook.resumeRun)
            XCTAssertTrue(outlook.segments.contains { $0.running && $0.start == burst.at && $0.end < resume.at })
        }
        XCTAssertTrue(outlook.comingBack.contains(resume))
    }

    func testPausingTheHeaviestSessionPushesThePauseLater() throws {
        let outlook = project()
        let paused = try XCTUnwrap(outlook.allPausedAt)
        let whatIf = try XCTUnwrap(outlook.whatIf)
        XCTAssertEqual(whatIf.session.label, "cf-builder")
        XCTAssertGreaterThan(whatIf.allPausedAt ?? .distantFuture, paused)
        XCTAssertEqual(outlook.biggest.map(\.label), ["cf-builder", "platform-engineer", "cf-designer"])
        XCTAssertEqual(outlook.rateLine, "~270M tokens/h across 14 sessions")
        XCTAssertEqual(outlook.biggestLine, "Biggest users: cf-builder 113M/h · platform-engineer 52M/h · cf-designer 28M/h")
        XCTAssertTrue(outlook.line.hasPrefix("Runs until about "))
        XCTAssertTrue(outlook.line.hasSuffix("(cybrio's new week)"))
    }

    func testAccountsWithRoomForTheWeekRunThrough() {
        let roomy = [account(fluxon, "fluxon", ratio: max20x, windowUsed: 10, windowResetIn: 2, weeklyUsed: 5,
                             weeklyResetIn: 100, perWeekly: 8),
                     account(cybrio, "cybrio", ratio: max20x, windowUsed: 0, windowResetIn: nil, weeklyUsed: 0,
                             weeklyResetIn: 30, perWeekly: 8)]
        let light = [CapacityOutlook.Session(id: "a", label: "a", tokensPerHour: 8_000_000),
                     CapacityOutlook.Session(id: "b", label: "b", tokensPerHour: 2_000_000)]
        let outlook = project(roomy, light)
        XCTAssertNil(outlook.allPausedAt)
        XCTAssertNil(outlook.resume)
        XCTAssertNil(outlook.whatIf)
        XCTAssertEqual(outlook.line, "Runs through the next 7 days at the current rate.")
        XCTAssertTrue(outlook.segments.allSatisfy(\.running))
        XCTAssertEqual(outlook.spanEnd, hours(7 * 24))
    }

    func testExcludedAndUnavailableAccountsNeverCount() throws {
        let plain = project()
        let roomy = [account(excluded, "excluded", ratio: max20x, windowUsed: 0, windowResetIn: nil, weeklyUsed: 0,
                             weeklyResetIn: 150, perWeekly: 8, availability: .excluded),
                     account(signedOut, "signed out", ratio: max20x, windowUsed: 0, windowResetIn: nil, weeklyUsed: 0,
                             weeklyResetIn: 150, perWeekly: 8, availability: .unavailable)]
        let outlook = project(tonight() + roomy)
        XCTAssertEqual(outlook.allPausedAt, plain.allPausedAt)
        XCTAssertEqual(outlook.resume, plain.resume)
        XCTAssertFalse(outlook.events.contains { $0.account == excluded || $0.account == signedOut })
        // An account at its limit serves nothing until the reset that frees
        // it, which is after the resume here.
        XCTAssertFalse(outlook.events.contains { $0.account == atLimit })
    }

    func testAlreadyPausedSaysWhenSessionsResume() throws {
        let spent = [account(cybrio, "cybrio", ratio: max5x, windowUsed: 40, windowResetIn: 1, weeklyUsed: 99,
                             weeklyResetIn: 3),
                     account(hexorda, "hexorda", ratio: max5x, windowUsed: 99, windowResetIn: 2, weeklyUsed: 99,
                             weeklyResetIn: 50, availability: .atLimit)]
        let outlook = project(spent, sessions())
        XCTAssertTrue(outlook.alreadyPaused)
        XCTAssertEqual(outlook.allPausedAt, now)
        let resume = try XCTUnwrap(outlook.resume)
        XCTAssertEqual(resume.name, "cybrio")
        XCTAssertEqual(resume.kind, .newWeek)
        XCTAssertEqual(resume.at.timeIntervalSince(hours(3)), 0, accuracy: 1)
        XCTAssertTrue(outlook.line.hasPrefix("All paused · resumes about "))
        XCTAssertTrue(outlook.line.hasSuffix("(cybrio's new week)"))
        XCTAssertTrue(outlook.runningOut.isEmpty)
        XCTAssertNil(outlook.whatIf)
    }

    func testIdleSessionsSpendNothing() {
        let idle = (1...3).map { CapacityOutlook.Session(id: "idle-\($0)", label: "idle-\($0)", tokensPerHour: 0) }
        let outlook = project(tonight(), idle)
        XCTAssertNil(outlook.allPausedAt)
        XCTAssertTrue(outlook.biggest.isEmpty)
        XCTAssertNil(outlook.biggestLine)
        XCTAssertEqual(outlook.rateLine, "~0M tokens/h across 3 sessions")
    }
}
