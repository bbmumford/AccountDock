import XCTest
@testable import AccountDock

/// How new sessions, stranded slot sessions and the shared sign-in's group
/// are spread when every account would run out before its weekly reset:
/// the pool's reading lifetime, the projected next account, the pacer's
/// weights and placements, and the burn rate after an arrival.
final class BalancingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A reading with the weekly window alone, as an account without a
    /// session window reports.
    private func weeklyReading(_ used: Double, resetIn hours: Double) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: used, resetsAt: iso(now.addingTimeInterval(hours * 3600))),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
    }

    // MARK: - Burn rate after a reset or an arrival

    func testAResetGrantedWithinTheSameWindowTeachesNoRateFromTheBurstAfterIt() {
        var trend = QuotaTrend()
        let start = now
        func read(_ used: Double, at seconds: TimeInterval) {
            trend.record(weeklyReading(used, resetIn: 100), at: start.addingTimeInterval(seconds))
        }
        read(99, at: 0)
        // The grant empties the window; its reset time stays. The sessions
        // sent back to the account rewrite their contexts at once.
        read(0, at: 60)
        read(4, at: 130)
        read(8, at: 250)
        // Then the work's own 20% per hour.
        read(9, at: 400)
        read(10, at: 610)
        read(12, at: 970)
        read(14, at: 1330)
        XCTAssertEqual(trend.weeklyBurnPerHour, 20, accuracy: 0.01)
    }

    func testTheSessionsASwitchBringsTeachNoRateUntilTheyHaveArrived() {
        func trend(settling period: TimeInterval) -> QuotaTrend {
            var trend = QuotaTrend()
            func read(_ used: Double, at seconds: TimeInterval) {
                trend.record(weeklyReading(used, resetIn: 100), at: now.addingTimeInterval(seconds))
            }
            for (step, used) in [20.0, 22, 24, 26].enumerated() { read(used, at: Double(step) * 360) }
            trend.settle(at: now.addingTimeInterval(1080), for: period)
            // The group's first requests on the account rewrite its cache
            // over the next nine minutes.
            read(30, at: 1200)
            read(33, at: 1440)
            read(37, at: 1560)
            read(40, at: 1650)
            read(42, at: 2010)
            return trend
        }
        XCTAssertEqual(trend(settling: QuotaTrend.arrivalSettlePeriod).weeklyBurnPerHour, 20, accuracy: 0.01)
        XCTAssertGreaterThan(trend(settling: QuotaTrend.settlePeriod).weeklyBurnPerHour, 40,
                             "five minutes leave the later arrivals in the rate")
    }

    func testASessionTheRouterMovesSettlesTheAccountItArrivesOn() {
        let from = UUID(), to = UUID()
        let seen: [String: (account: UUID, at: Date)] = ["s": (from, now.addingTimeInterval(-120))]
        XCTAssertTrue(AppState.routedArrival("s", on: to, seen: seen))
        XCTAssertFalse(AppState.routedArrival("s", on: from, seen: seen), "a session staying where it was arrives nowhere")
        XCTAssertFalse(AppState.routedArrival("new", on: to, seen: seen), "nor does one seen for the first time")
        // Settled as a slot move is: the rewrite of the arriving session's
        // context teaches no rate; the work's own rate does.
        var trend = QuotaTrend()
        func read(_ used: Double, at seconds: TimeInterval) {
            trend.record(weeklyReading(used, resetIn: 100), at: now.addingTimeInterval(seconds))
        }
        for (step, used) in [20.0, 22, 24, 26].enumerated() { read(used, at: Double(step) * 360) }
        if AppState.routedArrival("s", on: to, seen: seen) { trend.settle(at: now.addingTimeInterval(1080)) }
        read(30, at: 1150)
        read(33, at: 1300)
        read(35, at: 1660)
        read(37, at: 2020)
        XCTAssertEqual(trend.weeklyBurnPerHour, 20, accuracy: 0.01)
    }

    // MARK: - Pool readings

    func testAnAccountInUseKeepsAShareOfItsWeightOnAnOldReading() {
        let read = now.addingTimeInterval(-20 * 60)
        let used = read.addingTimeInterval(60)
        XCTAssertEqual(FailoverPlanner.poolReadingConfidence(inUse: true, observedAt: now.addingTimeInterval(-5 * 60),
                                                             lastRequest: now, now: now), 1)
        XCTAssertEqual(FailoverPlanner.poolReadingConfidence(inUse: true, observedAt: read, lastRequest: used, now: now),
                       0.5, accuracy: 0.001, "ten minutes' lifetime over twenty minutes' age")
        XCTAssertEqual(FailoverPlanner.poolReadingConfidence(inUse: true, observedAt: now.addingTimeInterval(-61 * 60),
                                                             lastRequest: now, now: now), 0)
        XCTAssertEqual(FailoverPlanner.poolReadingConfidence(inUse: false, observedAt: now.addingTimeInterval(-5 * 3600),
                                                             lastRequest: now, now: now), 1,
                       "an idle account's reading stands for six hours")
    }

    func testAccountsSessionsRunOnAreReadBeforeIdleOnes() {
        let active = Account(email: "a@mail.example", displayName: "A", provider: .claudeCode, isActive: true)
        let serving = Account(email: "s@mail.example", displayName: "S", provider: .claudeCode)
        let idle = Account(email: "i@mail.example", displayName: "I", provider: .claudeCode)
        let order = AppState.readUrgencyOrder(
            [idle, serving, active], serving: [serving.id],
            updatedAt: [idle.id: now.addingTimeInterval(-20 * 60), serving.id: now.addingTimeInterval(-60),
                        active.id: now])
        XCTAssertEqual(order.map(\.id), [active.id, serving.id, idle.id],
                       "a passive reading makes the serving account look newer than an idle one")
    }

    // MARK: - The projected next account

    private func policy(preferMostCapacity: Bool = false, balancing: Bool = true) -> ProviderFailoverPolicy {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = true
        policy.sessionEnabled = false
        policy.weeklyEnabled = true
        policy.weeklyThreshold = 100
        policy.intelligentBalancingEnabled = balancing
        policy.preferMostCapacity = preferMostCapacity
        policy.loops = true
        policy.balancingMinimumDwellMinutes = 30
        policy.waitForImminentReset = true
        return policy
    }

    private func weeklyState(_ id: UUID, used: Double, resetIn hours: Double, active: Bool = false, burn: Double = 0,
                             staying: Double = 0, consumedElsewhere: Bool = false) -> QuotaAccountState {
        var state = QuotaAccountState(id: id, usage: weeklyReading(used, resetIn: hours),
                                      observedAt: now.addingTimeInterval(-60), weeklyBurnPerHour: burn,
                                      sessionPerWeekly: 8, isActive: active, mayBeConsumedElsewhere: consumedElsewhere)
        state.stayingSessionBurnPerHour = staying
        return state
    }

    func testAnAccountWithTooLittleRoomToCarryTheGroupIsNotProjected() throws {
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let active = UUID(), almostSpent = UUID(), roomy = UUID()
        // 2.5% an hour of the active account's 3% moves; 2% left on the
        // other passes the dwell margin but lasts under an hour.
        let current = weeklyState(active, used: 15, resetIn: 135, active: true, burn: 3, staying: 4)
        let ladder = [weeklyState(roomy, used: 6, resetIn: 147), weeklyState(almostSpent, used: 98, resetIn: 35), current]
        let toTrigger = try XCTUnwrap(planner.secondsUntilTrigger(current, now: now))
        XCTAssertEqual(planner.plan(current: current, ladder: ladder, lastSwitch: nil, now: now.addingTimeInterval(toTrigger)),
                       .verify([roomy]), "the allowance that resets first cannot carry the work for an hour")
        let next = try XCTUnwrap(planner.nextSwitch(current: current, ladder: ladder, now: now))
        XCTAssertEqual(next.account, roomy)
    }

    func testADestinationWithoutASessionWindowNeedsMinutesOfTheWeeklyRateConverted() {
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let current = weeklyState(UUID(), used: 50, resetIn: 100, active: true, burn: 3)
        let destination = weeklyState(UUID(), used: 10, resetIn: 100)
        // 3% of the week an hour is 24 session percent at 8 to 1; ten
        // minutes of it is 4.
        XCTAssertEqual(planner.destinationMinimum(current: current, destination: destination), 4, accuracy: 0.001)
        XCTAssertTrue(planner.carries(destination, from: current, at: now))
        let sliver = weeklyState(UUID(), used: 98, resetIn: 100)
        XCTAssertFalse(planner.carries(sliver, from: current, at: now), "16 session percent last 40 minutes at 24 an hour")
    }

    func testTheProjectedAccountIsKeptUntilAnotherIsClearlyBetter() throws {
        let planner = FailoverPlanner(settings: .init(policy: policy(preferMostCapacity: true, balancing: false),
                                                      provider: .claudeCode))
        let active = UUID(), b = UUID(), c = UUID()
        let current = weeklyState(active, used: 50, resetIn: 100, active: true, burn: 5)
        func ladder(_ bUsed: Double, _ cUsed: Double) -> [QuotaAccountState] {
            [current, weeklyState(b, used: bUsed, resetIn: 120), weeklyState(c, used: cUsed, resetIn: 120)]
        }
        // b and c take turns at having slightly more room.
        let first = try XCTUnwrap(planner.nextSwitch(current: current, ladder: ladder(40, 42), now: now))
        XCTAssertEqual(first.account, b)
        XCTAssertEqual(planner.nextSwitch(current: current, ladder: ladder(42, 40), now: now)?.account, c,
                       "without a projection to keep, the most room wins")
        XCTAssertEqual(planner.nextSwitch(current: current, ladder: ladder(42, 40), keeping: b, now: now)?.account, b)
        // c with more than twice b's room replaces it.
        XCTAssertEqual(planner.nextSwitch(current: current, ladder: ladder(80, 10), keeping: b, now: now)?.account, c)
    }

    // MARK: - Pacing with the group projected to move

    /// Weekly-only accounts at one window percent per million tokens.
    private func pacerAccount(_ id: UUID, left: Double, resetIn hours: Double, burn: Double = 0,
                              weight: Double = 1, ratio: Double = 1) -> SessionPacer.Account {
        var account = SessionPacer.Account(id: id, utilization: 0, resetsAt: nil, burnPerHour: burn, baseWeight: weight,
                                           percentPerMillion: ratio)
        account.hasSessionWindow = false
        account.weeklyRemaining = left
        account.weeklyResetsAt = now.addingTimeInterval(hours * 3600)
        return account
    }

    private func group(on account: UUID, tokensPerHour: Double, next: UUID?, inHours hours: Double?,
                       sessions: Int = 4) -> SessionPacer.SharedGroup {
        SessionPacer.SharedGroup(account: account, tokensPerHour: tokensPerHour, contextTokens: 400_000, models: [],
                                 nextAccount: next, switchAt: hours.map { now.addingTimeInterval($0 * 3600) },
                                 sessionCount: sessions)
    }

    func testWhenEverythingRunsOutNewSessionsGoWhereRoomIsLeftAfterTheGroupsNeed() {
        let active = UUID(), next = UUID(), idle = UUID()
        // The group spends 10%/h on the active account for 20 hours, then on
        // the next account; each account also spends a few percent an hour
        // of its own. Together, at 18%/h, the 1100% left lasts 61 hours.
        let accounts = [pacerAccount(active, left: 400, resetIn: 150, burn: 13),
                        pacerAccount(next, left: 400, resetIn: 150, burn: 2),
                        pacerAccount(idle, left: 300, resetIn: 150, burn: 3)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [], now: now,
                                       sharedGroup: group(on: active, tokensPerHour: 10_000_000, next: next, inHours: 20))
        let weights = plan.weights
        XCTAssertEqual(weights[next] ?? -1, 0, accuracy: 0.0001, "the group needs all of it after the switch")
        let share = (weights[active] ?? 0) / ((weights[active] ?? 0) + (weights[idle] ?? 0))
        // At the run-out the active account has 400 − 3 × 61.1 − 200 left,
        // the idle one 300 − 3 × 61.1.
        XCTAssertEqual(share, 16.67 / (16.67 + 116.67), accuracy: 0.01)
    }

    func testTheNextAccountKeepsAWeightWhenTheGroupWouldSpendItsWholeRoom() {
        let active = UUID(), next = UUID()
        // Two accounts, each short of its reset; the next has the room.
        let accounts = [pacerAccount(active, left: 100, resetIn: 150, burn: 12),
                        pacerAccount(next, left: 500, resetIn: 150, burn: 2)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [], now: now,
                                       sharedGroup: group(on: active, tokensPerHour: 10_000_000, next: next, inHours: 10))
        XCTAssertGreaterThan(plan.weights[next] ?? 0, 0)
        XCTAssertEqual(plan.weights[active] ?? -1, 0, accuracy: 0.0001,
                       "the group alone spends the active account by the switch")
    }

    func testAnAccountsSustainedShareCountsHowLongItLastsWithTheGroup() {
        let pacer = SessionPacer()
        let next = pacerAccount(UUID(), left: 100, resetIn: 100)
        let share = SessionPacer.SharedShare(percentPerHour: 10, from: now.addingTimeInterval(5 * 3600), until: nil)
        let outlook = pacer.outlook(next, burn: 0, now: now, shared: share)
        XCTAssertEqual(outlook.allowedPerHour, 0, accuracy: 0.0001, "the group's 950% by the reset exceeds its room")
        XCTAssertEqual(SessionPacer.sustainedShare(outlook, now: now), 15.0 / 100, accuracy: 0.001,
                       "it lasts 15 of the 100 hours")
    }

    func testADrainingAccountTakesNoNewSessionItCannotCarryForTheRunway() {
        // Unpaced: the drain's weight, even preferred, gives way to the runway.
        XCTAssertEqual(AppState.poolWeight(tier: .usable, urgent: false, anyBelow: false, forecastAtLimit: false,
                                           anyOpen: true, draining: true, othersLowOnWeeklyRoom: true),
                       AppState.drainingPreferred)
        XCTAssertEqual(AppState.poolWeight(tier: .usable, urgent: false, anyBelow: false, forecastAtLimit: false,
                                           anyOpen: true, draining: true, othersLowOnWeeklyRoom: true, shortOfRunway: true), 0)
        XCTAssertEqual(AppState.poolWeight(tier: .belowTrigger, urgent: true, anyBelow: true, forecastAtLimit: false,
                                           anyOpen: true, draining: false, othersLowOnWeeklyRoom: false, shortOfRunway: true), 0,
                       "a few percent below a trigger is no room either")
        // Backup's 2% of the week is 16 session percent: beside its own
        // session's 5 an hour it carries another for the hour, not beside 12.
        XCTAssertTrue(AppState.carriesNewSession(headroom: 16, burn: 5, newSessionBurn: 5))
        XCTAssertFalse(AppState.carriesNewSession(headroom: 16, burn: 12, newSessionBurn: 5))

        // Paced: a draining account at its preferred weight, with room for
        // its own rate until its reset in two hours but not for one more
        // session for an hour, takes none while another account can.
        let draining = UUID(), other = UUID()
        let accounts = [pacerAccount(draining, left: 4, resetIn: 2, weight: AppState.drainingPreferred, ratio: 0.25),
                        pacerAccount(other, left: 500, resetIn: 150, burn: 2, ratio: 0.25)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [], now: now)
        XCTAssertEqual(plan.weights[draining] ?? -1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(plan.weights[other] ?? 0, 0)
    }

    func testOnlyAnAccountRunningOutBeforeThePoolGivesSessionsUp() {
        let early = UUID(), late = UUID()
        // Both reach their limits days before their weekly resets; the
        // two together last 55 hours at 4%/h, `early` alone 50.
        let accounts = [pacerAccount(early, left: 100, resetIn: 150, burn: 2),
                        pacerAccount(late, left: 120, resetIn: 150, burn: 2)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [], now: now)
        XCTAssertEqual(Set(plan.shedding.keys), [early])
        XCTAssertEqual(plan.shedReasons[early], .poolRunsOut(now.addingTimeInterval(55 * 3600)))

        // Running out half an hour before the pool is not worth a session's
        // cache rewrite.
        let even = [pacerAccount(early, left: 100, resetIn: 150, burn: 2),
                    pacerAccount(late, left: 102, resetIn: 150, burn: 2)]
        XCTAssertTrue(SessionPacer().plan(accounts: even, sessions: [], now: now).shedding.isEmpty)
    }

    func testStrandedSessionsSpreadOverTheAccountsWithRoom() {
        let a = UUID(), b = UUID()
        let accounts = [pacerAccount(a, left: 100, resetIn: 150), pacerAccount(b, left: 100, resetIn: 150)]
        let stranded = (1...4).map {
            SessionPacer.RebalanceSession(id: "s\($0)", account: UUID(), tokensPerHour: 5_000_000, contextTokens: 100_000,
                                          model: nil, movable: true)
        }
        let placed = SessionPacer().place(stranded, accounts: accounts, running: [], destinations: [a, b], now: now)
        XCTAssertEqual(placed.count, 4)
        XCTAssertEqual(placed.values.filter { $0 == a }.count, 2)
        XCTAssertEqual(placed.values.filter { $0 == b }.count, 2)

        // Twice the room takes twice the sessions.
        let uneven = [pacerAccount(a, left: 200, resetIn: 150), pacerAccount(b, left: 100, resetIn: 150)]
        let six = (1...6).map {
            SessionPacer.RebalanceSession(id: "s\($0)", account: UUID(), tokensPerHour: 5_000_000, contextTokens: 100_000,
                                          model: nil, movable: true)
        }
        let spread = SessionPacer().place(six, accounts: uneven, running: [], destinations: [a, b], now: now)
        XCTAssertEqual(spread.values.filter { $0 == a }.count, 4)
        XCTAssertEqual(spread.values.filter { $0 == b }.count, 2)
    }

    func testRebalanceCountsTheUseAnAccountsReadingsShowBeyondItsSessions() {
        let a = UUID(), b = UUID()
        let session = SessionPacer.RebalanceSession(id: "s", account: a, tokensPerHour: 5_000_000, contextTokens: 10_000,
                                                    model: nil, movable: true)
        // a's readings show 20%/h, its one session 5%/h.
        let accounts = [pacerAccount(a, left: 100, resetIn: 150, burn: 20), pacerAccount(b, left: 100, resetIn: 150)]
        let plan = SessionPacer().rebalance(accounts: accounts, sessions: [session], destinations: [a, b], now: now)
        XCTAssertEqual(plan.earliestRunOutBefore?.timeIntervalSince(now) ?? 0, 5 * 3600, accuracy: 60,
                       "100% at the 20%/h its readings show")
        XCTAssertEqual(plan.moves["s"], b)
    }

    func testAStrandedSessionGoesWhereItWasPlaced() {
        let spent = UUID(), personal = UUID(), active = UUID()
        let choice = AppState.slotChoice(current: spent, pinned: nil, requested: nil, balance: nil,
                                         cannotServe: { $0 == spent }, modelSpent: false, byWeight: [active, personal],
                                         placed: personal, fallback: active)
        XCTAssertEqual(choice.target, personal)
        let unusable = AppState.slotChoice(current: spent, pinned: nil, requested: nil, balance: nil,
                                           cannotServe: { $0 == spent || $0 == personal }, modelSpent: false,
                                           byWeight: [active, personal], placed: personal, fallback: active)
        XCTAssertEqual(unusable.target, active, "a placement that can no longer serve falls back to the pool's choice")
    }

    // MARK: - Regression

    /// The accounts as they stood one evening: the active account and one
    /// other had most of their weekly allowance after resets granted early;
    /// every other account was at 98–100% of its week. Weekly limits only,
    /// failover at 100%, balancing on, the ladder in the user's order.
    func testAnEveningWithTwoRoomyAccountsAndTheRestNearlySpent() throws {
        let personal = UUID(), hstlesSystem = UUID(), orbtrSystem = UUID(), backup = UUID()
        let orbtrBrandon = UUID(), hstlesBrandon = UUID()
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let ratio = 0.25
        // Four sessions on the shared sign-in at 20M weighted tokens an hour
        // each: 20% (in session units) an hour, 2.5% of the week.
        let groupTokens = 80_000_000.0
        let sessionTokens = 20_000_000.0
        let sessionUnits = sessionTokens / 1_000_000 * ratio

        // Failover's view: the active account burns the group's rate.
        func ladder(activeBurn: Double, backupStaying: Double) -> (QuotaAccountState, [QuotaAccountState]) {
            let current = weeklyState(hstlesBrandon, used: 15, resetIn: 135.5, active: true, burn: activeBurn)
            return (current, [
                weeklyState(personal, used: 6, resetIn: 147.5, staying: sessionUnits, consumedElsewhere: true),
                weeklyState(hstlesSystem, used: 99, resetIn: 73.5),
                weeklyState(orbtrSystem, used: 100, resetIn: 157.5),
                weeklyState(backup, used: 98, resetIn: 35.5, staying: backupStaying, consumedElsewhere: true),
                weeklyState(orbtrBrandon, used: 99, resetIn: 110.5),
                current
            ])
        }
        // The group's rate as the readings show it from cycle to cycle.
        var projected: UUID?
        var switchAt: Date?
        for (burn, staying) in [(3.0, 5.0), (2.2, 4.0), (4.5, 5.0), (2.8, 6.0), (2.5, 5.0)] {
            let (current, accounts) = ladder(activeBurn: burn, backupStaying: staying)
            if projected == nil {
                // As of the switch, Backup's allowance resets first but
                // cannot carry the group; Personal is read and switched to.
                let toTrigger = try XCTUnwrap(planner.secondsUntilTrigger(current, now: now))
                XCTAssertEqual(planner.plan(current: current, ladder: accounts, lastSwitch: nil,
                                            now: now.addingTimeInterval(toTrigger)), .verify([personal]))
            }
            let next = try XCTUnwrap(planner.nextSwitch(current: current, ladder: accounts, keeping: projected, now: now))
            XCTAssertNotEqual(next.account, backup, "2% of the week carries the group for minutes")
            if let projected { XCTAssertEqual(next.account, projected, "the projection holds from cycle to cycle") }
            projected = next.account
            switchAt = next.at
        }
        XCTAssertEqual(projected, personal)

        // Balancing would spend Backup's allowance first, since it resets
        // a hundred hours before HSTLES (brandon)'s, but Backup cannot
        // carry the group; Personal resets later, so the work stays.
        let (healthy, all) = ladder(activeBurn: 3, backupStaying: 5)
        XCTAssertEqual(planner.latestStart(healthy, now: now).timeIntervalSince(
            planner.latestStart(all.first(where: { $0.id == backup })!, now: now)) / 3600, 100, accuracy: 0.01,
                       "without a 5-hour window an allowance's latest start is its reset")
        XCTAssertEqual(planner.plan(current: healthy, ladder: all, lastSwitch: nil, now: now), .stay(.healthy))
        XCTAssertEqual(AppState.balanceSwitchEvent(source: "HSTLES (brandon)", target: "Backup", hours: 100),
                       "Balancing moves work from HSTLES (brandon) to Backup: Backup's allowance must start being used 100 hour(s) before HSTLES (brandon)'s for each to be used up before it resets.")

        // HSTLES (brandon) reaches its limit: the switch goes to Personal,
        // never onto Backup's 2%.
        let spentActive = weeklyState(hstlesBrandon, used: 99.5, resetIn: 135.5, active: true, burn: 3)
        let (_, everyone) = ladder(activeBurn: 3, backupStaying: 5)
        let atLimit = everyone.map { $0.id == hstlesBrandon ? spentActive : $0 }
        XCTAssertEqual(planner.plan(current: spentActive, ladder: atLimit, lastSwitch: nil, now: now),
                       .switchTo(personal, .exhausted))
        // With only Backup left below its limit, failover waits for the
        // first reset instead.
        let withoutPersonal = atLimit.filter { $0.id != personal }
        XCTAssertEqual(planner.plan(current: spentActive, ladder: withoutPersonal, lastSwitch: nil, now: now),
                       .waitForReset(hstlesSystem, now.addingTimeInterval(73.5 * 3600)))
        XCTAssertFalse(planner.hasFallback(current: spentActive, ladder: withoutPersonal, now: now))
        XCTAssertNil(planner.nextSwitch(current: spentActive, ladder: withoutPersonal, now: now))

        // The pacer's view: the pool is the three accounts below their
        // limits; one slot session runs on Personal and one on Backup.
        let accounts = [
            pacerAccount(hstlesBrandon, left: (99 - 15) * 8, resetIn: 135.5, burn: groupTokens / 1_000_000 * ratio,
                         ratio: ratio),
            pacerAccount(personal, left: (99 - 6) * 8, resetIn: 147.5, burn: sessionUnits, ratio: ratio),
            pacerAccount(backup, left: (99 - 98) * 8, resetIn: 35.5, burn: sessionUnits, ratio: ratio)
        ]
        func slot(_ id: String, on account: UUID) -> SessionPacer.Session {
            SessionPacer.Session(id: id, account: account, tokensPerHour: sessionTokens, contextTokens: 150_000,
                                 lastSeen: now.addingTimeInterval(-60), cacheLifetime: 3600,
                                 recentTokensPerHour: sessionTokens)
        }
        let shared = SessionPacer.SharedGroup(account: hstlesBrandon, tokensPerHour: groupTokens, contextTokens: 600_000,
                                              models: [], nextAccount: projected, switchAt: switchAt, sessionCount: 4)
        let pacer = SessionPacer()
        // Backup's readings show its slot session's rate; the session
        // itself is not among those the pacer may move.
        let plan = pacer.plan(accounts: accounts, sessions: [slot("p1", on: personal)], now: now, sharedGroup: shared)
        XCTAssertGreaterThan(plan.weights[personal] ?? 0, 0, "the account the group moves to keeps the room it does not need")
        XCTAssertEqual(plan.weights[hstlesBrandon] ?? -1, 0, accuracy: 0.0001,
                       "the group alone spends the active account by the switch")
        XCTAssertEqual(plan.weights[backup] ?? -1, 0, accuracy: 0.0001)

        // Shedding: every account here reaches its limit days before its
        // weekly reset, but only Backup does so while the others still
        // have room. Personal, which the group moves to, lasts past the
        // accounts' run-out; HSTLES (brandon) reaches its limit only as the
        // group's switch does.
        XCTAssertEqual(Set(plan.shedding.keys), [backup])
        guard case .poolRunsOut(let end)? = plan.shedReasons[backup] else {
            return XCTFail("Backup sheds because it runs out before the pool does")
        }
        XCTAssertEqual(end.timeIntervalSince(now) / 3600, 47.5, accuracy: 0.1,
                       "1424% left in tokens at the group's 80M and two sessions' 20M an hour each")
        XCTAssertTrue(AppState.sheddingEvent(account: "Backup", allowance: nil, limitAt: now.addingTimeInterval(1.6 * 3600),
                                             reason: .poolRunsOut(end), outcome: "1 session(s) move to other accounts at their next turn.",
                                             now: now)
            .contains("while the other accounts still have room"))
        // Its slot session moves to Personal, which then still lasts about
        // as long as the accounts together; HSTLES (brandon) would run out
        // a day sooner with it.
        let shedding = pacer.plan(accounts: accounts, sessions: [slot("p1", on: personal), slot("b1", on: backup)], now: now,
                                  sharedGroup: shared)
        XCTAssertEqual(shedding.moves, ["b1": personal])

        // ORBTR (brandon) reaches its limit: its three slot sessions leave.
        let running = [SessionPacer.RebalanceSession(id: "p1", account: personal, tokensPerHour: sessionTokens,
                                                     contextTokens: 150_000, model: nil, movable: true)]
        let stranded = (1...3).map {
            SessionPacer.RebalanceSession(id: "o\($0)", account: orbtrBrandon, tokensPerHour: sessionTokens,
                                          contextTokens: 150_000, model: nil, movable: true)
        }
        let placed = pacer.place(stranded, accounts: accounts.filter { $0.id != backup }, running: running,
                                 destinations: [personal, hstlesBrandon], now: now, sharedGroup: shared)
        XCTAssertEqual(placed.count, 3)
        XCTAssertFalse(placed.values.contains(hstlesBrandon), "nothing piles onto the active account")

        // With the group lighter than the active account's room, the room
        // left on each takes the sessions in proportion.
        let light = SessionPacer.SharedGroup(account: hstlesBrandon, tokensPerHour: groupTokens / 4, contextTokens: 600_000,
                                             models: [], nextAccount: personal, switchAt: switchAt, sessionCount: 4)
        let both = pacer.place((1...6).map {
            SessionPacer.RebalanceSession(id: "o\($0)", account: orbtrBrandon, tokensPerHour: sessionTokens * 4,
                                          contextTokens: 150_000, model: nil, movable: true)
        }, accounts: accounts.filter { $0.id != backup }.map { account in
            var account = account
            if account.id == hstlesBrandon { account.burnPerHour = groupTokens / 4 / 1_000_000 * ratio }
            return account
        }, running: running, destinations: [personal, hstlesBrandon], now: now, sharedGroup: light)
        XCTAssertGreaterThan(both.values.filter { $0 == hstlesBrandon }.count, 0)
        XCTAssertGreaterThan(both.values.filter { $0 == personal }.count, 0)
    }

    /// The rebalance preview later that evening: eight sessions on
    /// HSTLES (brandon), the four on the shared sign-in and four slot
    /// sessions; Personal with 94% of its week left and one slot session;
    /// Backup's slot session deep in a turn; ORBTR (brandon) at its limit,
    /// its readings still rising with its three slot sessions.
    func testTheEveningRebalanceMovesSlotSessionsToPersonal() throws {
        let personal = UUID(), backup = UUID(), orbtrBrandon = UUID(), hstlesBrandon = UUID()
        let ratio = 0.25
        let sessionTokens = 20_000_000.0
        let sessionUnits = sessionTokens / 1_000_000 * ratio
        let groupTokens = 80_000_000.0
        let accounts = [
            pacerAccount(hstlesBrandon, left: (99 - 15) * 8, resetIn: 135.5,
                         burn: groupTokens / 1_000_000 * ratio + 4 * sessionUnits, ratio: ratio),
            pacerAccount(personal, left: (99 - 6) * 8, resetIn: 147.5, burn: sessionUnits, ratio: ratio),
            pacerAccount(backup, left: (99 - 98) * 8, resetIn: 35.5, burn: sessionUnits, ratio: ratio),
            pacerAccount(orbtrBrandon, left: 0, resetIn: 110.5, burn: 3 * sessionUnits, ratio: ratio)
        ]
        func session(_ id: String, on account: UUID, movable: Bool = true) -> SessionPacer.RebalanceSession {
            SessionPacer.RebalanceSession(id: id, account: account, tokensPerHour: sessionTokens, contextTokens: 150_000,
                                          model: nil, movable: movable)
        }
        let sessions = (1...4).map { session("h\($0)", on: hstlesBrandon) } + [session("p1", on: personal)]
            + [session("b1", on: backup, movable: false)] + (1...3).map { session("o\($0)", on: orbtrBrandon) }
        // The group leaves HSTLES (brandon) for Personal when the week runs
        // out there, at 5% of the week an hour in 17 hours.
        let shared = SessionPacer.SharedGroup(account: hstlesBrandon, tokensPerHour: groupTokens, contextTokens: 600_000,
                                              models: [], nextAccount: personal,
                                              switchAt: now.addingTimeInterval(17 * 3600), sessionCount: 4)
        let plan = SessionPacer().rebalance(accounts: accounts, sessions: sessions,
                                            destinations: [hstlesBrandon, personal, backup], now: now, sharedGroup: shared)
        let toPersonal = plan.moves.filter { $0.value == personal }.keys
        XCTAssertFalse(toPersonal.isEmpty, "ORBTR (brandon) at its limit and Backup's held session no longer end the search")
        XCTAssertTrue(toPersonal.allSatisfy { $0.hasPrefix("h") }, "slot sessions leave HSTLES (brandon) for Personal")
        XCTAssertNil(plan.moves["b1"])
        let before = try XCTUnwrap(plan.earliestRunOutBefore)
        let after = try XCTUnwrap(plan.earliestRunOutAfter)
        XCTAssertEqual(before.timeIntervalSince(now) / 3600, 16.8, accuracy: 0.05,
                       "HSTLES (brandon) at 40% an hour with the group runs out first")
        XCTAssertGreaterThan(after, before.addingTimeInterval(3 * 3600))
    }

    // MARK: - Spending a remainder that would otherwise expire

    /// The evening again, with Backup idle at 98% of its week and 31 hours
    /// to its reset: three heavy slot sessions and one light idle one on
    /// HSTLES (brandon) beside the shared group, a lighter one mid-turn and
    /// a lighter one pinned there, and Personal's one session.
    private struct RemainderEvening {
        let personal = UUID(), backup = UUID(), hstlesBrandon = UUID()
        let ratio = 0.25
        let sessionTokens = 20_000_000.0
        let groupTokens = 80_000_000.0
    }

    private func remainderAccounts(_ evening: RemainderEvening, backupLeft: Double = (99 - 98) * 8,
                                   backupResetIn: Double = 31) -> [SessionPacer.Account] {
        let units = evening.sessionTokens / 1_000_000 * evening.ratio
        return [
            pacerAccount(evening.hstlesBrandon, left: (99 - 15) * 8, resetIn: 135.5,
                         burn: evening.groupTokens / 1_000_000 * evening.ratio + 3 * units, ratio: evening.ratio),
            pacerAccount(evening.personal, left: (99 - 6) * 8, resetIn: 147.5, burn: units, ratio: evening.ratio),
            pacerAccount(evening.backup, left: backupLeft, resetIn: backupResetIn, ratio: evening.ratio)
        ]
    }

    private func remainderSessions(_ evening: RemainderEvening, light: Double = 800_000,
                                   lightContext: Int = 100_000) -> [SessionPacer.Session] {
        func session(_ id: String, on account: UUID, current: Double, recent: Double, quietFor seconds: TimeInterval,
                     context: Int = 150_000) -> SessionPacer.Session {
            SessionPacer.Session(id: id, account: account, tokensPerHour: current, contextTokens: context,
                                 lastSeen: now.addingTimeInterval(-seconds), cacheLifetime: 3600,
                                 lastTurnStart: now.addingTimeInterval(-seconds - 60), recentTokensPerHour: recent)
        }
        let heavy = (1...3).map {
            session("h\($0)", on: evening.hstlesBrandon, current: evening.sessionTokens, recent: evening.sessionTokens,
                    quietFor: 60 * Double($0))
        }
        return heavy + [
            // Between turns for ten minutes; its rate fades, its last hour's does not.
            session("light", on: evening.hstlesBrandon, current: light / 2, recent: light, quietFor: 10 * 60,
                    context: lightContext),
            // Lighter still, but mid-turn: its last request was moments ago.
            session("busy", on: evening.hstlesBrandon, current: 400_000, recent: 400_000, quietFor: 20),
            // Lighter still, but pinned to HSTLES (brandon).
            session("pinned", on: evening.hstlesBrandon, current: 0, recent: 300_000, quietFor: 15 * 60),
            session("p1", on: evening.personal, current: evening.sessionTokens, recent: evening.sessionTokens, quietFor: 60)
        ]
    }

    private func remainderGroup(_ evening: RemainderEvening) -> SessionPacer.SharedGroup {
        SessionPacer.SharedGroup(account: evening.hstlesBrandon, tokensPerHour: evening.groupTokens, contextTokens: 600_000,
                                 models: [], nextAccount: evening.personal, switchAt: now.addingTimeInterval(17 * 3600),
                                 sessionCount: 4)
    }

    func testALightIdleSlotSessionSpendsBackupsLastPercentBeforeItResets() throws {
        let evening = RemainderEvening()
        // Failover's view: Backup's 2% cannot carry the group, so neither
        // balancing nor a switch moves it there.
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let current = weeklyState(evening.hstlesBrandon, used: 15, resetIn: 135.5, active: true, burn: 3)
        let backupState = weeklyState(evening.backup, used: 98, resetIn: 31, consumedElsewhere: true)
        let ladder = [weeklyState(evening.personal, used: 6, resetIn: 147.5, staying: 5, consumedElsewhere: true),
                      backupState, current]
        XCTAssertFalse(planner.carries(backupState, from: current, at: now))
        XCTAssertEqual(planner.plan(current: current, ladder: ladder, lastSwitch: nil, now: now), .stay(.healthy),
                       "the shared group stays where it is")

        // The pacer's view: Backup is offered as a remainder, every slot
        // session as a candidate.
        let sessions = remainderSessions(evening)
        let spending = SessionPacer.RemainderSpending(accounts: [evening.backup], sessions: Set(sessions.map(\.id)))
        let plan = SessionPacer().plan(accounts: remainderAccounts(evening), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertEqual(plan.moves, ["light": evening.backup],
                       "the light idle session goes; the heavy ones, the mid-turn and the pinned one stay")
        let remainder = try XCTUnwrap(plan.remainders["light"])
        XCTAssertEqual(remainder.account, evening.backup)
        XCTAssertEqual(remainder.unused, 8, accuracy: 0.001, "1% of the week below the limit at 8 to 1, none of it in use")
        XCTAssertEqual(remainder.resetsAt, now.addingTimeInterval(31 * 3600))
        XCTAssertNil(plan.shedding[evening.backup], "a session placed for the remainder reaches no limit there")
        // 0.8M an hour for 31 hours is 6.2% at 0.25 per million: a second
        // session would follow only with more than half of the 8% left.
        XCTAssertEqual(plan.remainders.count, 1)

        // New sessions: Backup keeps a small weight for what is left of it.
        let backupWeight = plan.weights[evening.backup] ?? 0
        XCTAssertGreaterThan(backupWeight, 0)
        XCTAssertLessThan(backupWeight, (plan.weights[evening.personal] ?? 0) * 0.02)

        // Once there, the session stays: Backup no longer offers enough
        // unused allowance to move another session, and gives none up.
        let arrived = sessions.map { session -> SessionPacer.Session in
            var session = session
            if session.id == "light" { session.account = evening.backup }
            return session
        }
        let next = SessionPacer().plan(accounts: remainderAccounts(evening, backupLeft: 8 - 0.03), sessions: arrived, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertTrue(next.moves.isEmpty)

        XCTAssertEqual(
            AppState.remainderMoveEvent(session: "session 1234abcd", account: "Backup", percentLeft: 2,
                                        resetsAt: now.addingTimeInterval(31 * 3600), now: now)
                .hasPrefix("Moved session 1234abcd (light use) to Backup to use its last 2% before it resets on "), true)
        XCTAssertTrue(AppState.remainderMoveEvent(session: "session 1234abcd", account: "Backup", percentLeft: 2,
                                                  resetsAt: now.addingTimeInterval(31 * 3600), now: now)
            .hasSuffix("; it rebuilds its cache there."))
    }

    func testARemainderBelowOneCacheRewriteMovesNothing() {
        let evening = RemainderEvening()
        let sessions = remainderSessions(evening)
        let spending = SessionPacer.RemainderSpending(accounts: [evening.backup], sessions: Set(sessions.map(\.id)))
        // The light session's 100,000-token context costs 0.029% to write
        // there; 0.02% is left.
        let tiny = SessionPacer().plan(accounts: remainderAccounts(evening, backupLeft: 0.02), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertTrue(tiny.moves.isEmpty)
        // Room for the session, but its use is not clearly worth the
        // rewrite: a 2M-token context costs 0.575%, its use 0.6% by a
        // reset in three hours.
        let unworthy = SessionPacer().plan(accounts: remainderAccounts(evening, backupResetIn: 3),
                                           sessions: remainderSessions(evening, lightContext: 2_000_000), now: now,
                                           sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertTrue(unworthy.moves.isEmpty)
        // A session too heavy for the remainder is not sent to spend it.
        let heavy = SessionPacer().plan(accounts: remainderAccounts(evening), sessions: remainderSessions(evening, light: 2_000_000),
                                        now: now, sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertTrue(heavy.moves.isEmpty, "2M an hour for 31 hours is 15.5%, more than the 8% left")
        // Nor is anything moved without a remainder offered.
        let none = SessionPacer().plan(accounts: remainderAccounts(evening), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"])
        XCTAssertTrue(none.moves.isEmpty)
    }

    func testAMidTurnOrPinnedLightSessionIsNotChosen() {
        let evening = RemainderEvening()
        // Only the mid-turn and the pinned sessions are light enough.
        let sessions = remainderSessions(evening).filter { $0.id != "light" }
        let spending = SessionPacer.RemainderSpending(accounts: [evening.backup], sessions: Set(sessions.map(\.id)))
        let plan = SessionPacer().plan(accounts: remainderAccounts(evening), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertTrue(plan.moves.isEmpty)
        // A session `AppState.remainderSpending` leaves out, as it does one
        // its record shows working, is not chosen either.
        let all = remainderSessions(evening)
        let without = SessionPacer.RemainderSpending(accounts: [evening.backup],
                                                     sessions: Set(all.map(\.id)).subtracting(["light"]))
        XCTAssertTrue(SessionPacer().plan(accounts: remainderAccounts(evening), sessions: all, now: now,
                                          sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: without)
            .moves.isEmpty)
    }

    func testTheSharedGroupIsNeverMovedForARemainder() {
        let evening = RemainderEvening()
        let sessions = remainderSessions(evening)
        // Personal, the account the group is projected to move to, would
        // also leave some of its week unused; it carries the group's share,
        // so it spends nothing as a remainder, and no session leaves it.
        let spending = SessionPacer.RemainderSpending(accounts: [evening.personal, evening.backup],
                                                      sessions: Set(sessions.map(\.id)))
        let plan = SessionPacer().plan(accounts: remainderAccounts(evening), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertEqual(plan.moves, ["light": evening.backup])
        XCTAssertFalse(plan.moves.values.contains(evening.personal))
        // The group's own sessions are never among the pacer's sessions; the
        // failover plan, which alone moves the group, never takes it to
        // Backup at its limit either.
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let spentActive = weeklyState(evening.hstlesBrandon, used: 99.5, resetIn: 135.5, active: true, burn: 3)
        let ladder = [weeklyState(evening.backup, used: 98, resetIn: 31, consumedElsewhere: true), spentActive]
        XCTAssertNotEqual(planner.plan(current: spentActive, ladder: ladder, lastSwitch: nil, now: now),
                          .switchTo(evening.backup, .exhausted))
    }

    func testASecondLightSessionFollowsWhenTheFirstLeavesMostOfTheRemainder() {
        let evening = RemainderEvening()
        var sessions = remainderSessions(evening)
        sessions.append(SessionPacer.Session(id: "light2", account: evening.hstlesBrandon, tokensPerHour: 0,
                                             contextTokens: 100_000, lastSeen: now.addingTimeInterval(-5 * 60),
                                             cacheLifetime: 3600, recentTokensPerHour: 1_000_000))
        let spending = SessionPacer.RemainderSpending(accounts: [evening.backup], sessions: Set(sessions.map(\.id)))
        // 3% of the week, 24 session percent: the first uses 6.2 of it.
        let plan = SessionPacer().plan(accounts: remainderAccounts(evening, backupLeft: 24), sessions: sessions, now: now,
                                       sharedGroup: remainderGroup(evening), fixed: ["pinned"], remainders: spending)
        XCTAssertEqual(plan.moves, ["light": evening.backup, "light2": evening.backup])
    }

    // MARK: - Plans of different sizes

    /// Weekly-only states with an explicit token cost: Max 20x at 0.25% of
    /// a session per million tokens, Pro, a twentieth the size, at 5.
    private func sizedState(used: Double, ratio: Double, active: Bool = false, burn: Double = 0) -> QuotaAccountState {
        var state = weeklyState(UUID(), used: used, resetIn: 100, active: active, burn: burn)
        state.percentPerMillion = ratio
        return state
    }

    func testTheGroupMovingFromAMax20xAccountOntoAProAccountCountsAtProsSize() {
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let current = sizedState(used: 50, ratio: 0.25, active: true, burn: 5)
        let pro = sizedState(used: 60, ratio: 5)
        XCTAssertEqual(planner.expectedBurn(movingFrom: current, to: pro).weekly, 100, accuracy: 0.001,
                       "5% of a Max 20x week an hour is 100% of a Pro week")
        XCTAssertFalse(planner.carries(pro, from: current, at: now))
        let max20x = sizedState(used: 60, ratio: 0.25)
        XCTAssertEqual(planner.expectedBurn(movingFrom: current, to: max20x).weekly, 5, accuracy: 0.001)
        XCTAssertTrue(planner.carries(max20x, from: current, at: now), "the same 40% of a Max 20x week carries it")
    }

    func testAProAccountWithHalfItsWeekHasLessRoomThanAMax20xAccountWithATenth() throws {
        let planner = FailoverPlanner(settings: .init(policy: policy(preferMostCapacity: true, balancing: false),
                                                      provider: .claudeCode))
        let pro = sizedState(used: 50, ratio: 5)
        let max20x = sizedState(used: 90, ratio: 0.25)
        let proRoom = planner.tokenRoom(pro, try XCTUnwrap(planner.projection(pro, now: now)))
        let maxRoom = planner.tokenRoom(max20x, try XCTUnwrap(planner.projection(max20x, now: now)))
        XCTAssertEqual(proRoom, 80, accuracy: 0.001, "400 session percent at 5 per million")
        XCTAssertEqual(maxRoom, 320, accuracy: 0.001, "80 session percent at 0.25 per million")
        // The account with the most room is the one with the most tokens.
        let spent = sizedState(used: 99.5, ratio: 0.25, active: true, burn: 0.5)
        XCTAssertEqual(planner.plan(current: spent, ladder: [spent, pro, max20x], lastSwitch: nil, now: now),
                       .switchTo(max20x.id, .exhausted))
    }

    func testNewSessionsAndRebalancingPlaceByTokenRoom() {
        let pro = UUID(), max20x = UUID()
        // Pro has half its week, 400 session percent, at 5 per million:
        // 80 million tokens. Max 20x has a tenth, 80 percent at 0.25: 320.
        let accounts = [pacerAccount(pro, left: 400, resetIn: 100, ratio: 5),
                        pacerAccount(max20x, left: 80, resetIn: 100, ratio: 0.25)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [], now: now)
        XCTAssertEqual((plan.weights[max20x] ?? 0) / (plan.weights[pro] ?? 1), 4, accuracy: 0.001,
                       "four times the tokens left take four times the new sessions")

        let session = SessionPacer.RebalanceSession(id: "s", account: pro, tokensPerHour: 20_000_000, contextTokens: 100_000,
                                                    model: nil, movable: true)
        let rebalanced = SessionPacer().rebalance(accounts: accounts, sessions: [session], destinations: [pro, max20x], now: now)
        XCTAssertEqual(rebalanced.moves["s"], max20x, "100% of Pro an hour lasts 4 hours, 5% of Max 20x 16")
        var stranded = session
        stranded.account = UUID()
        XCTAssertEqual(SessionPacer().place([stranded], accounts: accounts, running: [], destinations: [pro, max20x], now: now),
                       ["s": max20x])
    }

    func testAnAccountWithNoLearnedCostIsSeededFromItsPlanSize() {
        let max20x = UUID(), max5x = UUID(), pro = UUID(), unknown = UUID()
        var model = TurnCostModel()
        model.accountPercentPerMillion = [max20x: 0.25]
        let sizes: [UUID: Double] = [max20x: 20, max5x: 5, pro: 1]
        let proSeed = model.ratio(for: pro, sizes: sizes)
        XCTAssertEqual(proSeed.ratio, 5, accuracy: 0.0001, "twenty times the Max 20x account's cost")
        XCTAssertEqual(proSeed.source, .seededFromLearned)
        XCTAssertEqual(model.ratio(for: max5x, sizes: sizes).ratio, 1, accuracy: 0.0001)
        XCTAssertEqual(model.ratio(for: max20x, sizes: sizes).source, .learned)
        XCTAssertEqual(model.ratio(for: unknown, sizes: sizes).source, .planWide)
        // With nothing learned, the plan-wide cost is spread by size.
        let fresh = TurnCostModel()
        let small = fresh.ratio(for: pro, sizes: [max20x: 20, pro: 1])
        let large = fresh.ratio(for: max20x, sizes: [max20x: 20, pro: 1])
        XCTAssertEqual(small.ratio / large.ratio, 20, accuracy: 0.0001)
        XCTAssertEqual(small.source, .seededFromPlanWide)

        // The plan size comes from the credential's rate-limit tier.
        var ultra = Account(email: "u@mail.example", displayName: "U", provider: .claudeCode, subscriptionType: "max")
        ultra.rateLimitTier = "default_claude_max_20x"
        XCTAssertEqual(ultra.planSize, 20)
        ultra.rateLimitTier = "default_claude_max_5x"
        XCTAssertEqual(ultra.planSize, 5)
        ultra.rateLimitTier = nil
        XCTAssertNil(ultra.planSize, "a Max plan without its tier could be either size")
        XCTAssertEqual(Account(email: "p@mail.example", displayName: "P", provider: .claudeCode, subscriptionType: "pro").planSize, 1)
        XCTAssertNil(Account(email: "c@mail.example", displayName: "C", provider: .codex, subscriptionType: "plus").planSize)
    }

    func testTheWeekSimulatorServesDemandAtEachAccountsSize() {
        // Demand of 1% an hour at the plan-wide size spends 20% an hour of
        // a plan a twentieth that size: its 100% lasts five hours, and its
        // week resets after the simulated one.
        let small = QuotaSimulator.Account(id: UUID(), session: 0, sessionReset: nil, weekly: 0,
                                           weeklyReset: now.addingTimeInterval(200 * 3600), sessionPerWeekly: 8,
                                           hasSessionWindow: false, scale: 20)
        let outcome = QuotaSimulator().run(accounts: [small], strategy: .earliestDeadline, demand: { _ in 1 }, start: now)
        XCTAssertEqual(outcome.served, 5, accuracy: 0.01)
        XCTAssertEqual(outcome.firstShortfall?.timeIntervalSince(now) ?? 0, 5 * 3600, accuracy: 15 * 60)
    }

    /// A heavy Opus session on a Max 20x account that reports no 5-hour
    /// window, and new Pro accounts with none of their 5-hour window used:
    /// at Max 20x's token cost the Pro window looks able to carry the
    /// session for hours; at Pro's own it lasts half an hour.
    func testAHeavySessionIsNeverPlacedOnAProAccountWhoseFiveHourWindowItWouldExhaust() {
        let personal = UUID(), bytrix = UUID(), hexorda = UUID()
        let opus = SessionPacer.Session(id: "platform-execution", account: personal, tokensPerHour: 40_000_000,
                                        contextTokens: 150_000, lastSeen: now.addingTimeInterval(-5 * 60),
                                        cacheLifetime: 3600, model: "claude-opus-4", recentTokensPerHour: 40_000_000)
        func pro(_ id: UUID, ratio: Double) -> SessionPacer.Account {
            var account = SessionPacer.Account(id: id, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1,
                                               percentPerMillion: ratio)
            account.weeklyRemaining = 99 * 8
            account.weeklyResetsAt = now.addingTimeInterval(140 * 3600)
            return account
        }
        // Personal's 5% of its week lasts 4 hours at 10% an hour.
        let max20x = pacerAccount(personal, left: 40, resetIn: 100, burn: 10, ratio: 0.25)
        let unsized = SessionPacer().plan(accounts: [max20x, pro(bytrix, ratio: 0.25), pro(hexorda, ratio: 0.25)],
                                          sessions: [opus], now: now)
        XCTAssertEqual(unsized.moves["platform-execution"].map { $0 == bytrix || $0 == hexorda }, true,
                       "counted at Max 20x's cost, a Pro window takes the session")
        // At Pro's own cost the session spends 200% of its 5-hour window an
        // hour: the window would be out within the runway, so no Pro account
        // takes it or a new session like it.
        let sized = SessionPacer().plan(accounts: [max20x, pro(bytrix, ratio: 5), pro(hexorda, ratio: 5)],
                                        sessions: [opus], now: now)
        XCTAssertNil(sized.moves["platform-execution"])
        XCTAssertEqual(sized.weights[bytrix] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(sized.weights[hexorda] ?? -1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(sized.weights[personal] ?? 0, 0)

        // Failover's view: a switch would not take the work to Pro either.
        let planner = FailoverPlanner(settings: .init(policy: policy(), provider: .claudeCode))
        let current = sizedState(used: 50, ratio: 0.25, active: true, burn: 1.25)
        var proState = QuotaAccountState(
            id: bytrix,
            usage: UsageAPIResponse(fiveHour: UsageWindow(utilization: 0, resetsAt: nil),
                                    sevenDay: UsageWindow(utilization: 1, resetsAt: iso(now.addingTimeInterval(140 * 3600))),
                                    sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                                    sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil),
            observedAt: now.addingTimeInterval(-60), sessionPerWeekly: 8)
        proState.percentPerMillion = 5
        XCTAssertEqual(planner.expectedBurn(movingFrom: current, to: proState).session, 200, accuracy: 0.001,
                       "10 session percent an hour on Max 20x is 200 on Pro")
        XCTAssertFalse(planner.carries(proState, from: current, at: now), "its 5-hour window lasts half an hour")
        proState.percentPerMillion = 0.25
        XCTAssertTrue(planner.carries(proState, from: current, at: now))
    }
}
