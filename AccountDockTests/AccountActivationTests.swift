import XCTest
@testable import AccountDock

/// The active account of each provider is read from the accounts' own
/// flags (`[Account].active(for:)`) and set by `makeActive`, so no copy of
/// it can disagree with them.
final class AccountActivationTests: XCTestCase {
    private func accounts() -> [Account] {
        [
            Account(email: "one@example.com", displayName: "One", provider: .claudeCode, isActive: true),
            Account(email: "two@example.com", displayName: "Two", provider: .claudeCode),
            Account(email: "codex-a@example.com", displayName: "Codex A", provider: .codex, isActive: true),
            Account(email: "codex-b@example.com", displayName: "Codex B", provider: .codex),
            Account(email: "kimi@example.com", displayName: "Kimi", provider: .kimi, isActive: true),
        ]
    }

    private func assertOneActivePerProvider(_ accounts: [Account], file: StaticString = #filePath, line: UInt = #line) {
        for provider in Set(accounts.map(\.provider)) {
            XCTAssertEqual(accounts.filter { $0.provider == provider && $0.isActive }.count, 1,
                           "\(provider.rawValue)", file: file, line: line)
        }
    }

    func testExactlyOneActiveAccountPerProviderAfterEachOperation() {
        var accounts = accounts()
        let claudeTwo = accounts[1].id
        let codexB = accounts[3].id

        accounts.makeActive(claudeTwo)
        assertOneActivePerProvider(accounts)
        XCTAssertEqual(accounts.active(for: .claudeCode)?.id, claudeTwo)
        XCTAssertEqual(accounts.active(for: .codex)?.id, accounts[2].id, "another provider keeps its active account")

        accounts.makeActive(codexB)
        assertOneActivePerProvider(accounts)
        XCTAssertEqual(accounts.active(for: .codex)?.id, codexB)
        XCTAssertEqual(accounts.active(for: .claudeCode)?.id, claudeTwo)

        let added = Account(email: "three@example.com", displayName: "Three", provider: .claudeCode, isActive: true)
        accounts.append(added)
        accounts.makeActive(added.id)
        assertOneActivePerProvider(accounts)
        XCTAssertEqual(accounts.active(for: .claudeCode)?.id, added.id)

        accounts.removeAll { $0.id == added.id }
        accounts.makeActive(accounts[0].id)
        assertOneActivePerProvider(accounts)

        accounts.makeActive(UUID())
        assertOneActivePerProvider(accounts)
    }

    func testRelabellingTheActiveCodexAccountLeavesTheActiveClaudeAccount() {
        var accounts = accounts()
        let claude = accounts.active(for: .claudeCode)
        let codexIndex = accounts.firstIndex { $0.provider == .codex && $0.isActive }!
        accounts[codexIndex].customLabel = "Work"
        XCTAssertEqual(accounts.active(for: .claudeCode), claude)
        XCTAssertEqual(accounts.active(for: .codex)?.customLabel, "Work")
        assertOneActivePerProvider(accounts)
    }
}
