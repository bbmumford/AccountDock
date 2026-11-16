import XCTest
@testable import AccountDock

/// Five Claude accounts at 2:57 pm on a Monday: Backup, a Max 20x account
/// with no 5-hour window and 54% of its week left, carries about 100M
/// weighted tokens an hour; fluxon, a Max 20x account whose window reset at
/// 2:50 pm, has an empty window and 74% of its week; hexorda, bytrix and
/// cybrio, Max 5x accounts, have 47%, 7% and 13% of their windows left,
/// resetting at 3:09, 3:30 and 3:29 pm. Each account's cost per million
/// weighted tokens is the one it had learned or been seeded with.
final class SmallWindowLaneTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_801_420)
    let backup = UUID(), fluxon = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID()

    // MARK: - Fixture

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func reading(session: Double?, resetIn minutes: Double?, weekly: Double, weeklyResetIn hours: Double) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: session.map { UsageWindow(utilization: $0, resetsAt: minutes.map { iso(at(minutes: $0)) }) },
            sevenDay: UsageWindow(utilization: weekly, resetsAt: iso(now.addingTimeInterval(hours * 3600))),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
    }

    private func state(_ id: UUID, session: Double?, resetIn minutes: Double?, weekly: Double, weeklyResetIn hours: Double,
                       ratio: Double, active: Bool = false, burn: Double = 0, at time: Date? = nil) -> QuotaAccountState {
        var state = QuotaAccountState(id: id, usage: reading(session: session, resetIn: minutes, weekly: weekly, weeklyResetIn: hours),
                                      observedAt: (time ?? now).addingTimeInterval(-60), sessionBurnPerHour: burn,
                                      sessionPerWeekly: 8, isActive: active)
        state.percentPerMillion = ratio
        return state
    }

    /// The live policy: no threshold failover, balancing on with a six-hour
    /// advantage and a 30-minute dwell.
    private func settings() -> FailoverPlanner.Settings {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = false
        policy.sessionEnabled = false
        policy.weeklyEnabled = true
        policy.weeklyThreshold = 100
        policy.intelligentBalancingEnabled = true
        policy.balancingMinimumAdvantageHours = 6
        policy.balancingMinimumDwellMinutes = 30
        var settings = FailoverPlanner.Settings(policy: policy, provider: .claudeCode)
        settings.sessionTrigger = 100
        settings.weeklyTrigger = 100
        return settings
    }

    private func account(_ id: UUID, used: Double, resetIn minutes: Double?, weekly: Double, weeklyResetIn hours: Double,
                         ratio: Double, burn: Double = 0, weight: Double = 1, window: Bool = true) -> SessionPacer.Account {
        var account = SessionPacer.Account(id: id, utilization: used, resetsAt: minutes.map { at(minutes: $0) },
                                           burnPerHour: burn, baseWeight: weight, percentPerMillion: ratio,
                                           hasSessionWindow: window)
        account.weeklyRemaining = (99 - weekly) * 8
        account.weeklyResetsAt = now.addingTimeInterval(hours * 3600)
        return account
    }

    private func accounts(fluxonWeight: Double = 1) -> [SessionPacer.Account] {
        [account(backup, used: 0, resetIn: nil, weekly: 46, weeklyResetIn: 161, ratio: 0.95, burn: 95, window: false),
         account(fluxon, used: 0, resetIn: 293, weekly: 26, weeklyResetIn: 32, ratio: 0.966, weight: fluxonWeight),
         account(hexorda, used: 53, resetIn: 12, weekly: 8, weeklyResetIn: 110, ratio: 3.0, burn: 64),
         account(bytrix, used: 93, resetIn: 33, weekly: 13, weeklyResetIn: 10, ratio: 1.151, burn: 5),
         account(cybrio, used: 87, resetIn: 32, weekly: 12, weeklyResetIn: 30, ratio: 6.73)]
    }

    /// A session at `rate` weighted tokens an hour over its last hour, quiet
    /// for `quiet` minutes, its current rate fading meanwhile.
    private func session(_ id: String, on account: UUID, rate: Double, context: Int, quiet: Double,
                         turn: Double? = nil) -> SessionPacer.Session {
        SessionPacer.Session(id: id, account: account, tokensPerHour: rate * exp(-quiet / 20), contextTokens: context,
                             lastSeen: at(minutes: -quiet), cacheLifetime: 3600,
                             lastTurnStart: turn.map { at(minutes: -$0) }, recentTokensPerHour: rate)
    }

    private func sessions() -> [SessionPacer.Session] {
        [session("8c64c5f8", on: backup, rate: 32_600_000, context: 465_000, quiet: 3, turn: 8),
         session("4822c359", on: backup, rate: 33_800_000, context: 42_000, quiet: 3, turn: 52),
         session("583fb354", on: backup, rate: 22_300_000, context: 418_000, quiet: 3, turn: 34),
         session("a78ddf66", on: backup, rate: 13_200_000, context: 693_000, quiet: 3, turn: 5),
         session("19496bb9", on: backup, rate: 1_300_000, context: 489_000, quiet: 12),
         session("3a862465", on: backup, rate: 0, context: 200_000, quiet: 25),
         session("33962de2", on: hexorda, rate: 21_300_000, context: 300_000, quiet: 1, turn: 22),
         session("345dc95e", on: bytrix, rate: 4_700_000, context: 761_000, quiet: 2, turn: 486),
         session("1603da04", on: bytrix, rate: 0, context: 562_000, quiet: 107),
         session("5386173b", on: bytrix, rate: 0, context: 310_000, quiet: 158),
         session("075198d6", on: cybrio, rate: 0, context: 611_000, quiet: 61)]
    }

    // MARK: - A balance switch carries the shared sign-in for the runway

    /// At 2:50 pm fluxon, active, has just reset; it had been held at its
    /// limit for three hours, so its learned rate is nothing. cybrio's
    /// allowance must start being used eight hours before fluxon's, but its
    /// window has 13% left for 39 minutes: 1.9M tokens at its cost, which a
    /// typical session spends in five minutes.
    func testABalanceSwitchDoesNotMoveTheSharedSignInOntoAWindowThatCannotCarryIt() {
        let then = now.addingTimeInterval(-7 * 60)
        let current = state(fluxon, session: 0, resetIn: 293 + 7, weekly: 26, weeklyResetIn: 32.1, ratio: 0.966,
                            active: true, at: then)
        let ladder = [state(backup, session: nil, resetIn: nil, weekly: 45, weeklyResetIn: 161, ratio: 0.95, at: then),
                      state(hexorda, session: 44, resetIn: 19, weekly: 6, weeklyResetIn: 110, ratio: 3.0, at: then),
                      state(cybrio, session: 87, resetIn: 39, weekly: 12, weeklyResetIn: 30.1, ratio: 6.73, at: then),
                      current]
        var unfloored = settings()
        unfloored.balanceMovingTokensPerHour = 0
        guard case .switchTo(cybrio, .balance(let hours)) = FailoverPlanner(settings: unfloored)
            .plan(current: current, ladder: ladder, lastSwitch: nil, now: then) else {
            return XCTFail("judged by fluxon's learned rate alone, the switch goes to cybrio")
        }
        XCTAssertEqual(hours, 7.6, accuracy: 0.2)

        // The sign-in's work counted at a typical session's rate at least.
        var floored = settings()
        floored.balanceMovingTokensPerHour = SessionPacer.typicalNewSessionRate(sessions())
        let planner = FailoverPlanner(settings: floored)
        XCTAssertFalse(planner.carries(ladder[2], from: current, at: then, floor: floored.balanceMovingTokensPerHour))
        XCTAssertEqual(planner.plan(current: current, ladder: ladder, lastSwitch: nil, now: then), .stay(.healthy),
                       "the shared sign-in stays on fluxon's fresh window")
        // Even refilled, a Max 5x window spends a typical session's hour in
        // 42 minutes; a Max 20x window carries it.
        let refilled = state(cybrio, session: 0, resetIn: 300, weekly: 12, weeklyResetIn: 29.5, ratio: 6.73, at: then)
        XCTAssertFalse(planner.carries(refilled, from: current, at: then, floor: floored.balanceMovingTokensPerHour))
        let large = state(backup, session: 0, resetIn: 300, weekly: 12, weeklyResetIn: 29.5, ratio: 0.95, at: then)
        XCTAssertTrue(planner.carries(large, from: current, at: then, floor: floored.balanceMovingTokensPerHour))
    }

    /// While the shared sign-in sits on cybrio, failover projects it back to
    /// fluxon within minutes, and the pacer keeps fluxon's room for it: no
    /// new session goes there. With the sign-in left on fluxon, fluxon
    /// takes new sessions again.
    func testTheSignInProjectedBackOntoFluxonKeepsFluxonsRoomForIt() {
        let projected = SessionPacer.SharedGroup(account: cybrio, tokensPerHour: 60_000_000, contextTokens: 300_000, models: [],
                                                 nextAccount: fluxon, switchAt: at(minutes: 5), sessionCount: 1)
        let bounced = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, sharedGroup: projected)
        XCTAssertEqual(bounced.weights[fluxon], 0)

        let stayed = SessionPacer.SharedGroup(account: fluxon, tokensPerHour: 20_000_000, contextTokens: 300_000, models: [],
                                              sessionCount: 1)
        let kept = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, sharedGroup: stayed)
        XCTAssertGreaterThan(kept.weights[fluxon] ?? 0, 0)
    }

    // MARK: - A window that resets soon has the whole next window after it

    /// Backup reaches its weekly limit at about 7:30 pm and would then wait
    /// days. Counted without the windows hexorda, bytrix and cybrio get
    /// back within the half hour, the accounts together last no longer
    /// than Backup, so it gave nothing up; counted with them they last
    /// hours longer, and Backup's sessions go where they fit: one to
    /// fluxon's empty window, which lasts as long as Backup would, a light
    /// one to bytrix's last 7%, which it spends no faster than the reset
    /// refills it.
    func testBackupGivesSessionsToFluxonAndToTheWindowsThatResetSoon() throws {
        let pacer = SessionPacer()
        let backupAccount = accounts()[0]
        let burn = Dictionary(uniqueKeysWithValues: accounts().map { ($0.id, $0.burnPerHour) })
        let runOut = try XCTUnwrap(pacer.poolRunOut(accounts(), burn: burn, spent: [:], shares: [:], sharedGroup: nil, now: now))
        let backupLimit = try XCTUnwrap(pacer.outlook(backupAccount, burn: 95, now: now).limitAt)
        XCTAssertGreaterThan(runOut.timeIntervalSince(backupLimit), 2 * 3600)
        XCTAssertEqual(pacer.roomBy(accounts()[3], at(minutes: 40), spent: 0, now: now), 6 + 99, accuracy: 0.001,
                       "bytrix's 6% to its limit, then a whole window from 3:30 pm")

        let plan = pacer.plan(accounts: accounts(), sessions: sessions(), now: now)
        XCTAssertNotNil(plan.shedding[backup])
        let toFluxon = plan.moves.filter { $0.value == fluxon }.keys
        XCTAssertEqual(toFluxon.count, 1)
        XCTAssertTrue(toFluxon.allSatisfy { ["4822c359", "583fb354", "33962de2"].contains($0) },
                      "one heavy session, from Backup or from hexorda, whose next window it would fill by 4:30 pm")
        XCTAssertEqual(plan.moves["19496bb9"], bytrix)
        XCTAssertNil(plan.moves["8c64c5f8"], "two such sessions would fill fluxon's window long before Backup runs out")
        XCTAssertFalse(plan.moves.values.contains(cybrio), "cybrio's 13% at its cost holds none of them until 3:29 pm")
        // Counted without the refills the accounts together ran out with
        // Backup, which then gave nothing up.
        let blindRoom = accounts().reduce(0.0) { total, account in
            total + pacer.millions(max(0, pacer.windowsLeft(account, spent: 0, now: now).map(\.left).min() ?? 0), on: account)
        }
        let blindHours = blindRoom / accounts().reduce(0.0) { $0 + pacer.millions($1.burnPerHour, on: $1) }
        XCTAssertLessThan(blindHours * 3600, backupLimit.timeIntervalSince(now) + 3600)
    }

    /// A new session needs the room until the reset and a whole window
    /// after it, not the room left now for the whole hour.
    @MainActor
    func testAWindowResettingWithinTheHourCarriesANewSessionByItsRoomUntilThen() {
        XCTAssertTrue(AppState.carriesNewSession(sessionRoom: 20, weeklyRoom: 500, resetIn: 15 * 60, burn: 10, newSessionBurn: 30))
        XCTAssertFalse(AppState.carriesNewSession(headroom: 20, burn: 10, newSessionBurn: 30),
                       "the 20% counted for the whole hour")
        // bytrix: 7% for 33 minutes at its own 5% and a typical session's
        // 24.5% an hour; cybrio: 13% for 32 minutes at 143% an hour.
        XCTAssertFalse(AppState.carriesNewSession(sessionRoom: 7, weeklyRoom: 696, resetIn: 33 * 60, burn: 5, newSessionBurn: 24.5))
        XCTAssertFalse(AppState.carriesNewSession(sessionRoom: 13, weeklyRoom: 704, resetIn: 32 * 60, burn: 0, newSessionBurn: 143))
        // The weekly allowance still binds over the whole hour.
        XCTAssertFalse(AppState.carriesNewSession(sessionRoom: 20, weeklyRoom: 30, resetIn: 15 * 60, burn: 10, newSessionBurn: 30))
    }

    /// cybrio at 87% with its reset 32 minutes away, spending 20% an hour,
    /// does not reach its limit in this window, so failover projects no
    /// switch off it then.
    func testAWindowThatResetsBeforeItsLimitIsNotHeadingForIt() {
        let planner = FailoverPlanner(settings: settings())
        let slow = state(cybrio, session: 87, resetIn: 32, weekly: 12, weeklyResetIn: 30, ratio: 6.73, active: true, burn: 20)
        XCTAssertNil(planner.secondsUntilExhaustion(slow, now: now))
        XCTAssertNil(planner.secondsUntilTrigger(slow, now: now))
        let fast = state(cybrio, session: 87, resetIn: 32, weekly: 12, weeklyResetIn: 30, ratio: 6.73, active: true, burn: 60)
        XCTAssertNotNil(planner.secondsUntilExhaustion(fast, now: now), "60% an hour spends the 13% in 13 minutes")
    }
}
