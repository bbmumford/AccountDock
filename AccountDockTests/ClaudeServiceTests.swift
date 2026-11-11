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

    func testUsageReadingsIdentifyAsTheClaudeCodeClient() {
        XCTAssertEqual(ClaudeService.usageUserAgent(version: "2.1.311"), "claude-cli/2.1.311 (external, cli)")
    }

    func testLimitResetsAreReadFromTheUsageReadingAndAnUnknownGrantIsDropped() throws {
        let json = #"""
        {"seven_day":{"utilization":94,"resets_at":"2026-11-17T10:59:59.650820+00:00"},
         "extra_usage":{"is_enabled":false},
         "cedar_ember":{"eligible":true,"at_limit":false,"next_grant_id":"full-reset-2611","grants":[
          {"id":"launch-2610-fable","label":"New model launch: one Fable reset","resets_total":1,"resets_left":1,
           "starts_at":"2026-11-09T18:00:00+00:00","ends_at":"2027-03-09T07:59:00+00:00",
           "clears":["seven_day_overage_included"],"paused":false,"usable_now":true,"type":"full"},
          {"id":"full-reset-2611","label":"One full limit reset (November 2026)","resets_total":1,"resets_left":1,
           "ends_at":"2026-12-10T22:00:00+00:00","clears":["seven_day","seven_day_overage_included"],
           "paused":false,"usable_now":true,"type":"weekly"},
          {"id":"spent","label":"Used","resets_total":2,"resets_left":0,"clears":["five_hour"]},
          {"label":"no id or count"}
         ]}}
        """#
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.sevenDay?.utilization, 94, "a reset field never costs the windows")
        let resets = try XCTUnwrap(usage.limitResets)
        XCTAssertEqual(resets.grants.map(\.id), ["launch-2610-fable", "full-reset-2611", "spent"])
        XCTAssertEqual(resets.available.map(\.id), ["full-reset-2611", "launch-2610-fable"], "soonest to expire first, none spent")
        XCTAssertEqual(resets.available.map(\.kind), ["All-models reset", "Fable reset"])
        XCTAssertTrue(resets.available.allSatisfy(\.usableNow))

        let roundTrip = try JSONDecoder().decode(UsageAPIResponse.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(roundTrip.limitResets, resets, "a saved reading keeps its resets")
        XCTAssertEqual(usage.merged(withNewer: try JSONDecoder().decode(UsageAPIResponse.self, from: Data(#"{"seven_day":{"utilization":95}}"#.utf8))).limitResets,
                       resets, "a reading without resets keeps the last known ones")
    }

    func testAMalformedResetFieldLeavesTheReadingIntact() throws {
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(#"{"seven_day":{"utilization":10},"cedar_ember":"surprise"}"#.utf8))
        XCTAssertEqual(usage.sevenDay?.utilization, 10)
        XCTAssertNil(usage.limitResets)
    }

    func testEveryAccountsLimitResetsAreAskedForHourlyOldestFirst() {
        let now = Date()
        let never = Account(email: "never@mail.example", displayName: "Never")
        let old = Account(email: "old@mail.example", displayName: "Old")
        let recent = Account(email: "recent@mail.example", displayName: "Recent")
        let accounts = [recent, old, never]
        var checked: [UUID: Date] = [old.id: now.addingTimeInterval(-2 * 3600), recent.id: now.addingTimeInterval(-600)]
        XCTAssertEqual(AppState.accountDueForLimitResets(accounts, checkedAt: checked, now: now)?.id, never.id, "one never asked comes first")
        checked[never.id] = now
        XCTAssertEqual(AppState.accountDueForLimitResets(accounts, checkedAt: checked, now: now)?.id, old.id)
        checked[old.id] = now
        XCTAssertNil(AppState.accountDueForLimitResets(accounts, checkedAt: checked, now: now), "none is asked twice within the hour")
        XCTAssertEqual(AppState.accountDueForLimitResets(accounts, checkedAt: checked, now: now.addingTimeInterval(3000))?.id, recent.id)
    }

    func testResetsOfOneOfferEndingTheSameDayAreCountedTogether() {
        let resets = LimitResets(grants: [
            .init(id: "fable", label: "Fable reset", resetsTotal: 1, resetsLeft: 1, endsAt: "2027-03-09T07:59:00+00:00",
                  refills: [.model("Fable")]),
            .init(id: "fable-6mo", label: "Fable reset, six months", resetsTotal: 1, resetsLeft: 1, endsAt: "2027-03-09T07:59:00+00:00",
                  refills: [.model("Fable")]),
            .init(id: "full", label: "Full reset", resetsTotal: 1, resetsLeft: 1, endsAt: "2026-12-10T22:00:00+00:00",
                  refills: [.weekly, .model("Fable")]),
            .init(id: "fable-later", resetsTotal: 1, resetsLeft: 1, endsAt: "2027-06-01T00:00:00+00:00",
                  refills: [.model("Fable")]),
        ])
        let groups = resets.availableGroups
        XCTAssertEqual(groups.map(\.kind), ["All-models reset", "Fable reset", "Fable reset"])
        XCTAssertEqual(groups.map(\.resetsLeft), [1, 2, 1])
        XCTAssertEqual(groups[1].labels, ["Fable reset", "Fable reset, six months"])
        XCTAssertEqual(groups[1].resetsTotal, 2, "two whole grants read as 2 left, not 2 of 2")
    }

    func testASavedReadingKeepsItsResetsInTheSharedFormAndOldSavedReadingsStillRead() throws {
        let anthropic = #"{"seven_day":{"utilization":5},"cedar_ember":{"grants":[{"id":"g","resets_left":1,"clears":["seven_day"],"usable_now":true}]}}"#
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(anthropic.utf8))
        XCTAssertEqual(usage.limitResets?.grants.first?.refills, [.weekly])
        let saved = try JSONEncoder().encode(usage)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertTrue(text.contains("limit_resets") && !text.contains("cedar_ember"), "saved in the provider-neutral form")
        XCTAssertEqual(try JSONDecoder().decode(UsageAPIResponse.self, from: saved).limitResets, usage.limitResets)
    }

    func testCodexResetCreditsReadIntoTheSharedFormWithoutCostingItsWindows() throws {
        let reply = #"""
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_at":1794000000,"reset_after_seconds":600},
         "secondary_window":{"used_percent":70,"limit_window_seconds":604800,"reset_at":1794500000,"reset_after_seconds":6000}},
         "rate_limit_reset_credits":{"available_count":2}}
        """#
        let usage = try CodexService.decodeUsage(Data(reply.utf8))
        XCTAssertNotNil(usage.sevenDay)
        let groups = try XCTUnwrap(usage.limitResets).availableGroups
        XCTAssertEqual(groups.map(\.kind), ["Full reset"])
        XCTAssertEqual(groups.first?.resetsLeft, 2)
        let odd = try CodexService.decodeUsage(Data(#"{"rate_limit":{"secondary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1794500000}},"rate_limit_reset_credits":"surprise"}"#.utf8))
        XCTAssertNotNil(odd.sevenDay, "an unknown reset shape never costs the windows")
        XCTAssertNil(odd.limitResets)
    }

    func testOnlyProvidersThatReportResetsAreReadForThem() {
        XCTAssertTrue(AIProviderType.claudeCode.capabilities.reportsLimitResets)
        XCTAssertTrue(AIProviderType.codex.capabilities.reportsLimitResets)
        XCTAssertFalse(AIProviderType.kimi.capabilities.reportsLimitResets)
    }
}
