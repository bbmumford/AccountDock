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

    // MARK: - Measured and forecast exhaustion

    func testAForecastAtTheLimitMakesNoExhaustedSwitchAndNoWait() {
        let p = planner(policy())
        // Read at 97% ten minutes ago; the burn carries the forecast past 100%.
        let current = account(session: 97, weekly: 40, age: 600, active: true, burn: 20)
        XCTAssertFalse(p.isMeasuredAtLimit(current, now: now))
        XCTAssertTrue(p.isForecastAtLimit(current, now: now))
        XCTAssertEqual(p.tier(current, now: now), .usable)
        XCTAssertEqual(p.servingVerdict(current, now: now, lead: 0), .nearLimit, "no new sessions start there")
        XCTAssertNil(p.availableAt(current, now: now))

        let roomy = account(session: 50, weekly: 95)
        XCTAssertEqual(p.plan(current: current, ladder: [current, roomy], lastSwitch: nil, now: now), .stay(.drainingToLimit),
                       "a forecast does not move the whole workload to an account above its thresholds")
        let spent = account(session: 100, weekly: 40, sessionReset: 1800)
        XCTAssertEqual(p.plan(current: current, ladder: [current, spent], lastSwitch: nil, now: now), .stay(.drainingToLimit),
                       "a forecast does not wait for another account's reset")
    }

    func testAForecastCrossingAThresholdStillMovesToAnAccountBelowItsThresholds() {
        let current = account(session: 97, weekly: 40, age: 600, active: true, burn: 20)
        let fresh = account(session: 5, weekly: 5)
        XCTAssertEqual(planner(policy()).plan(current: current, ladder: [current, fresh], lastSwitch: nil, now: now),
                       .switchTo(fresh.id, .threshold))
    }

    func testAReadingAtTheLimitOrARefusalStillMovesWorkAndWaits() {
        let p = planner(policy())
        let roomy = account(session: 50, weekly: 95)
        let atLimit = account(session: 99.5, weekly: 40, active: true)
        XCTAssertEqual(p.plan(current: atLimit, ladder: [atLimit, roomy], lastSwitch: nil, now: now), .switchTo(roomy.id, .exhausted))

        var refused = account(session: 50, weekly: 40, active: true)
        refused.refusedAtLimit = true
        XCTAssertTrue(p.isMeasuredAtLimit(refused, now: now))
        XCTAssertEqual(p.plan(current: refused, ladder: [refused, roomy], lastSwitch: nil, now: now), .switchTo(roomy.id, .exhausted))

        let spent = account(session: 100, weekly: 40, sessionReset: 1800)
        guard case .waitForReset = p.plan(current: atLimit, ladder: [atLimit, spent], lastSwitch: nil, now: now) else {
            return XCTFail("a measured limit with every account spent waits for a reset")
        }
    }

    func testAFreshStatusLineReadingWithRoomStandsOverTheForecast() {
        let p = planner(policy())
        // A burst-learned burn grows a reading 90 seconds old from 40% to 100%.
        var current = account(session: 40, weekly: 40, age: 90, active: true, burn: 2400)
        XCTAssertTrue(p.isForecastAtLimit(current, now: now))
        XCTAssertTrue(p.isTriggered(current, now: now))
        XCTAssertEqual(p.servingVerdict(current, now: now, lead: 150), .nearLimit)

        current.liveReadingAt = current.observedAt
        XCTAssertTrue(p.liveReadingShowsRoom(current, now: now))
        XCTAssertFalse(p.isForecastAtLimit(current, now: now))
        XCTAssertFalse(p.isTriggered(current, now: now))
        XCTAssertEqual(p.servingVerdict(current, now: now, lead: 150), .canServe)
        let other = account(session: 5, weekly: 5)
        XCTAssertEqual(p.plan(current: current, ladder: [current, other], lastSwitch: nil, now: now), .stay(.healthy))

        // Too old, over a trigger, or refused since: the forecast stands.
        XCTAssertFalse(p.liveReadingShowsRoom(current, now: now.addingTimeInterval(FailoverPlanner.liveReadingLifetime)))
        var over = account(session: 92, weekly: 40, age: 10, active: true, burn: 50)
        over.liveReadingAt = over.observedAt
        XCTAssertFalse(p.liveReadingShowsRoom(over, now: now))
        XCTAssertTrue(p.isTriggered(over, now: now))
        var refused = current
        refused.refusedAtLimit = true
        XCTAssertFalse(p.liveReadingShowsRoom(refused, now: now))
        var older = current
        older.liveReadingAt = current.observedAt?.addingTimeInterval(-30)
        XCTAssertFalse(p.liveReadingShowsRoom(older, now: now), "only while it is the newest reading")
    }

    func testAStatusLineNeverOverridesAModelLimitFromTheLastWholeReading() {
        let p = planner(policy())
        // `plannedUsage` narrows the long window to the session model's own
        // allowance from the last whole reading: spent here.
        var spentModel = account(session: 40, weekly: 100, age: 10, active: true, burn: 10)
        spentModel.liveReadingAt = spentModel.observedAt
        XCTAssertFalse(p.liveReadingShowsRoom(spentModel, now: now))
        XCTAssertEqual(p.servingVerdict(spentModel, now: now, lead: 0), .atLimit)
    }

    func testTwoStatusesAlternatingEachCycleRecordNoStreamOfEvents() {
        var gate = AppState.StatusEventGate()
        let exhausted = "All accounts exhausted. Waiting for A to reset at 9:00."
        let draining = "Using A up to its limit; no other account is below its failover threshold."
        var events: [String] = []
        var t = now
        func note(_ status: String) {
            if let event = gate.note(status, now: t, settle: AppState.statusSettle) { events.append(event) }
            t = t.addingTimeInterval(20)
        }
        // The first status is recorded once it has stood for a cycle.
        for _ in 0..<8 { note(draining) }
        XCTAssertEqual(events, [draining])
        for _ in 0..<30 { note(exhausted); note(draining) }
        XCTAssertEqual(events, [draining], "alternating each cycle records nothing")
        for _ in 0..<8 { note(exhausted) }
        XCTAssertEqual(events, [draining, exhausted], "a status that lasts is recorded once")

        gate.recorded("Switched to B.")
        XCTAssertNil(gate.note("Switched to B.", now: t, settle: AppState.statusSettle))
    }

    func testEveryAccountAtItsLimitWaitsForReadingsFromThisLaunch() {
        let launched = now.addingTimeInterval(-60)
        let stale = (readAt: Optional(now.addingTimeInterval(-3 * 3600)), fresh: false)
        let current = (readAt: Optional(now.addingTimeInterval(-10)), fresh: true)
        let storedFresh = (readAt: Optional(launched.addingTimeInterval(-120)), fresh: true)
        let unread = (readAt: Date?.none, fresh: false)
        XCTAssertTrue(AppState.awaitsFirstReadings([current, stale], launchedAt: launched, now: now))
        XCTAssertTrue(AppState.awaitsFirstReadings([current, unread], launchedAt: launched, now: now))
        XCTAssertFalse(AppState.awaitsFirstReadings([current, storedFresh], launchedAt: launched, now: now))
        let readThisLaunch = (readAt: Optional(launched.addingTimeInterval(5)), fresh: false)
        XCTAssertFalse(AppState.awaitsFirstReadings([readThisLaunch], launchedAt: launched, now: now))
        XCTAssertFalse(AppState.awaitsFirstReadings([stale], launchedAt: now.addingTimeInterval(-FailoverPlanner.liveFreshness),
                                                    now: now), "not for longer than a reading's freshness after launch")
    }

    func testARecordedRefusalStandsUntilAReadingAnswersIt() {
        let refused = now.addingTimeInterval(-60)
        let before = now.addingTimeInterval(-600)
        XCTAssertTrue(AppState.refusalStands(at: refused, scopedKey: nil, askedKey: nil, readAt: before, wholeAt: before, now: now))
        XCTAssertFalse(AppState.refusalStands(at: refused, scopedKey: nil, askedKey: nil, readAt: now, wholeAt: before, now: now),
                       "a newer reading answers it")
        XCTAssertFalse(AppState.refusalStands(at: now.addingTimeInterval(-AppState.refusalStanding - 1), scopedKey: nil,
                                              askedKey: nil, readAt: before.addingTimeInterval(-3600), wholeAt: before, now: now))
        // A refusal of a session on a model with its own allowance is about
        // that allowance: it counts for that model only, until a whole reading.
        XCTAssertTrue(AppState.refusalStands(at: refused, scopedKey: "fable", askedKey: "fable", readAt: now, wholeAt: before, now: now))
        XCTAssertFalse(AppState.refusalStands(at: refused, scopedKey: "fable", askedKey: nil, readAt: before, wholeAt: before, now: now))
        XCTAssertFalse(AppState.refusalStands(at: refused, scopedKey: "fable", askedKey: "fable", readAt: now, wholeAt: now, now: now))
    }

    func testAReadingWithinTheInFlightReserveCountsAsMeasuredAtTheLimit() {
        var settings = FailoverPlanner.Settings(policy: policy(), provider: .claudeCode)
        settings.inFlightReservePercent = 5
        let p = FailoverPlanner(settings: settings)
        let current = account(session: 96, weekly: 40, active: true)
        let roomy = account(session: 50, weekly: 95)
        XCTAssertTrue(p.isMeasuredAtLimit(current, now: now, reserve: 5))
        XCTAssertEqual(p.plan(current: current, ladder: [current, roomy], lastSwitch: nil, now: now), .switchTo(roomy.id, .exhausted))
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

    private func sessionReading(_ s: Double, resetIn: TimeInterval?) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: UsageWindow(utilization: s, resetsAt: resetIn.map { iso(now.addingTimeInterval($0)) }),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(now.addingTimeInterval(4 * 86_400))),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
    }

    func testAResumeBurstAfterAWindowResetDoesNotSetTheBurnRate() {
        var trend = QuotaTrend()
        // The old window, read at a steady 12% per hour.
        trend.record(sessionReading(80, resetIn: 600), at: now)
        trend.record(sessionReading(81, resetIn: 600), at: now.addingTimeInterval(300))
        // It resets; paused sessions resume and re-send their contexts.
        let newReset: TimeInterval = 600 + 5 * 3600
        trend.record(sessionReading(2, resetIn: newReset), at: now.addingTimeInterval(700))
        trend.record(sessionReading(20, resetIn: newReset), at: now.addingTimeInterval(760))
        trend.record(sessionReading(33, resetIn: newReset), at: now.addingTimeInterval(820))
        // Then the steady rate again.
        for step in 1...4 {
            trend.record(sessionReading(33 + Double(step), resetIn: newReset), at: now.addingTimeInterval(820 + Double(step) * 300))
        }
        XCTAssertEqual(trend.sessionBurnPerHour, 12, accuracy: 0.01)
        XCTAssertEqual(trend.currentUncertainty(now: now.addingTimeInterval(2020)).session, 0, accuracy: 0.01)
    }

    func testABurstWhenAnUnstartedWindowStartsIsNotLearned() {
        var trend = QuotaTrend()
        trend.record(sessionReading(0, resetIn: nil), at: now)
        trend.record(sessionReading(33, resetIn: 5 * 3600), at: now.addingTimeInterval(120))
        trend.record(sessionReading(34, resetIn: 5 * 3600), at: now.addingTimeInterval(240))
        trend.record(sessionReading(35, resetIn: 5 * 3600), at: now.addingTimeInterval(540))
        trend.record(sessionReading(36, resetIn: 5 * 3600), at: now.addingTimeInterval(840))
        XCTAssertEqual(trend.sessionBurnPerHour, 12, accuracy: 0.01)
    }

    func testReadingsJustAfterPausedSessionsResumeTeachNoRate() {
        var trend = QuotaTrend()
        trend.record(sessionReading(10, resetIn: 3 * 3600), at: now)
        trend.settle(at: now)
        trend.record(sessionReading(25, resetIn: 3 * 3600), at: now.addingTimeInterval(60))
        trend.record(sessionReading(33, resetIn: 3 * 3600), at: now.addingTimeInterval(120))
        trend.record(sessionReading(34, resetIn: 3 * 3600), at: now.addingTimeInterval(420))
        trend.record(sessionReading(35, resetIn: 3 * 3600), at: now.addingTimeInterval(720))
        XCTAssertEqual(trend.sessionBurnPerHour, 12, accuracy: 0.01)
    }

    func testOneBurstInASteadySeriesCannotSetTheForecast() {
        var trend = QuotaTrend()
        var t: TimeInterval = 0
        var used = 10.0
        func read(_ rise: Double, after: TimeInterval) {
            t += after
            used += rise
            trend.record(sessionReading(used, resetIn: 4 * 3600), at: now.addingTimeInterval(t))
        }
        read(0, after: 0)
        read(1, after: 300)
        read(1, after: 300)
        read(1, after: 300)
        read(20, after: 60)
        read(1, after: 300)
        XCTAssertEqual(trend.sessionBurnPerHour, 12, accuracy: 0.01)
        XCTAssertLessThan(trend.currentUncertainty(now: now.addingTimeInterval(t)).session, 1)
    }

    func testWholePercentReadingsGiveTheAverageRateNotAlternatingZeros() {
        var trend = QuotaTrend()
        // 12% per hour read in whole percent every 40 seconds.
        for step in 0...60 {
            let at = Double(step) * 40
            trend.record(sessionReading((10 + at / 300).rounded(.down), resetIn: 4 * 3600), at: now.addingTimeInterval(at))
        }
        XCTAssertEqual(trend.sessionBurnPerHour, 12, accuracy: 1)
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
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(30))
        budget.recordThrottle(retryAfter: nil, now: now)
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(60))
        XCTAssertFalse(budget.canSpend(.critical, now: now.addingTimeInterval(50)))
        XCTAssertTrue(budget.canSpend(.critical, now: now.addingTimeInterval(160)))
        for _ in 0..<10 { budget.recordThrottle(retryAfter: nil, now: now) }
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(UsageRequestBudget.longestCooldown))
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

    func testAStatusLineStillOnTheWindowBeforeAnEarlyResetIsIgnored() {
        let now = Date()
        func reading(_ used: Double, resetIn hours: Double) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: nil,
                sevenDay: UsageWindow(utilization: used, resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(hours * 3600)), windowSeconds: nil),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
                iguanaNecktie: nil, extraUsage: nil
            )
        }
        let afterReset = reading(13, resetIn: 150)
        XCTAssertTrue(AppState.describesSupersededWindow(reading(99, resetIn: 96), stored: afterReset),
                      "the window that ended at the early reset")
        XCTAssertFalse(AppState.describesSupersededWindow(reading(14, resetIn: 150), stored: afterReset))
        XCTAssertFalse(AppState.describesSupersededWindow(reading(2, resetIn: 168), stored: reading(99, resetIn: 0.1)),
                       "a later window replaces the stored one")
        XCTAssertFalse(AppState.describesSupersededWindow(reading(50, resetIn: 96), stored: nil))
    }

    func testASwitchForAModelsOwnLimitSaysSo() throws {
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        XCTAssertEqual(AppState.limitingModel(usage: usage, models: ["claude-fable-5"], wholeAtLimit: false, narrowedAtLimit: true),
                       "Fable")
        XCTAssertNil(AppState.limitingModel(usage: usage, models: ["claude-fable-5"], wholeAtLimit: true, narrowedAtLimit: true),
                     "the whole allowance spent is the limit")
        XCTAssertNil(AppState.limitingModel(usage: usage, models: ["claude-other-1"], wholeAtLimit: false, narrowedAtLimit: true))
        XCTAssertNil(AppState.limitingModel(usage: usage, models: ["claude-fable-5"], wholeAtLimit: false, narrowedAtLimit: false))
        XCTAssertEqual(AppState.exhaustedSwitchEvent(source: "Personal", target: "ORBTR", modelLimit: "Fable"),
                       "Personal has no Fable allowance left for the sessions on the shared sign-in; switching to ORBTR.")
        XCTAssertEqual(AppState.exhaustedSwitchEvent(source: "Personal", target: "ORBTR", modelLimit: nil),
                       "Personal is at its limit; switching to ORBTR.")
    }

    func testASlotSessionOfUnknownModelIsJudgedByTheWholeAllowance() throws {
        // Fable has 5% of the weekly left here: the shared sessions on Fable
        // see the narrowed window at 95%; a slot of unknown model sees 60%.
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        XCTAssertEqual(usage.weeklyWindow(forModels: ["claude-fable-5"])?.utilization ?? 0, 95, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyWindow(forModel: nil)?.utilization ?? 0, 60, accuracy: 0.001)
        // Its model is learned from its status line by its slot directory.
        let payload = Data(#"{"session_id":"abc","model":{"id":"claude-fable-5","display_name":"Fable"},"rate_limits":{"five_hour":{"used_percentage":7}}}"#.utf8)
        var observation = try XCTUnwrap(PassiveUsageTelemetry.statusLineObservation(from: payload, observedAt: now, processKey: nil))
        observation.slotDirectory = "/slots/session/x"
        let carried = observation.with(usage: observation.usage)
        XCTAssertEqual(carried.slotDirectory, "/slots/session/x")
        XCTAssertEqual(carried.processKey, "abc")
        XCTAssertEqual(carried.model, "Fable")
    }

    func testOnlyWorkOnAModelWithItsOwnLimitIsJudgedByThatLimit() throws {
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        let whole = try XCTUnwrap(usage.sevenDay?.utilization)
        let limited = try XCTUnwrap(usage.modelWeeklyLimits.first?.model)
        let scoped = try XCTUnwrap(usage.weeklyWindow(forModel: limited)?.utilization)
        XCTAssertEqual(usage.weeklyWindow(forModels: [])?.utilization, whole, "sessions on no limited model see the whole allowance")
        XCTAssertEqual(usage.weeklyWindow(forModels: ["claude-other-1"])?.utilization, whole)
        XCTAssertEqual(usage.weeklyWindow(forModels: ["claude-other-1", limited])?.utilization, max(whole, scoped),
                       "sessions that move together are held to the tightest of their models")
    }

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

    // MARK: - Saved settings

    func testSettingsSavedWithoutASwitchMethodSwitchSafely() throws {
        let policy = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: Data("{}".utf8))
        XCTAssertEqual(policy.switchMethod, .safeRestart)
    }

    // MARK: - Reading cadence

    func testTheActiveAccountIsReadSoonerAsItNearsATrigger() {
        let p = planner(policy())
        XCTAssertEqual(p.readingInterval(account(session: 20, weekly: 20, active: true, burn: 10), now: now), 300,
                       "seven hours from the trigger: the longest interval")
        // 87% read a minute ago at 60%/h is 88% now, two minutes from 90%.
        XCTAssertEqual(p.readingInterval(account(session: 87, weekly: 20, active: true, burn: 60), now: now), 60, accuracy: 1)
        // Past the trigger the limit sets the pace: 96% now, four minutes from 100%.
        XCTAssertEqual(p.readingInterval(account(session: 95, weekly: 20, active: true, burn: 60), now: now), 120, accuracy: 1)
        XCTAssertEqual(p.readingInterval(account(session: 40, weekly: 20, active: true), now: now), 300,
                       "nothing measurably consumed: the longest interval")
    }

    func testAnExhaustedAccountIsReadJustAfterItsResetWithSparseReadsBefore() {
        let p = planner(policy())
        XCTAssertEqual(p.nextUsefulReading(account(session: 100, weekly: 50, sessionReset: 3 * 3600, active: true), now: now),
                       now.addingTimeInterval(15 * 60))
        XCTAssertEqual(p.nextUsefulReading(account(session: 100, weekly: 50, sessionReset: 120, active: true), now: now),
                       now.addingTimeInterval(125))
        XCTAssertNil(p.nextUsefulReading(account(session: 40, weekly: 40, active: true), now: now))
    }

    @MainActor
    func testAThrottledBudgetWaitsForTheProvidersRetryAfterUpToTheLongestCooldown() {
        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        budget.recordThrottle(retryAfter: now.addingTimeInterval(3 * 60), now: now)
        XCTAssertEqual(budget.blockedUntil, now.addingTimeInterval(3 * 60))
        XCTAssertFalse(budget.canSpend(.critical, now: now.addingTimeInterval(2 * 60)))
        let hour = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        hour.recordThrottle(retryAfter: now.addingTimeInterval(60 * 60), now: now)
        XCTAssertEqual(hour.blockedUntil, now.addingTimeInterval(UsageRequestBudget.longestCooldown))
        XCTAssertTrue(hour.canSpend(.critical, now: now.addingTimeInterval(6 * 60)))
    }

    func testAReadingOfAnAccountInUseStandsUntilSomethingUsesTheAccount() {
        let read = now.addingTimeInterval(-20 * 60)
        XCTAssertEqual(FailoverPlanner.poolReadingLifetime(inUse: true, observedAt: read, lastRequest: read.addingTimeInterval(-60)),
                       FailoverPlanner.idleFallbackFreshness, "its sessions have been idle since the reading")
        XCTAssertEqual(FailoverPlanner.poolReadingLifetime(inUse: true, observedAt: read, lastRequest: read.addingTimeInterval(60)),
                       FailoverPlanner.liveFreshness)
        XCTAssertEqual(FailoverPlanner.poolReadingLifetime(inUse: true, observedAt: read, lastRequest: nil),
                       FailoverPlanner.idleFallbackFreshness)
        XCTAssertEqual(FailoverPlanner.poolReadingLifetime(inUse: false, observedAt: read, lastRequest: now),
                       FailoverPlanner.idleFallbackFreshness)
    }

    func testTheActiveAccountsSuccessorIsAnotherUsableAccountOfItsProvider() {
        let leaving = Account(email: "a@mail.example", displayName: "A", provider: .claudeCode, isActive: true)
        let signedOut = Account(email: "b@mail.example", displayName: "B", provider: .claudeCode)
        let ready = Account(email: "c@mail.example", displayName: "C", provider: .claudeCode)
        let other = Account(email: "d@mail.example", displayName: "D", provider: .codex)
        let all = [leaving, other, signedOut, ready]
        XCTAssertEqual(AppState.successor(of: leaving, among: all) { $0.id == signedOut.id }?.id, ready.id)
        XCTAssertNil(AppState.successor(of: leaving, among: [leaving, other, signedOut]) { $0.id == signedOut.id },
                     "an account of another provider, or one needing sign-in, does not take over")
    }

    func testAnIdleAccountAtAModelLimitCountsAsAtALimit() throws {
        let scoped = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        let atLimit = scoped.modelWeeklyLimits.contains { $0.percent >= AppState.atLimitPercent }
            || (scoped.sevenDay?.utilization ?? 0) >= AppState.atLimitPercent
        XCTAssertEqual(AppState.readingIsAtALimit(scoped), atLimit)
        let spent = UsageAPIResponse(
            fiveHour: nil, sevenDay: UsageWindow(utilization: 96, resetsAt: nil), sevenDayOauthApps: nil, sevenDayOpus: nil,
            sevenDaySonnet: nil, sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
        XCTAssertTrue(AppState.readingIsAtALimit(spent))
        let roomy = UsageAPIResponse(
            fiveHour: nil, sevenDay: UsageWindow(utilization: 40, resetsAt: nil), sevenDayOauthApps: nil, sevenDayOpus: nil,
            sevenDaySonnet: nil, sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
        XCTAssertFalse(AppState.readingIsAtALimit(roomy))
        XCTAssertFalse(AppState.readingIsAtALimit(nil))
    }

    func testAModelsOwnLimitIsReadAgainOnceTheLongWindowHasMoved() throws {
        let scoped = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(scopedResponse.utf8))
        XCTAssertFalse(scoped.modelWeeklyLimits.isEmpty)
        let long = try XCTUnwrap(scoped.sevenDay?.utilization)
        func whole(_ secondsAgo: TimeInterval, _ utilization: Double?) -> AppState.WholeReading {
            AppState.WholeReading(at: now.addingTimeInterval(-secondsAgo), longUtilization: utilization)
        }
        XCTAssertTrue(AppState.wholeReadingIsDue(scoped, whole: nil, now: now), "the model's limit was never read whole")
        XCTAssertFalse(AppState.wholeReadingIsDue(scoped, whole: whole(600, long), now: now),
                       "nothing was used since, however long ago")
        XCTAssertTrue(AppState.wholeReadingIsDue(scoped, whole: whole(120, long - 1), now: now),
                      "a point of the window was used since the model's limit was read")
        XCTAssertTrue(AppState.wholeReadingIsDue(scoped, whole: whole(120, long + 30), now: now), "the window reset since")
        XCTAssertFalse(AppState.wholeReadingIsDue(scoped, whole: whole(20, long - 5), now: now),
                       "readings are spaced")
        XCTAssertFalse(AppState.wholeReadingIsDue(scoped, whole: whole(120, long - 0.4), now: now))

        // A reading with no limit of a model's own is kept current by
        // passive readings alone.
        let plain = UsageAPIResponse(
            fiveHour: nil, sevenDay: scoped.sevenDay, sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
        XCTAssertTrue(plain.modelWeeklyLimits.isEmpty)
        XCTAssertFalse(AppState.wholeReadingIsDue(plain, whole: nil, now: now))
        XCTAssertFalse(AppState.wholeReadingIsDue(nil, whole: nil, now: now))
    }

    func testThreeSwitchesAwayInTheWindowAreALoop() {
        let at = { (minutes: Double) in self.now.addingTimeInterval(-minutes * 60) }
        XCTAssertFalse(FailoverPlanner.isSwitchLoop([at(1), at(3)], now: now))
        XCTAssertTrue(FailoverPlanner.isSwitchLoop([at(1), at(3), at(5)], now: now))
        XCTAssertFalse(FailoverPlanner.isSwitchLoop([at(1), at(3), at(40)], now: now), "old switches do not count")
    }

    func testALockedActiveAccountIsKeptInThePolicy() throws {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        XCTAssertFalse(policy.activeAccountLocked)
        policy.activeAccountLocked = true
        let decoded = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertTrue(decoded.activeAccountLocked)
    }

    // MARK: - Triggers, limits and headroom

    func testAnAccountLimitedOnBothWindowsReturnsAtTheLaterReset() {
        let spent = account(session: 100, weekly: 100, sessionReset: 600, weeklyReset: 3600)
        XCTAssertEqual(planner(policy()).availableAt(spent, now: now), now.addingTimeInterval(3600))
    }

    func testCrossingATriggerLeavesTheAccountUsableUntilItsLimit() {
        var settings = policy(session: 80, weekly: 90)
        var p = planner(settings)
        XCTAssertTrue(p.isTriggered(account(session: 81, weekly: 20, active: true), now: now))
        XCTAssertTrue(p.isTriggered(account(session: 20, weekly: 91, active: true), now: now))
        XCTAssertEqual(p.tier(account(session: 20, weekly: 91), now: now), .usable)
        XCTAssertEqual(p.tier(account(session: 20, weekly: 30), now: now), .belowTrigger)
        XCTAssertEqual(p.tier(account(session: 100, weekly: 30), now: now), .exhausted)
        settings.sessionEnabled = false
        p = planner(settings)
        XCTAssertTrue(p.isTriggered(account(session: 100, weekly: 30, active: true), now: now),
                      "the limit moves work even when the session trigger is off")
        XCTAssertEqual(p.tier(account(session: 100, weekly: 30), now: now), .exhausted,
                       "a spent session is never a destination, even when its trigger is off")
    }

    func testACodexSessionWindowCountsOnlyWhenThePlanReportsOne() {
        var codex = ProviderFailoverPolicy.defaults(for: .codex)
        codex.weeklyThreshold = 85
        let p = FailoverPlanner(settings: .init(policy: codex, provider: .codex))
        XCTAssertTrue(p.isTriggered(account(session: 100, weekly: 20, active: true), now: now))
        XCTAssertEqual(p.tier(account(session: nil, weekly: 20), now: now), .belowTrigger)
    }

    func testHeadroomIsSetByTheWeakerWindow() {
        let p = planner(policy())
        var weeklyBound = account(session: 10, weekly: 70)
        weeklyBound.sessionPerWeekly = 1
        XCTAssertEqual(p.headroom(weeklyBound, p.projection(weeklyBound, now: now)!), 30)
        var sessionBound = account(session: 80, weekly: 10)
        sessionBound.sessionPerWeekly = 1
        XCTAssertEqual(p.headroom(sessionBound, p.projection(sessionBound, now: now)!), 20)
    }

    // MARK: - Choosing a destination

    func testDoesNotWrapToEarlierAccountsWithoutLooping() {
        var settings = policy()
        settings.loops = false
        let earlier = account(session: 10, weekly: 10)
        let current = account(session: 95, weekly: 30, active: true)
        let later = account(session: 99, weekly: 99)
        let plan = planner(settings).plan(current: current, ladder: [earlier, current, later], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.drainingToLimit))
    }

    func testAnUnreadAccountIsPassedOverForOneWithAKnownReading() {
        let current = account(session: 95, weekly: 30, active: true)
        let unread = QuotaAccountState(id: UUID())
        let spent = account(session: 100, weekly: 20)
        let known = account(session: 0, weekly: 42)
        let plan = planner(policy()).plan(current: current, ladder: [current, unread, spent, known], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(known.id, .threshold))
    }

    func testAnAccountWithAnUnconfirmedResetIsPassedOverForTheNextConfirmedOne() {
        let current = account(session: 95, weekly: 30, active: true)
        let unconfirmed = account(session: 0, weekly: 20, resetUnverified: true)
        let confirmed = account(session: 30, weekly: 40)
        let plan = planner(policy()).plan(current: current, ladder: [current, unconfirmed, confirmed], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .switchTo(confirmed.id, .threshold))
    }

    func testHoldsOnlyWhenEveryBreachedWindowResetsWithinTheGrace() {
        let p = planner(policy(session: 80, weekly: 80))
        let spare = account(session: 0, weekly: 0)
        let bothSoon = account(session: 85, weekly: 85, sessionReset: 60, weeklyReset: 240, active: true)
        XCTAssertEqual(p.plan(current: bothSoon, ladder: [bothSoon, spare], lastSwitch: nil, now: now),
                       .stay(.holdingForImminentReset))
        let weeklyLater = account(session: 85, weekly: 85, sessionReset: 60, weeklyReset: 360, active: true)
        XCTAssertEqual(p.plan(current: weeklyLater, ladder: [weeklyLater, spare], lastSwitch: nil, now: now),
                       .switchTo(spare.id, .threshold))
    }

    // MARK: - Balancing destinations

    func testBalancingSpendsTheLessUsedAllowanceWhenBothResetTogether() {
        let busy = account(session: 10, weekly: 60, weeklyReset: 6 * 86_400, active: true)
        let quiet = account(session: 10, weekly: 20, weeklyReset: 6 * 86_400)
        let plan = planner(policy(balancing: true)).plan(current: busy, ladder: [busy, quiet], lastSwitch: nil, now: now)
        guard case .switchTo(let id, .balance) = plan else { return XCTFail("got \(plan)") }
        XCTAssertEqual(id, quiet.id)

        var quietActive = quiet
        quietActive.isActive = true
        var busyIdle = busy
        busyIdle.isActive = false
        XCTAssertEqual(planner(policy(balancing: true)).plan(current: quietActive, ladder: [quietActive, busyIdle], lastSwitch: nil, now: now),
                       .stay(.healthy))
    }

    func testBalancingNeverMovesToAnAccountWithAnUnconfirmedReset() {
        let current = account(session: 10, weekly: 60, weeklyReset: 6 * 86_400, active: true)
        let unconfirmed = account(session: 0, weekly: 0, weeklyReset: 86_400, resetUnverified: true)
        let plan = planner(policy(balancing: true)).plan(current: current, ladder: [current, unconfirmed], lastSwitch: nil, now: now)
        XCTAssertEqual(plan, .stay(.healthy))
    }

    // MARK: - Serving verdict

    func testServingVerdictTable() {
        let lead: TimeInterval = 10 * 60
        var refused = account(session: 10, weekly: 10)
        refused.refusedAtLimit = true
        let cases: [(String, QuotaAccountState, ServingVerdict)] = [
            ("healthy", account(session: 10, weekly: 10), .canServe),
            ("at the limit", account(session: 100, weekly: 40), .atLimit),
            ("refused at the limit", refused, .atLimit),
            ("quarantined", account(session: 10, weekly: 10, credentialsUsable: false), .ineligible),
            ("reset unverified", account(session: 10, weekly: 10, resetUnverified: true), .ineligible),
            ("reaching the limit within the lead", account(session: 50, weekly: 20, active: true, burn: 600), .nearLimit),
        ]
        let planner = planner(policy())
        for (name, state, expected) in cases {
            XCTAssertEqual(planner.servingVerdict(state, now: now, lead: lead), expected, name)
        }
        XCTAssertEqual(planner.servingVerdict(account(session: 50, weekly: 20, active: true, burn: 600), now: now, lead: 0),
                       .canServe, "no lead asks only whether it can serve")
    }

    func testServingViewIgnoresTheCredentialResetAndRefusal() {
        let planner = planner(policy())
        var refused = account(session: 10, weekly: 10, credentialsUsable: false, resetUnverified: true)
        refused.refusedAtLimit = true
        let view = planner.servingView(refused)
        XCTAssertTrue(view.credentialsUsable)
        XCTAssertFalse(view.resetUnverified)
        XCTAssertFalse(view.refusedAtLimit)
        XCTAssertEqual(planner.servingVerdict(view, now: now, lead: 0), .canServe)
        XCTAssertEqual(planner.servingVerdict(planner.servingView(account(session: 100, weekly: 40, credentialsUsable: false)),
                                              now: now, lead: 0), .atLimit)
    }
}


private extension FailoverPlan {
    var isSwitch: Bool {
        if case .switchTo = self { return true }
        return false
    }
}
