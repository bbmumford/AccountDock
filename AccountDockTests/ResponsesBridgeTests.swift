import XCTest
@testable import AccountDock

/// `ResponsesBridge` serves a Responses client from a Messages backend:
/// these pin the request it sends the backend, the events it writes the
/// client for each way a backend's stream can end, and the setting that
/// lets a provider's CLI reach it.
final class ResponsesBridgeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A Messages stream of `events`, one JSON object per event.
    private func stream(_ events: [String]) -> Data {
        Data(events.map { "event: x\ndata: \($0)\n\n" }.joined().utf8)
    }

    /// The Responses events in `data`, checking each frame names its type.
    private func events(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { frame in
            let lines = frame.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 2, file: file, line: line)
            let event = try object(String(lines[1].dropFirst("data: ".count)))
            XCTAssertEqual(lines[0], "event: \(event["type"] as? String ?? "")", file: file, line: line)
            return event
        }
    }

    private func types(_ events: [[String: Any]]) -> [String] { events.compactMap { $0["type"] as? String } }

    private func response(_ event: [String: Any]?) -> [String: Any] { event?["response"] as? [String: Any] ?? [:] }

    private func dictionary(_ value: [String: Any]) -> NSDictionary { value as NSDictionary }

    private let opening = #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_1h_input_tokens":5},"output_tokens":1}}}"#

    // MARK: - Request

    func testARequestMapsToAMessagesRequest() throws {
        let request = try object(#"""
        {
          "model": "gpt-x", "instructions": "Be brief.", "stream": true, "max_output_tokens": 900,
          "tool_choice": "required", "parallel_tool_calls": false, "prompt_cache_key": "thread-1",
          "tools": [
            {"type": "function", "name": "shell", "description": "Run a command", "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}}},
            {"type": "custom", "name": "apply_patch", "description": "Patch files"},
            {"type": "namespace", "name": "mcp__files", "tools": [{"type": "function", "name": "read", "description": "Read", "parameters": {"properties": {}}}]},
            {"type": "web_search"}
          ],
          "input": [
            {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "Use tools."}]},
            {"type": "message", "role": "user", "content": [
              {"type": "input_text", "text": "Look at this"},
              {"type": "input_image", "image_url": "data:image/jpeg;base64,QUJD"},
              {"type": "input_image", "image_url": "https://example.invalid/a.png"}]},
            {"type": "reasoning", "encrypted_content": "opaque"},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Reading."}]},
            {"type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{\"cmd\":\"ls\"}"},
            {"type": "function_call", "call_id": "c2", "namespace": "mcp__files", "name": "read", "arguments": ""},
            {"type": "custom_tool_call", "call_id": "c3", "name": "apply_patch", "input": "*** Begin Patch"},
            {"type": "function_call_output", "call_id": "c1", "output": "a.txt"},
            {"type": "function_call_output", "call_id": "c2", "output": [{"type": "input_text", "text": "body"}, {"type": "input_image", "image_url": "data:image/png;base64,REVG"}]},
            {"type": "custom_tool_call_output", "call_id": "c3", "output": "Done"},
            {"type": "function_call_output", "call_id": "unknown", "output": "orphan"},
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Next"}]}
          ]
        }
        """#)
        let (body, tools) = ResponsesBridge.messagesRequest(request, model: "k3")
        let expected = try object(#"""
        {
          "model": "k3", "max_tokens": 900, "stream": true,
          "system": [{"type": "text", "text": "Be brief.\n\nUse tools.", "cache_control": {"type": "ephemeral"}}],
          "tool_choice": {"type": "any", "disable_parallel_tool_use": true},
          "tools": [
            {"name": "shell", "description": "Run a command", "input_schema": {"type": "object", "properties": {"cmd": {"type": "string"}}}},
            {"name": "apply_patch", "description": "Patch files\n\nPass the tool's whole input as the `input` string, exactly as the tool expects it.",
             "input_schema": {"type": "object", "properties": {"input": {"type": "string"}}, "required": ["input"]}},
            {"name": "mcp__files__read", "description": "Read", "input_schema": {"type": "object", "properties": {}}}
          ],
          "messages": [
            {"role": "user", "content": [
              {"type": "text", "text": "Look at this"},
              {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "QUJD"}},
              {"type": "image", "source": {"type": "url", "url": "https://example.invalid/a.png"}}]},
            {"role": "assistant", "content": [
              {"type": "text", "text": "Reading."},
              {"type": "tool_use", "id": "c1", "name": "shell", "input": {"cmd": "ls"}},
              {"type": "tool_use", "id": "c2", "name": "mcp__files__read", "input": {}},
              {"type": "tool_use", "id": "c3", "name": "apply_patch", "input": {"input": "*** Begin Patch"}}]},
            {"role": "user", "content": [
              {"type": "tool_result", "tool_use_id": "c1", "content": "a.txt"},
              {"type": "tool_result", "tool_use_id": "c2", "content": [
                {"type": "text", "text": "body"},
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "REVG"}}]},
              {"type": "tool_result", "tool_use_id": "c3", "content": "Done"},
              {"type": "text", "text": "Next", "cache_control": {"type": "ephemeral"}}]}
          ]
        }
        """#)
        XCTAssertEqual(dictionary(body), dictionary(expected))
        XCTAssertEqual(tools.tool("mcp__files__read"), .init(namespace: "mcp__files", name: "read", custom: false))
        XCTAssertEqual(tools.tool("apply_patch"), .init(namespace: nil, name: "apply_patch", custom: true))
        XCTAssertFalse(ResponsesBridge.startsTurn(try object(#"{"input":[{"type":"function_call_output","call_id":"c"}]}"#)))
        XCTAssertTrue(ResponsesBridge.startsTurn(request))
        XCTAssertEqual(ResponsesBridge.sessionID(request), "thread-1")
    }

    func testToolsListedInTheInputAreOffered() throws {
        let request = try object(#"""
        {"model": "gpt-x", "tool_choice": "auto", "input": [
          {"type": "additional_tools", "role": "developer", "tools": [
            {"type": "custom", "name": "exec", "description": "Run code", "format": {"type": "grammar", "syntax": "lark", "definition": "start: /.+/"}},
            {"type": "function", "name": "wait", "description": "Wait", "strict": false, "parameters": {"type": "object", "properties": {}}},
            {"type": "namespace", "name": "collaboration", "description": "Agents", "tools": [
              {"type": "function", "name": "list_agents", "description": "List", "parameters": {"type": "object", "properties": {}}}]}]},
          {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "Rules."}]},
          {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}]}
        """#)
        let (body, tools) = ResponsesBridge.messagesRequest(request, model: nil)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["exec", "wait", "collaboration__list_agents"])
        XCTAssertEqual((body["tool_choice"] as? [String: Any]).map(dictionary), dictionary(["type": "auto"]))
        XCTAssertEqual(body["model"] as? String, "gpt-x")
        XCTAssertEqual(body["max_tokens"] as? Int, ResponsesBridge.defaultMaxOutputTokens)
        XCTAssertEqual((body["system"] as? [[String: Any]])?.first?["text"] as? String, "Rules.")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(tools.tool("exec")?.custom, true)
        XCTAssertEqual(tools.tool("collaboration__list_agents")?.namespace, "collaboration")
    }

    func testAToolNameTheBackendCannotTakeIsShortenedAndMapsBack() {
        var names = ResponsesBridge.ToolNames()
        let long = String(repeating: "n", count: 70)
        let wire = names.wireName(namespace: "space.one", name: long, custom: false)
        XCTAssertLessThanOrEqual(wire.count, 64)
        XCTAssertFalse(wire.contains("."))
        XCTAssertEqual(names.wireName(namespace: "space.one", name: long, custom: false), wire, "one name per tool")
        XCTAssertEqual(names.tool(wire), .init(namespace: "space.one", name: long, custom: false))
    }

    // MARK: - Reply

    func testANormalReplyBecomesResponsesEvents() throws {
        let translator = ResponsesStreamTranslator(tools: .init(), responseID: "resp_test")
        let output = try events(translator.feed(stream([
            opening,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ])))
        XCTAssertEqual(types(output), ["response.created", "response.output_item.added", "response.output_text.delta",
                                       "response.output_text.delta", "response.output_item.done", "response.completed"])
        XCTAssertEqual(response(output[0])["id"] as? String, "resp_test")
        XCTAssertEqual(output[2]["delta"] as? String, "Hel")
        let item = try XCTUnwrap(output[4]["item"] as? [String: Any])
        XCTAssertEqual(output[4]["output_index"] as? Int, 0, "thinking takes no output index")
        XCTAssertEqual(item["id"] as? String, output[2]["item_id"] as? String)
        let content: [[String: Any]] = [["type": "output_text", "text": "Hello", "annotations": [String]()]]
        XCTAssertEqual(dictionary(item), dictionary([
            "type": "message", "id": item["id"] ?? "", "role": "assistant", "status": "completed", "content": content,
        ]))
        let completed = response(output[5])
        XCTAssertEqual(completed["id"] as? String, "resp_test")
        XCTAssertEqual(completed["status"] as? String, "completed")
        XCTAssertEqual((completed["usage"] as? [String: Any]).map(dictionary), dictionary([
            "input_tokens": 60, "input_tokens_details": ["cached_tokens": 30, "cache_write_tokens": 20],
            "output_tokens": 7, "output_tokens_details": ["reasoning_tokens": 0], "total_tokens": 67,
        ]))
        XCTAssertEqual(translator.outcome, .completed)
        XCTAssertFalse(translator.failed)
        XCTAssertTrue(translator.finish().isEmpty, "a closed response is not closed again")
    }

    func testToolCallsKeepTheClientsNamesAndForms() throws {
        var names = ResponsesBridge.ToolNames()
        let namespaced = names.wireName(namespace: "mcp__files", name: "read", custom: false)
        let custom = names.wireName(namespace: nil, name: "apply_patch", custom: true)
        let translator = ResponsesStreamTranslator(tools: names, responseID: "resp_test")
        let output = try events(translator.feed(stream([
            opening,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"\#(namespaced)","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"\#(custom)","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"input\":\"*** Begin Patch\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ])))
        XCTAssertEqual(types(output), ["response.created", "response.output_item.added", "response.output_item.done",
                                       "response.output_item.added", "response.output_item.done", "response.completed"])
        let added = try XCTUnwrap(output[1]["item"] as? [String: Any])
        XCTAssertEqual(added["status"] as? String, "in_progress")
        XCTAssertEqual(added["arguments"] as? String, "")
        let call = try XCTUnwrap(output[2]["item"] as? [String: Any])
        XCTAssertEqual(dictionary(call), dictionary([
            "type": "function_call", "id": call["id"] ?? "", "call_id": "toolu_1", "namespace": "mcp__files", "name": "read",
            "arguments": #"{"path":"a.txt"}"#, "status": "completed",
        ]))
        let patch = try XCTUnwrap(output[4]["item"] as? [String: Any])
        XCTAssertEqual(output[4]["output_index"] as? Int, 1)
        XCTAssertEqual(dictionary(patch), dictionary([
            "type": "custom_tool_call", "id": patch["id"] ?? "", "call_id": "toolu_2", "name": "apply_patch",
            "input": "*** Begin Patch", "status": "completed",
        ]))
        XCTAssertEqual(translator.outcome, .completed)
    }

    func testABackendErrorBecomesAFailedResponse() throws {
        let translator = ResponsesStreamTranslator(tools: .init(), responseID: "resp_test")
        let output = try events(translator.feed(stream([
            opening,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Par"}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tial"}}"#,
            #"{"type":"message_stop"}"#,
        ])))
        XCTAssertEqual(types(output), ["response.created", "response.output_item.added", "response.output_text.delta", "response.failed"],
                       "nothing follows the failure, and the open item is not reported done")
        XCTAssertEqual(dictionary(response(output.last)), dictionary([
            "id": "resp_test", "status": "failed", "error": ["code": "server_is_overloaded", "message": "Overloaded"],
        ]))
        XCTAssertTrue(translator.failed)
        XCTAssertEqual(translator.outcome, .failed(code: "server_is_overloaded", message: "Overloaded"))
        XCTAssertTrue(translator.finish().isEmpty)
        XCTAssertTrue(translator.fail(code: "server_error", message: "late").isEmpty, "one closing event")

        let limited = ResponsesStreamTranslator(tools: .init(), responseID: "resp_limit")
        let refusal = try events(limited.feed(stream([#"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#])))
        XCTAssertEqual(types(refusal), ["response.failed"])
        XCTAssertEqual((response(refusal[0])["error"] as? [String: Any])?["code"] as? String, "rate_limit_exceeded")
    }

    func testATruncatedStreamFailsInsteadOfCompleting() throws {
        let translator = ResponsesStreamTranslator(tools: .init(), responseID: "resp_test")
        let partial = try events(translator.feed(stream([
            opening,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Running"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"cmd\":\"make bui"}}"#,
        ])))
        XCTAssertEqual(types(partial), ["response.created", "response.output_item.added", "response.output_text.delta",
                                        "response.output_item.done", "response.output_item.added"])
        XCTAssertNil(translator.outcome)
        let closing = try events(translator.finish())
        XCTAssertEqual(types(closing), ["response.failed"], "a cut-off tool call is never reported done")
        XCTAssertEqual(response(closing[0])["id"] as? String, "resp_test")
        XCTAssertEqual(response(closing[0])["status"] as? String, "failed")
        XCTAssertEqual((response(closing[0])["error"] as? [String: Any])?["code"] as? String, "server_error")
        XCTAssertTrue(translator.failed)
        XCTAssertEqual(translator.counts.context, 60, "what the backend counted before the cut is still reported")

        let empty = ResponsesStreamTranslator(tools: .init(), responseID: "resp_empty")
        XCTAssertEqual(types(try events(empty.finish())), ["response.failed"])
        XCTAssertTrue(empty.failed)
    }

    func testATransportFailureUsesTheResponsesOwnID() throws {
        let translator = ResponsesStreamTranslator(tools: .init())
        let created = try events(translator.feed(stream([opening])))
        let failure = try events(translator.fail(code: "server_error", message: "Kimi stopped replying"))
        let id = try XCTUnwrap(response(created[0])["id"] as? String)
        XCTAssertTrue(id.hasPrefix("resp_") && id.count > 20)
        XCTAssertEqual(response(failure[0])["id"] as? String, id)
        XCTAssertEqual(translator.outcome, .failed(code: "server_error", message: "Kimi stopped replying"))
    }

    func testAReplyStoppedAtTheOutputCapIsIncomplete() throws {
        let translator = ResponsesStreamTranslator(tools: .init(), responseID: "resp_test")
        let output = try events(translator.feed(stream([
            opening,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Long"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":32000}}"#,
            #"{"type":"message_stop"}"#,
        ])))
        XCTAssertEqual(types(output).last, "response.incomplete")
        XCTAssertFalse(types(output).contains("response.completed"))
        let closing = response(output.last)
        XCTAssertEqual(closing["status"] as? String, "incomplete")
        XCTAssertEqual((closing["incomplete_details"] as? [String: Any])?["reason"] as? String, "max_output_tokens")
        XCTAssertEqual((closing["usage"] as? [String: Any])?["output_tokens"] as? Int, 32_000)
        XCTAssertEqual(translator.outcome, .incomplete(reason: "max_output_tokens"))
        XCTAssertFalse(translator.failed)
    }

    // MARK: - Usage

    func testTheScannerAndTheTranslatorCountAStreamAlike() {
        let streams: [[String]] = [
            // Anthropic: input at the start, output at the end.
            [opening, #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#, #"{"type":"message_stop"}"#],
            // A backend that reports input only at the end, with nulls.
            [#"{"type":"message_start","message":{"usage":{"input_tokens":0,"output_tokens":0}}}"#,
             #"{"type":"message_delta","delta":{},"usage":{"input_tokens":100,"cache_read_input_tokens":400,"cache_creation_input_tokens":null,"output_tokens":12}}"#,
             #"{"type":"message_stop"}"#],
            // Closing totals without the cache breakdown keep the opening one's.
            [opening, #"{"type":"message_delta","delta":{},"usage":{"input_tokens":11,"cache_creation_input_tokens":21,"cache_read_input_tokens":31,"output_tokens":3}}"#],
            // A stream cut before its closing usage.
            [opening],
        ]
        let expected = [
            RouterLogic.TokenCounts(context: 60, cacheWrite: 20, cacheWriteLong: 5, cacheRead: 30, output: 7),
            RouterLogic.TokenCounts(context: 500, cacheWrite: 0, cacheWriteLong: 0, cacheRead: 400, output: 12),
            RouterLogic.TokenCounts(context: 63, cacheWrite: 21, cacheWriteLong: 5, cacheRead: 31, output: 3),
            RouterLogic.TokenCounts(context: 60, cacheWrite: 20, cacheWriteLong: 5, cacheRead: 30, output: 1),
        ]
        for (events, counts) in zip(streams, expected) {
            let scanner = SSEScanner()
            _ = scanner.feed(stream(events))
            let translator = ResponsesStreamTranslator(tools: .init())
            _ = translator.feed(stream(events))
            _ = translator.finish()
            XCTAssertEqual(scanner.counts, counts)
            XCTAssertEqual(translator.counts, scanner.counts)
        }
    }

    // MARK: - Held streams and entries

    func testAnErrorAfterAHeldResponsesStreamIsAFailedResponse() throws {
        XCTAssertTrue(ProviderPassthrough.isResponsesPath("/responses"))
        XCTAssertTrue(ProviderPassthrough.isResponsesPath("/responses?x=1"))
        XCTAssertFalse(ProviderPassthrough.isResponsesPath("/responses/compact"))
        XCTAssertFalse(ProviderPassthrough.isResponsesPath("/chat/completions"))

        let limit = Data(#"{"error":{"type":"usage_limit_reached","message":"limit"}}"#.utf8)
        let failed = try events(ProviderPassthrough.streamError(status: 429, body: limit, responses: true))
        XCTAssertEqual(types(failed), ["response.failed"])
        let reply = response(failed[0])
        XCTAssertEqual(reply["status"] as? String, "failed")
        XCTAssertTrue((reply["id"] as? String ?? "").hasPrefix("resp_"))
        XCTAssertEqual((reply["error"] as? [String: Any]).map(dictionary), dictionary(["code": "usage_limit_reached", "message": "limit"]))

        let plain = try events(ProviderPassthrough.streamError(status: 502, body: Data("no route".utf8), responses: true))
        XCTAssertEqual((response(plain[0])["error"] as? [String: Any]).map(dictionary), dictionary(["code": "server_error", "message": "no route"]))
        let refused = try events(ProviderPassthrough.streamError(status: 429, body: Data(), responses: true))
        XCTAssertEqual((response(refused[0])["error"] as? [String: Any])?["code"] as? String, "rate_limit_exceeded")
        XCTAssertTrue(String(decoding: ProviderPassthrough.streamError(status: 429, body: limit), as: UTF8.self).hasPrefix("data: {"),
                      "other endpoints keep the chat-completions error")
    }

    func testAPassthroughEntryHoldsRequestsUnlessItSaysNot() throws {
        let stored = Data(#"{"kimi":{"upstream":"https://api.kimi.ai/coding/v1","sessionField":"prompt_cache_key"}}"#.utf8)
        XCTAssertEqual(try RouterConfig.decoder().decode([String: ProviderPassthrough.Entry].self, from: stored)["kimi"]?.holdsRequests, true)
        let entry = ProviderPassthrough.Entry(upstream: "https://chatgpt.com/backend-api/codex", sessionField: "prompt_cache_key", holdsRequests: false)
        let decoded = try RouterConfig.decoder().decode(ProviderPassthrough.Entry.self, from: RouterConfig.encoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses")?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
    }

    func testAPassthroughRouteSurvivesTheStateFile() throws {
        var state = RouterState()
        state.passthroughRoutes["codex"] = PassthroughRoute(backend: RouteTarget.kimi.backend(model: nil, maxContextTokens: nil), routed: true, fallback: true)
        let decoded = try RouterConfig.decoder().decode(RouterState.self, from: RouterConfig.encoder().encode(state))
        XCTAssertEqual(decoded.passthroughRoutes, state.passthroughRoutes)
        XCTAssertEqual(decoded.passthroughRoutes["codex"]?.backend.tokenFile, "target-kimi")
        XCTAssertTrue(RouterState().passthroughRoutes.isEmpty)
    }

    // MARK: - The setting

    func testRoutingThroughTheBridgeIsOffUntilTheUserTurnsItOn() throws {
        let policy = ProviderFailoverPolicy.defaults(for: .codex)
        XCTAssertFalse(policy.routeThroughBridge)
        XCTAssertFalse(policy.usesBridge(for: .codex))
        let saved = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: Data(#"{"enabled":true,"suspendAgentsWhenExhausted":true}"#.utf8))
        XCTAssertFalse(saved.routeThroughBridge, "a policy saved before the setting existed leaves it off")

        var on = policy
        on.routeThroughBridge = true
        XCTAssertFalse(on.usesBridge(for: .codex), "no service chosen yet")
        on.routeTarget = "kimi"
        XCTAssertTrue(on.usesBridge(for: .codex))
        XCTAssertFalse(on.usesBridge(for: .claudeCode), "the routed provider needs no bridge")
        XCTAssertFalse(on.usesBridge(for: .kimi))
        XCTAssertEqual(try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(on)), on)
        var target = policy
        target.routeTarget = "kimi"
        XCTAssertFalse(target.usesBridge(for: .codex), "a stored target alone routes nothing")
    }

    func testACLIIsPointedAtTheRouterOnlyByItsOwnSetting() {
        let off = ProviderFailoverPolicy.defaults(for: .codex)
        var on = off
        on.routeThroughBridge = true
        on.routeTarget = "kimi"
        let everyone = Set(AIProviderType.implementedProviders)
        XCTAssertFalse(ProviderRequestHold.wantsRouter(.codex, pausing: everyone, routerRunning: true, policy: off, agentInstalled: true),
                       "pausing Codex with the router running leaves its config alone")
        XCTAssertTrue(ProviderRequestHold.wantsRouter(.codex, pausing: [], routerRunning: false, policy: on, agentInstalled: true))
        XCTAssertFalse(ProviderRequestHold.wantsRouter(.codex, pausing: [], routerRunning: true, policy: on, agentInstalled: false),
                       "not before the router's agent exists")
        XCTAssertFalse(ProviderRequestHold.wantsRouter(.kimi, pausing: everyone, routerRunning: true, policy: on, agentInstalled: true),
                       "Kimi Code drops its sign-in at the router")
        XCTAssertFalse(ProviderRequestHold.wantsRouter(.claudeCode, pausing: everyone, routerRunning: true, policy: on, agentInstalled: true))

        let hold = AIProviderType.codex.capabilities.requestHold
        XCTAssertEqual(hold?.key, "openai_base_url")
        XCTAssertEqual(hold?.table, "")
        XCTAssertEqual(hold?.bridgedProtocol, .anthropicMessages)
        XCTAssertEqual(hold?.holdsPausedRequests, false)
        XCTAssertEqual(hold?.keyAbsentByDefault, true)
        XCTAssertEqual(ProviderRequestHold.routedURL(.codex), RouterConfig.baseURL + "/__provider/codex")
    }

    func testAKeyBeforeAnyTableIsSetAndRemovedLeavingTheFileAsItWas() throws {
        let url = directory.appendingPathComponent("config.toml")
        let original = """
        model = "gpt-x"
        approval_policy = "never"

        [projects."/tmp/x"]
        trust_level = "trusted"
        openai_base_url = "https://example.invalid/not-the-root-key"
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        let routed = "http://127.0.0.1:47321/__provider/codex"
        XCTAssertNil(TOMLHookConfig.value(at: url, table: "", key: "openai_base_url"), "only keys before the first table")
        try TOMLHookConfig.setValue(at: url, table: "", key: "openai_base_url", value: routed, comment: "# accountdock-router")
        XCTAssertEqual(TOMLHookConfig.value(at: url, table: "", key: "openai_base_url"), routed)
        let written = try String(contentsOf: url, encoding: .utf8)
        let header = try XCTUnwrap(written.range(of: "[projects"))
        XCTAssertTrue(written[..<header.lowerBound].contains("openai_base_url = \"\(routed)\" # accountdock-router"))
        XCTAssertEqual(TOMLHookConfig.value(at: url, table: #"projects."/tmp/x""#, key: "openai_base_url"), "https://example.invalid/not-the-root-key")
        try TOMLHookConfig.removeValue(at: url, table: "", key: "openai_base_url")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        try TOMLHookConfig.removeValue(at: url, table: "", key: "openai_base_url")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "removing an absent key changes nothing")
    }
}
