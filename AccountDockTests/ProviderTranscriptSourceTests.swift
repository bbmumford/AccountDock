import XCTest
@testable import AccountDock

/// The Codex and Kimi transcript sources, on fixture lines in each CLI's
/// own format.
final class ProviderTranscriptSourceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Codex

    private func codexRow(_ type: String, _ payload: [String: Any], at: Date) -> String {
        line(["timestamp": stamp(at), "type": type, "payload": payload])
    }

    private func tokenCount(input: Int, cached: Int, output: Int, total: Int) -> [String: Any] {
        let usage: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
                                    "output_tokens": output, "reasoning_output_tokens": 2, "total_tokens": input + output]
        return ["type": "token_count",
                "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": usage, "model_context_window": 258400],
                "rate_limits": ["primary": ["used_percent": 12.5, "window_minutes": 300, "resets_at": 1_900_000_000]]]
    }

    func testCodexRolloutsGiveEachRequestItsModelTurnAndName() async throws {
        let config = try temporaryDirectory()
        let day = config.appendingPathComponent("sessions/2026/11/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let session = "01a1da91-bd1c-7580-b0e0-47e3bef5cbe7"
        let now = Date()
        let at = now.addingTimeInterval(-120)
        let rollout = codexRow("session_meta", ["id": session, "model_provider": "accountdock", "parent_thread_id": NSNull()], at: at)
            + codexRow("turn_context", ["turn_id": "t1", "model": "gpt-5.6-sol"], at: at)
            + codexRow("event_msg", ["type": "task_started", "turn_id": "t1"], at: at)
            + codexRow("event_msg", ["type": "user_message", "message": "say ok"], at: at)
            + codexRow("event_msg", tokenCount(input: 1200, cached: 800, output: 7, total: 1207), at: at.addingTimeInterval(1))
            + codexRow("event_msg", tokenCount(input: 1200, cached: 800, output: 7, total: 1207), at: at.addingTimeInterval(2))
            + codexRow("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": [:]], at: at.addingTimeInterval(2))
            + codexRow("event_msg", tokenCount(input: 1500, cached: 1200, output: 30, total: 2737), at: at.addingTimeInterval(3))
            + codexRow("event_msg", ["type": "task_complete", "turn_id": "t1", "last_agent_message": "ok"], at: at.addingTimeInterval(4))
        try rollout.write(to: day.appendingPathComponent("rollout-2026-11-15T01-59-06-\(session).jsonl"), atomically: true, encoding: .utf8)
        try (line(["id": session, "thread_name": "old name", "updated_at": "2026-11-15T00:00:00Z"])
             + line(["id": session, "thread_name": "release notes", "updated_at": "2026-11-15T01:00:00Z"]))
            .write(to: config.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let feed = TranscriptRequestFeed()
        let requests = await feed.newRequests(.codex, configDirectory: config.path, now: now)
        XCTAssertEqual(requests.count, 2, "a repeated total and a rate-limit-only row are no requests")
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.session, session)
        XCTAssertEqual(first.model, "gpt-5.6-sol")
        XCTAssertEqual(first.contextTokens, 1200)
        XCTAssertEqual(first.cacheReadTokens, 800)
        XCTAssertEqual(first.outputTokens, 7)
        XCTAssertTrue(first.startsTurn)
        XCTAssertFalse(first.subagent)
        XCTAssertEqual(first.sessionName, "release notes")
        XCTAssertFalse(requests[1].startsTurn, "the turn's second request")
        let again = await feed.newRequests(.codex, configDirectory: config.path, now: now)
        XCTAssertTrue(again.isEmpty)
    }

    func testACodexUsageLimitRefusalAndASubagentsRequests() async throws {
        let config = try temporaryDirectory()
        let day = config.appendingPathComponent("sessions/2026/11/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let (parent, child) = ("01a1da92-8182-7e42-9baf-579d56c79c4b", "01a1da93-0000-7000-8000-000000000001")
        let now = Date()
        let at = now.addingTimeInterval(-60)
        let words = "You've hit your usage limit. Upgrade to Pro or try again at 4:46 AM."
        let refused = codexRow("session_meta", ["id": parent], at: at)
            + codexRow("event_msg", ["type": "user_message", "message": "go"], at: at)
            + codexRow("event_msg", ["type": "error", "message": words, "codex_error_info": "usage_limit_exceeded"], at: at)
            + codexRow("event_msg", ["type": "task_complete", "turn_id": "t",
                                     "error": ["message": words, "codex_error_info": "usage_limit_exceeded"]], at: at)
            + codexRow("event_msg", ["type": "task_complete", "turn_id": "u",
                                     "error": ["message": "stream disconnected", "codex_error_info": "response_stream_disconnected"]], at: at)
        try refused.write(to: day.appendingPathComponent("rollout-2026-11-15T01-59-56-\(parent).jsonl"), atomically: true, encoding: .utf8)
        let sub = codexRow("session_meta", ["id": child, "parent_thread_id": parent], at: at)
            + codexRow("turn_context", ["model": "gpt-5.6-mini"], at: at)
            + codexRow("event_msg", ["type": "user_message", "message": "task"], at: at)
            + codexRow("event_msg", tokenCount(input: 50_000, cached: 0, output: 900, total: 50_900), at: at)
        try sub.write(to: day.appendingPathComponent("rollout-2026-11-15T02-00-00-\(child).jsonl"), atomically: true, encoding: .utf8)

        let requests = await TranscriptRequestFeed().newRequests(.codex, configDirectory: config.path, now: now)
        let refusals = requests.filter { $0.limitRefusal != nil }
        XCTAssertEqual(refusals.count, 1, "the error and the turn's end are one refusal; another error is none")
        XCTAssertEqual(refusals.first?.limitRefusal, words)
        XCTAssertEqual(refusals.first?.session, parent)
        let subagent = try XCTUnwrap(requests.first { $0.limitRefusal == nil })
        XCTAssertEqual(subagent.session, parent, "a subagent's requests are its session's")
        XCTAssertEqual(subagent.agent, child)
        XCTAssertEqual(subagent.agentModel, "gpt-5.6-mini")
        XCTAssertFalse(subagent.startsTurn)
        XCTAssertNil(subagent.model)
        XCTAssertTrue(CodexTranscriptSource.isUsageLimit(["usage_limit_exceeded": ["resets_at": 1]]))
    }

    // MARK: - Kimi

    private func kimiRow(_ type: String, _ fields: [String: Any], at: Date) -> String {
        var record = fields
        record["type"] = type
        record["time"] = Int(at.timeIntervalSince1970 * 1000)
        return line(record)
    }

    func testKimiWireLogsGiveEachRequestItsTurnSubagentAndTitle() async throws {
        let config = try temporaryDirectory()
        let session = config.appendingPathComponent("sessions/wd_proj-ab12/session_7f3e", isDirectory: true)
        let main = session.appendingPathComponent("agents/main", isDirectory: true)
        let helper = session.appendingPathComponent("agents/agent-2", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let now = Date()
        let at = now.addingTimeInterval(-90)
        let usage: [String: Any] = ["inputOther": 300, "inputCacheRead": 9000, "inputCacheCreation": 100, "output": 40]
        let wire = line(["type": "metadata", "protocol_version": "1.5", "created_at": Int(at.timeIntervalSince1970 * 1000)])
            + kimiRow("turn.prompt", ["agentId": "main", "input": [["type": "text", "text": "fix it"]], "origin": ["kind": "user"]], at: at)
            + kimiRow("usage.record", ["agentId": "main", "model": "kimi-for-coding", "usage": usage, "usageScope": "turn"], at: at.addingTimeInterval(1))
            + kimiRow("usage.record", ["agentId": "main", "model": "kimi-for-coding", "usage": usage, "usageScope": "turn"], at: at.addingTimeInterval(2))
            + kimiRow("turn.ended", ["agentId": "main", "turnId": 0, "reason": "failed",
                                     "error": ["code": "provider.api_error", "name": "APIProviderQuotaExhaustedError",
                                               "message": "You exceeded your current quota", "retryable": false]], at: at.addingTimeInterval(3))
            + kimiRow("turn.ended", ["agentId": "main", "turnId": 1, "reason": "failed",
                                     "error": ["code": "provider.connection_error", "message": "socket hang up"]], at: at.addingTimeInterval(4))
        try wire.write(to: main.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        let sub = kimiRow("turn.prompt", ["agentId": "agent-2", "input": "task", "origin": ["kind": "agent"]], at: at)
            + kimiRow("usage.record", ["agentId": "agent-2", "model": "kimi-k3", "usage": usage, "usageScope": "turn"], at: at.addingTimeInterval(1))
        try sub.write(to: helper.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        try #"{"title":"Fix the login bug","titleKind":"generated"}"#
            .write(to: session.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let requests = await TranscriptRequestFeed().newRequests(.kimi, configDirectory: config.path, now: now)
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.map(\.session)), ["session_7f3e"])
        XCTAssertTrue(requests.allSatisfy { $0.sessionName == "Fix the login bug" })
        let mainRequests = requests.filter { !$0.subagent && $0.limitRefusal == nil }
        XCTAssertEqual(mainRequests.map(\.startsTurn), [true, false])
        XCTAssertEqual(mainRequests.first?.contextTokens, 9400)
        XCTAssertEqual(mainRequests.first?.cacheReadTokens, 9000)
        XCTAssertEqual(mainRequests.first?.cacheWriteTokens, 100)
        XCTAssertEqual(mainRequests.first?.outputTokens, 40)
        XCTAssertEqual(mainRequests.first?.model, "kimi-for-coding")
        let subagent = try XCTUnwrap(requests.first { $0.subagent })
        XCTAssertEqual(subagent.agent, "agent-2")
        XCTAssertEqual(subagent.agentModel, "kimi-k3")
        XCTAssertFalse(subagent.startsTurn)
        XCTAssertNil(subagent.model)
        XCTAssertEqual(requests.compactMap(\.limitRefusal), ["You exceeded your current quota"],
                       "a quota refusal counts; a dropped connection does not")
    }

    func testKimiRateLimitRefusalsAndUntitledSessions() {
        let file = TranscriptFile(url: URL(fileURLWithPath: "/x/sessions/w/s1/agents/main/wire.jsonl"), session: "s1")
        var state = TranscriptReadState()
        let row: [String: Any] = ["type": "turn.ended", "reason": "failed", "time": 1_794_668_397_000,
                                  "error": ["code": "provider.rate_limit", "message": "429 Too Many Requests"]]
        guard case let .refusal(refusal) = KimiTranscriptSource().row(row, file: file, state: &state) else {
            return XCTFail("a rate-limit failure is a refusal")
        }
        XCTAssertEqual(refusal.limitRefusal, "429 Too Many Requests")
        XCTAssertEqual(refusal.at, Date(timeIntervalSince1970: 1_794_668_397))
        XCTAssertNil(KimiTranscriptSource.title(inState: Data(#"{"title":"New Session"}"#.utf8)))
        XCTAssertEqual(KimiTranscriptSource.transcriptFile(URL(fileURLWithPath: "/x/sessions/w/s1/agents/agent-9/wire.jsonl")),
                       TranscriptFile(url: URL(fileURLWithPath: "/x/sessions/w/s1/agents/agent-9/wire.jsonl"), session: "s1", agent: "agent-9"))
        XCTAssertNil(KimiTranscriptSource.transcriptFile(URL(fileURLWithPath: "/x/sessions/w/s1/wire.jsonl")))
    }

    func testEveryProviderWithASourceLearnsFromIt() {
        for provider in [AIProviderType.claudeCode, .codex, .kimi] {
            XCTAssertNotNil(provider.capabilities.transcriptSource, "\(provider)")
        }
        XCTAssertEqual(AIProviderType.codex.capabilities.transcriptDirectory, "sessions")
        XCTAssertEqual(AIProviderType.claudeCode.capabilities.transcriptDirectory, "projects")
    }
}
