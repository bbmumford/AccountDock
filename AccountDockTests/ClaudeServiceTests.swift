import XCTest
@testable import AccountDock

final class ClaudeServiceTests: XCTestCase {
    func testLiveProfileReportsCurrentSubscription() {
        let profile: [String: Any] = [
            "account": ["subscription_type": "pro"]
        ]
        XCTAssertEqual(
            ClaudeService.liveSubscription(fromProfileJSON: profile),
            ClaudeSubscriptionSnapshot(planType: "pro", isInactive: false)
        )
    }

    func testExpiredLiveProfileClearsStaleSubscription() {
        let profile: [String: Any] = [
            "subscription": ["status": "expired", "endsAt": "2026-08-28T00:00:00Z"],
            "subscriptionType": "max"
        ]
        XCTAssertEqual(
            ClaudeService.liveSubscription(fromProfileJSON: profile),
            ClaudeSubscriptionSnapshot(planType: nil, isInactive: true)
        )
    }

    func testRunningProcessParserOnlyAcceptsClaudeExecutable() {
        let sample = """
          101 /opt/homebrew/bin/claude /opt/homebrew/bin/claude --resume abc
          102 /usr/bin/zsh zsh -c echo claude
          103 /Applications/Visual Studio Code.app/Contents/MacOS/Electron Electron claude
          104 /path/to/claude /path/to/claude auth login
          105 /path/to/claude /path/to/claude --ignored-self
        """

        let result = ClaudeService.parseRunningProcesses(sample, excludingPID: 105)

        XCTAssertEqual(result.map(\.id), [101, 104])
        XCTAssertEqual(result.map(\.label), ["Claude Code session", "Claude browser login"])
        XCTAssertEqual(result.first?.sessionID, "abc")
    }

    func testRunningProcessLabelRecognizesIDEAndChrome() {
        let sample = """
          201 /extension/claude /Users/me/.vscode/extensions/anthropic/resources/claude --verbose
          202 /bin/claude /bin/claude --claude-in-chrome-mcp
        """

        let result = ClaudeService.parseRunningProcesses(sample, excludingPID: -1)

        XCTAssertEqual(result.map(\.label), ["VS Code Claude session", "Claude in Chrome"])
    }

    func testResumeSessionIDSupportsEqualsAndSeparatedForms() {
        XCTAssertEqual(
            ClaudeService.extractResumeSessionID(from: "claude --resume=abc-123"),
            "abc-123"
        )
        XCTAssertEqual(
            ClaudeService.extractResumeSessionID(from: "claude --resume abc_123"),
            "abc_123"
        )
        XCTAssertNil(ClaudeService.extractResumeSessionID(from: "claude --continue"))
    }

    func testRetryAfterSupportsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ClaudeService.retryAfterDate("120", now: now),
            now.addingTimeInterval(120)
        )

        let parsed = ClaudeService.retryAfterDate("Wed, 15 Nov 2023 00:15:00 GMT", now: now)
        XCTAssertNotNil(parsed)
    }

    func testWarmupUsesOAuthCompatibleSafeMode() {
        let arguments = ClaudeService.warmupArguments(sessionID: "probe-id")

        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertFalse(arguments.contains("--bare"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
    }
}
