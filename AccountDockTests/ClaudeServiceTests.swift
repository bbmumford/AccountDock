import XCTest
@testable import AccountDock

final class ClaudeServiceTests: XCTestCase {
    func testRateLimitTierComesFromTheToken() {
        XCTAssertEqual(ClaudeService.rateLimitTier(from: #"{"claudeAiOauth":{"rateLimitTier":"default_claude_max_20x"}}"#), "default_claude_max_20x")
        XCTAssertNil(ClaudeService.rateLimitTier(from: #"{"claudeAiOauth":{}}"#))
    }

    func testProfileIdentityNamesTheTokensAccount() {
        let profile: [String: Any] = [
            "account": ["uuid": "acct-1", "email": "owner@mail.example", "display_name": "Owner"],
            "organization": ["uuid": "org-1"]
        ]
        XCTAssertEqual(
            ClaudeService.profileIdentity(fromProfileJSON: profile),
            ClaudeProfileIdentity(accountUUID: "acct-1", email: "owner@mail.example")
        )
        XCTAssertEqual(
            ClaudeService.profileIdentity(fromProfileJSON: ["organization": ["uuid": "org-1"]]),
            ClaudeProfileIdentity(accountUUID: nil, email: nil)
        )
    }

    func testLiveCredentialOwnerIsMatchedByProviderIDBeforeEmail() {
        let first = Account(email: "a@mail.example", displayName: "A")
        let second = Account(email: "b@mail.example", displayName: "B")
        let ids = [first.id: "uuid-a", second.id: "uuid-b"]
        func match(_ owner: CredentialOwner) -> UUID? {
            AppState.owningAccount(owner, among: [first, second], providerAccountID: { ids[$0.id] })?.id
        }
        XCTAssertEqual(match(CredentialOwner(providerAccountID: "uuid-b", email: "a@mail.example")), second.id)
        XCTAssertEqual(match(CredentialOwner(providerAccountID: "unknown", email: "A@MAIL.example")), first.id)
        XCTAssertNil(match(CredentialOwner(providerAccountID: nil, email: "c@mail.example")))
    }

    func testOnlyAnotherAccountsRenewedCredentialIsAdoptedAndTheActiveOneRestored() {
        let active = UUID(), other = UUID()
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: active, activeID: active, signedInAsActive: true, activeCopyIsCurrent: false), .saveActiveCopy)
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: active, activeID: active, signedInAsActive: true, activeCopyIsCurrent: true), .none)
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: active, activeID: active, signedInAsActive: false, activeCopyIsCurrent: false), .none)
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: other, activeID: active, signedInAsActive: true, activeCopyIsCurrent: false), .adopt(restoreActive: true))
        // Signed in as another account outside AccountDock: its credential is
        // saved, and the live slot is left alone.
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: other, activeID: active, signedInAsActive: false, activeCopyIsCurrent: false), .adopt(restoreActive: false))
        // Only the identity named the active account: a session on it rewrote
        // the identity, and the live credential's owner is the active account.
        // Nothing is installed, so no running session moves.
        XCTAssertEqual(AppState.liveCredentialAction(ownerID: other, activeID: active, signedInAsActive: true, activeCopyIsCurrent: false, liveWasActives: false), .makeOwnerActive)
    }

    func testSignallingRunningSessionsChangesOnlyTheModificationTime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".credentials.json")
        try Data("{}".utf8).write(to: file)
        let later = Date().addingTimeInterval(60)
        XCTAssertTrue(ClaudeCredentialModule.touchIfPresent(file.path, now: later))
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        // A missing file is never created: it would read as a stored credential.
        let absent = dir.appendingPathComponent("absent.json")
        XCTAssertFalse(ClaudeCredentialModule.touchIfPresent(absent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testOnlyLeavingAnAccountThatWouldRefuseThemMovesRunningSessionsAtOnce() {
        XCTAssertTrue(AppState.switchMovesRunningSessions(.exhausted))
        XCTAssertTrue(AppState.switchMovesRunningSessions(.workloadUnavailable))
        XCTAssertFalse(AppState.switchMovesRunningSessions(.threshold))
        XCTAssertFalse(AppState.switchMovesRunningSessions(.balance(advantageHours: 2)))
    }

    func testCredentialDigestDistinguishesCredentialsWithoutHoldingThem() {
        let first = AppState.credentialDigest("{\"claudeAiOauth\":{\"accessToken\":\"a\"}}")
        XCTAssertEqual(first, AppState.credentialDigest("{\"claudeAiOauth\":{\"accessToken\":\"a\"}}"))
        XCTAssertNotEqual(first, AppState.credentialDigest("{\"claudeAiOauth\":{\"accessToken\":\"b\"}}"))
        XCTAssertFalse(first.contains("accessToken"))
        XCTAssertEqual(first.count, 64)
    }

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
