import XCTest
@testable import AccountDock

/// Where the router sends a Codex request it does not bridge, and how it
/// bridges Codex's compaction call.
final class CodexBridgeTests: XCTestCase {
    private let chatGPT = "https://chatgpt.com/backend-api/codex"
    private let openAI = "https://api.openai.com/v1"
    private let signIn = [("Authorization", "Bearer eyJhbGciOiJub25lIn0.eyJleHAiOjF9.sig"), ("ChatGPT-Account-ID", "acct-1")]
    private let apiKey = [("Authorization", "Bearer sk-test-not-a-real-key")]

    private var hold: RequestHoldSupport { AIProviderType.codex.capabilities.requestHold! }

    // MARK: - Upstream by credential

    func testASignInGoesToTheChatGPTEndpointAndAnAPIKeyToTheOpenAIAPI() {
        let entry = ProviderRequestHold.entry(hold, upstream: hold.defaultUpstream)
        XCTAssertEqual(entry.apiKeyUpstream, openAI)
        XCTAssertEqual(ProviderPassthrough.clientAuth(signIn), .signIn)
        XCTAssertEqual(ProviderPassthrough.clientAuth(apiKey), .apiKey)
        XCTAssertEqual(ProviderPassthrough.clientAuth([("Authorization", "Bearer eyJa.eyJb.c")]), .signIn, "a JWT without the header")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: signIn)?.absoluteString,
                       chatGPT + "/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: apiKey)?.absoluteString,
                       openAI + "/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/models?client_version=1", headers: apiKey)?.absoluteString,
                       openAI + "/models?client_version=1")
    }

    func testABaseURLTheUserSetTakesEveryRequest() {
        let entry = ProviderRequestHold.entry(hold, upstream: "https://proxy.example/v1")
        XCTAssertNil(entry.apiKeyUpstream)
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: apiKey)?.absoluteString,
                       "https://proxy.example/v1/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: signIn)?.absoluteString,
                       "https://proxy.example/v1/responses")
    }

    func testAnEntryRecordedBeforeAPIKeyUpstreamsSendsEverythingToItsUpstream() throws {
        let data = Data(#"{"codex":{"upstream":"https://chatgpt.com/backend-api/codex","sessionField":"prompt_cache_key"}}"#.utf8)
        let entry = try XCTUnwrap(RouterConfig.decoder().decode([String: ProviderPassthrough.Entry].self, from: data)["codex"])
        XCTAssertNil(entry.apiKeyUpstream)
        XCTAssertEqual(ProviderPassthrough.upstream(entry, headers: apiKey), chatGPT)
    }

    // MARK: - Compaction

    private let conversation: [String: Any] = [
        "model": "gpt-5-codex",
        "instructions": "You are Codex.",
        "input": [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the failing test."]]],
            ["type": "function_call", "call_id": "c1", "name": "shell", "arguments": #"{"command":["ls"]}"#],
            ["type": "function_call_output", "call_id": "c1", "output": "a.swift"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Found it."]]],
        ],
        "tools": [["type": "function", "name": "shell", "parameters": ["type": "object"]]],
        "parallel_tool_calls": false,
    ]

    func testCompactionAsksTheBackendForASummaryAfterTheWholeConversation() throws {
        XCTAssertTrue(ProviderPassthrough.isCompactPath("/responses/compact"))
        XCTAssertFalse(ProviderPassthrough.isResponsesPath("/responses/compact"))
        let body = ResponsesBridge.compactionRequest(conversation, model: "k3")
        XCTAssertEqual(body["model"] as? String, "k3")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["type"] as? String, "none", "tools are offered, none called")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        let last = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(last.last?["text"] as? String, ResponsesBridge.compactionInstruction)
    }

    func testTheCompactedConversationIsTheUsersMessagesAndTheSummary() throws {
        let reply = Data(#"{"content":[{"type":"text","text":"The user wants the test fixed; a.swift is next."}],"usage":{"input_tokens":10}}"#.utf8)
        let summary = try XCTUnwrap(ResponsesBridge.summaryText(inMessagesReply: reply))
        let data = ResponsesBridge.compactionReply(summary: summary, request: conversation)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"output":[{"content":[{"text":"Fix the failing test.","type":"input_text"}],"role":"user","type":"message"},"#
                       + #"{"content":[{"text":"The conversation so far was compacted. This summary of it was written for you to continue from:\n\n"#
                       + #"The user wants the test fixed; a.swift is next.","type":"input_text"}],"role":"user","type":"message"}]}"#)
        XCTAssertNil(ResponsesBridge.summaryText(inMessagesReply: Data(#"{"content":[]}"#.utf8)))
    }

    func testOnlyTheNewestUserMessagesWithinTheBudgetAreKept() throws {
        let long = String(repeating: "x", count: ResponsesBridge.compactionUserBytes / 2 + 1)
        let request: [String: Any] = ["input": ["first", long, long, "last"].map {
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": $0]]]
        }]
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: ResponsesBridge.compactionReply(summary: "s", request: request)) as? [String: Any])
        let texts = (root["output"] as? [[String: Any]] ?? []).compactMap {
            (($0["content"] as? [[String: Any]])?.first?["text"] as? String)
        }
        XCTAssertEqual(texts.count, 3, "the newest long message, the last and the summary")
        XCTAssertEqual(texts[1], "last")
    }
}
