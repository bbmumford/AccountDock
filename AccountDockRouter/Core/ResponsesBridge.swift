import Foundation

/// Serves an OpenAI Responses request, as Codex sends it, from an
/// Anthropic Messages backend: the request is rewritten for the backend and
/// the backend's streamed reply is rewritten as Responses events.
///
/// Only what such a backend can carry is kept. OpenAI's encrypted reasoning
/// and hosted tools (web search, tool search) stay out of the request, and
/// the backend's thinking stays out of the reply, so the session's history
/// holds nothing either side cannot read back.
enum ResponsesBridge {
    /// Replies are capped at this many tokens unless the request asks for
    /// fewer.
    static let defaultMaxOutputTokens = 32_000

    /// How the backend's tool names map back to the client's: Messages tool
    /// names are flat, while Codex groups tools in namespaces and has
    /// free-form tools that take raw text.
    struct ToolNames: Equatable {
        struct Tool: Equatable {
            var namespace: String?
            var name: String
            /// A free-form tool, sent as a function taking one `input` string.
            var custom: Bool
        }

        private(set) var byWireName: [String: Tool] = [:]
        private var wireNames: [String: String] = [:]

        /// The backend's name for `name` in `namespace`, assigned on first
        /// use: the two joined by `__`, shortened with a digest when the
        /// result breaks the Messages API's name rule.
        mutating func wireName(namespace: String?, name: String, custom: Bool) -> String {
            let key = (namespace.map { $0 + "\u{1}" } ?? "") + name
            if let existing = wireNames[key] { return existing }
            var wire = namespace.map { "\($0)__\(name)" } ?? name
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            if wire.count > 64 || wire.unicodeScalars.contains(where: { !allowed.contains($0) }) || byWireName[wire] != nil {
                let cleaned = String(wire.unicodeScalars.filter { allowed.contains($0) }.prefix(54))
                wire = cleaned + "_" + RouterLogic.fingerprint(key).prefix(9)
            }
            wireNames[key] = wire
            byWireName[wire] = Tool(namespace: namespace, name: name, custom: custom)
            return wire
        }

        func tool(_ wire: String) -> Tool? { byWireName[wire] }
    }

    /// A Codex request starts a turn when its last input item is the user's
    /// own message rather than a tool call's output.
    static func startsTurn(_ request: [String: Any]) -> Bool {
        guard let input = request["input"] as? [[String: Any]], let last = input.last else { return true }
        return last["type"] as? String == "message" && last["role"] as? String == "user"
    }

