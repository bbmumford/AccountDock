import XCTest
@testable import AccountDock

/// An account whose 5-hour window resets while a session sits idle in its
/// slot: Claude Code redraws that session's status line at the reset,
/// without a request, and leaves the passed window out. The account must
/// still be warmed unless a reading after the reset shows the window
/// started by real requests.
final class PostResetWarmupTests: XCTestCase {
    /// The provider's reset time of the account's 5-hour window.
    private let reset = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "idle-session"
    private typealias Warmup = AppState.PendingWindowWarmup

    private func stamp(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: reset.addingTimeInterval(offset))
    }

    /// The account's reading before the reset: its session window nearly
    /// used up, resetting at `reset`.
    private var beforeReset: UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: UsageWindow(utilization: 87, resetsAt: stamp(0), windowSeconds: 18_000),
            sevenDay: UsageWindow(utilization: 12, resetsAt: stamp(18.5 * 3600), windowSeconds: 604_800),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
    }

    /// A status-line payload as the AccountDock status-line command saves
    /// it, with `limits` as its `rate_limits`.
    private func statusLine(_ limits: [String: Any], at offset: TimeInterval) throws -> PassiveUsageObservation {
        let payload: [String: Any] = ["session_id": session, "rate_limits": limits]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(PassiveUsageTelemetry.statusLineObservation(
            from: data, observedAt: reset.addingTimeInterval(offset), processKey: nil))
    }

    private func limit(_ percent: Double, resetsIn offset: TimeInterval) -> [String: Any] {
        ["used_percentage": percent, "resets_at": reset.addingTimeInterval(offset).timeIntervalSince1970]
    }

    /// What `ingestPassiveTelemetry` does with `observation` at `ingestedAt`
    /// for an account cleared at the reset: the reading it stores and
    /// whether that confirms the reset.
    private func ingest(_ observation: PassiveUsageObservation, stored: UsageAPIResponse, ingestedAt: TimeInterval,
                        reset: Date?, requestedAt: Date?) -> (stored: UsageAPIResponse, applied: AppState.PassiveApplication) {
        let noSessionWindow = observation.usage.reportsNoSessionWindow
        let dropped = observation.with(usage: observation.usage.droppingPassedWindows(at: self.reset.addingTimeInterval(ingestedAt)))
        let applied = AppState.passiveApplication(dropped, reportedNoSessionWindow: noSessionWindow, reset: reset,
                                                  hasSessionWindow: true, sessionRequestedAt: requestedAt)
        return (stored.merged(withNewer: applied.usage, clearingSession: applied.clearsSession), applied)
    }

    func testAnIdleSessionsRedrawnStatusLineLeavesTheResetWindowToBeWarmed() throws {
        // Just after the reset: it is applied and the session window left to warm.
        let cleared = beforeReset.expiringPassedResets(at: reset.addingTimeInterval(0.99))
        let pending = AppState.passedResetWindows(beforeReset, sessionQuota: true, now: reset.addingTimeInterval(0.99))
        XCTAssertEqual(pending, Warmup(session: true, weekly: false, resetAt: reset))
        XCTAssertEqual(cleared.fiveHour?.isUnusedUnstartedWindow, true)

        // A second after the reset Claude Code redraws the status line of a
        // session whose last request came 26 minutes before it, without the
        // window that passed.
        let redrawn = try statusLine(["seven_day": limit(12, resetsIn: 18.5 * 3600)], at: 1)
        XCTAssertTrue(redrawn.usage.reportsNoSessionWindow)
        let lastRequest = reset.addingTimeInterval(-26 * 60)
        let (stored, applied) = ingest(redrawn, stored: cleared, ingestedAt: 17, reset: reset, requestedAt: lastRequest)
        XCTAssertFalse(applied.confirmsReset, "a status line from before any request after the reset confirms nothing")
        XCTAssertFalse(applied.clearsSession, "its missing session window is no sign the account has none")
        XCTAssertFalse(applied.isLive, "it stands as no live reading")
        XCTAssertEqual(stored.fiveHour?.isUnusedUnstartedWindow, true, "the reset window stays to be warmed")
        XCTAssertEqual(stored.sevenDay?.utilization, 12, "the long window it carries is still recorded")

        // The account still awaits verification, so `verifyPassedResets`
        // takes it once the provider has opened the new window.
        XCTAssertFalse(AppState.unverifiedReadingStartsWarmup(verified: false, awaitingVerification: true))
        let account = Account(email: "slot@mail.example", displayName: "S", subscriptionType: "max")
        let settled = reset.addingTimeInterval(AppState.postResetSettle + 1)
        XCTAssertEqual(AppState.postResetVerificationOrder(
            [account], awaiting: [account.id], warming: [account.id], clearedAt: [account.id: reset.addingTimeInterval(0.99)],
            retryAfter: [:], updatedAt: [account.id: reset.addingTimeInterval(1)], now: settled).map(\.id), [account.id])
        XCTAssertEqual(AppState.warmupStep(requested: pending, stored: stored, verifiedAt: nil, unusedSinceReset: false,
                                           sessionQuota: true, lastProbeAt: nil, now: settled), .readFirst,
                       "the account a session sits on is read first")

        // The warm-up's reading: the provider leaves an unstarted window
        // out, and the account's window just reset, whatever its stored
        // plan says (`readingHasSessionWindow`).
        let whole = UsageAPIResponse(
            fiveHour: nil, sevenDay: UsageWindow(utilization: 12, resetsAt: stamp(18.5 * 3600), windowSeconds: 604_800),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
        XCTAssertNil(account.planHasSessionWindow, "a Max plan without its tier does not say")
        XCTAssertTrue(AppState.readingHasSessionWindow(planHasSessionWindow: account.planHasSessionWindow, sessionWindowReset: true))
        let read = whole.fillingUnstartedSessionWindow(hasSessionWindow: true, length: Allowance.sessionWindow)
        XCTAssertEqual(AppState.warmupStep(requested: pending, stored: read, verifiedAt: settled, unusedSinceReset: false,
                                           sessionQuota: true, lastProbeAt: nil, now: settled),
                       .probe(Warmup(session: true, weekly: false)), "the probe starts the window within the minute")
    }

    func testTheSameReadingAppliedAsItReadsWouldHaveEndedTheWarmup() throws {
        let cleared = beforeReset.expiringPassedResets(at: reset.addingTimeInterval(0.99))
        let pending = AppState.passedResetWindows(beforeReset, sessionQuota: true, now: reset.addingTimeInterval(0.99))
        let redrawn = try statusLine(["seven_day": limit(12, resetsIn: 18.5 * 3600)], at: 1)
        let (stored, applied) = ingest(redrawn, stored: cleared, ingestedAt: 17, reset: nil, requestedAt: nil)
        XCTAssertTrue(applied.confirmsReset)
        XCTAssertNil(stored.fiveHour, "taken as an account without a session window")
        XCTAssertEqual(AppState.warmupStep(requested: pending, stored: stored, verifiedAt: nil, unusedSinceReset: false,
                                           sessionQuota: true, lastProbeAt: nil, now: reset.addingTimeInterval(31)), .none)
    }

    func testAWindowStartedByTheSessionsRequestsAfterTheResetIsNotWarmed() throws {
        let cleared = beforeReset.expiringPassedResets(at: reset.addingTimeInterval(0.99))
        let pending = AppState.passedResetWindows(beforeReset, sessionQuota: true, now: reset.addingTimeInterval(0.99))
        let replied = try statusLine(["five_hour": limit(4, resetsIn: 5 * 3600),
                                      "seven_day": limit(12, resetsIn: 18.5 * 3600)], at: 8 * 60 + 36)
        for requestedAt in [reset.addingTimeInterval(8 * 60 + 25), nil] {
            let (stored, applied) = ingest(replied, stored: cleared, ingestedAt: 9 * 60, reset: reset, requestedAt: requestedAt)
            XCTAssertTrue(applied.confirmsReset, "a window with use and a reset ahead came with a reply after the reset")
            XCTAssertTrue(applied.isLive)
            XCTAssertEqual(stored.fiveHour?.utilization, 4)
            XCTAssertEqual(AppState.warmupStep(requested: pending, stored: stored, verifiedAt: nil, unusedSinceReset: false,
                                               sessionQuota: true, lastProbeAt: nil, now: reset.addingTimeInterval(9 * 60)),
                           .none)
        }
    }

    func testAMovingPlaceholderIsNotAStartedWindow() throws {
        let cleared = beforeReset.expiringPassedResets(at: reset.addingTimeInterval(0.99))
        let pending = AppState.passedResetWindows(beforeReset, sessionQuota: true, now: reset.addingTimeInterval(0.99))
        // No use, and a reset a whole window after the reading itself.
        let placeholder = try statusLine(["five_hour": limit(0, resetsIn: 5 * 3600 + 20),
                                          "seven_day": limit(12, resetsIn: 18.5 * 3600)], at: 20)
        let (stored, applied) = ingest(placeholder, stored: cleared, ingestedAt: 25, reset: reset,
                                       requestedAt: reset.addingTimeInterval(-26 * 60))
        XCTAssertFalse(applied.confirmsReset)
        XCTAssertFalse(applied.isLive)
        XCTAssertEqual(stored.fiveHour?.isUnusedUnstartedWindow, true, "the placeholder's countdown is not kept")
        XCTAssertEqual(AppState.warmupStep(requested: pending, stored: stored, verifiedAt: nil, unusedSinceReset: false,
                                           sessionQuota: true, lastProbeAt: nil, now: reset.addingTimeInterval(31)),
                       .readFirst)
        // The same window after the session's own request is a started one.
        let (afterRequest, requested) = ingest(placeholder, stored: cleared, ingestedAt: 25, reset: reset,
                                               requestedAt: reset.addingTimeInterval(19))
        XCTAssertTrue(requested.confirmsReset)
        XCTAssertNotNil(afterRequest.fiveHour?.resetsAtDate)
    }

    func testAPlanWithoutASessionWindowIsSeenSoOnceTheSessionSentARequest() throws {
        let weeklyOnly = UsageAPIResponse(
            fiveHour: UsageWindow(utilization: 0, resetsAt: nil, windowSeconds: 18_000),
            sevenDay: UsageWindow(utilization: 40, resetsAt: stamp(3 * 86_400), windowSeconds: 604_800),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
        let replied = try statusLine(["seven_day": limit(41, resetsIn: 3 * 86_400)], at: 120)
        let (stored, applied) = ingest(replied, stored: weeklyOnly, ingestedAt: 130, reset: reset,
                                       requestedAt: reset.addingTimeInterval(110))
        XCTAssertTrue(applied.clearsSession, "a reply after the reset without the window shows the plan has none")
        XCTAssertTrue(applied.confirmsReset)
        XCTAssertNil(stored.fiveHour)
    }

    func testTheUsageCacheKeepsAnUnstartedWindowOnAnAccountWithOne() throws {
        let cleared = beforeReset.expiringPassedResets(at: reset.addingTimeInterval(0.99))
        let weekly = UsageWindow(utilization: 12, resetsAt: stamp(18.5 * 3600), windowSeconds: 604_800)
        func cache(at offset: TimeInterval) -> PassiveUsageObservation {
            PassiveUsageObservation(
                source: .claudeUsageCache,
                usage: UsageAPIResponse(fiveHour: nil, sevenDay: weekly, sevenDayOauthApps: nil, sevenDayOpus: nil,
                                        sevenDaySonnet: nil, sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil),
                observedAt: reset.addingTimeInterval(offset), claudeAccountUUID: "uuid", codexHome: nil,
                processKey: nil, limitReached: false
            )
        }
        let (stored, applied) = ingest(cache(at: 40), stored: cleared, ingestedAt: 45, reset: reset, requestedAt: nil)
        XCTAssertTrue(applied.confirmsReset, "the endpoint's reply after the reset shows the windows as they are")
        XCTAssertFalse(applied.clearsSession)
        XCTAssertEqual(stored.fiveHour?.isUnusedUnstartedWindow, true)
        XCTAssertFalse(ingest(cache(at: -40), stored: cleared, ingestedAt: 45, reset: reset, requestedAt: nil).applied.confirmsReset,
                       "a reply fetched before the reset confirms nothing")
        XCTAssertFalse(AppState.readingHasSessionWindow(planHasSessionWindow: nil, sessionWindowReset: false),
                       "an account whose plan does not say and whose window did not reset is left to its replies")
    }
}
