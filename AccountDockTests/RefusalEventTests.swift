import XCTest
@testable import AccountDock

/// A session refused at a usage limit is recorded once per limit, however
/// many of its subagents are refused and however many replies they sent
/// before the limit land in between. The fixture is the minute hexorda ran
/// out under platform-engineer (session 33962de2, sixteen agents) and
/// platform-execution (session 583fb354, five): their transcripts and their
/// subagents' interleave refusals with served replies from 18:05:12 to
/// 18:05:34.
final class RefusalEventTests: XCTestCase {
    private let words = "You've hit your session limit · resets 9:10pm (Australia/Melbourne)"

    private func row(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func served(_ id: String, at: Date, session: String, sidechain: Bool) -> String {
        row(["type": "assistant", "isSidechain": sidechain, "timestamp": stamp(at), "requestId": "r-" + id,
             "sessionId": session,
             "message": ["id": id, "model": "claude-opus-5-5",
                         "usage": ["input_tokens": 1, "cache_read_input_tokens": 200_000, "output_tokens": 400]]])
    }

    private func refused(at: Date, session: String, sidechain: Bool) -> String {
        row(["type": "assistant", "isSidechain": sidechain, "isApiErrorMessage": true, "error": "rate_limit",
             "timestamp": stamp(at), "sessionId": session,
             "message": ["model": "<synthetic>", "content": [["type": "text", "text": words]]]])
    }

    /// One row of the fixture: seconds after the minute, the agent (nil for
    /// the session's own transcript), and whether it was refused.
    private typealias Step = (seconds: Double, agent: String?, refused: Bool)

    /// platform-engineer's rows in the order they were written.
    private let engineer: [Step] = [
        (11.741, "aio-switch", false), (12.660, "session-rpc", true), (12.767, "aio-switch", true),
        (13.725, nil, false), (14.334, "training-executor", false), (15.460, nil, true),
        (16.513, "seed-producer", false), (17.651, "conversation", false), (18.731, "daemon-3", true),
        (22.987, "consolidation", false), (23.580, "operations", false), (24.168, "training-executor", true),
        (24.975, nil, true), (25.368, "conversation", true), (25.739, "consolidation", false),
        (27.784, "consolidation", true), (33.889, "operations", true),
    ]

    /// platform-execution's rows.
    private let execution: [Step] = [
        (12.705, nil, false), (14.600, "ab07", false), (14.779, "a3dd", true), (15.116, nil, false),
        (15.753, "ab07", true), (16.975, nil, false), (17.065, "ae02", true), (18.453, nil, false),
        (19.264, "a4ca", true), (20.508, "a797", true), (27.112, nil, true),
    ]

    /// Writes `steps` as the transcript of `session` and its subagents under
    /// a fresh config directory, the minute starting at `minute`.
    private func writeTranscripts(_ steps: [Step], session: String, minute: Date, config: URL) throws {
        let fm = FileManager.default
        let project = config.appendingPathComponent("projects/p", isDirectory: true)
        let subagents = project.appendingPathComponent("\(session)/subagents", isDirectory: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for (index, step) in steps.enumerated() {
            let at = minute.addingTimeInterval(step.seconds)
            let name = step.agent.map { "agent-\($0).jsonl" } ?? "\(session).jsonl"
            let text = step.refused
                ? refused(at: at, session: step.agent.map { "agent-\($0)" } ?? session, sidechain: step.agent != nil)
                : served("\(session)-\(index)", at: at, session: step.agent.map { "agent-\($0)" } ?? session,
                         sidechain: step.agent != nil)
            files[name, default: ""] += text
        }
        for (name, text) in files {
            let directory = name == "\(session).jsonl" ? project : subagents
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// The events `noteRefusal` records for `requests`, read in order as
    /// `recordTranscriptRequests` reads them, by its rules: the latest
    /// refusal kept per session, a served request clearing it only when it
    /// answers it (`servedAnswersRefusal`), and an event for each refusal
    /// `refusalIsNews` passes. `oldRule` replays the rule that let any
    /// served request start a new run.
    private func events(_ requests: [TranscriptRequest], now: Date, oldRule: Bool = false) -> [String: Int] {
        var refusals: [String: AppState.SessionRefusal] = [:]
        var noted: [String: AppState.NotedRefusal] = [:]
        var counts: [String: Int] = [:]
        for request in requests {
            if let words = request.limitRefusal {
                let last = refusals[request.session]?.at
                guard last.map({ $0 < request.at }) ?? true else { continue }
                refusals[request.session] = AppState.SessionRefusal(at: request.at, account: UUID(), words: words,
                                                                    agent: request.agent)
                let limit = AppState.refusalLimitKey(words, at: request.at)
                let news = oldRule
                    ? AppState.refusalIsNews(at: request.at, last: last, now: now)
                    : AppState.refusalIsNews(at: request.at, limit: limit, noted: noted[request.session], now: now)
                guard news else { continue }
                noted[request.session] = AppState.NotedRefusal(limit: limit, at: request.at)
                counts[request.session, default: 0] += 1
                continue
            }
            guard let refusal = refusals[request.session] else { continue }
            let answers = oldRule ? refusal.at < request.at : AppState.servedAnswersRefusal(refusal, request: request)
            if answers { refusals[request.session] = nil }
        }
        return counts
    }

    func testEachSessionIsRecordedOnceForTheLimitItsSubagentsRanInto() async throws {
        let fm = FileManager.default
        let config = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: config) }
        let now = Date()
        let minute = now.addingTimeInterval(-40)
        try writeTranscripts(engineer, session: "33962de2", minute: minute, config: config)
        try writeTranscripts(execution, session: "583fb354", minute: minute, config: config)

        let requests = await TranscriptRequestFeed().newRequests(.claudeCode, configDirectory: config.path, now: now)
        let refusals = requests.filter { $0.limitRefusal != nil }
        XCTAssertEqual(refusals.count, engineer.filter(\.refused).count + execution.filter(\.refused).count,
                       "every refusal is read, those only a subagent's transcript holds included")
        XCTAssertEqual(Set(refusals.filter { $0.agent != nil }.map(\.session)), ["33962de2", "583fb354"],
                       "a subagent's refusal is its session's")

        XCTAssertEqual(events(requests, now: now), ["33962de2": 1, "583fb354": 1],
                       "one event per session for the one limit")
        XCTAssertGreaterThan(events(requests, now: now, oldRule: true)["33962de2"] ?? 0, 1,
                             "replies sent before the limit started a new run each time")
    }

    func testOnlyTheRefusedAgentsOwnLaterRequestAnswersItsRefusal() {
        let at = Date()
        let refusal = AppState.SessionRefusal(at: at, account: UUID(), words: words, agent: "daemon-3")
        func request(_ seconds: TimeInterval, agent: String?) -> TranscriptRequest {
            TranscriptRequest(session: "33962de2", at: at.addingTimeInterval(seconds), contextTokens: 1,
                              cacheWriteTokens: 0, cacheWriteLongTokens: 0, outputTokens: 1, cacheLifetime: nil,
                              startsTurn: false, agent: agent)
        }
        XCTAssertFalse(AppState.servedAnswersRefusal(refusal, request: request(5, agent: "consolidation")),
                       "another agent's reply landing seconds later was sent before the limit")
        XCTAssertFalse(AppState.servedAnswersRefusal(refusal, request: request(5, agent: nil)))
        XCTAssertTrue(AppState.servedAnswersRefusal(refusal, request: request(30, agent: "daemon-3")),
                      "the refused agent served again: the account serves it")
        XCTAssertTrue(AppState.servedAnswersRefusal(refusal, request: request(6 * 60, agent: nil)),
                      "a request well after the refusal was sent after it")
        XCTAssertFalse(AppState.servedAnswersRefusal(refusal, request: request(-1, agent: "daemon-3")))
    }

    func testALaterLimitIsNewsAndARefusalWithoutAResetIsSpacedOut() {
        let now = Date()
        let first = AppState.refusalLimitKey(words, at: now.addingTimeInterval(-300))
        let noted = AppState.NotedRefusal(limit: first, at: now.addingTimeInterval(-300))
        XCTAssertFalse(AppState.refusalIsNews(at: now.addingTimeInterval(-30), limit: first, noted: noted, now: now),
                       "the same limit again")
        let weekly = AppState.refusalLimitKey("You've hit your weekly limit · resets Nov 20 at 12pm", at: now)
        XCTAssertTrue(AppState.refusalIsNews(at: now.addingTimeInterval(-30), limit: weekly, noted: noted, now: now),
                      "another limit")
        let plain = AppState.refusalLimitKey("You've reached your limit.", at: now)
        let notedPlain = AppState.NotedRefusal(limit: plain, at: now.addingTimeInterval(-90))
        XCTAssertFalse(AppState.refusalIsNews(at: now.addingTimeInterval(-30), limit: plain, noted: notedPlain, now: now))
        XCTAssertFalse(AppState.refusalIsNews(at: now.addingTimeInterval(-60 * 60), limit: first, noted: nil, now: now),
                       "read back from the transcript at launch")
    }
}
