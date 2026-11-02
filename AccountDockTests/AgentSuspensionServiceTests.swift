import XCTest
@testable import AccountDock

final class AgentSuspensionServiceTests: XCTestCase {
    func testProcessDiscoveryDoesNotMatchHelpersContainingProviderText() {
        XCTAssertFalse(AgentSuspensionService.matchesCommand(
            "/bin/ps -axo pid=,command= --note /opt/homebrew/bin/claude process scan",
            provider: .claudeCode
        ))
        XCTAssertFalse(AgentSuspensionService.matchesCommand(
            "/bin/sh -c echo /usr/local/bin/codex process scan",
            provider: .codex
        ))
    }

    func testProcessDiscoveryMatchesProviderExecutableTokens() {
        XCTAssertTrue(AgentSuspensionService.matchesCommand(
            "/opt/homebrew/bin/claude --resume abc",
            provider: .claudeCode
        ))
        XCTAssertTrue(AgentSuspensionService.matchesCommand(
            "/usr/bin/node /Users/test/.local/bin/codex resume abc",
            provider: .codex
        ))
        XCTAssertTrue(AgentSuspensionService.matchesCommand(
            "/Users/test/.kimi-code/bin/kimi --session abc",
            provider: .kimi
        ))
    }
}
