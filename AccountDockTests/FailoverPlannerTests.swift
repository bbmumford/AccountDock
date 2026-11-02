import XCTest
@testable import AccountDock

final class FailoverPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func policy(
        session: Double = 90,
        weekly: Double = 90,
        balancing: Bool = false,
        failover: Bool = true
    ) -> ProviderFailoverPolicy {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = failover
        policy.sessionThreshold = session
        policy.weeklyThreshold = weekly
        policy.intelligentBalancingEnabled = balancing
        policy.balancingMinimumDwellMinutes = 30
        policy.balancingMinimumAdvantageHours = 6
        policy.resetGraceMinutes = 5
        return policy
    }

    private func planner(_ policy: ProviderFailoverPolicy, canVerify: Bool = true) -> FailoverPlanner {
        FailoverPlanner(settings: .init(policy: policy, provider: .claudeCode, canVerify: canVerify))
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func account(
        _ id: UUID = UUID(),
        session: Double?,
        weekly: Double,
        sessionReset: TimeInterval? = 3 * 3600,
        weeklyReset: TimeInterval = 4 * 86_400,
        age: TimeInterval = 60,
        active: Bool = false,
        burn: Double = 0,
        consumedElsewhere: Bool = false,
        credentialsUsable: Bool = true,
        resetUnverified: Bool = false
    ) -> QuotaAccountState {
        QuotaAccountState(
            id: id,
            usage: UsageAPIResponse(
                fiveHour: session.map {
                    UsageWindow(utilization: $0, resetsAt: sessionReset.map { iso(now.addingTimeInterval($0)) })
                },
                sevenDay: UsageWindow(utilization: weekly, resetsAt: iso(now.addingTimeInterval(weeklyReset))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            ),
            observedAt: now.addingTimeInterval(-age),
            sessionBurnPerHour: burn,
            weeklyBurnPerHour: burn / 8,
            isActive: active,
            mayBeConsumedElsewhere: consumedElsewhere,
            credentialsUsable: credentialsUsable,
            resetUnverified: resetUnverified
        )
    }

    // MARK: - Waiting for a reset

    func testRoutingAndDistributionWithoutSessionSlotsNeedTheRouter() {
        var policy = ProviderFailoverPolicy()
        policy.enabled = true
        policy.intelligentBalancingEnabled = true
        policy.suspendAgentsWhenExhausted = true
        policy.extendCacheLifetime = true
        XCTAssertFalse(policy.usesRouter(for: .claudeCode))
        XCTAssertFalse(policy.usesRouter(for: .codex))

        var distributed = policy
        distributed.distributeSessions = true
        XCTAssertFalse(distributed.usesRouter(for: .claudeCode))
        XCTAssertTrue(distributed.usesRouter(for: .codex))
        XCTAssertTrue(distributed.usesRouter(for: .kimi))

        var routed = policy
        routed.routeTarget = "kimi"
        XCTAssertTrue(routed.usesRouter(for: .claudeCode))
    }

    func testAnAccountHeldShortOfItsLimitIsWaitedOnBeforeOneResettingDaysLater() {
        // The active account is held at 98% because the requests under way
        // need more than the last 2%; another account's weekly limit is spent
        // for two days. The active account's own session reset comes first.
        var settings = FailoverPlanner.Settings(policy: policy(), provider: .claudeCode, canVerify: true)
        settings.inFlightReservePercent = 4
        let p = FailoverPlanner(settings: settings)
        let current = account(session: 98, weekly: 52, sessionReset: 40 * 60, active: true)
        let spentWeek = account(session: 0, weekly: 100, weeklyReset: 2 * 86_400)
        let plan = p.plan(current: current, ladder: [current, spentWeek], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .waitForReset(current.id, now.addingTimeInterval(40 * 60)))
        XCTAssertNil(p.availableAt(current, now: now), "at 98% the session window is not at its limit on its own")
    }

    func testAnAccountRefusedShortOfItsLimitIsWaitedOnByItsFullerWindow() {
        var current = account(session: 97, weekly: 52, sessionReset: 50 * 60, active: true)
        current.refusedAtLimit = true
        let spentWeek = account(session: 0, weekly: 100, weeklyReset: 2 * 86_400)
        let plan = planner(policy()).plan(current: current, ladder: [current, spentWeek], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .waitForReset(current.id, now.addingTimeInterval(50 * 60)))
    }

    func testASliverIsNotADestinationWhenItsOwnSessionsBurnFast() {
        // The active account is spent and idle while its sessions wait; the
        // other has 4% left and burns 60% an hour when its sessions run.
        let current = account(session: 0, weekly: 100, weeklyReset: 2 * 86_400, active: true)
        var sliver = account(session: 96, weekly: 50, sessionReset: 40 * 60)
        sliver.sessionBurnPerHour = 60
        let p = planner(policy())
        XCTAssertGreaterThan(p.destinationMinimum(current: current, destination: sliver), 4)
        let plan = p.plan(current: current, ladder: [current, sliver], lastSwitch: nil, now: now)
        if case .switchTo(let id, _) = plan { XCTAssertNotEqual(id, sliver.id, "\(plan)") }
    }

    // MARK: - Destination safety on both windows

    func testNeverSwitchesToAnAccountThatIsMerelyBelowOneHundredPercent() {
        let current = account(session: 96, weekly: 40, active: true)
        let nearlyFull = account(session: 98, weekly: 30)
        let plan = planner(policy()).plan(current: current, ladder: [current, nearlyFull], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.drainingToLimit))
    }

    func testRejectsDestinationWhoseSessionIsSpentEvenWithWeeklyRoom() {
        let current = account(session: 95, weekly: 50, active: true)
        let sessionSpent = account(session: 100, weekly: 5)
        let healthy = account(session: 20, weekly: 60)
        let plan = planner(policy()).plan(current: current, ladder: [current, sessionSpent, healthy], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(healthy.id, .threshold))
    }

    func testRejectsDestinationWhoseWeeklyIsSpentEvenWithSessionRoom() {
        let current = account(session: 95, weekly: 50, active: true)
        let weeklySpent = account(session: 0, weekly: 100)
        let healthy = account(session: 40, weekly: 40)
        let plan = planner(policy()).plan(current: current, ladder: [current, weeklySpent, healthy], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(healthy.id, .threshold))
    }

    func testDestinationNeedsRoomForTheExpectedBurnDuringTheDwell() {
        // 30 minutes at 20%/h is 10 points: 82% is too close to a 90% trigger.
        let current = account(session: 92, weekly: 30, active: true, burn: 20)
        let tight = account(session: 82, weekly: 30)
        let roomy = account(session: 60, weekly: 30)
        let plan = planner(policy()).plan(current: current, ladder: [current, tight, roomy], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(roomy.id, .threshold))
    }

    func testFollowsLadderOrderAmongSafeDestinations() {
        let current = account(session: 91, weekly: 30, active: true)
        let first = account(session: 50, weekly: 70)
        let second = account(session: 0, weekly: 0)
        let plan = planner(policy()).plan(current: current, ladder: [current, first, second], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(first.id, .threshold))
    }

    func testLoopsBackToEarlierAccountsWhenLooping() {
        let earlier = account(session: 10, weekly: 10)
        let current = account(session: 95, weekly: 30, active: true)
        let later = account(session: 99, weekly: 99)
        let plan = planner(policy()).plan(current: current, ladder: [earlier, current, later], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(earlier.id, .threshold))
    }

    // MARK: - Freshness

    func testReadsADestinationThatMayHaveBeenConsumedSinceItWasLastSeen() {
        let current = account(session: 95, weekly: 30, active: true)
        let stale = account(session: 10, weekly: 20, age: 30 * 60, consumedElsewhere: true)
        let plan = planner(policy()).plan(current: current, ladder: [current, stale], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .verify([stale.id]))
    }

    func testSkipsAStaleDestinationWhenNoReadingCanBeAfforded() {
        let current = account(session: 95, weekly: 30, active: true)
        let stale = account(session: 10, weekly: 20, age: 30 * 60, consumedElsewhere: true)
        let fresh = account(session: 30, weekly: 30)
        let plan = planner(policy(), canVerify: false).plan(current: current, ladder: [current, stale, fresh], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(fresh.id, .threshold))
    }

    func testAnIdleDestinationIsReadAgainBeforeASwitchWhenAReadingIsAffordable() {
        let current = account(session: 95, weekly: 30, active: true)
        let idle = account(session: 10, weekly: 20, age: 2 * 3600)
        let plan = planner(policy()).plan(current: current, ladder: [current, idle], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .verify([idle.id]))
    }

    func testIdleAccountReadingIsTrustedForHoursWhileNoReadingCanBeAfforded() {
        let current = account(session: 95, weekly: 30, active: true)
        let idle = account(session: 10, weekly: 20, age: 2 * 3600)
        let plan = planner(policy(), canVerify: false).plan(current: current, ladder: [current, idle], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(idle.id, .threshold))
    }

    func testFastBurnTriggersBeforeTheNextCycleWouldSeeTheTrigger() {
        // 94% rising at 480%/h reaches 98% within the 30 s lookahead.
        let current = account(session: 94, weekly: 40, age: 0, active: true, burn: 480)
        XCTAssertTrue(planner(policy(session: 96, weekly: 99)).isTriggered(current, now: now))
        let slow = account(session: 94, weekly: 40, age: 0, active: true, burn: 60)
        XCTAssertFalse(planner(policy(session: 96, weekly: 99)).isTriggered(slow, now: now))
    }

    func testANearlySpentWeeklyIsNotADestinationUnderAFastBurn() {
        // The failure seen in practice: the active account at its 96% session
        // trigger, burning fast, and a destination with only 4% weekly left.
        let current = account(session: 96, weekly: 52, age: 0, active: true, burn: 140)
        let nearlySpent = account(session: 0, weekly: 96)
        let healthy = account(session: 6, weekly: 71)
        let plan = planner(policy(session: 96, weekly: 99)).plan(
            current: current, ladder: [current, nearlySpent, healthy], lastSwitch: nil, now: now
        )
        XCTAssertEqual(plan, .switchTo(healthy.id, .threshold))
    }

    func testProjectsTheActiveAccountForwardWhileItsReadingAges() {
        // 80% observed 10 minutes ago at 60%/h is 90% now: the trigger fired
        // even though no new reading arrived.
        let current = account(session: 80, weekly: 30, age: 600, active: true, burn: 60)
        let spare = account(session: 0, weekly: 0)
        let plan = planner(policy()).plan(current: current, ladder: [current, spare], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(spare.id, .threshold))
    }

    func testIneligibleAccountsAreNeverChosen() {
        let current = account(session: 95, weekly: 30, active: true)
        let quarantined = account(session: 0, weekly: 0, credentialsUsable: false)
        let unverified = account(session: 0, weekly: 0, resetUnverified: true)
        let plan = planner(policy()).plan(current: current, ladder: [current, quarantined, unverified], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.drainingToLimit))
    }

    // MARK: - Exhaustion

    func testAtTheLimitMovesToTheUsableAccountWithMostHeadroom() {
        let current = account(session: 100, weekly: 40, active: true)
        let some = account(session: 93, weekly: 40)
        let more = account(session: 91, weekly: 50)
        let plan = planner(policy()).plan(current: current, ladder: [current, some, more], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(more.id, .exhausted))
    }

    func testWhenEverythingIsExhaustedWaitsForTheLastLimitingResetOfEachAccount() {
        // A's session resets soon but its weekly limit is also spent and resets
        // in two days; B is session-limited only and returns in two hours.
        let a = account(session: 100, weekly: 100, sessionReset: 600, weeklyReset: 2 * 86_400, active: true)
        let b = account(session: 100, weekly: 70, sessionReset: 2 * 3600)
        let plan = planner(policy()).plan(current: a, ladder: [a, b], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .waitForReset(b.id, now.addingTimeInterval(2 * 3600)))
    }

    func testAnExhaustedAccountWithUnreadableCandidatesWaitsToVerifyThemInsteadOfSwitching() {
        let current = account(session: 100, weekly: 50, active: true)
        let stale = account(session: 10, weekly: 20, age: 3 * 3600, consumedElsewhere: true)
        let plan = planner(policy(), canVerify: false).plan(current: current, ladder: [current, stale], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .verify([stale.id]))
    }

    func testAnAccountWithAnUnconfirmedResetIsReadBeforeItIsWaitedOn() {
        let current = account(session: 100, weekly: 50, sessionReset: 2 * 3600, active: true)
        let unconfirmed = account(session: 100, weekly: 50, sessionReset: -60, resetUnverified: true)
        let plan = planner(policy()).plan(current: current, ladder: [current, unconfirmed], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .verify([unconfirmed.id]))
    }

    // MARK: - Accounts without a session window

    func testAnAccountWithoutASessionWindowIsLimitedOnlyByItsWeeklyAllowance() {
        let p = planner(policy())
        let open = account(session: nil, weekly: 29)
        XCTAssertEqual(p.tier(open, now: now), .belowTrigger)
        XCTAssertEqual(p.tier(account(session: nil, weekly: 100), now: now), .exhausted)
        XCTAssertEqual(p.availableAt(account(session: nil, weekly: 100), now: now), now.addingTimeInterval(4 * 86_400))
        let current = account(session: 100, weekly: 40, active: true)
        XCTAssertEqual(p.plan(current: current, ladder: [current, open], lastSwitch: nil, now: now), .switchTo(open.id, .exhausted))
    }

    func testAnActiveAccountWithoutASessionWindowStaysUntilItsWeeklyLimit() {
        let p = planner(policy())
        let current = account(session: nil, weekly: 50, active: true, burn: 80)
        let spare = account(session: 0, weekly: 0)
        XCTAssertFalse(p.isTriggered(current, now: now))
        if case .switchTo = p.plan(current: current, ladder: [current, spare], lastSwitch: nil, now: now) {
            XCTFail("a high session rate from before the window was removed is not a reason to move")
        }
        XCTAssertTrue(p.isTriggered(account(session: nil, weekly: 95, active: true), now: now))
    }

    func testASimulatedAccountWithoutASessionWindowIsNotCappedPerFiveHours() {
        var capped = QuotaSimulator.Account(id: UUID(), session: 0, weekly: 0, weeklyReset: now.addingTimeInterval(86_400), sessionPerWeekly: 8)
        var simulator = QuotaSimulator()
        simulator.horizon = 5 * 3600
        let limited = simulator.run(accounts: [capped], strategy: .earliestDeadline, demand: { _ in 6 }, start: now)
        XCTAssertGreaterThan(limited.unmet, 15)
        capped.hasSessionWindow = false
        let open = simulator.run(accounts: [capped], strategy: .earliestDeadline, demand: { _ in 6 }, start: now)
        XCTAssertEqual(open.unmet, 0, accuracy: 0.01)
        XCTAssertEqual(open.served, 30, accuracy: 0.01)
    }

    func testAReadingWithoutASessionWindowClearsTheStoredOne() {
        func reading(session: Double?, weekly: Double?) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: session.map { UsageWindow(utilization: $0, resetsAt: iso(now.addingTimeInterval(3600))) },
                sevenDay: weekly.map { UsageWindow(utilization: $0, resetsAt: iso(now.addingTimeInterval(400_000))) },
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
        }
        let stored = reading(session: 40, weekly: 20)
        let weeklyOnly = reading(session: nil, weekly: 21)
        XCTAssertTrue(weeklyOnly.reportsNoSessionWindow)
        XCTAssertNil(stored.merged(withNewer: weeklyOnly, clearingSession: true).fiveHour)
        // A passed session window is not an absent one, so the caller doesn't
        // clear for it, and a partial reading keeps what is stored.
        XCTAssertEqual(stored.merged(withNewer: weeklyOnly).fiveHour?.utilization, 40)
        XCTAssertFalse(reading(session: nil, weekly: nil).reportsNoSessionWindow)
        // A later reading with a window brings it back.
        let cleared = stored.merged(withNewer: weeklyOnly, clearingSession: true)
        XCTAssertEqual(cleared.merged(withNewer: reading(session: 5, weekly: 21)).fiveHour?.utilization, 5)
    }

    func testAWholePercentWeeklyStepIsNotReadAsAHighBurnWithoutASessionWindow() {
        var trend = QuotaTrend()
        func weekly(_ w: Double) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: nil,
                sevenDay: UsageWindow(utilization: w, resetsAt: iso(now.addingTimeInterval(400_000))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
        }
        trend.sessionBurnPerHour = 50
        trend.record(weekly(20), at: now)
        XCTAssertEqual(trend.sessionBurnPerHour, 0, "no window, no session rate")
        trend.record(weekly(21), at: now.addingTimeInterval(60))
        XCTAssertEqual(trend.weeklyBurnPerHour, 0, "one point in a minute is rounding, not 60% per hour")
        trend.record(weekly(22), at: now.addingTimeInterval(20 * 60))
        XCTAssertEqual(trend.weeklyBurnPerHour, 6, accuracy: 0.01)
        trend.record(weekly(22), at: now.addingTimeInterval(55 * 60))
        XCTAssertLessThan(trend.weeklyBurnPerHour, 6, "a long quiet stretch still lowers the rate")
    }

    func testASignedOutAccountIsIneligibleNotExhausted() {
        let p = planner(policy())
        let signedOut = account(session: 100, weekly: 100, sessionReset: 3600, credentialsUsable: false)
        XCTAssertEqual(p.tier(signedOut, now: now), .ineligible)
        XCTAssertNil(p.availableAt(signedOut, now: now))
        let current = account(session: 100, weekly: 40, sessionReset: 1800, active: true)
        let plan = p.plan(current: current, ladder: [current, signedOut], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .waitForReset(current.id, now.addingTimeInterval(1800)))
    }

    func testOnlyExhaustedAccountsHaveAnAvailabilityTime() {
        let p = planner(policy())
        XCTAssertNil(p.availableAt(account(session: 40, weekly: 40), now: now))
        XCTAssertNil(p.availableAt(account(session: 100, weekly: 40, credentialsUsable: false), now: now))
        XCTAssertEqual(
            p.availableAt(account(session: 100, weekly: 40, sessionReset: 3600), now: now),
            now.addingTimeInterval(3600)
        )
    }

    func testHoldsWhenTheBreachedWindowResetsBeforeItWouldRunOut() {
        let current = account(session: 92, weekly: 30, sessionReset: 120, active: true, burn: 30)
        let spare = account(session: 0, weekly: 0)
        let plan = planner(policy()).plan(current: current, ladder: [current, spare], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.holdingForImminentReset))
    }

    func testDoesNotHoldWhenTheAccountWouldRunOutBeforeTheReset() {
        // 8 points at 120%/h is four minutes, the reset is five away.
        let current = account(session: 92, weekly: 30, sessionReset: 300, active: true, burn: 120)
        let spare = account(session: 0, weekly: 0)
        let plan = planner(policy()).plan(current: current, ladder: [current, spare], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(spare.id, .threshold))
    }

    func testWithoutThresholdFailoverOnlyTheProviderLimitMovesWork() {
        var settings = FailoverPlanner.Settings(policy: policy(balancing: true, failover: false), provider: .claudeCode)
        settings.sessionTrigger = 100
        settings.weeklyTrigger = 100
        let planner = FailoverPlanner(settings: settings)
        let current = account(session: 97, weekly: 40, active: true)
        let spare = account(session: 0, weekly: 0, weeklyReset: 6 * 86_400)
        XCTAssertFalse(planner.isTriggered(current, now: now))
    }

    // MARK: - Balancing

    func testBalancingSpendsTheAllowanceThatResetsSoonest() {
        let current = account(session: 10, weekly: 20, weeklyReset: 6 * 86_400, active: true)
        let sooner = account(session: 10, weekly: 50, weeklyReset: 1 * 86_400)
        let plan = planner(policy(balancing: true)).plan(current: current, ladder: [current, sooner], lastSwitch: nil, now: now)
        guard case .switchTo(let id, .balance(let hours)) = plan else {
            return XCTFail("expected a balancing switch, got \(plan)")
        }
        XCTAssertEqual(id, sooner.id)
        XCTAssertGreaterThan(hours, 6)
    }

    func testBalancingNeverMovesToASessionNearItsLimit() {
        let current = account(session: 10, weekly: 20, weeklyReset: 6 * 86_400, active: true)
        let soonerButSessionFull = account(session: 99, weekly: 30, weeklyReset: 1 * 86_400)
        let plan = planner(policy(balancing: true)).plan(current: current, ladder: [current, soonerButSessionFull], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.healthy))
    }

    func testBalancingRespectsTheMinimumDwell() {
        let current = account(session: 10, weekly: 20, weeklyReset: 6 * 86_400, active: true)
        let sooner = account(session: 10, weekly: 50, weeklyReset: 1 * 86_400)
        let plan = planner(policy(balancing: true)).plan(
            current: current, ladder: [current, sooner],
            lastSwitch: now.addingTimeInterval(-10 * 60), now: now
        )
        XCTAssertEqual(plan, .stay(.dwell))
    }

    func testLatestStartAccountsForTheSessionCapOnDrainSpeed() {
        let planner = planner(policy())
        // 80 weekly points at 8 session points each, 100 per 5 hours, take
        // 32 hours to drain: use must start 32 hours before the reset.
        var state = account(session: 0, weekly: 20, weeklyReset: 3 * 86_400)
        state.sessionPerWeekly = 8
        let start = planner.latestStart(state, now: now)
        XCTAssertEqual(start.timeIntervalSince(now), 3 * 86_400 - 32 * 3600, accuracy: 1)
    }

    func testBalancingPrefersAnAllowanceTheSessionCapCanNoLongerDrainInTime() {
        // Both weekly limits reset in 48 hours. The other account's 90 remaining
        // points need 36 hours of capped use while the active account's 15 need
        // 6, so the larger allowance must start being used first.
        let current = account(session: 0, weekly: 85, weeklyReset: 2 * 86_400, active: true)
        let urgent = account(session: 0, weekly: 10, weeklyReset: 2 * 86_400)
        let plan = planner(policy(balancing: true)).plan(current: current, ladder: [current, urgent], lastSwitch: nil, now: now)
        guard case .switchTo(let id, .balance) = plan else { return XCTFail("got \(plan)") }
        XCTAssertEqual(id, urgent.id)
    }

    // MARK: - Trends, merging, budget, passive readings

    func testTrendLearnsBurnRateAndSessionToWeeklyRatio() {
        var trend = QuotaTrend()
        func usage(_ s: Double, _ w: Double) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: UsageWindow(utilization: s, resetsAt: iso(now.addingTimeInterval(9000))),
                sevenDay: UsageWindow(utilization: w, resetsAt: iso(now.addingTimeInterval(400_000))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
        }
        trend.record(usage(10, 20), at: now)
        trend.record(usage(11, 20), at: now.addingTimeInterval(20))
        trend.record(usage(26, 22), at: now.addingTimeInterval(1800))
        XCTAssertEqual(trend.sessionBurnPerHour, 32, accuracy: 0.01)
        XCTAssertEqual(trend.sessionPerWeekly ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(trend.currentRates(now: now.addingTimeInterval(1800 + 1800)).session, 16, accuracy: 0.01)
    }

    func testWindowMergeIsMonotonicWithinAWindowAndAdvancesToANewOne() {
        let reset = now.addingTimeInterval(3600)
        let stored = UsageWindow(utilization: 70, resetsAt: iso(reset))
        XCTAssertEqual(stored.merged(withNewer: UsageWindow(utilization: 65, resetsAt: iso(reset))).utilization, 70)
        XCTAssertEqual(stored.merged(withNewer: UsageWindow(utilization: 75, resetsAt: iso(reset))).utilization, 75)
        let next = UsageWindow(utilization: 3, resetsAt: iso(reset.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(stored.merged(withNewer: next).utilization, 3)
        // A stored window resetting later than a live newer one was another
        // account's; the newer reading corrects it.
        XCTAssertEqual(next.merged(withNewer: stored).utilization, 70)
        XCTAssertEqual(next.merged(withNewer: stored).resetsAtDate, stored.resetsAtDate)
    }

    @MainActor
    func testBudgetReservesAllowanceForFailoverCriticalReadings() {
        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        XCTAssertTrue(budget.spend(.background, now: now))
        XCTAssertFalse(budget.spend(.background, now: now))
        XCTAssertTrue(budget.spend(.candidate, now: now))
        XCTAssertFalse(budget.spend(.candidate, now: now))
        XCTAssertTrue(budget.spend(.critical, now: now))
        XCTAssertFalse(budget.spend(.critical, now: now))
        XCTAssertTrue(budget.spend(.critical, now: now.addingTimeInterval(31)))
    }

    @MainActor
    func testBudgetBacksOffExponentiallyAfterThrottling() {
        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        budget.recordThrottle(retryAfter: nil, now: now)
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(60))
        budget.recordThrottle(retryAfter: nil, now: now)
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(120))
        XCTAssertFalse(budget.canSpend(.critical, now: now.addingTimeInterval(100)))
        XCTAssertTrue(budget.canSpend(.critical, now: now.addingTimeInterval(160)))
    }

    func testReadsClaudeCodeUsageCache() throws {
        let json = """
        {"cachedUsageUtilization":{"fetchedAtMs":1800000000000,"accountUuid":"abc",
         "utilization":{"five_hour":{"utilization":42,"resets_at":"2027-01-15T08:00:00.123+00:00","limit_dollars":null},
                        "seven_day":{"utilization":70,"resets_at":"2027-01-20T00:00:00+00:00"},
                        "seven_day_omelette":null}}}
        """
        let observation = try XCTUnwrap(PassiveUsageTelemetry.claudeUsageCacheObservation(from: Data(json.utf8)))
        XCTAssertEqual(observation.claudeAccountUUID, "abc")
        XCTAssertEqual(observation.usage.fiveHour?.utilization, 42)
        XCTAssertEqual(observation.usage.sevenDay?.utilization, 70)
        XCTAssertEqual(observation.observedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testReadsStatusLineRateLimits() throws {
        let json = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":88,"resets_at":1800003600},"seven_day":{"used_percentage":51,"resets_at":1800300000}}}"#
        let observation = try XCTUnwrap(PassiveUsageTelemetry.statusLineObservation(from: Data(json.utf8), observedAt: now, processKey: nil))
        XCTAssertEqual(observation.processKey, "s1")
        XCTAssertEqual(observation.usage.fiveHour?.utilization, 88)
        XCTAssertEqual(observation.usage.sevenDay?.resetsAtDate, Date(timeIntervalSince1970: 1_800_300_000))
    }

    func testReadsCodexRolloutRateLimits() throws {
        let line = #"{"timestamp":"2027-01-15T08:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1800003600},"secondary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1800300000},"rate_limit_reached_type":null}}}"#
        let observation = try XCTUnwrap(PassiveUsageTelemetry.codexObservation(fromLine: Data(line.utf8), codexHome: "/h"))
        XCTAssertEqual(observation.usage.fiveHour?.utilization, 2)
        XCTAssertEqual(observation.usage.sevenDay?.utilization, 100)
        XCTAssertTrue(observation.limitReached)
        XCTAssertEqual(observation.codexHome, "/h")
    }

    func testDetectsClaudeTokensThatAreAboutToExpire() {
        let soon = #"{"claudeAiOauth":{"expiresAt":\#((now.timeIntervalSince1970 + 60) * 1000)}}"#
        let later = #"{"claudeAiOauth":{"expiresAt":\#((now.timeIntervalSince1970 + 3600) * 1000)}}"#
        XCTAssertTrue(ClaudeCredentialModule.expires(soon, within: 300, now: now))
        XCTAssertFalse(ClaudeCredentialModule.expires(later, within: 300, now: now))
    }

    // MARK: - Agent suspension

    func testAReadingOfAPausedAccountOnlyShowsCapacityAfterAWindowRestarts() {
        func usage(_ session: Double, resetIn: TimeInterval) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(now.addingTimeInterval(resetIn))),
                sevenDay: UsageWindow(utilization: 40, resetsAt: iso(now.addingTimeInterval(4 * 86_400))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
        }
        let atPause = usage(97, resetIn: 3600)
        XCTAssertFalse(AppState.windowReset(since: atPause, in: usage(97, resetIn: 3600)))
        XCTAssertFalse(AppState.windowReset(since: atPause, in: usage(95, resetIn: 3600)))
        XCTAssertTrue(AppState.windowReset(since: atPause, in: usage(0, resetIn: 5 * 3600)))
    }

    func testPausedAgentsKeepTheirLearnedBaselineWithoutLearningARate() {
        var trend = QuotaTrend()
        func usage(_ session: Double) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(now.addingTimeInterval(3600))),
                sevenDay: UsageWindow(utilization: 40, resetsAt: iso(now.addingTimeInterval(4 * 86_400))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
        }
        trend.record(usage(80), at: now)
        trend.record(usage(90), at: now.addingTimeInterval(600))
        let learned = trend.sessionBurnPerHour
        trend.rebase(usage(90), at: now.addingTimeInterval(1200))
        XCTAssertEqual(trend.sessionBurnPerHour, learned)
        XCTAssertEqual(trend.session?.at, now.addingTimeInterval(1200))
    }

    func testAccountDockNeverPausesItsOwnChildProcesses() {
        let parents: [Int32: Int32] = [500: 1, 600: 500, 700: 600, 800: 1]
        XCTAssertTrue(AgentSuspensionService.descends(700, from: 500, parents: parents))
        XCTAssertFalse(AgentSuspensionService.descends(800, from: 500, parents: parents))
        XCTAssertFalse(AgentSuspensionService.descends(900, from: 500, parents: [900: 900]))
    }

    func testDifferentRatiosOnTwoAccountsCreateAnAdvantageThatASharedRatioRemoves() {
        // The balancing move seen in practice: one account with a learned
        // ratio of 4.5 and another on the default of 8 looked 8 h apart.
        func state(weekly: Double, resetHours: Double, k: Double?) -> QuotaAccountState {
            var s = account(session: 30, weekly: weekly, weeklyReset: resetHours * 3600)
            s.sessionPerWeekly = k
            return s
        }
        let p = planner(policy(balancing: true))
        let mixed = p.latestStart(state(weekly: 80, resetHours: 150, k: 4.5), now: now)
            .timeIntervalSince(p.latestStart(state(weekly: 46, resetHours: 160, k: nil), now: now)) / 3600
        let shared = p.latestStart(state(weekly: 80, resetHours: 150, k: 4.5), now: now)
            .timeIntervalSince(p.latestStart(state(weekly: 46, resetHours: 160, k: 4.5), now: now)) / 3600
        XCTAssertGreaterThan(mixed, 6)
        XCTAssertLessThan(shared, 6)
    }

    // MARK: - Model-scoped weekly limits

    private let scopedResponse = """
    {"five_hour":{"utilization":7,"resets_at":"2099-10-17T14:00:00+00:00"},
     "seven_day":{"utilization":60,"resets_at":"2099-10-23T13:00:00+00:00"},
     "limits":[{"kind":"session","percent":7},{"kind":"weekly_all","percent":60},
               {"kind":"weekly_scoped","percent":90,"resets_at":"2099-10-22T13:00:00+00:00",
                "scope":{"model":{"id":null,"display_name":"Fable"},"surface":{"unexpected":true}}},
               {"kind":"future_kind","scope":"not an object"}],
     "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":45,"allowance_percent_of_weekly":50}]}
    """

    func testAModelScopedWeeklyLimitNarrowsTheRoomForWorkOnThatModel() throws {
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        XCTAssertEqual(usage.limits?.count, 4, "unknown limit shapes keep their positions")
        XCTAssertEqual(usage.modelWeeklyLimits.first?.model, "Fable")
        // Whole weekly leaves 40; Fable may use 50 of the weekly and has used 45, leaving 5.
        XCTAssertEqual(usage.weeklyWindow(forModel: "Fable 5.1")?.utilization ?? 0, 95, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyWindow(forModel: "Fable 5.1")?.resetsAt, "2099-10-22T13:00:00+00:00")
        XCTAssertEqual(usage.weeklyWindow(forModel: "Opus 5.5")?.utilization, 60)
        XCTAssertEqual(usage.weeklyWindow(forModel: nil)?.utilization, 60)
    }

    func testStatusLineReportsTheSessionModel() throws {
        let payload = #"{"session_id":"s","model":{"id":"claude-fable-5-1","display_name":"Fable 5.1"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":4102444800}}}"#
        let observation = try XCTUnwrap(PassiveUsageTelemetry.statusLineObservation(from: Data(payload.utf8), observedAt: now, processKey: nil))
        XCTAssertEqual(observation.model, "Fable 5.1")
    }

    // MARK: - Uncertainty, extra usage and simulated balancing

    func testAnUncertainBurnRateTriggersEarlierThanASteadyOne() {
        let p = planner(policy(session: 96, weekly: 99))
        var steady = account(session: 93, weekly: 40, age: 120, active: true, burn: 60)
        XCTAssertFalse(p.isTriggered(steady, now: now))
        steady.sessionBurnStdDev = 60
        XCTAssertTrue(p.isTriggered(steady, now: now))
    }

    func testExtraUsageServesOnlyOnceEveryAllowanceIsExhausted() {
        var settings = FailoverPlanner.Settings(policy: policy(), provider: .claudeCode)
        settings.allowExtraUsage = true
        let p = FailoverPlanner(settings: settings)
        var current = account(session: 100, weekly: 60, active: true)
        current.extraUsageAvailable = true
        let healthy = account(session: 10, weekly: 20)
        XCTAssertEqual(p.plan(current: current, ladder: [current, healthy], lastSwitch: nil, now: now), .switchTo(healthy.id, .exhausted))
        let spent = account(session: 100, weekly: 100)
        XCTAssertEqual(p.plan(current: current, ladder: [current, spent], lastSwitch: nil, now: now), .stay(.usingExtraUsage))
    }

    func testWorkMovesBeforeTheRequestsUnderWayCouldReachTheLimit() {
        var settings = FailoverPlanner.Settings(policy: policy(session: 90), provider: .claudeCode)
        let current = account(session: 96, weekly: 40, active: true)
        // Above its own trigger, so only a move at the limit may use it.
        let other = account(session: 92, weekly: 40)
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, other], lastSwitch: nil, now: now),
                       .stay(.drainingToLimit), "4% left and nothing under way: the account keeps serving")
        settings.inFlightReservePercent = 4
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, other], lastSwitch: nil, now: now),
                       .switchTo(other.id, .exhausted), "4% left but four requests under way: the work moves now")
    }

    func testAnAccountAtTheLimitMovesOnlyToRoomForMoreThanAFewMinutes() {
        let p = planner(policy(session: 90))
        let current = account(session: 100, weekly: 40, active: true, burn: 120)
        let sliver = account(session: 50, weekly: 99.5)
        let roomy = account(session: 80, weekly: 50)
        XCTAssertEqual(p.plan(current: current, ladder: [current, sliver], lastSwitch: nil, now: now).isSwitch, false,
                       "half a weekly percent at 120%/h of session use lasts about two minutes")
        XCTAssertEqual(p.plan(current: current, ladder: [current, sliver, roomy], lastSwitch: nil, now: now),
                       .switchTo(roomy.id, .exhausted))
        XCTAssertFalse(p.hasFallback(current: current, ladder: [current, sliver], now: now))
    }

    func testAnAccountTheProviderRefusedIsNeverADestination() {
        let p = planner(policy())
        let current = account(session: 100, weekly: 40, active: true)
        var refused = account(session: 10, weekly: 20)
        refused.refusedAtLimit = true
        XCTAssertEqual(p.tier(refused, now: now), .ineligible)
        XCTAssertNotEqual(p.plan(current: current, ladder: [current, refused], lastSwitch: nil, now: now), .switchTo(refused.id, .exhausted))
    }

    func testSwitchCostWidensTheDestinationMargin() {
        var settings = FailoverPlanner.Settings(policy: policy(session: 90), provider: .claudeCode)
        let destination = account(session: 80, weekly: 20)
        XCTAssertEqual(FailoverPlanner(settings: settings).tier(destination, now: now), .belowTrigger)
        settings.switchCostPercent = 12
        XCTAssertEqual(FailoverPlanner(settings: settings).tier(destination, now: now), .usable)
    }

    func testWithAForecastBalancingMovesOnlyWhenTheWeekServesMore() {
        var settings = FailoverPlanner.Settings(policy: policy(balancing: true), provider: .claudeCode)
        let current = account(session: 20, weekly: 20, weeklyReset: 6 * 86_400, active: true)
        let expiring = account(session: 0, weekly: 30, weeklyReset: 20 * 3600)
        settings.demand = { _ in 3 }
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, expiring], lastSwitch: nil, now: now),
                       .switchTo(expiring.id, .balance(advantageHours: FailoverPlanner(settings: settings).latestStart(current, now: now)
                        .timeIntervalSince(FailoverPlanner(settings: settings).latestStart(expiring, now: now)) / 3600)))
        settings.demand = { _ in 0 }
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, expiring], lastSwitch: nil, now: now),
                       .stay(.healthy), "with no work to serve, moving gains nothing")
    }
}


private extension FailoverPlan {
    var isSwitch: Bool {
        if case .switchTo = self { return true }
        return false
    }
}