    /// The session a Codex request belongs to: its `prompt_cache_key`, which
    /// Codex sets to the thread its hooks report as the session.
    static func sessionID(_ request: [String: Any]) -> String? {
        (request["prompt_cache_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The Messages request serving `request` with `model` in `dialect`, and
    /// the tool names it uses.
    static func messagesRequest(_ request: [String: Any], model: String?,
                                dialect: RouterBackend.MessagesDialect = .compatible) -> (body: [String: Any], tools: ToolNames) {
        var names = ToolNames()
        var system: [String] = []
        if let instructions = request["instructions"] as? String, !instructions.isEmpty { system.append(instructions) }
        var messages: [[String: Any]] = []
        var toolList = request["tools"] as? [[String: Any]] ?? []

        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = messages.indices.last, messages[last]["role"] as? String == role {
                messages[last]["content"] = (messages[last]["content"] as? [[String: Any]] ?? []) + blocks
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        let input: [[String: Any]]
        if let items = request["input"] as? [[String: Any]] {
            input = items
        } else if let text = request["input"] as? String {
            input = [["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        } else {
            input = []
        }
        for item in input {
            let type = item["type"] as? String ?? "message"
            switch type {
            case "message":
                let role = item["role"] as? String ?? "user"
                let blocks = contentBlocks(item["content"])
                if role == "system" || role == "developer" {
                    // Instructions given before the conversation join the
                    // system prompt; later ones stay where they were given.
                    if messages.isEmpty {
                        system += blocks.compactMap { $0["text"] as? String }
                    } else {
                        append("user", blocks)
                    }
                } else {
                    append(role == "assistant" ? "assistant" : "user", blocks)
                }
            case "function_call":
                let name = names.wireName(namespace: item["namespace"] as? String, name: item["name"] as? String ?? "", custom: false)
                let arguments = (item["arguments"] as? String).flatMap { Data($0.utf8).isEmpty ? nil : Data($0.utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                append("assistant", [["type": "tool_use", "id": item["call_id"] as? String ?? "", "name": name, "input": arguments]])
            case "custom_tool_call":
                let name = names.wireName(namespace: item["namespace"] as? String, name: item["name"] as? String ?? "", custom: true)
                append("assistant", [["type": "tool_use", "id": item["call_id"] as? String ?? "", "name": name,
                                      "input": ["input": item["input"] as? String ?? ""]]])
            case "additional_tools":
                // Codex can list its tools in an input item instead of in
                // `tools`; both are offered to the backend.
                toolList += item["tools"] as? [[String: Any]] ?? []
            case "function_call_output", "custom_tool_call_output":
                append("user", [["type": "tool_result", "tool_use_id": item["call_id"] as? String ?? "",
                                 "content": toolResultContent(item["output"])]])
            case "reasoning" where dialect == .claude:
                // The backend's own thinking, returned to it where it was
                // given; OpenAI's encrypted reasoning is left out.
                if let block = thinkingBlock(fromReasoning: item) { append("assistant", [block]) }
            default:
                // Reasoning, hosted-tool calls and other OpenAI-only items.
                continue
            }
        }
        messages = pairedToolCalls(messages)
        if messages.first?["role"] as? String != "user" {
            messages.insert(["role": "user", "content": [["type": "text", "text": "(conversation continues)"]]], at: 0)
        }
        // The prompt cache is marked at the end of the conversation, so the
        // next request reads everything before it.
        if let last = messages.indices.last, var blocks = messages[last]["content"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            messages[last]["content"] = blocks
        }

        var body: [String: Any] = [
            "model": model ?? request["model"] as? String ?? "",
            "max_tokens": (request["max_output_tokens"] as? NSNumber)?.intValue ?? defaultMaxOutputTokens,
            "stream": true,
            "messages": messages,
        ]
        let systemText = system.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !systemText.isEmpty { body["system"] = [["type": "text", "text": systemText, "cache_control": ["type": "ephemeral"]]] }
        if dialect == .compatible {
            if let temperature = request["temperature"] as? NSNumber { body["temperature"] = temperature }
            if let topP = request["top_p"] as? NSNumber { body["top_p"] = topP }
        } else if let effort = (request["reasoning"] as? [String: Any])?["effort"] as? String {
            body["output_config"] = ["effort": claudeEffort(effort)]
        }

        let tools = toolDefinitions(toolList, names: &names)
        if !tools.isEmpty {
            body["tools"] = tools
            var choice: [String: Any]
            switch request["tool_choice"] {
            case let value as String where value == "required": choice = ["type": "any"]
            case let value as String where value == "none": choice = ["type": "none"]
            case let value as [String: Any]:
                if let name = value["name"] as? String {
                    choice = ["type": "tool", "name": names.wireName(namespace: value["namespace"] as? String, name: name, custom: false)]
                } else {
                    choice = ["type": "auto"]
                }
            default: choice = ["type": "auto"]
            }
            // Anthropic's current models take no forced tool use; the model
            // is left to choose.
            if dialect == .claude, ["any", "tool"].contains(choice["type"] as? String ?? "") { choice = ["type": "auto"] }
            if request["parallel_tool_calls"] as? Bool == false, choice["type"] as? String != "none" {
                choice["disable_parallel_tool_use"] = true
            }
            body["tool_choice"] = choice
        }
        return (body, names)
    }

    /// Anthropic's effort for Codex's reasoning effort, which also has
    /// `minimal`.
    static func claudeEffort(_ effort: String) -> String {
        ["low", "medium", "high", "xhigh", "max"].contains(effort) ? effort : effort == "minimal" ? "low" : "medium"
    }

    /// Marks a reasoning item's `encrypted_content` as a thinking block of
    /// the bridge's backend, which only the bridge reads back.
    static let thinkingPrefix = "accountdock-thinking:"

    /// The reasoning item carrying a backend's thinking block to Codex,
    /// which sends it back with the conversation's later requests.
    static func reasoningItem(thinking block: [String: Any], id: String) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])) ?? Data()
        return ["type": "reasoning", "id": id, "summary": [] as [Any], "encrypted_content": thinkingPrefix + data.base64EncodedString()]
    }

    /// The thinking block a reasoning item carries back; nil for any other
    /// reasoning, as OpenAI's own.
    static func thinkingBlock(fromReasoning item: [String: Any]) -> [String: Any]? {
        guard let content = item["encrypted_content"] as? String, content.hasPrefix(thinkingPrefix),
              let data = Data(base64Encoded: String(content.dropFirst(thinkingPrefix.count))),
              let block = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ["thinking", "redacted_thinking"].contains(block["type"] as? String ?? "") else { return nil }
        return block
    }

    /// The request without thinking blocks, for a backend account that
    /// rejects another account's signatures.
    static func withoutThinking(_ body: [String: Any]) -> [String: Any] {
        guard var messages = body["messages"] as? [[String: Any]] else { return body }
        for index in messages.indices {
            guard let blocks = messages[index]["content"] as? [[String: Any]] else { continue }
            let kept = blocks.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
            if kept.count != blocks.count { messages[index]["content"] = kept.isEmpty ? [["type": "text", "text": "…"]] : kept }
        }
        var result = body
        result["messages"] = messages
        return result
    }

    /// Messages blocks for a Responses message's content: text and images.
    private static func contentBlocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return text.isEmpty ? [] : [["type": "text", "text": text]] }
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { part -> [String: Any]? in
            switch part["type"] as? String {
            case "input_text", "output_text", "text", "refusal", "summary_text":
                let text = (part["text"] as? String) ?? (part["refusal"] as? String) ?? ""
                return text.isEmpty ? nil : ["type": "text", "text": text]
            case "input_image":
                return imageBlock(part["image_url"] as? String)
            case "input_file":
                let name = part["filename"] as? String ?? "a file"
                return ["type": "text", "text": "(\(name) was attached here; this model cannot read it.)"]
            default:
                return nil
            }
        }
    }

    /// An image block for a data URL or a remote URL.
    private static func imageBlock(_ url: String?) -> [String: Any]? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
            let mediaType = header.split(separator: ";").first.map(String.init) ?? "image/png"
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": String(url[url.index(after: comma)...])]]
        }
        return ["type": "image", "source": ["type": "url", "url": url]]
    }

