import XCTest
@testable import AccountDock

final class RouterLogicTests: XCTestCase {
    private func body(_ messages: [[String: Any]], session: String = "abc") -> [String: Any] {
        ["model": "claude-fable-5-1", "metadata": ["user_id": "user_x_account_y_session_\(session)"], "messages": messages]
    }

    func testSessionComesFromClaudeCodeMetadata() {
        XCTAssertEqual(RouterLogic.sessionID(body([])), "abc")
        XCTAssertNil(RouterLogic.sessionID(["messages": []]))
        let json = #"{"device_id":"d1","account_uuid":"a1","session_id":"8c64c5f8-45c6-4738-a815-b1ae3511f33e"}"#
        XCTAssertEqual(RouterLogic.sessionID(["metadata": ["user_id": json]]), "8c64c5f8-45c6-4738-a815-b1ae3511f33e")
        XCTAssertNil(RouterLogic.sessionID(["metadata": ["user_id": #"{"device_id":"d1"}"#]]))
    }

    func testToolResultsContinueATurnAndUserTextStartsOne() {
        XCTAssertTrue(RouterLogic.startsTurn(body([["role": "user", "content": "do it"]])))
        XCTAssertTrue(RouterLogic.startsTurn(body([["role": "user", "content": [["type": "text", "text": "hi"]]]])))
        XCTAssertFalse(RouterLogic.startsTurn(body([["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]])))
    }

    func testATurnFinishesWhereItBeganUnlessTheNewBackendAcceptsForeignThinking() {
        XCTAssertEqual(RouterLogic.backend(desired: "anthropic", turnBackend: "kimi", startsTurn: false, desiredValidatesThinking: true), "kimi")
        XCTAssertEqual(RouterLogic.backend(desired: "anthropic", turnBackend: "kimi", startsTurn: true, desiredValidatesThinking: true), "anthropic")
        XCTAssertEqual(RouterLogic.backend(desired: "kimi", turnBackend: "anthropic", startsTurn: false, desiredValidatesThinking: false), "kimi")
        XCTAssertEqual(RouterLogic.backend(desired: "anthropic", turnBackend: nil, startsTurn: false, desiredValidatesThinking: true), "anthropic")
    }

    func testSessionsKeepTheirAccountAndNewSessionsGoToTheLeastLoadedWeightedAccount() {
        let members = [
            RouterPoolMember(accountID: "a", tokenFile: "a", weight: 1),
            RouterPoolMember(accountID: "b", tokenFile: "b", weight: 2),
            RouterPoolMember(accountID: "c", tokenFile: "c", weight: 0),
        ]
        XCTAssertEqual(RouterLogic.poolAccount(current: "c", startsTurn: true, members: members, unavailable: [], load: [:]), "c",
                       "an account kept for its sessions still serves them")
        XCTAssertEqual(RouterLogic.poolAccount(current: nil, startsTurn: true, members: members, unavailable: [], load: ["a": 1, "b": 1]), "b")
        XCTAssertEqual(RouterLogic.poolAccount(current: nil, startsTurn: true, members: members, unavailable: [], load: ["a": 0, "b": 1]), "a")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: false, members: members, unavailable: ["a"], load: [:]), "b")
        XCTAssertEqual(RouterLogic.poolAccount(current: nil, startsTurn: true, members: members, unavailable: ["a"], load: [:]), "b",
                       "a weight of zero takes no new session while a weighted account can")
        XCTAssertEqual(RouterLogic.poolAccount(current: nil, startsTurn: true, members: members, unavailable: ["a", "b"], load: [:]), "c",
                       "once every weighted account refused, the rest serve in pool order")
        XCTAssertNil(RouterLogic.poolAccount(current: nil, startsTurn: true, members: members, unavailable: ["a", "b", "c"], load: [:]))
    }

    func testSessionsFollowThePreferredAccountAtTheirNextTurn() {
        let members = [
            RouterPoolMember(accountID: "active", tokenFile: "active", weight: 1),
            RouterPoolMember(accountID: "previous", tokenFile: "previous", weight: 0),
        ]
        XCTAssertEqual(RouterLogic.poolAccount(current: "previous", startsTurn: false, members: members, unavailable: [], load: [:],
                                               followPreferred: true), "previous", "a turn finishes on its account")
        XCTAssertEqual(RouterLogic.poolAccount(current: "previous", startsTurn: true, members: members, unavailable: [], load: [:],
                                               followPreferred: true), "active", "the next turn moves to the active account")
        XCTAssertEqual(RouterLogic.poolAccount(current: "previous", startsTurn: true, members: members, unavailable: [], load: [:]),
                       "previous", "without following, a session keeps its account")
        XCTAssertEqual(RouterLogic.poolAccount(current: "previous", startsTurn: true, members: members, unavailable: ["active"], load: [:],
                                               followPreferred: true), "previous", "a refused active account leaves the session where it is")
    }

    func testOlderRouterStatesStillDecode() throws {
        let state = try RouterConfig.decoder().decode(RouterState.self, from: Data(#"{"route":"anthropic","pool":[]}"#.utf8))
        XCTAssertFalse(state.sessionsFollowPreferred)
        XCTAssertEqual(state.primary, "anthropic")
    }

    func testThinkingFromAnotherBackendIsRemovedAndOtherAccountsOnlyWhenRequired() {
        let kimi = RouterLogic.signatureKey("k-sig"), other = RouterLogic.signatureKey("a2-sig"), own = RouterLogic.signatureKey("a1-sig")
        let issuers = [kimi: "kimi", other: "anthropic|acct-2", own: "anthropic|acct-1"]
        let request = body([
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "a", "signature": "k-sig"],
                ["type": "text", "text": "answer"],
            ]],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "b", "signature": "a2-sig"],
                ["type": "thinking", "thinking": "c", "signature": "a1-sig"],
                ["type": "tool_use", "id": "t", "name": "Bash", "input": [:]],
            ]],
            ["role": "assistant", "content": [["type": "thinking", "thinking": "d", "signature": "k-sig"]]],
        ])
        let (lenient, removedLenient) = RouterLogic.cleanedThinking(request, target: "anthropic", account: "acct-1", issuers: issuers, stripOtherAccounts: false)
        XCTAssertEqual(removedLenient, 2)
        let messages = lenient["messages"] as! [[String: Any]]
        XCTAssertEqual((messages[1]["content"] as! [[String: Any]]).map { $0["type"] as! String }, ["text"])
        XCTAssertEqual((messages[2]["content"] as! [[String: Any]]).count, 3)
        XCTAssertEqual((messages[3]["content"] as! [[String: Any]]).first?["type"] as? String, "text", "an emptied message keeps a text block")
        XCTAssertEqual(RouterLogic.cleanedThinking(request, target: "anthropic", account: "acct-1", issuers: issuers, stripOtherAccounts: true).1, 3)
        XCTAssertEqual(RouterLogic.cleanedThinking(request, target: "kimi", account: nil, issuers: [:], stripOtherAccounts: false).1, 0)
    }

    func testPlanLimitIsToldApartFromAShortThrottle() {
        XCTAssertTrue(RouterLogic.isPlanLimit(status: 429, headers: ["Anthropic-Ratelimit-Unified-Status": "rejected"], body: Data()))
        XCTAssertTrue(RouterLogic.isPlanLimit(status: 429, headers: [:], body: Data(#"{"error":{"message":"Claude AI usage limit reached"}}"#.utf8)))
        XCTAssertFalse(RouterLogic.isPlanLimit(status: 429, headers: ["anthropic-ratelimit-unified-status": "allowed"], body: Data(#"{"error":{"type":"rate_limit_error","message":"Too many requests"}}"#.utf8)))
        XCTAssertFalse(RouterLogic.isPlanLimit(status: 500, headers: ["anthropic-ratelimit-unified-status": "rejected"], body: Data()))
    }

    func testKimisForbiddenUsageLimitIsAPlanLimit() {
        let kimi = Data(#"{"error":{"message":"You've reached your 5-hour usage limit. Your quota will reset when the current 5-hour window ends."}}"#.utf8)
        XCTAssertTrue(RouterLogic.isPlanLimit(status: 403, headers: [:], body: kimi))
        let permission = Data(#"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement"}}"#.utf8)
        XCTAssertFalse(RouterLogic.isPlanLimit(status: 403, headers: [:], body: permission))
        // The unified status header counts only on a 429.
        XCTAssertFalse(RouterLogic.isPlanLimit(status: 403, headers: ["anthropic-ratelimit-unified-status": "rejected"], body: permission))
    }

    func testRequestShapeDescribesStructureWithoutText() {
        let body: [String: Any] = [
            "model": "k3", "max_tokens": 1, "stream": true,
            "thinking": ["type": "enabled", "budget_tokens": 1024],
            "tools": [["name": "Bash"], ["name": "Read"]],
            "system": [["type": "text", "text": "secret system prompt"]],
            "metadata": ["user_id": "x"],
            "context_management": ["edits": []],
            "messages": [
                ["role": "user", "content": "first question"],
                ["role": "assistant", "content": [["type": "thinking", "thinking": "t"], ["type": "tool_use", "id": "1"]]],
                ["role": "user", "content": [["type": "tool_result", "tool_use_id": "1", "content": "private output"]]],
            ],
        ]
        let shape = RouterLogic.requestShape(body)
        XCTAssertEqual(shape, "model=k3 max_tokens=1 stream=true thinking=enabled/1024 tools=2 system=1 blocks messages=3 last=assistant[thinking,tool_use] user[tool_result] other=context_management")
        XCTAssertFalse(shape.contains("secret") || shape.contains("private") || shape.contains("question"))
    }

    func testUnifiedUsageHeadersBecomePercentages() throws {
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.04",
            "anthropic-ratelimit-unified-5h-reset": "1792247400",
            "anthropic-ratelimit-unified-7d-utilization": "0.55",
            "anthropic-ratelimit-unified-7d-reset": "1792796400",
            "anthropic-ratelimit-unified-status": "allowed",
        ]
        let usage = try XCTUnwrap(RouterLogic.unifiedUsage(headers, credential: "fp", accountID: nil, at: Date()))
        XCTAssertEqual(usage.sessionUtilization ?? 0, 4, accuracy: 0.0001)
        XCTAssertEqual(usage.weeklyUtilization ?? 0, 55, accuracy: 0.0001)
        XCTAssertEqual(usage.weeklyReset, Date(timeIntervalSince1970: 1_792_796_400))
        XCTAssertNil(RouterLogic.unifiedUsage([:], credential: "fp", accountID: nil, at: Date()))
    }

    func testRouteTargetsDescribeBackendsWithoutProviderCodeInTheRouter() {
        let backend = RouteTarget.kimi.backend(model: nil, maxContextTokens: nil)
        XCTAssertEqual(backend.model, "k3")
        XCTAssertEqual(backend.auth, .bearer)
        XCTAssertEqual(backend.messagesURL?.absoluteString, "https://api.kimi.ai/coding/v1/messages")
        XCTAssertFalse(backend.validatesThinkingSignatures)
        XCTAssertEqual(RouteTarget.available(for: .claudeCode).map(\.id), ["kimi"])
        XCTAssertTrue(RouteTarget.available(for: .kimi).isEmpty)
    }

    func testStreamedSignaturesAndUsageAreCollectedAcrossChunkBoundaries() {
        let stream = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":5000,"output_tokens":1}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"AB"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"CD"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}

        """
        let scanner = SSEScanner()
        var found: [String] = []
        let bytes = Data(stream.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + 7)
            found += scanner.feed(bytes[index..<end])
            index = end
        }
        found += scanner.finish()
        XCTAssertEqual(found, ["ABCD"])
        XCTAssertEqual(scanner.counts.context, 5_210)
        XCTAssertEqual(scanner.counts.cacheWrite, 200)
        XCTAssertEqual(scanner.counts.output, 42)
    }
}

final class UsageLearningTests: XCTestCase {
    func testRequestCostIsLearnedFromTokensAndTheFollowingReading() {
        var model = TurnCostModel()
        let account = UUID()
        model.recordReading(account: account, session: 10)
        for _ in 0..<4 {
            model.recordRequest(session: "s", account: account, context: 1_000_000, cacheWrite: 100_000, output: 20_000, at: Date())
        }
        // Weighted per request: 900k × 0.1 + 100k × 1.25 + 20k × 5 = 315k.
        model.recordReading(account: account, session: 16.3)
        XCTAssertEqual(model.percentPerMillion ?? 0, 6.3 / 1.26, accuracy: 0.01)
        XCTAssertEqual(model.expectedRequestCost(session: "s"), 0.315 * 6.3 / 1.26, accuracy: 0.01)
        XCTAssertGreaterThan(model.switchCost(sessionsOn: nil, now: Date()), 0)
    }

    func testDemandForecastLearnsByHourOfWeekAndFillsSilentHours() {
        var forecast = DemandForecast()
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        forecast.record(weeklyRise: 3, at: start)
        forecast.record(weeklyRise: 2, at: start.addingTimeInterval(30 * 60))
        forecast.record(weeklyRise: 1, at: start.addingTimeInterval(3 * 60 * 60))
        XCTAssertEqual(forecast.buckets[DemandForecast.hourOfWeek(start)], 5)
        XCTAssertEqual(forecast.buckets[DemandForecast.hourOfWeek(start.addingTimeInterval(3600))], 0)
        XCTAssertFalse(forecast.isTrained)
    }

    func testSimulatorServesInParallelWhatOneAccountsSessionCapCannot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = (0..<3).map { _ in
            QuotaSimulator.Account(id: UUID(), session: 0, sessionReset: nil, weekly: 0,
                                   weeklyReset: now.addingTimeInterval(7 * 86_400), sessionPerWeekly: 8)
        }
        var simulator = QuotaSimulator()
        simulator.horizon = 5 * 3600
        // 6 weekly-% per hour exceeds one account's 2.5 per hour session cap.
        let serial = simulator.run(accounts: accounts, strategy: .preferring([accounts[0].id]), demand: { _ in 6 }, start: now)
        let parallel = simulator.run(accounts: accounts, strategy: .parallel, demand: { _ in 6 }, start: now)
        XCTAssertEqual(serial.unmet, 0, accuracy: 0.01, "work moves on to the next account when one is full")
        XCTAssertEqual(parallel.served, 30, accuracy: 0.01)
        XCTAssertEqual(parallel.unmet, 0, accuracy: 0.01)
        let overloaded = simulator.run(accounts: [accounts[0]], strategy: .earliestDeadline, demand: { _ in 6 }, start: now)
        XCTAssertGreaterThan(overloaded.unmet, 15)
        XCTAssertNotNil(overloaded.firstShortfall)
    }

    func testAllowanceLeftWhenAWindowResetsCountsAsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = QuotaSimulator.Account(id: UUID(), session: 0, sessionReset: nil, weekly: 60,
                                             weeklyReset: now.addingTimeInterval(3600), sessionPerWeekly: 8)
        var simulator = QuotaSimulator()
        simulator.horizon = 2 * 3600
        let outcome = simulator.run(accounts: [account], strategy: .earliestDeadline, demand: { _ in 0 }, start: now)
        XCTAssertEqual(outcome.expired, 40, accuracy: 0.01)
    }
}

final class TOMLHookConfigTests: XCTestCase {
    func testMarkedHookTablesAreAddedAndRemovedWithoutTouchingOtherLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-\(UUID().uuidString).toml")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("accountdock-hooks-backup"))
        }
        let original = """
        default_model = "kimi-code/k3"

        [[hooks]]
        event = "Stop"
        command = "other tool"
        timeout = 10

        [providers."managed:kimi-code"]
        type = "kimi"
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        try TOMLHookConfig.install(at: url, events: ["UserPromptSubmit", "Stop"], command: "/bin/sh '/a b/hook.sh' \"x\"", timeout: 5, marker: "# accountdock-hook")
        XCTAssertTrue(TOMLHookConfig.hasHooks(at: url, events: ["UserPromptSubmit", "Stop"], marker: "# accountdock-hook"))
        XCTAssertFalse(TOMLHookConfig.hasHooks(at: url, events: ["PreToolUse"], marker: "# accountdock-hook"))
        let installed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(installed.contains(#"command = "/bin/sh '/a b/hook.sh' \"x\"""#))
        try TOMLHookConfig.install(at: url, events: ["UserPromptSubmit", "Stop"], command: "c", timeout: 5, marker: "# accountdock-hook")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "# accountdock-hook").count - 1, 2, "reinstalling replaces")
        try TOMLHookConfig.uninstall(at: url, marker: "# accountdock-hook")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       original.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
