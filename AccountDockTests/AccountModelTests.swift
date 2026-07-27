import XCTest
@testable import AccountDock

final class AccountModelTests: XCTestCase {
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
}
