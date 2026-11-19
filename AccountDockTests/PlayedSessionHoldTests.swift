import XCTest
@testable import AccountDock

/// A play is one release: the session runs on the account serving it, and
/// once that account is at or near its limit it is held again
/// (`AppState.UserResume`, `judgePlays`, `listHolds`). The fixture is
/// 19 November at 10:48:37 pm: ORBTR at its limit held five sessions,
/// cf-designer (session a78ddf66) among them. The user played cf-designer
/// at 10:53:02 pm with ORBTR still spent; at 10:56:59 pm session balancing
/// moved its slot to cybrio, the account with room; at 10:58:27 pm cybrio
/// was at its limit and four sessions there were held, cf-designer not, as
/// it was resumed; at 11:16:51 pm cybrio refused it at its weekly limit.
final class PlayedSessionHoldTests: XCTestCase {
    private var home: URL!
    let orbtr = UUID(), cybrio = UUID()
    let designer = "a78ddf66-0a33-4161-b945-8c6dd6f3b17d"
    /// cybrio's sessions the runway held at 10:58:27 pm.
    let onCybrio = ["19496bb9", "68802953", "8c64c5f8", "f964a9fc"]
    /// ORBTR's sessions held since 10:48:37 pm, less cf-designer.
    let onOrbtr = ["33962de2", "345dc95e", "4822c359", "583fb354"]

    private func at(_ clock: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-11-19T\(clock)+11:00")!
    }

