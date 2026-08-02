import XCTest
@testable import AccountDock

final class FailoverDecisionTests: XCTestCase {
    func testLegacyFailoverPolicyDefaultsCodexSwitchingToSafeRestart() throws {
        let policy = try JSONDecoder().decode(
            ProviderFailoverPolicy.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(policy.codexSwitchMode, .safeRestart)
    }

    func testAdaptivePollingTightensNearLimit() {
        let policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        XCTAssertEqual(
            FailoverDecision.pollInterval(
                usage: usage(session: 20, weekly: 20),
                provider: .claudeCode,
                policy: policy,
                noFailoverAvailable: false,
                blockingReset: nil,
                retryAfter: nil
            ),
            300
        )
        XCTAssertEqual(
            FailoverDecision.pollInterval(
                usage: usage(session: 87, weekly: 20),
                provider: .claudeCode,
                policy: policy,
                noFailoverAvailable: false,
                blockingReset: nil,
                retryAfter: nil
            ),
            15
        )
    }

    func testExhaustedPollingBacksOffUntilResetOrRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        XCTAssertEqual(
            FailoverDecision.pollInterval(
                usage: usage(session: 100, weekly: 100),
                provider: .claudeCode,
                policy: policy,
                noFailoverAvailable: true,
                blockingReset: now.addingTimeInterval(3 * 60 * 60),
                retryAfter: nil,
                now: now
            ),
            900
        )
        XCTAssertEqual(
            FailoverDecision.pollInterval(
                usage: usage(session: 100, weekly: 100),
                provider: .claudeCode,
                policy: policy,
                noFailoverAvailable: true,
                blockingReset: nil,
                retryAfter: now.addingTimeInterval(20 * 60),
                now: now
            ),
            1_205
        )
    }

    func testBlockingResetUsesLastBreachedWindowToRestoreCapacity() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 90
        policy.weeklyThreshold = 90
        let sessionReset = Date().addingTimeInterval(600)
        let weeklyReset = Date().addingTimeInterval(3600)
        let usage = usage(
            session: 100,
            weekly: 100,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset
        )

        let result = FailoverDecision.blockingResetDate(
            usage: usage,
            provider: .claudeCode,
            policy: policy
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.timeIntervalSince1970, weeklyReset.timeIntervalSince1970, accuracy: 1)
    }

    func testClaudeEitherWindowCanTriggerButDestinationNeedsBothWindows() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 80
        policy.weeklyThreshold = 90

        XCTAssertTrue(FailoverDecision.exceedsThreshold(
            usage: usage(session: 81, weekly: 20),
            provider: .claudeCode,
            policy: policy
        ))
        XCTAssertTrue(FailoverDecision.exceedsThreshold(
            usage: usage(session: 20, weekly: 91),
            provider: .claudeCode,
            policy: policy
        ))
        XCTAssertFalse(FailoverDecision.hasCapacity(
            usage: usage(session: 20, weekly: 91),
            provider: .claudeCode,
            policy: policy
        ))
        XCTAssertTrue(FailoverDecision.hasCapacity(
            usage: usage(session: 20, weekly: 30),
            provider: .claudeCode,
            policy: policy
        ))
    }

    func testCodexIgnoresSessionWindow() {
        var policy = ProviderFailoverPolicy.defaults(for: .codex)
        policy.weeklyThreshold = 85

        XCTAssertFalse(FailoverDecision.exceedsThreshold(
            usage: usage(session: 100, weekly: 20),
            provider: .codex,
            policy: policy
        ))
    }

    func testCapacityScoreUsesWeakestEnabledWindow() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 90
        policy.weeklyThreshold = 90

        XCTAssertEqual(
            FailoverDecision.capacityScore(
                usage: usage(session: 10, weekly: 70),
                provider: .claudeCode,
                policy: policy
            ),
            20
        )
    }

    func testRotationWrapsOnlyWhenLooping() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(
            FailoverDecision.candidates(orderedIDs: ids, currentID: ids[1], loops: false),
            [ids[2]]
        )
        XCTAssertEqual(
            FailoverDecision.candidates(orderedIDs: ids, currentID: ids[1], loops: true),
            [ids[2], ids[0]]
        )
    }

    func testCandidateSelectionUsesLastKnownAvailableQuota() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 97
        policy.weeklyThreshold = 98
        let unavailable = UUID()
        let cachedAvailable = UUID()
        let exhausted = UUID()

        let result = FailoverDecision.eligibleCandidates(
            [unavailable, cachedAvailable, exhausted],
            usageByID: [
                cachedAvailable: usage(session: 0, weekly: 42),
                exhausted: usage(session: 100, weekly: 20),
            ],
            provider: .claudeCode,
            policy: policy
        )

        XCTAssertEqual(result, [cachedAvailable])
    }

    func testLocallyElapsedResetCannotBecomeFailoverDestinationUntilVerified() {
        let resetButUnverified = UUID()
        let nextVerified = UUID()
        let policy = ProviderFailoverPolicy.defaults(for: .claudeCode)

        let result = FailoverDecision.eligibleCandidates(
            [resetButUnverified, nextVerified],
            usageByID: [
                resetButUnverified: usage(session: 0, weekly: 20),
                nextVerified: usage(session: 30, weekly: 40),
            ],
            provider: .claudeCode,
            policy: policy,
            unverifiedResetIDs: [resetButUnverified]
        )

        XCTAssertEqual(result, [nextVerified])
    }

    func testImminentResetRequiresEveryBreachedWindowToResetSoon() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.sessionThreshold = 80
        policy.weeklyThreshold = 80
        policy.resetGraceMinutes = 5
        let now = Date()

        XCTAssertTrue(FailoverDecision.shouldWaitForImminentReset(
            usage: usage(
                session: 85,
                weekly: 85,
                sessionReset: now.addingTimeInterval(60),
                weeklyReset: now.addingTimeInterval(240)
            ),
            provider: .claudeCode,
            policy: policy,
            now: now
        ))
        XCTAssertFalse(FailoverDecision.shouldWaitForImminentReset(
            usage: usage(
                session: 85,
                weekly: 85,
                sessionReset: now.addingTimeInterval(60),
                weeklyReset: now.addingTimeInterval(360)
            ),
            provider: .claudeCode,
            policy: policy,
            now: now
        ))
    }

    private func usage(
        session: Double,
        weekly: Double,
        sessionReset: Date? = nil,
        weeklyReset: Date? = nil
    ) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: UsageWindow(
                utilization: session,
                resetsAt: sessionReset.map(iso8601)
            ),
            sevenDay: UsageWindow(
                utilization: weekly,
                resetsAt: weeklyReset.map(iso8601)
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
