import XCTest
@testable import AccountDock

/// The readings that confirm a passed reset, the warm-up that starts the
/// next window, the request allowance both draw on, and the checks a
/// refusal and an old reading get before sessions are placed by them.
final class UsageVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Warmup = AppState.PendingWindowWarmup

    private func stamp(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    /// A reading with a session window (`session` nil: none) and a long one.
    private func usage(session: Double?, sessionReset: TimeInterval? = nil, weekly: Double,
                       weeklyReset: TimeInterval? = 3 * 86_400) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: session.map { UsageWindow(utilization: $0, resetsAt: sessionReset.map(stamp), windowSeconds: 18_000) },
            sevenDay: UsageWindow(utilization: weekly, resetsAt: weeklyReset.map(stamp)),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
    }

    private func account(_ name: String, active: Bool = false) -> Account {
        Account(email: "\(name)@mail.example", displayName: name, provider: .claudeCode, isActive: active)
    }

    // MARK: - The request allowance

    @MainActor
    func testAPassedResetIsReadWithinTheNextCycleWhileBackgroundReadsHoldTheBudget() {
        let inUse = account("inuse"), idle = account("idle"), reset = account("reset")
        let order = AppState.postResetVerificationOrder(
            [inUse, idle, reset], awaiting: [reset.id], warming: [reset.id],
            clearedAt: [reset.id: now.addingTimeInterval(-AppState.postResetSettle)], retryAfter: [:],
            updatedAt: [inUse.id: now, idle.id: now.addingTimeInterval(-7200), reset.id: now.addingTimeInterval(-3600)],
            now: now)
        XCTAssertEqual(order.map(\.id), [reset.id], "the account whose reset passed is read, whatever the others' ages")

        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        XCTAssertTrue(budget.spend(.background, now: now), "an account in use is read in the background")
        XCTAssertFalse(budget.canSpend(.background, now: now), "background reads stop there")
        XCTAssertTrue(budget.spend(.verification, now: now), "the verification read still goes through this cycle")

        // Background reads taking each refill as it comes still leave the
        // verification read its share by the next cycle.
        let tight = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        XCTAssertTrue(tight.spend(.background, now: now))
        let later = now.addingTimeInterval(18)
        XCTAssertTrue(tight.spend(.background, now: later))
        XCTAssertFalse(tight.canSpend(.verification, now: later))
        let nextCycle = later.addingTimeInterval(20)
        XCTAssertFalse(tight.canSpend(.background, now: nextCycle), "background reads cannot take the verification share")
        XCTAssertTrue(tight.spend(.verification, now: nextCycle))
        XCTAssertTrue(tight.canSpend(.critical, now: nextCycle), "the active account's critical read keeps its allowance")
    }

    func testAResetIsReadOnlyOnceItHasSettledAndOutOfACoolDown() {
        let settling = account("settling"), cooling = account("cooling"), failing = account("failing")
        let loaded = account("loaded")
        let order = AppState.postResetVerificationOrder(
            [settling, cooling, failing, loaded], awaiting: [settling.id, cooling.id, failing.id, loaded.id], warming: [],
            clearedAt: [settling.id: now.addingTimeInterval(-5), cooling.id: now.addingTimeInterval(-600)],
            failedAt: [failing.id: now.addingTimeInterval(-10)],
            retryAfter: [cooling.id: now.addingTimeInterval(60)], updatedAt: [:], now: now)
        XCTAssertEqual(order.map(\.id), [loaded.id],
                       "one cleared seconds ago waits for the provider, one in a cool-down for its end, one just read in vain for its spacing")
        XCTAssertEqual(AppState.postResetReadAllowed(clearedAt: nil, failedAt: nil, retryAfter: now.addingTimeInterval(60)),
                       now.addingTimeInterval(60), "the cool-down's end, when the quota cycle runs again")
    }

    @MainActor
    func testASavedSignInsOwnershipCheckIsPaidWithTheReadingThatNeedsIt() {
        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        XCTAssertTrue(budget.spend(.background, now: now))
        XCTAssertFalse(budget.canSpend(.background, now: now), "a second background admission never fits beside the first")
        XCTAssertTrue(budget.spendFollowUp(of: .background, now: now), "the reading's ownership check does")
        XCTAssertFalse(budget.spendFollowUp(of: .background, now: now), "but only one, above half a request")
        XCTAssertTrue(budget.canSpend(.critical, now: now))

        let verification = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        XCTAssertTrue(verification.spend(.verification, now: now))
        XCTAssertTrue(verification.spend(.verification, now: now))
        XCTAssertTrue(verification.spendFollowUp(of: .verification, now: now))

        let throttled = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        throttled.recordThrottle(retryAfter: now.addingTimeInterval(60), now: now)
        XCTAssertFalse(throttled.spendFollowUp(of: .critical, now: now.addingTimeInterval(30)), "nothing goes out in a cool-down")
    }

    // MARK: - Warm-ups

    func testAVerifiedUnstartedWindowTriggersExactlyOneProbe() {
        let unstarted = usage(session: 0, weekly: 40)
        let both = Warmup(session: true, weekly: true)
        let step = AppState.warmupStep(requested: both, stored: unstarted, verifiedAt: now, unusedSinceReset: false,
                                       sessionQuota: true, lastProbeAt: nil, now: now)
        XCTAssertEqual(step, .probe(Warmup(session: true, weekly: false)), "the probe runs on the reading just taken")

        let lagging = AppState.warmupStep(requested: both, stored: unstarted, verifiedAt: now.addingTimeInterval(60),
                                          unusedSinceReset: false, sessionQuota: true, lastProbeAt: now,
                                          now: now.addingTimeInterval(61))
        XCTAssertEqual(lagging, .none, "a provider still reporting it unstarted after the probe starts no second one")

        let pinned = unstarted.pinningWarmupCountdowns(session: true, weekly: false, startedAt: now)
        XCTAssertTrue(AppState.windowsToWarm(pinned, requested: both, sessionQuota: true).isEmpty,
                      "the countdown pinned from the probe shows the window started")

        let stale = AppState.warmupStep(requested: both, stored: unstarted,
                                        verifiedAt: now.addingTimeInterval(-AppState.warmupEvidenceLifetime - 1),
                                        unusedSinceReset: false, sessionQuota: true, lastProbeAt: nil, now: now)
        XCTAssertEqual(stale, .readFirst, "an older reading is read again before a probe")

        let nextReset = Warmup(session: true, weekly: false, resetAt: now.addingTimeInterval(600))
        XCTAssertEqual(AppState.warmupStep(requested: nextReset, stored: unstarted, verifiedAt: now.addingTimeInterval(690),
                                           unusedSinceReset: false, sessionQuota: true, lastProbeAt: now,
                                           now: now.addingTimeInterval(700)),
                       .probe(Warmup(session: true, weekly: false)), "a reset after the probe arms the next one")
    }

    func testAPassedResetStartsTheWindowWithoutAReadingWhenNothingHasUsedTheAccount() {
        let cleared = usage(session: 3, sessionReset: -10, weekly: 40).expiringPassedResets(at: now)
        let passed = AppState.passedResetWindows(usage(session: 3, sessionReset: -10, weekly: 40), sessionQuota: true, now: now)
        XCTAssertEqual(passed, Warmup(session: true, weekly: false, resetAt: now.addingTimeInterval(-10)))

        let early = AppState.warmupStep(requested: passed, stored: cleared, verifiedAt: nil, unusedSinceReset: true,
                                        sessionQuota: true, lastProbeAt: nil, now: now)
        XCTAssertEqual(early, .readFirst, "within the margin the provider may not have opened the window")
        let settled = now.addingTimeInterval(AppState.warmupResetMargin)
        XCTAssertEqual(AppState.warmupStep(requested: passed, stored: cleared, verifiedAt: nil, unusedSinceReset: true,
                                           sessionQuota: true, lastProbeAt: nil, now: settled),
                       .probe(Warmup(session: true, weekly: false)))
        XCTAssertEqual(AppState.warmupStep(requested: passed, stored: cleared, verifiedAt: nil, unusedSinceReset: false,
                                           sessionQuota: true, lastProbeAt: nil, now: settled),
                       .readFirst, "an account something may have used is read first")
    }

    func testAnAccountWithNoSessionWindowIsNeverWarmedForOne() {
        let maxPlan = usage(session: nil, weekly: 45)
        let both = Warmup(session: true, weekly: true)
        XCTAssertEqual(AppState.warmupStep(requested: both, stored: maxPlan, verifiedAt: now, unusedSinceReset: true,
                                           sessionQuota: true, lastProbeAt: nil, now: now), .none,
                       "its long window is running and it has no session window")
        let weeklyPassed = usage(session: nil, weekly: 45, weeklyReset: -120)
        let armed = AppState.passedResetWindows(weeklyPassed, sessionQuota: true, now: now)
        XCTAssertFalse(armed.session)
        XCTAssertFalse(AppState.windowsToWarm(weeklyPassed.expiringPassedResets(at: now), requested: both,
                                              sessionQuota: true).session)
    }

    func testAStartedWindowIsNotProbed() {
        let both = Warmup(session: true, weekly: true, resetAt: now.addingTimeInterval(-600))
        for started in [usage(session: 3, weekly: 40), usage(session: 0, sessionReset: 3600, weekly: 40)] {
            XCTAssertEqual(AppState.warmupStep(requested: both, stored: started, verifiedAt: now, unusedSinceReset: true,
                                               sessionQuota: true, lastProbeAt: nil, now: now), .none)
        }
        XCTAssertTrue(AppState.windowsToWarm(usage(session: 0, weekly: 100), requested: both, sessionQuota: true).isEmpty,
                      "a session window is not started while the long window is spent")
    }

    @MainActor
    func testAThrottleDefersTheProbeUntilTheCoolDownEndsThenItRuns() {
        let budget = UsageRequestBudget(capacity: 3, refillInterval: 30, now: now)
        budget.recordThrottle(retryAfter: now.addingTimeInterval(90), now: now)
        let until = budget.nextAvailable(.verification, now: now)
        XCTAssertEqual(until, now.addingTimeInterval(90))
        let delay = AppState.warmupRetryDelay(.heldUntil(until), failures: 0, now: now)
        XCTAssertEqual(delay, 91)
        XCTAssertFalse(budget.canSpend(.verification, now: now.addingTimeInterval(89)))
        XCTAssertTrue(budget.spend(.verification, now: now.addingTimeInterval(delay ?? 0)), "the warm-up's reading goes out then")

        let named = now.addingTimeInterval(45)
        XCTAssertEqual(AppState.warmupDeferral(for: ClaudeService.UsageError.rateLimited(named), now: now), .heldUntil(named))
        XCTAssertEqual(AppState.warmupDeferral(for: ClaudeService.UsageError.network("timed out"), now: now), .failed)
        XCTAssertEqual(AppState.warmupRetryDelay(.failed, failures: 1, now: now), AppState.warmupFailureDelays[0])
        XCTAssertNil(AppState.warmupRetryDelay(.failed, failures: AppState.warmupFailureDelays.count + 1, now: now),
                     "failures past the ladder wait for the next reset")
    }

    // MARK: - Readings cleared at a reset

    func testAReadingClearedAtAResetCountsAsUnknownUntilVerified() {
        let cleared = usage(session: 100, sessionReset: -60, weekly: 40).expiringPassedResets(at: now)
        XCTAssertEqual(cleared.fiveHour?.utilization, 0)
        XCTAssertTrue(AppState.snapshotAwaitsVerification(cleared, resetUnverified: true))
        XCTAssertTrue(AppState.snapshotAwaitsVerification(cleared, resetUnverified: nil),
                      "a snapshot saved without the mark cannot be told from one cleared at a reset")
        XCTAssertFalse(AppState.snapshotAwaitsVerification(usage(session: 40, sessionReset: 3600, weekly: 40), resetUnverified: nil))

        let planner = FailoverPlanner(settings: .init(policy: ProviderFailoverPolicy.defaults(for: .claudeCode), provider: .claudeCode))
        let unverified = QuotaAccountState(id: UUID(), usage: cleared, observedAt: now, resetUnverified: true)
        XCTAssertEqual(planner.tier(unverified, now: now), .ineligible, "no session is placed on the cleared 0%")
    }

    // MARK: - Old readings and refusals

    func testAnAccountInUseIsReadBeforeItTakesASessionOnAnOldReading() {
        let read = now.addingTimeInterval(-20 * 60)
        XCTAssertFalse(FailoverPlanner.poolReadingIsCurrent(inUse: true, observedAt: read, lastRequest: read.addingTimeInterval(60),
                                                            now: now), "its sessions have used it since")
        XCTAssertTrue(FailoverPlanner.poolReadingIsCurrent(inUse: true, observedAt: now.addingTimeInterval(-5 * 60),
                                                           lastRequest: now, now: now))
        XCTAssertTrue(FailoverPlanner.poolReadingIsCurrent(inUse: false, observedAt: now.addingTimeInterval(-5 * 3600),
                                                           lastRequest: now, now: now), "an idle account changes only at its resets")
    }

    func testAWeeklyRefusalsDatedResetIsRead() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne"))
        let refused = try XCTUnwrap(CredentialAudit.date("2026-11-14T18:16:00Z"))
        let reset = AppState.refusalResetDate("You've hit your weekly limit · resets Nov 20 at 12pm", at: refused, calendar: calendar)
        XCTAssertEqual(reset, CredentialAudit.date("2026-11-20T01:00:00Z"))
        XCTAssertEqual(AppState.refusalResetDate("resets 3:20am", at: refused, calendar: calendar),
                       CredentialAudit.date("2026-11-14T16:20:00Z").map { $0.addingTimeInterval(86_400) })
    }

    func testARefusalOnAnOldReadingIsReadBeforeAnythingMovesThenFollowsTheResetItStates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne"))
        let personal = UUID(), hstles = UUID()
        let refused = try XCTUnwrap(CredentialAudit.date("2026-11-14T18:16:00Z"))
        let hstlesReset = try XCTUnwrap(CredentialAudit.date("2026-11-20T01:00:00Z"))
        let personalReset = try XCTUnwrap(CredentialAudit.date("2026-11-18T03:00:00Z"))
        let words = "You've hit your weekly limit · resets Nov 20 at 12pm"
        // HSTLES's stored reading carries Personal's reset, from before the refusal.
        let stale = [(id: personal, resets: [personalReset]), (id: hstles, resets: [personalReset])]
        let first = AppState.refusalVerification(words: words, at: refused, attributed: personal, windows: stale,
                                                 wholeAt: [personal: refused.addingTimeInterval(-3600),
                                                           hstles: refused.addingTimeInterval(-7200)],
                                                 inUse: [personal, hstles], calendar: calendar)
        XCTAssertEqual(first.account, personal)
        XCTAssertEqual(first.read, [personal], "the account it was attributed to is read at once")
        XCTAssertTrue(first.doubtful, "its stated reset is no window of that account")
        XCTAssertFalse(AppState.refusalCounts(verified: !first.doubtful, at: refused, now: refused.addingTimeInterval(60)),
                       "nothing moves for it while that reading is held back")
        XCTAssertTrue(AppState.refusalCounts(verified: false, at: refused,
                                             now: refused.addingTimeInterval(AppState.refusalVerificationWait)))

        let second = AppState.refusalVerification(words: words, at: refused, attributed: personal, windows: stale,
                                                  wholeAt: [personal: refused.addingTimeInterval(5),
                                                            hstles: refused.addingTimeInterval(-7200)],
                                                  inUse: [personal, hstles], calendar: calendar)
        XCTAssertEqual(second.read, [hstles], "read, Personal does not reset then: the account in use whose reading is old is read")

        let read = [(id: personal, resets: [personalReset]), (id: hstles, resets: [hstlesReset])]
        let third = AppState.refusalVerification(words: words, at: refused, attributed: personal, windows: read,
                                                 wholeAt: [personal: refused.addingTimeInterval(5), hstles: refused.addingTimeInterval(8)],
                                                 inUse: [personal, hstles], calendar: calendar)
        XCTAssertEqual(third.account, hstles, "once read, the stated reset is HSTLES's window")
        XCTAssertTrue(third.read.isEmpty)
        XCTAssertFalse(third.doubtful)

        let confirmed = AppState.refusalVerification(words: words, at: refused, attributed: hstles, windows: read,
                                                     wholeAt: [hstles: refused.addingTimeInterval(-120)],
                                                     inUse: [personal, hstles], calendar: calendar)
        XCTAssertEqual(confirmed.read, [hstles], "an account read before the refusal is read again")
        XCTAssertFalse(confirmed.doubtful, "but its windows show the stated reset, so the refusal counts meanwhile")
    }
}