    private var directory: URL { home.appendingPathComponent("Pause") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("PlayedHold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The pause at ORBTR's limit, cf-designer played out of it.
    private func pauseWithDesignerPlayed() {
        AgentPauseGate.write(AgentPauseGate.PauseFile(
            sessions: onOrbtr + [designer], reason: "an account's room lasts its sessions less than a reading and a request round",
            pausedAt: at("22:48:37"), resumeAt: nil, holdsNewTurns: false, holdsListedNewTurns: true),
                             for: .claudeCode, directory: directory)
        XCTAssertFalse(AgentPauseGate.playOne(.claudeCode, session: designer, running: Set(onOrbtr + onCybrio + [designer]),
                                              directory: directory), "the other sessions stay paused")
    }

    // MARK: - The play

    func testAPlayOnASpentAccountIsRecordedAndCoversThatLimitOnly() {
        // 10:53:02 pm: ORBTR is at its limit; the play is recorded anyway.
        let play = AppState.UserResume(playedOn: orbtr, spent: true)
        XCTAssertTrue(play.releases(serving: orbtr), "the user chose to run it into ORBTR's limit")
        let still = AppState.judgePlays([designer: play], resumed: [designer], serving: { _ in self.orbtr },
                                        nearLimit: { $0 == self.orbtr })
        XCTAssertEqual(still.standing[designer], play, "while it stays on spent ORBTR it runs on")
        XCTAssertTrue(still.heldAgain.isEmpty)
        XCTAssertFalse(play.releases(serving: cybrio), "the play covers no limit of the account it moves to")
    }

    func testOnCybrioItIsHeldAgainOnceCybrioIsAtItsLimitBeforeTheRefusal() throws {
        let play = AppState.UserResume(playedOn: orbtr, spent: true)
        // 10:57 pm: its slot serves cybrio, which has room; the play follows it there.
        let landed = AppState.judgePlays([designer: play], resumed: [designer], serving: { _ in self.cybrio },
                                         nearLimit: { $0 == self.orbtr })
        let followed = try XCTUnwrap(landed.standing[designer])
        XCTAssertEqual(followed.account, cybrio)
        XCTAssertEqual(followed.playedOn, orbtr)
        XCTAssertFalse(followed.spent)
        XCTAssertFalse(followed.releases(serving: cybrio))
        // 10:58:27 pm: cybrio is at its limit, eighteen minutes before it refused cf-designer.
        let reached = AppState.judgePlays([designer: followed], resumed: [designer], serving: { _ in self.cybrio },
                                          nearLimit: { _ in true })
        XCTAssertTrue(reached.standing.isEmpty)
        XCTAssertEqual(reached.heldAgain.map(\.session), [designer])
        XCTAssertEqual(reached.heldAgain.first?.play.account, cybrio)
        // Judged straight after the move, with cybrio at its limit already.
        let direct = AppState.judgePlays([designer: play], resumed: [designer], serving: { _ in self.cybrio },
                                         nearLimit: { _ in true })
        XCTAssertEqual(direct.heldAgain.map(\.session), [designer],
                       "ORBTR being spent at the play never excuses cybrio's limit")
    }

    func testThePlayAtALimitEndsOnceThatAccountHasRoomAgain() throws {
        let play = AppState.UserResume(playedOn: orbtr, spent: true)
        let reset = AppState.judgePlays([designer: play], resumed: [designer], serving: { _ in self.orbtr },
                                        nearLimit: { _ in false })
        let after = try XCTUnwrap(reset.standing[designer])
        XCTAssertFalse(after.spent, "ORBTR has room again")
        let next = AppState.judgePlays([designer: after], resumed: [designer], serving: { _ in self.orbtr },
                                       nearLimit: { _ in true })
        XCTAssertEqual(next.heldAgain.map(\.session), [designer], "ORBTR's next limit holds it")
    }

    func testAPlayWithRoomIsHeldAtThatAccountsLimitAndASecondPlayReleasesItAgain() throws {
        let roomy = AppState.UserResume(playedOn: cybrio, spent: false)
        let reached = AppState.judgePlays([designer: roomy], resumed: [designer], serving: { _ in self.cybrio },
                                          nearLimit: { _ in true })
        XCTAssertEqual(reached.heldAgain.map(\.session), [designer])
        // The user plays it again on cybrio, now at its limit: released the same way.
        let again = AppState.UserResume(playedOn: cybrio, spent: true)
        let runs = AppState.judgePlays([designer: again], resumed: [designer], serving: { _ in self.cybrio },
                                       nearLimit: { _ in true })
        XCTAssertEqual(runs.standing[designer], again)
        XCTAssertTrue(runs.heldAgain.isEmpty)
    }

    func testAPlayWhoseSessionTheGateHoldsAgainIsOver() {
        let play = AppState.UserResume(playedOn: orbtr, spent: true)
        let judged = AppState.judgePlays([designer: play], resumed: [], serving: { _ in self.orbtr },
                                         nearLimit: { _ in true })
        XCTAssertTrue(judged.standing.isEmpty)
        XCTAssertTrue(judged.heldAgain.isEmpty, "a pause or a rule already holds it")
    }

    // MARK: - The rules holding sessions at a limit

    func testTheRuleHoldingCybriosSessionsHoldsThePlayedSessionAgain() {
        pauseWithDesignerPlayed()
        AgentPauseGate.resume(.claudeCode, session: "admitted", directory: directory)
        let running = Set(onOrbtr + onCybrio + [designer, "admitted"])
        XCTAssertFalse(AgentPauseGate.heldSessions(.claudeCode, running: running, directory: directory).contains(designer))
        // 10:58:27 pm: cybrio at its limit, nowhere with room; the play no
        // longer covers it, AccountDock's own admission still stands.
        let held = AppState.listHolds(.claudeCode, onCybrio + [designer, "admitted"],
                                      reason: "an account's room lasts its sessions less than a reading and a request round",
                                      now: at("22:58:27"), releaseStands: { $0 == "admitted" }, directory: directory)
        XCTAssertEqual(held.listed, onCybrio.sorted())
        XCTAssertEqual(held.replayed, [designer])
        let pause = AgentPauseGate.read(.claudeCode, directory: directory)
        XCTAssertEqual(Set(pause?.sessions ?? []), Set(onOrbtr + onCybrio + [designer]))
        XCTAssertFalse(AgentPauseGate.resumedSessions(.claudeCode, directory: directory).contains(designer))
        XCTAssertTrue(AgentPauseGate.heldSessions(.claudeCode, running: running, directory: directory).contains(designer),
                      "the gate holds it at its next tool call")
        XCTAssertTrue(AgentPauseGate.resumedSessions(.claudeCode, directory: directory).contains("admitted"))
    }

    func testAPlayStillCoveringItsAccountIsLeftToRun() {
        pauseWithDesignerPlayed()
        let held = AppState.listHolds(.claudeCode, [designer], reason: "no account with room can carry them until its reset",
                                      now: at("22:54:00"), releaseStands: { _ in true }, directory: directory)
        XCTAssertTrue(held.listed.isEmpty)
        XCTAssertTrue(held.replayed.isEmpty)
        XCTAssertTrue(AgentPauseGate.resumedSessions(.claudeCode, directory: directory).contains(designer))
    }

    func testUnderAPauseHoldingEveryTurnThePlayedSessionIsHeldAgainToo() {
        AgentPauseGate.write(AgentPauseGate.PauseFile(sessions: onOrbtr, reason: "every account is at its limit",
                                                      pausedAt: at("22:48:37"), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: directory)
        AgentPauseGate.resume(.claudeCode, session: designer, directory: directory)
        let held = AppState.listHolds(.claudeCode, [designer], reason: "no account with room can carry them until its reset",
                                      now: at("22:58:27"), releaseStands: { _ in false }, directory: directory)
        XCTAssertTrue(held.listed.isEmpty, "the pause holds every session already")
        XCTAssertEqual(held.replayed, [designer])
        XCTAssertTrue(AgentPauseGate.heldSessions(.claudeCode, running: [designer], directory: directory).contains(designer))
    }

    // MARK: - cybrio's weekly allowance

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func planner() -> FailoverPlanner {
        FailoverPlanner(settings: .init(policy: .defaults(for: .claudeCode), provider: .claudeCode, canVerify: true))
    }

    /// cybrio read five seconds before 10:57:05 pm, its 5-hour window
    /// resetting at 11:50 pm and its week at 9 pm on 24 November, with
    /// cf-designer on it at its pace after the play: 45M weighted tokens an
    /// hour, at cybrio's 2.124% of a window per million.
    private func cybrioState(session: Double = 46, weekly: Double) -> QuotaAccountState {
        let now = at("22:57:05")
        var state = QuotaAccountState(
            id: cybrio,
            usage: UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(at("23:50:00"))),
                sevenDay: UsageWindow(utilization: weekly, resetsAt: "2026-11-24T10:00:00Z"),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            ),
            observedAt: now.addingTimeInterval(-5),
            sessionBurnPerHour: 0,
            weeklyBurnPerHour: 0
        )
        state.sessionPerWeekly = 4
        state.percentPerMillion = 2.124
        state.sessionsBurnPerHour = 45 * 2.124
        state.runwayLead = AppState.runwayLead
        return state
    }

    func testAWeekRunningOutAtTheSessionsPaceIsNearItsLimitWhileTheWindowHasRoom() throws {
        let p = planner()
        let now = at("22:57:05")
        // 1.1% of the week left is 4.4% of a window: under three minutes at 95.6% an hour.
        let spending = cybrioState(weekly: 98.9)
        let windows = try XCTUnwrap(p.runwayByWindow(spending, now: now))
        XCTAssertGreaterThan(try XCTUnwrap(windows.session), 30 * 60, "the 5-hour window's 54% lasts over half an hour")
        XCTAssertLessThan(try XCTUnwrap(windows.weekly), AppState.runwayLead)
        XCTAssertEqual(p.runway(spending, now: now), windows.weekly)
        XCTAssertEqual(p.limitingWindow(spending, now: now), .weekly)
        // Re-holding judges the account by `servingVerdict` at `suspensionLead`.
        XCTAssertEqual(p.servingVerdict(spending, now: now, lead: AppState.suspensionLead), .nearLimit)
        XCTAssertEqual(p.servingVerdict(spending, now: now, lead: 0), .canServe, "it can still serve at all")
        // The runway sends cf-designer off, or holds it.
        let runway = try XCTUnwrap(p.runway(spending, now: now))
        XCTAssertEqual(AppState.runwayShed([(id: designer, tokensPerHour: 45_000_000)], others: 0,
                                           roomPercent: runway * spending.sessionsBurnPerHour / 3600,
                                           percentPerMillion: spending.percentPerMillion, lead: AppState.runwayLead),
                       [designer])

        // With half its week left, the window binds and has room.
        let roomy = cybrioState(weekly: 50)
        XCTAssertEqual(p.limitingWindow(roomy, now: now), .session)
        XCTAssertEqual(p.servingVerdict(roomy, now: now, lead: AppState.suspensionLead), .canServe)
        XCTAssertTrue(AppState.runwayShed([(id: designer, tokensPerHour: 45_000_000)], others: 0,
                                          roomPercent: try XCTUnwrap(p.runway(roomy, now: now)) * roomy.sessionsBurnPerHour / 3600,
                                          percentPerMillion: roomy.percentPerMillion, lead: AppState.runwayLead).isEmpty)
    }

    func testTheLimitingWindowWithNoSessionRunningIsTheOneWithLessRoom() {
        let p = planner()
        let now = at("22:57:05")
        var spent = cybrioState(weekly: 100)
        spent.sessionsBurnPerHour = 0
        XCTAssertEqual(p.limitingWindow(spent, now: now), .weekly, "the week cybrio refused it for")
        var window = cybrioState(session: 100, weekly: 60)
        window.sessionsBurnPerHour = 0
        XCTAssertEqual(p.limitingWindow(window, now: now), .session)
    }

    // MARK: - Events

    func testTheHoldAgainIsRecordedWithTheAccountItRanOn() {
        XCTAssertEqual(AppState.playHeldAgainEvent(session: "cf-designer", account: "cybrio", moved: true, refused: false),
                       "Paused cf-designer again: cybrio, where it ran after you resumed it, is about to reach its limit; it continues when an account has room.")
        XCTAssertEqual(AppState.playHeldAgainEvent(session: "cf-designer", account: "ORBTR", moved: false, refused: true),
                       "Paused cf-designer again: ORBTR, where you resumed it, reached its limit; it continues when an account has room.")
        XCTAssertEqual(AppState.pinnedHoldEvent(session: "api (4f2a)", account: "Work", hold: .threshold, again: true),
                       "Paused api (4f2a) again, pinned to Work, which reached its threshold; it continues when Work has room.")
    }
}
