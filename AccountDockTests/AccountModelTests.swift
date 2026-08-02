import XCTest
@testable import AccountDock

final class AccountModelTests: XCTestCase {
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
            .codexWeekly,
            .claudeSessionPercent,
            .claudeWeeklyPercent,
            .codexWeeklyPercent,
            .claudeWeeklyReset,
            .codexWeeklyReset,
            .claudeSessionReset,
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
}
