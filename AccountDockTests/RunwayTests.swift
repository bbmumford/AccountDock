import XCTest
@testable import AccountDock

/// An account is near its limit for its sessions when the room left lasts
/// them, at their pace now, less than a reading and a request round. The
/// fixture is hexorda at 6:05:05 pm, read at 90% of its 5-hour window, with
/// platform-engineer (session 33962de2, sixteen agents) and
/// platform-execution (session 583fb354, five agents, its 800K-token context
/// written afresh) on it: together 11M weighted tokens in their last
/// minute, at 2.545% of hexorda's window per million. The first refusal came
/// seven seconds later; the live reading with room had kept the account
/// "able to serve" until its next reading showed 100%.
final class RunwayTests: XCTestCase {
    /// 6:05:05 pm.
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func seconds(_ value: Double) -> Date { now.addingTimeInterval(value) }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func planner() -> FailoverPlanner {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 95
        policy.weeklyThreshold = 95
        return FailoverPlanner(settings: .init(policy: policy, provider: .claudeCode, canVerify: true))
    }

    /// hexorda as its sessions' status line reported it five seconds ago.
    private func hexorda(burn: Double, session: Double = 90, weekly: Double = 90) -> QuotaAccountState {
        var state = QuotaAccountState(
            id: UUID(),
            usage: UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(seconds(3 * 3600 + 5 * 60))),
                sevenDay: UsageWindow(utilization: weekly, resetsAt: iso(seconds(4 * 86_400))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            ),
            observedAt: seconds(-5),
            sessionBurnPerHour: 30,
            weeklyBurnPerHour: 4
        )
        state.liveReadingAt = state.observedAt
        state.percentPerMillion = 2.545
        state.sessionsBurnPerHour = burn
        state.runwayLead = AppState.runwayLead
        return state
    }

    /// Both sessions' requests over the five minutes before 6:05:05 pm.
    func rates() -> SessionRates {
        var rates = SessionRates()
        func record(_ session: String, at: Date, tokens: Double) {
            rates.record(session: session, account: UUID(), context: 0, cacheWrite: 0, output: Int(tokens / 5),
                         cacheLifetime: 3600, at: at)
        }
        for index in 0..<30 { record("33962de2", at: seconds(-87 + Double(index) * 2.9), tokens: 7_000_000 / 30) }
        for index in 0..<8 { record("583fb354", at: seconds(-19 + Double(index) * 2.3), tokens: 2_000_000 / 8) }
        return rates
    }

    func testABurstCountsAtItsPaceNow() {
        let rates = rates()
        XCTAssertEqual(rates.recentRate("33962de2", now: now), 84_000_000, accuracy: 1_000_000,
                       "7M over its last five minutes")
        XCTAssertLessThan(rates.tokensPerHour("33962de2", now: now), 25_000_000,
                          "the 20-minute decay counts the burst at a fraction of its pace")
        XCTAssertEqual(rates.recentRate("583fb354", now: now), 24_000_000, accuracy: 1_000_000)
        XCTAssertEqual(rates.recentRate("583fb354", now: seconds(6 * 60)), 0, "its burst has left the span")
    }

    func testTheRoomALiveReadingShowsIsNoRoomWhenTheSessionsSpendItBeforeTheNextReading() throws {
        let p = planner()
        let quiet = hexorda(burn: 0)
        XCTAssertTrue(p.liveReadingShowsRoom(quiet, now: now))
        XCTAssertEqual(p.servingVerdict(quiet, now: now, lead: AppState.suspensionLead), .canServe,
                       "with no pace of its own, the live reading stands")

        // 108M an hour at 2.545% per million: 275% of the window an hour.
        let bursting = hexorda(burn: 108 * 2.545)
        let runway = try XCTUnwrap(p.runway(bursting, now: now))
        XCTAssertEqual(runway, 127, accuracy: 3, "the 10% left lasts about two minutes")
        XCTAssertLessThan(runway, AppState.runwayLead)
        XCTAssertEqual(p.servingVerdict(bursting, now: now, lead: AppState.suspensionLead), .nearLimit)
        XCTAssertEqual(p.servingVerdict(bursting, now: now, lead: 0), .canServe, "it can still serve at all")

        let light = hexorda(burn: 10 * 2.545)
        XCTAssertGreaterThan(try XCTUnwrap(p.runway(light, now: now)), AppState.runwayWatch,
                             "one light session leaves the 10% for over 20 minutes")
        XCTAssertEqual(p.servingVerdict(light, now: now, lead: AppState.suspensionLead), .canServe)
    }

    func testTheWeeklyRoomBindsWhenItIsTheSmaller() throws {
        let p = planner()
        // At 6:05:35 pm hexorda read 92% of its week; 8% of a week is many
        // windows' worth, so the 5-hour window still binds.
        var state = hexorda(burn: 108 * 2.545, session: 50, weekly: 92)
        state.sessionPerWeekly = 8
        let runway = try XCTUnwrap(p.runway(state, now: now))
        XCTAssertEqual(runway, 50 / (108 * 2.545) * 3600 - 5, accuracy: 3)
        state.sessionPerWeekly = 1
        XCTAssertEqual(try XCTUnwrap(p.runway(state, now: now)), 8 / (108 * 2.545) * 3600 - 5, accuracy: 3,
                       "a week no larger than a window binds first")
    }

    func testTheHeaviestSessionsLeaveUntilTheRestLastALeadOnTheRoom() {
        let sessions = [(id: "583fb354", tokensPerHour: 24_000_000.0), (id: "33962de2", tokensPerHour: 84_000_000.0),
                        (id: "a78ddf66", tokensPerHour: 3_000_000.0)]
        XCTAssertEqual(AppState.runwayShed(sessions, others: 0, roomPercent: 10, percentPerMillion: 2.545,
                                           lead: AppState.runwayLead), ["33962de2"],
                       "without platform-engineer the other two leave hexorda's 10% for almost nine minutes")
        XCTAssertEqual(AppState.runwayShed(sessions, others: 0, roomPercent: 3, percentPerMillion: 2.545,
                                           lead: AppState.runwayLead), ["33962de2", "583fb354"],
                       "3% left: platform-execution leaves too")
        let quiet = sessions + [(id: "idle", tokensPerHour: 0.0)]
        XCTAssertEqual(AppState.runwayShed(quiet, others: 0, roomPercent: 0, percentPerMillion: 2.545,
                                           lead: AppState.runwayLead), ["33962de2", "583fb354", "a78ddf66"],
                       "at its limit every session that sends anything leaves; one that sends nothing costs nothing")
        XCTAssertEqual(AppState.runwayShed(sessions, others: 0, roomPercent: 60, percentPerMillion: 2.545,
                                           lead: AppState.runwayLead), [], "ample room")
        XCTAssertEqual(AppState.runwayShed([(id: "583fb354", tokensPerHour: 24_000_000)], others: 84_000_000,
                                           roomPercent: 10, percentPerMillion: 2.545, lead: AppState.runwayLead),
                       ["583fb354"], "work no rule here moves still spends the room")
    }

    func testTheLeadCoversTwoReadingsAndARequestRound() {
        XCTAssertGreaterThanOrEqual(AppState.runwayLead, 2 * AppState.runwayReadInterval + AppState.requestRound)
        XCTAssertGreaterThanOrEqual(AppState.runwayLead, AppState.suspensionLead)
        XCTAssertTrue(AppState.runwayHoldEvent(session: "platform-engineer", account: "hexorda", lasts: 127,
                                               percentPerHour: 275).contains("lasts about 2 min, less than the 3 min"))
    }

    func testAShortRunwayIsReadEveryMinuteAndAHeavyArrivalIsHeavy() {
        XCTAssertTrue(AppState.runwayReadIsDue(runway: 8 * 60, readAt: seconds(-70), now: now))
        XCTAssertFalse(AppState.runwayReadIsDue(runway: 8 * 60, readAt: seconds(-20), now: now),
                       "a session's live reading twenty seconds ago is recent enough")
        XCTAssertFalse(AppState.runwayReadIsDue(runway: 20 * 60, readAt: seconds(-300), now: now), "room is ample")
        XCTAssertFalse(AppState.runwayReadIsDue(runway: nil, readAt: seconds(-300), now: now),
                       "no session spends it, as once they are held")
        XCTAssertTrue(AppState.arrivalIsHeavy(tokensPerHour: 55_000_000, percentPerMillion: 1.176),
                      "platform-engineer's working rate on voltrix: two thirds of its window an hour")
        XCTAssertFalse(AppState.arrivalIsHeavy(tokensPerHour: 3_000_000, percentPerMillion: 2.545))
    }
}
