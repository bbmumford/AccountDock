import XCTest
@testable import AccountDock

/// The bridge's Claude dialect, on a fixed request and a fixed stream: what
/// Anthropic's Messages API is sent for a Codex request, and the Responses
/// events Codex gets back, thinking included so it returns to Claude with
/// the conversation's next request.
final class ClaudeBridgeTests: XCTestCase {
    private func json(_ text: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private var earlierThinking: [String: Any] {
        ResponsesBridge.reasoningItem(thinking: ["type": "thinking", "thinking": "I should list.", "signature": "sig-1"], id: "rs_0")
    }

    private var request: [String: Any] {
        [
            "model": "gpt-5-codex",
            "instructions": "Be brief.",
            "input": [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "List the files."]]],
                earlierThinking,
                ["type": "function_call", "call_id": "toolu_1", "name": "shell", "arguments": #"{"command":["ls"]}"#],
                ["type": "function_call_output", "call_id": "toolu_1", "output": "a.swift"],
                // OpenAI's own reasoning has no counterpart and is left out.
                ["type": "reasoning", "id": "rs_x", "summary": [], "encrypted_content": "gAAAA-openai"],
            ],
            "tools": [["type": "function", "name": "shell", "description": "Run a command.",
                       "parameters": ["type": "object", "properties": ["command": ["type": "array"]]]]],
            "tool_choice": "required",
            "parallel_tool_calls": false,
            "temperature": 0.2,
            "reasoning": ["effort": "minimal"],
            "max_output_tokens": 4000,
            "stream": true,
        ]
    }

    func testACodexRequestBecomesTheGoldenClaudeRequest() throws {
        let (body, _) = ResponsesBridge.messagesRequest(request, model: "claude-opus-5-5", dialect: .claude)
        XCTAssertEqual(body as NSDictionary, try json(#"""
        {
          "model": "claude-opus-5-5",
          "max_tokens": 4000,
          "stream": true,
          "system": [{"type": "text", "text": "Be brief.", "cache_control": {"type": "ephemeral"}}],
          "messages": [
            {"role": "user", "content": [{"type": "text", "text": "List the files."}]},
            {"role": "assistant", "content": [
              {"type": "thinking", "thinking": "I should list.", "signature": "sig-1"},
              {"type": "tool_use", "id": "toolu_1", "name": "shell", "input": {"command": ["ls"]}}
            ]},
            {"role": "user", "content": [
              {"type": "tool_result", "tool_use_id": "toolu_1", "content": "a.swift", "cache_control": {"type": "ephemeral"}}
            ]}
          ],
          "tools": [{"name": "shell", "description": "Run a command.",
                     "input_schema": {"type": "object", "properties": {"command": {"type": "array"}}}}],
          "tool_choice": {"type": "auto", "disable_parallel_tool_use": true},
          "output_config": {"effort": "low"}
        }
        """#))
        // A compatible backend keeps sampling and forced tool use, and
        // never sees the thinking.
        let (compatible, _) = ResponsesBridge.messagesRequest(request, model: "k3")
        XCTAssertEqual(compatible["temperature"] as? Double, 0.2)
        XCTAssertEqual((compatible["tool_choice"] as? [String: Any])?["type"] as? String, "any")
        XCTAssertNil(compatible["output_config"])
        let assistant = (compatible["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        XCTAssertEqual(assistant?.map { $0["type"] as? String }, ["tool_use"])
    }

    static let stream = [
        #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":300,"output_tokens":1}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-2"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Running ls."}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_2","name":"shell","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"[\"ls\"]}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        #"{"type":"message_stop"}"#,
    ].map { "event: x\ndata: \($0)\n\n" }.joined()

    /// The events of a translated stream as (name, payload) pairs.
    static func events(_ data: Data) -> [(String, NSDictionary)] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").compactMap { chunk in
            let lines = chunk.split(separator: "\n")
            guard let name = lines.first(where: { $0.hasPrefix("event: ") })?.dropFirst(7),
                  let payload = lines.first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                  let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? NSDictionary else { return nil }
            return (String(name), object)
        }
    }

    func testAClaudeStreamBecomesTheGoldenResponsesEvents() throws {
        let tools = ResponsesBridge.messagesRequest(request, model: "claude-opus-5-5", dialect: .claude).tools
        var next = 0
        let translator = ResponsesStreamTranslator(tools: tools, responseID: "resp_test", dialect: .claude,
                                                   makeID: { next += 1; return "\(next)" })
        var output = Data()
        // Split mid-line, as a network read can be.
        let bytes = Data(Self.stream.utf8)
        output.append(translator.feed(bytes.prefix(333)))
        output.append(translator.feed(bytes.dropFirst(333)))
        let thinking = ResponsesBridge.reasoningItem(thinking: ["type": "thinking", "thinking": "Plan.", "signature": "sig-2"], id: "rs_1")
        let expected: [(String, Any)] = [
            ("response.created", ["response": ["id": "resp_test", "status": "in_progress", "output": []]]),
            ("response.output_item.added", ["output_index": 0, "item": thinking]),
            ("response.output_item.done", ["output_index": 0, "item": thinking]),
            ("response.output_item.added", ["output_index": 1, "item": ["type": "message", "id": "msg_2", "role": "assistant",
                                                                        "status": "in_progress", "content": []]]),
            ("response.output_text.delta", ["item_id": "msg_2", "output_index": 1, "content_index": 0, "delta": "Running ls."]),
            ("response.output_item.done", ["output_index": 1, "item": ["type": "message", "id": "msg_2", "role": "assistant",
                                                                       "status": "completed",
                                                                       "content": [["type": "output_text", "text": "Running ls.", "annotations": []]]]]),
            ("response.output_item.added", ["output_index": 2, "item": ["type": "function_call", "id": "fc_3", "call_id": "toolu_2",
                                                                        "name": "shell", "status": "in_progress", "arguments": ""]]),
            ("response.output_item.done", ["output_index": 2, "item": ["type": "function_call", "id": "fc_3", "call_id": "toolu_2",
                                                                       "name": "shell", "status": "completed",
                                                                       "arguments": #"{"command":["ls"]}"#]]),
            ("response.completed", ["response": ["id": "resp_test", "status": "completed", "output": [],
                                                 "usage": ["input_tokens": 420,
                                                           "input_tokens_details": ["cached_tokens": 300, "cache_write_tokens": 20],
                                                           "output_tokens": 42, "output_tokens_details": ["reasoning_tokens": 0],
                                                           "total_tokens": 462]]]),
        ]
        let events = Self.events(output)
        XCTAssertEqual(events.map(\.0), expected.map(\.0))
        for (index, (name, payload)) in expected.enumerated() where index < events.count {
            var object = payload as? [String: Any] ?? [:]
            object["type"] = name
            XCTAssertEqual(events[index].1, object as NSDictionary, name)
        }
        XCTAssertEqual(translator.outcome, .completed)
        XCTAssertEqual(translator.counts.context, 420)
        // The thinking goes back to Claude with the next request.
        let following = request.merging(["input": [thinking]]) { $1 }
        let replayed = ResponsesBridge.messagesRequest(following, model: "claude-opus-5-5", dialect: .claude).body
        let blocks = (replayed["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertTrue(blocks?.contains { $0["type"] as? String == "thinking" && $0["signature"] as? String == "sig-2" } == true)
    }

    func testTheClaudeTargetIsOfferedOnlyToABridgedProvider() throws {
        XCTAssertTrue(RouteTarget.available(for: .codex).contains { $0.id == "claude" })
        XCTAssertFalse(RouteTarget.available(for: .claudeCode).contains { $0.id == "claude" })
        XCTAssertFalse(RouteTarget.allRoutedModels.contains("claude-opus-5-5"), "Claude Code's own usage keeps its models")
        let backend = RouteTarget.claude.backend(model: nil, maxContextTokens: nil)
        XCTAssertEqual(backend.model, "claude-opus-5-5")
        XCTAssertEqual(backend.dialect, .claude)
        XCTAssertTrue(backend.poolCredentials)
        XCTAssertTrue(backend.reportsUnifiedUsage)
        XCTAssertEqual(backend.betaFeatures, ["oauth-2025-04-20"])
        XCTAssertEqual(backend.maxContextTokens, 900_000)
        let decoded = try RouterConfig.decoder().decode(RouterBackend.self, from: RouterConfig.encoder().encode(backend))
        XCTAssertEqual(decoded, backend)
    }

    func testPoolAccountsServeABridgedSessionBeforeTheTargetsOwnToken() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = RouterState()
        state.pool = [RouterPoolMember(accountID: "a", tokenFile: "ta"), RouterPoolMember(accountID: "b", tokenFile: "tb")]
        let tokens = ["ta": RouterToken(accessToken: "A", expiresAt: now.addingTimeInterval(3600)),
                      "tb": RouterToken(accessToken: "B", expiresAt: now.addingTimeInterval(3600))]
        let pool = RouterLogic.PoolView(unavailable: [], load: ["a": 2], token: { tokens[$0] })
        let own = RouterToken(accessToken: "OWN", expiresAt: now.addingTimeInterval(3600))
        let backend = RouteTarget.claude.backend(model: nil, maxContextTokens: nil)
        let previous = RouterSessionRecord(backend: "claude", account: "a", lastServed: now, cacheLifetime: nil)
        let kept = RouterLogic.bridgeCredentials(backend: backend, state: state, previous: previous, startsTurn: true,
                                                 pool: pool, ownToken: own, now: now)
        XCTAssertEqual(kept.map(\.account), ["a", "b"], "the session keeps its account; the next takes a refusal")
        XCTAssertEqual(kept.map(\.token), ["A", "B"])
        let fresh = RouterLogic.bridgeCredentials(backend: backend, state: state, previous: nil, startsTurn: true,
                                                  pool: pool, ownToken: own, now: now)
        XCTAssertEqual(fresh.first?.account, "b", "a new session goes by load")
        let unpooled = RouterLogic.bridgeCredentials(backend: backend, state: RouterState(), previous: nil, startsTurn: true,
                                                     pool: pool, ownToken: own, now: now)
        XCTAssertEqual(unpooled.map(\.token), ["OWN"])
        var kimi = RouteTarget.kimi.backend(model: nil, maxContextTokens: nil)
        kimi.poolCredentials = false
        XCTAssertEqual(RouterLogic.bridgeCredentials(backend: kimi, state: state, previous: nil, startsTurn: true,
                                                     pool: pool, ownToken: own, now: now).map(\.token), ["OWN"])
        XCTAssertTrue(RouterLogic.bridgeCredentials(backend: kimi, state: state, previous: nil, startsTurn: true, pool: pool,
                                                    ownToken: RouterToken(accessToken: "OLD", expiresAt: now), now: now).isEmpty)
    }
}
