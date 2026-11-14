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
        let plan = pacer.plan(accounts: accounts, sessions: [slot("p1", on: personal), slot("b1", on: backup)], now: now,
                              sharedGroup: shared)
        XCTAssertGreaterThan(plan.weights[personal] ?? 0, 0, "the account the group moves to keeps the room it does not need")
        XCTAssertEqual(plan.weights[hstlesBrandon] ?? -1, 0, accuracy: 0.0001,
                       "the group alone spends the active account by the switch")
        XCTAssertEqual(plan.weights[backup] ?? -1, 0, accuracy: 0.0001)

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
}
