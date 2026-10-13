import XCTest
@testable import AccountDock

final class AccountModelTests: XCTestCase {
    func testProviderRegistryDefinesImplementedProvidersAndQuotaCapabilities() {
        XCTAssertEqual(AIProviderType.implementedProviders, [.claudeCode, .codex, .kimi])
        XCTAssertTrue(AIProviderType.claudeCode.capabilities.supportsSessionQuota)
        XCTAssertTrue(AIProviderType.codex.capabilities.supportsSessionQuota)
        XCTAssertEqual(AIProviderType.codex.capabilities.sessionQuotaMode, .whenPresent)
        XCTAssertEqual(AIProviderType.codex.capabilities.pricingPrefixes.first, "openai/")
        XCTAssertEqual(AIProviderType.kimi.capabilities.weeklyQuotaLabel, "Monthly limit")
        XCTAssertEqual(AIProviderType.kimi.capabilities.sessionQuotaLabel, "5-hour")
    }

    func testFreeTierEligibilityIsProviderCapabilityDriven() {
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .claudeCode, subscriptionType: "free"))
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .codex, subscriptionType: "free"))
        XCTAssertTrue(Account.supportsProviderWorkloads(provider: .gemini, subscriptionType: "free"))
    }

    func testFreeCodexAccountIsNotAWorkloadDestination() {
        let account = Account(
            email: "free@example.com",
            displayName: "Free",
            provider: .codex,
            subscriptionType: "free"
        )
        XCTAssertFalse(account.supportsProviderWorkloads)
        XCTAssertEqual(account.providerUnavailableLabel, "Codex unavailable")
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .codex, subscriptionType: "FREE"))
    }

    func testPaidCodexAccountRemainsAWorkloadDestination() {
        let account = Account(
            email: "plus@example.com",
            displayName: "Plus",
            provider: .codex,
            subscriptionType: "plus"
        )
        XCTAssertTrue(account.supportsProviderWorkloads)
        XCTAssertNil(account.providerUnavailableLabel)
    }

    func testFreeClaudeAccountIsNotAClaudeCodeDestination() {
        let account = Account(
            email: "free@example.com",
            displayName: "Free",
            provider: .claudeCode,
            subscriptionType: "free"
        )
        XCTAssertFalse(account.supportsProviderWorkloads)
        XCTAssertEqual(account.providerUnavailableLabel, "Claude Code unavailable")
    }

    func testUnusedUnstartedWindowRequiresConfirmedZeroAndNoReset() {
        XCTAssertTrue(UsageWindow(utilization: 0, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(UsageWindow(utilization: nil, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(UsageWindow(utilization: 1, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(
            UsageWindow(
                utilization: 0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
            ).isUnusedUnstartedWindow
        )
    }

    func testLegacyAccountDecodesWithoutCredentialLocation() throws {
        let data = """
        {
          "id": "51437F9A-812D-4CAC-A322-3CB743182CB0",
          "email": "legacy@example.com",
          "displayName": "Legacy",
          "provider": "Claude Code",
          "isActive": true
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(account.email, "legacy@example.com")
        XCTAssertNil(account.credentialLocation)
    }

    func testProvidersMaintainIndependentActiveState() {
        let claude = Account(email: "claude@example.com", displayName: "Claude", isActive: true)
        let codex = Account(
            email: "codex@example.com",
            displayName: "Codex",
            provider: .codex,
            isActive: true,
            credentialLocation: "/managed/codex"
        )

        XCTAssertTrue(claude.isActive)
        XCTAssertTrue(codex.isActive)
        XCTAssertNotEqual(claude.provider, codex.provider)
    }

    func testMenuBarCatalogUsesProductDefaultOrder() {
        XCTAssertEqual(MenuBarModule.allCases, [
            .claudeSession,
            .claudeWeekly,
            .codexSession,
            .codexWeekly,
            .claudeSessionPercent,
            .claudeWeeklyPercent,
            .claudePercentages,
            .codexSessionPercent,
            .codexWeeklyPercent,
            .codexPercentages,
            .claudeWeeklyReset,
            .codexWeeklyReset,
            .claudeSessionReset,
            .codexSessionReset,
            .kimiSession,
            .kimiMonthly,
            .kimiSessionPercent,
            .kimiMonthlyPercent,
            .kimiPercentages,
            .kimiSessionReset,
            .kimiMonthlyReset,
            .dailyCost
        ])
    }

    func testCachedUsageClearsAfterKnownResetPasses() {
        let now = Date()
        let usage = UsageAPIResponse(
            fiveHour: UsageWindow(
                utilization: 100,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
            ),
            sevenDay: UsageWindow(
                utilization: 72,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let effective = usage.expiringPassedResets(at: now)

        XCTAssertEqual(effective.fiveHour?.utilization, 0)
        XCTAssertNil(effective.fiveHour?.resetsAt)
        XCTAssertEqual(effective.sevenDay?.utilization, 72)
        XCTAssertNotNil(effective.sevenDay?.resetsAt)
    }

    func testCachedUsageReportsItsNextFutureReset() throws {
        let now = Date()
        let sessionReset = now.addingTimeInterval(300)
        let weeklyReset = now.addingTimeInterval(600)
        let usage = UsageAPIResponse(
            fiveHour: UsageWindow(
                utilization: 40,
                resetsAt: ISO8601DateFormatter().string(from: sessionReset)
            ),
            sevenDay: UsageWindow(
                utilization: 80,
                resetsAt: ISO8601DateFormatter().string(from: weeklyReset)
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let nextReset = try XCTUnwrap(usage.nextResetDate)
        XCTAssertEqual(nextReset.timeIntervalSince1970,
                       sessionReset.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testSuccessfulWarmupPinsMovingPlaceholderAndLaterPollPreservesIt() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let placeholder = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 0, resetsAt: nil, windowSeconds: 604_800),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let pinned = placeholder.pinningWarmupCountdowns(
            session: false,
            weekly: true,
            startedAt: startedAt
        )
        XCTAssertEqual(
            try XCTUnwrap(pinned.sevenDay?.resetsAtDate).timeIntervalSince1970,
            startedAt.addingTimeInterval(604_800).timeIntervalSince1970,
            accuracy: 1
        )

        let preserved = placeholder.preservingEstablishedCountdowns(from: pinned)
        XCTAssertEqual(preserved.sevenDay?.resetsAt, pinned.sevenDay?.resetsAt)
    }

    func testRealProviderCountdownReplacesPinnedCountdown() {
        let pinned = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(
                utilization: 0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(500)),
                windowSeconds: 604_800
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )
        let provider = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(
                utilization: 1,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(400)),
                windowSeconds: 604_800
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        XCTAssertEqual(
            provider.preservingEstablishedCountdowns(from: pinned).sevenDay?.resetsAt,
            provider.sevenDay?.resetsAt
        )
    }
}
