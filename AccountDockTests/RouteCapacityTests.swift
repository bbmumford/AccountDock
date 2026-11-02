import XCTest
@testable import AccountDock

final class RouteCapacityTests: XCTestCase {
    func testThreadRequestsGetTheReplyThatMakesClaudeCodeResendWhole() throws {
        XCTAssertTrue(RouterLogic.carriesThread(["thread": ["type": "continue", "previous_message_id": "m"]]))
        XCTAssertFalse(RouterLogic.carriesThread(["messages": []]))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: RouterLogic.threadUnsupportedBody(backend: "Kimi")) as? [String: Any])
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual((error["details"] as? [String: Any])?["error_code"] as? String, "thread_unsupported_request")
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
    }

    func testDeferredToolsAndServerBlocksAreRemovedForATargetWithoutThem() {
        let body: [String: Any] = [
            "tools": [
                ["name": "Bash"],
                ["name": "Used", "defer_loading": true],
                ["name": "Unused", "defer_loading": true],
                ["type": "tool_search_tool_regex_20251119", "name": "tool_search"],
            ],
            "messages": [
                ["role": "assistant", "content": [
                    ["type": "server_tool_use", "id": "s1", "name": "tool_search"],
                    ["type": "tool_use", "id": "t1", "name": "Used"],
                ]],
                ["role": "user", "content": [
                    ["type": "tool_search_tool_result", "tool_use_id": "s1"],
                    ["type": "tool_result", "tool_use_id": "t1", "content": [["type": "tool_reference", "tool_name": "Used"]]],
                ]],
                ["role": "assistant", "content": [["type": "server_tool_use", "id": "s2", "name": "tool_search"]]],
            ],
        ]
        let cleaned = RouterLogic.withoutDeferredTools(body)
        let tools = cleaned["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["Bash", "Used"])
        XCTAssertNil(tools[1]["defer_loading"])
        let messages = cleaned["messages"] as? [[String: Any]] ?? []
        let first = messages[0]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(first.compactMap { $0["type"] as? String }, ["tool_use"])
        let second = messages[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(second.compactMap { $0["type"] as? String }, ["tool_result"])
        let inner = second[0]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(inner.first?["type"] as? String, "text")
        let third = messages[2]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(third.first?["type"] as? String, "text", "an emptied message keeps a text block")
    }

    func testOlderRouterStatesKeepAnthropicsThreadsAndGiveTargetsNone() throws {
        let json = #"{"backends":[{"id":"anthropic","baseURL":"https://api.anthropic.com"},{"id":"kimi","baseURL":"https://api.kimi.ai/coding/"}]}"#
        let state = try RouterConfig.decoder().decode(RouterState.self, from: Data(json.utf8))
        XCTAssertEqual(state.backend("anthropic")?.acceptsMessageThreads, true)
        XCTAssertEqual(state.backend("anthropic")?.acceptsDeferredTools, true)
        XCTAssertEqual(state.backend("kimi")?.acceptsMessageThreads, false)
        XCTAssertNil(state.backend("kimi")?.maxContextTokens)
        let kimi = RouteTarget.kimi.backend(model: nil, maxContextTokens: nil)
        XCTAssertEqual(kimi.maxContextTokens, RouteTarget.kimi.defaultMaxContextTokens(model: nil))
        XCTAssertFalse(kimi.acceptsDeferredTools)
    }

    func testOnlyModelsWithAMillionTokenContextAreRouteDestinations() {
        let kimi = RouteTarget.kimi
        XCTAssertEqual(kimi.routableModels.map(\.id), ["k3", "k3.1-pro", "k3.1-pro-highspeed", "kimi-for-coding"])
        XCTAssertEqual(kimi.model("k3-256k")?.id, "k3", "a model too small for a route falls back to the default")
        XCTAssertEqual(kimi.backend(model: "k3-256k", maxContextTokens: nil).model, "k3")
        XCTAssertEqual(kimi.defaultMaxContextTokens(model: "k3.1-pro"), Int(1_048_576 * RouteTarget.contextHeadroom))
        XCTAssertGreaterThan(kimi.defaultMaxContextTokens(model: nil), 900_000, "a 900k-token session can be routed")
        XCTAssertEqual(RouteTarget.available(for: .claudeCode).map(\.id), ["kimi"])
        XCTAssertTrue(RouteTarget.available(for: .codex).isEmpty, "the router does not speak Codex's protocol")
    }

    func testLateUsageInTheStreamIsCounted() {
        let scanner = SSEScanner()
        _ = scanner.feed(Data("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":0}}}\n".utf8))
        _ = scanner.feed(Data("data: {\"type\":\"message_delta\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":900,\"output_tokens\":7}}\n".utf8))
        XCTAssertEqual(scanner.counts, RouterLogic.TokenCounts(context: 1_000, cacheWrite: 0, cacheRead: 900, output: 7))
    }

    func testATargetIsNotUsedWhenItWouldNotLastOrIsDownToItsReserve() {
        // 23 million tokens in six minutes at 4.2% per million: a full window in minutes.
        let fast = RouteCapacity.evaluate(targetName: "Kimi", sessionPercent: 0, reservePercent: 25,
                                          tokensPerMinute: 3_800_000, percentPerMillion: 4.2, minimumMinutes: 15)
        XCTAssertFalse(fast.serves)
        XCTAssertEqual(fast.minutes ?? 0, 75 / (3.8 * 4.2), accuracy: 0.01)
        let slow = RouteCapacity.evaluate(targetName: "Kimi", sessionPercent: 10, reservePercent: 25,
                                          tokensPerMinute: 200_000, percentPerMillion: 4.2, minimumMinutes: 15)
        XCTAssertTrue(slow.serves)
        let reserved = RouteCapacity.evaluate(targetName: "Kimi", sessionPercent: 76, reservePercent: 25,
                                              tokensPerMinute: 0, percentPerMillion: 4.2, minimumMinutes: 15)
        XCTAssertFalse(reserved.serves)
        XCTAssertNotNil(reserved.reason)
    }

    func testPeakDemandRemembersTheBusiestStretchBeforeAPause() {
        let now = Date()
        var requests: [RecentRouterRequest] = []
        for minute in 0..<5 {
            requests.append(RecentRouterRequest(at: now.addingTimeInterval(Double(-40 + minute) * 60), session: "s",
                                                backend: "anthropic", context: 300_000, output: 1_000))
        }
        requests.append(RecentRouterRequest(at: now.addingTimeInterval(-30 * 60), session: "big",
                                            backend: "anthropic", context: 900_000, output: 0))
        XCTAssertEqual(RouteCapacity.tokensPerMinute(requests, maxContext: nil, now: now), 0)
        XCTAssertEqual(RouteCapacity.peakTokensPerMinute(requests, maxContext: 400_000, now: now), 301_000, accuracy: 1)
    }

    func testTheCostOfRoutedTokensIsLearnedFromTheTargetsReadings() {
        var model = RouteTargetCostModel()
        model.recordReading(session: 3.5)
        model.recordRouted(tokens: 23_000_000)
        XCTAssertEqual(model.estimatedSession(reading: 3.5, defaultRatio: 4), 95.5, accuracy: 0.01)
        model.recordReading(session: 100)
        XCTAssertEqual(model.percentPerMillion ?? 0, 96.5 / 23, accuracy: 0.001)
        XCTAssertEqual(model.pendingTokens, 0)
        model.recordReading(session: 0)
        XCTAssertEqual(model.lastSession, 0)
    }

    func testRoutedModelsBelongToTheirTargetsProvider() {
        XCTAssertTrue(RouteTarget.routedModels(for: .kimi).contains("k3"))
        XCTAssertTrue(RouteTarget.routedModels(for: .claudeCode).isEmpty)
        XCTAssertTrue(RouteTarget.allRoutedModels.contains("kimi-for-coding"))
    }
}