    /// A tool result's content: the output text, or its text and image items.
    private static func toolResultContent(_ output: Any?) -> Any {
        if let text = output as? String { return text }
        if let items = output as? [[String: Any]] {
            let blocks = contentBlocks(items)
            return blocks.isEmpty ? "" : blocks
        }
        if let object = output as? [String: Any], let text = object["content"] as? String { return text }
        return ""
    }

    /// The conversation with every tool call answered in the message after
    /// it, which the Messages API requires: a result whose call is missing
    /// is dropped, and a call left without a result gets one saying so.
    private static func pairedToolCalls(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var pending: [String] = []
        func answerPending() {
            guard !pending.isEmpty else { return }
            let missing = pending.map { ["type": "tool_result", "tool_use_id": $0, "content": "No output was recorded for this call."] as [String: Any] }
            pending = []
            if let last = result.indices.last, result[last]["role"] as? String == "user" {
                result[last]["content"] = missing + (result[last]["content"] as? [[String: Any]] ?? [])
            } else {
                result.append(["role": "user", "content": missing])
            }
        }
        for message in messages {
            var blocks = message["content"] as? [[String: Any]] ?? []
            if message["role"] as? String == "user" {
                let answered = Set(blocks.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil })
                blocks = blocks.filter { $0["type"] as? String != "tool_result" || pending.contains($0["tool_use_id"] as? String ?? "") }
                let unanswered = pending.filter { !answered.contains($0) }
                // Results come first in their message.
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                let others = blocks.filter { $0["type"] as? String != "tool_result" }
                blocks = unanswered.map { ["type": "tool_result", "tool_use_id": $0, "content": "No output was recorded for this call."] } + results + others
                pending = []
                if blocks.isEmpty { continue }
                result.append(["role": "user", "content": blocks])
            } else {
                answerPending()
                pending = blocks.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }
                result.append(message)
            }
        }
        if !pending.isEmpty, result.last?["role"] as? String == "assistant" {
            // The conversation ends on unanswered calls, which only the
            // client can answer; a trailing call would otherwise be invalid.
            answerPending()
        }
        return result
    }

    /// Messages tool definitions for the request's function, namespace and
    /// free-form tools; hosted tools have no counterpart and are left out.
    private static func toolDefinitions(_ tools: [[String: Any]], names: inout ToolNames) -> [[String: Any]] {
        var definitions: [[String: Any]] = []
        func add(_ tool: [String: Any], namespace: String?) {
            guard let name = tool["name"] as? String, !name.isEmpty else { return }
            switch tool["type"] as? String {
            case "function":
                var schema = tool["parameters"] as? [String: Any] ?? [:]
                if schema["type"] == nil { schema["type"] = "object" }
                definitions.append(["name": names.wireName(namespace: namespace, name: name, custom: false),
                                    "description": tool["description"] as? String ?? "",
                                    "input_schema": schema])
            case "custom":
                let description = (tool["description"] as? String ?? "")
                    + "\n\nPass the tool's whole input as the `input` string, exactly as the tool expects it."
                definitions.append(["name": names.wireName(namespace: namespace, name: name, custom: true),
                                    "description": description,
                                    "input_schema": ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]]])
            default:
                break
            }
        }
        for tool in tools {
            if tool["type"] as? String == "namespace" {
                let namespace = tool["name"] as? String
                for child in tool["tools"] as? [[String: Any]] ?? [] { add(child, namespace: namespace) }
            } else {
                add(tool, namespace: nil)
            }
        }
        return definitions
    }

    // MARK: - Compaction

    /// The instruction the backend summarises a conversation by.
    static let compactionInstruction = """
        Write a handoff summary of the conversation above for another model, which will continue the work from this \
        summary and the user's messages alone. Cover the task and the user's requirements and preferences; what has \
        been done, with the files, commands and results that matter; the decisions made and why; what remains, as \
        concrete next steps; and whatever is needed to continue, such as paths, identifiers, errors or partial output. \
        Write only the summary.
        """

    /// The text that introduces the summary in the compacted conversation.
    static let compactionPreface = "The conversation so far was compacted. This summary of it was written for you to continue from:\n\n"

    /// The most of the user's own messages a compacted conversation keeps,
    /// newest first, in bytes.
    static let compactionUserBytes = 80_000

    /// The Messages request that summarises a Codex conversation sent to
    /// `/responses/compact`: the conversation as `messagesRequest` writes it,
    /// whole and unstreamed, its tools offered but none called, and the
    /// summary instruction after it, so the cached conversation is read
    /// before the instruction.
    static func compactionRequest(_ request: [String: Any], model: String?,
                                  dialect: RouterBackend.MessagesDialect = .compatible) -> [String: Any] {
        var body = messagesRequest(request, model: model, dialect: dialect).body
        body["stream"] = false
        body["max_tokens"] = 16_000
        if body["tools"] != nil { body["tool_choice"] = ["type": "none"] }
        var messages = body["messages"] as? [[String: Any]] ?? []
        let instruction: [String: Any] = ["type": "text", "text": compactionInstruction]
        if let last = messages.indices.last, messages[last]["role"] as? String == "user" {
            messages[last]["content"] = (messages[last]["content"] as? [[String: Any]] ?? []) + [instruction]
        } else {
            messages.append(["role": "user", "content": [instruction]])
        }
        body["messages"] = messages
        return body
    }

    /// The text of an unstreamed Messages reply; nil when it holds none.
    static func summaryText(inMessagesReply data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The reply to `/responses/compact`: the items that replace the
    /// conversation. The user's own messages, newest kept first up to
    /// `compactionUserBytes` and in their order, then the summary as a user
    /// message. Context blocks Codex adds itself, written as tagged text
    /// (`<environment_context>`), are left for Codex to add again.
    static func compactionReply(summary: String, request: [String: Any]) -> Data {
        let items = request["input"] as? [[String: Any]] ?? []
        var texts: [String] = []
        for item in items where (item["type"] as? String ?? "message") == "message" && item["role"] as? String == "user" {
            let text = contentBlocks(item["content"]).compactMap { $0["text"] as? String }.joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("<") { texts.append(text) }
        }
        var kept: [String] = []
        var bytes = 0
        for text in texts.reversed() {
            bytes += text.utf8.count
            if bytes > compactionUserBytes, !kept.isEmpty { break }
            kept.insert(text, at: 0)
        }
        func message(_ text: String) -> [String: Any] {
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]
        }
        let output = kept.map(message) + [message(compactionPreface + summary)]
        return (try? JSONSerialization.data(withJSONObject: ["output": output], options: [.sortedKeys])) ?? Data()
    }

    /// A `response.failed` event carrying `message`, for an error that
    /// arrives after the stream began.
    static func failedEvent(id: String, code: String, message: String) -> Data {
        event("response.failed", ["response": ["id": id, "status": "failed", "error": ["code": code, "message": message]]])
    }

    /// An ID for a response the router originates.
    static func newResponseID() -> String {
        "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func event(_ type: String, _ fields: [String: Any]) -> Data {
        var object = fields
        object["type"] = type
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Data("event: \(type)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
}

/// Rewrites a streamed Messages reply as the Responses events Codex reads:
/// `response.created`, each output item's `added` and `done`, text deltas,
/// and one closing event: `response.completed` with the token use,
/// `response.incomplete` when the backend stopped at its output cap, or
/// `response.failed` when it reported an error or its stream ended early.
final class ResponsesStreamTranslator {
    /// How the reply ended.
    enum Outcome: Equatable {
        case completed
        /// The backend stopped before the reply was whole, for `reason`.
        case incomplete(reason: String)
        case failed(code: String, message: String)
    }

    private let tools: ResponsesBridge.ToolNames
    private let responseID: String
    private let dialect: RouterBackend.MessagesDialect
    private let makeID: () -> String
    private var buffer = Data()
    private var started = false
    /// Set by the closing event; nothing is written after it.
    private(set) var outcome: Outcome?
    private var stopReason: String?
    private var outputIndex = 0
    private struct Block {
        var kind: String
        var itemID: String
        var outputIndex: Int
        var text = ""
        var toolID = ""
        var toolName = ""
        var arguments = ""
        var signature = ""
    }
    private var blocks: [Int: Block] = [:]
    private var usage = RouterLogic.StreamUsage()
    /// Token use the backend has reported so far, counted as `SSEScanner`
    /// counts a Messages stream.
    var counts: RouterLogic.TokenCounts { usage.counts }
    /// The reply ended in `response.failed`; `serveResponses` records the
    /// backend's failure from it.
    var failed: Bool {
        if case .failed = outcome { return true }
        return false
    }

    /// `makeID` names each output item; the tests give fixed names.
    init(tools: ResponsesBridge.ToolNames, responseID: String = ResponsesBridge.newResponseID(),
         dialect: RouterBackend.MessagesDialect = .compatible, makeID: @escaping () -> String = ResponsesStreamTranslator.shortID) {
        self.tools = tools
        self.responseID = responseID
        self.dialect = dialect
        self.makeID = makeID
    }

    /// Events for the next part of the backend's stream.
    func feed(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.starts(with: Data("data:".utf8)),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5))) as? [String: Any] else { continue }
            output.append(handle(event))
        }
        return output
    }

    /// The closing event for a stream the backend ended without
    /// `message_stop` or an error: the reply is not whole, so it fails.
    func finish() -> Data {
        fail(code: "server_error", message: started
            ? "The routed backend's reply ended before it was complete."
            : "The routed backend ended its reply without content.")
    }

    /// `response.failed` for this response, unless it already closed. Items
    /// still open are not reported done: a tool call cut short must not run.
    func fail(code: String, message: String) -> Data {
        guard outcome == nil else { return Data() }
        outcome = .failed(code: code, message: message)
        blocks.removeAll()
        return ResponsesBridge.failedEvent(id: responseID, code: code, message: message)
    }

    private func handle(_ event: [String: Any]) -> Data {
        guard outcome == nil else { return Data() }
        var output = Data()
        if !started, event["type"] as? String != "error" {
            started = true
            output.append(ResponsesBridge.event("response.created", ["response": ["id": responseID, "status": "in_progress", "output": []]]))
        }
        let index = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "message_start":
            if let message = event["message"] as? [String: Any], let start = message["usage"] as? [String: Any] {
                usage.start(start)
            }
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { break }
            switch block["type"] as? String {
            case "text":
                let item = Block(kind: "text", itemID: "msg_" + makeID(), outputIndex: outputIndex)
                outputIndex += 1
                blocks[index] = item
                output.append(ResponsesBridge.event("response.output_item.added", [
                    "output_index": item.outputIndex,
                    "item": ["type": "message", "id": item.itemID, "role": "assistant", "status": "in_progress", "content": []],
                ]))
                if let text = block["text"] as? String, !text.isEmpty { output.append(textDelta(index, text)) }
            case "tool_use":
                var item = Block(kind: "tool", itemID: "fc_" + makeID(), outputIndex: outputIndex)
                outputIndex += 1
                item.toolID = block["id"] as? String ?? "call_" + makeID()
                item.toolName = block["name"] as? String ?? ""
                if let input = block["input"] as? [String: Any], !input.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: input) {
                    item.arguments = String(decoding: data, as: UTF8.self)
                }
                blocks[index] = item
                output.append(ResponsesBridge.event("response.output_item.added", ["output_index": item.outputIndex, "item": toolItem(item, done: false)]))
            case "thinking" where dialect == .claude, "redacted_thinking" where dialect == .claude:
                // Reported whole once it stops, as a reasoning item Codex
                // sends back with the conversation.
                var item = Block(kind: block["type"] as? String ?? "thinking", itemID: "rs_" + makeID(), outputIndex: outputIndex)
                outputIndex += 1
                item.text = block["thinking"] as? String ?? ""
                item.signature = block["signature"] as? String ?? ""
                item.arguments = block["data"] as? String ?? ""
                blocks[index] = item
            default:
                // Thinking of a compatible backend stays with it.
                break
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { output.append(textDelta(index, text)) }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String { blocks[index]?.arguments += partial }
            case "thinking_delta":
                if let thinking = delta["thinking"] as? String { blocks[index]?.text += thinking }
            case "signature_delta":
                if let signature = delta["signature"] as? String { blocks[index]?.signature += signature }
            default:
                break
            }
        case "content_block_stop":
            if let block = blocks.removeValue(forKey: index) { output.append(itemDone(block)) }
        case "message_delta":
            if let late = event["usage"] as? [String: Any] { usage.update(late) }
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
        case "message_stop":
            output.append(completed())
        case "error":
            let error = event["error"] as? [String: Any]
            let type = error?["type"] as? String ?? "server_error"
            output.append(fail(
                code: type == "rate_limit_error" ? "rate_limit_exceeded" : type == "overloaded_error" ? "server_is_overloaded" : "server_error",
                message: error?["message"] as? String ?? "The routed backend reported an error."))
        default:
            break
        }
        return output
    }

    private func textDelta(_ index: Int, _ text: String) -> Data {
        guard var block = blocks[index], block.kind == "text" else { return Data() }
        block.text += text
        blocks[index] = block
        return ResponsesBridge.event("response.output_text.delta", [
            "item_id": block.itemID, "output_index": block.outputIndex, "content_index": 0, "delta": text,
        ])
    }

    private func toolItem(_ block: Block, done: Bool) -> [String: Any] {
        let tool = tools.tool(block.toolName)
        var item: [String: Any] = ["id": block.itemID, "call_id": block.toolID, "name": tool?.name ?? block.toolName,
                                   "status": done ? "completed" : "in_progress"]
        if let namespace = tool?.namespace { item["namespace"] = namespace }
        if tool?.custom == true {
            item["type"] = "custom_tool_call"
            let arguments = (try? JSONSerialization.jsonObject(with: Data(block.arguments.utf8))) as? [String: Any]
            item["input"] = done ? (arguments?["input"] as? String ?? block.arguments) : ""
        } else {
            item["type"] = "function_call"
            item["arguments"] = done ? (block.arguments.isEmpty ? "{}" : block.arguments) : ""
        }
        return item
    }

    private func itemDone(_ block: Block) -> Data {
        if block.kind == "thinking" || block.kind == "redacted_thinking" {
            let thinking: [String: Any] = block.kind == "thinking"
                ? ["type": "thinking", "thinking": block.text, "signature": block.signature]
                : ["type": "redacted_thinking", "data": block.arguments]
            let item = ResponsesBridge.reasoningItem(thinking: thinking, id: block.itemID)
            return ResponsesBridge.event("response.output_item.added", ["output_index": block.outputIndex, "item": item])
                + ResponsesBridge.event("response.output_item.done", ["output_index": block.outputIndex, "item": item])
        }
        if block.kind == "text" {
            return ResponsesBridge.event("response.output_item.done", [
                "output_index": block.outputIndex,
                "item": ["type": "message", "id": block.itemID, "role": "assistant", "status": "completed",
                         "content": [["type": "output_text", "text": block.text, "annotations": []]]],
            ])
        }
        return ResponsesBridge.event("response.output_item.done", ["output_index": block.outputIndex, "item": toolItem(block, done: true)])
    }

    /// The closing event after `message_stop`: `response.incomplete` when
    /// the backend stopped at its output cap, else `response.completed`.
    private func completed() -> Data {
        guard outcome == nil else { return Data() }
        var output = Data()
        // Blocks the backend left open are closed first.
        for index in blocks.keys.sorted() { output.append(itemDone(blocks[index]!)) }
        blocks.removeAll()
        let counts = usage.counts
        var response: [String: Any] = [
            "id": responseID, "output": [],
            "usage": [
                "input_tokens": counts.context,
                "input_tokens_details": ["cached_tokens": counts.cacheRead, "cache_write_tokens": counts.cacheWrite],
                "output_tokens": counts.output,
                "output_tokens_details": ["reasoning_tokens": 0],
                "total_tokens": counts.context + counts.output,
            ],
        ]
        if stopReason == "max_tokens" {
            outcome = .incomplete(reason: "max_output_tokens")
            response["status"] = "incomplete"
            response["incomplete_details"] = ["reason": "max_output_tokens"]
            output.append(ResponsesBridge.event("response.incomplete", ["response": response]))
        } else {
            outcome = .completed
            response["status"] = "completed"
            output.append(ResponsesBridge.event("response.completed", ["response": response]))
        }
        return output
    }

    static func shortID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
