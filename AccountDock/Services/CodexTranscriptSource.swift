import Foundation

/// Codex's transcripts: the rollouts it writes under
/// `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, one per thread, a
/// resumed thread appending to its own. Every row is
/// `{"timestamp", "type", "payload"}`:
///
/// - `session_meta`: the thread's `id`, and for a subagent's thread the
///   `parent_thread_id` its requests are credited to;
/// - `turn_context`: the `model` the following requests use;
/// - `event_msg` `user_message`: a prompt, so the next request starts a turn;
/// - `event_msg` `token_count`: after each response, `info.last_token_usage`
///   (`input_tokens`, which include `cached_input_tokens` and
///   `cache_write_input_tokens`, and `output_tokens`) with the running
///   `total_token_usage`; a row repeating the previous total, or with
///   `info` null, reports rate limits only;
/// - `event_msg` `task_complete` or `error` whose `codex_error_info` is
///   `usage_limit_exceeded`: the turn was refused at a usage limit, in the
///   words of `message`.
///
/// Thread names live in `session_index.jsonl` in Codex's home, one
/// `{"id", "thread_name", "updated_at"}` per rename, the last one standing.
struct CodexTranscriptSource: ProviderTranscriptSource {
    let directory = "sessions"
    static let sessionIndexFile = "session_index.jsonl"
    static let usageLimitError = "usage_limit_exceeded"
    /// Seconds a prompt cache the provider wrote is taken to last.
    static let cacheLifetime: TimeInterval = 5 * 60

    func files(under root: URL, cutoff: Date, now: Date, listing: inout TranscriptListing) -> [TranscriptFile] {
        recentFiles(under: root, cutoff: cutoff) { url in
            guard let session = Self.sessionID(ofRollout: url) else { return nil }
            return TranscriptFile(url: url, session: session)
        }
    }

    /// The thread ID that ends a rollout's file name; nil for any other file.
    static func sessionID(ofRollout url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-"), name.count > 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) != nil ? id : nil
    }

    func row(_ row: [String: Any], file: TranscriptFile, state: inout TranscriptReadState) -> TranscriptRow {
        guard let payload = row["payload"] as? [String: Any] else { return .none }
        switch row["type"] as? String {
        case "session_meta":
            if let parent = (payload["parent_thread_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                state.session = parent
                state.agent = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file.session
            } else if let id = (payload["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                state.session = id
            }
            return .none
        case "turn_context":
            if let model = (payload["model"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) { state.model = model }
            return .none
        case "event_msg":
            break
        default:
            return .none
        }
        guard let stamp = row["timestamp"] as? String, let at = Self.date(stamp) else { return .none }
        let session = state.session ?? file.session
        switch payload["type"] as? String {
        case "user_message":
            return state.agent != nil ? .none : .prompt
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return .none }
            let total = (info["total_token_usage"] as? [String: Any]).map { Self.int($0["total_tokens"]) }
            if let total, total == state.lastTotal { return .none }
            state.lastTotal = total
            let input = Self.int(last["input_tokens"])
            let write = Self.int(last["cache_write_input_tokens"])
            let read = Self.int(last["cached_input_tokens"])
            guard input > 0 || Self.int(last["output_tokens"]) > 0 else { return .none }
            return .request(TranscriptRequest(
                session: session, at: at, contextTokens: input, cacheWriteTokens: write, cacheWriteLongTokens: 0,
                outputTokens: Self.int(last["output_tokens"]), cacheLifetime: write > 0 ? Self.cacheLifetime : nil,
                startsTurn: false, model: state.agent != nil ? nil : state.model, cacheReadTokens: read,
                agent: state.agent, agentModel: state.agent != nil ? state.model : nil
            ), key: nil)
        case "task_complete", "error":
            let error = payload["type"] as? String == "error" ? payload : payload["error"] as? [String: Any]
            guard let error, Self.isUsageLimit(error["codex_error_info"]) else { return .none }
            let words = error["message"] as? String ?? ""
            // A refused turn may be recorded by both its error and its end.
            if state.lastRefusal == words, let previous = state.lastRefusalAt, abs(at.timeIntervalSince(previous)) < 60 {
                return .none
            }
            state.lastRefusal = words
            state.lastRefusalAt = at
            return .refusal(TranscriptRequest(
                session: session, at: at, contextTokens: 0, cacheWriteTokens: 0, cacheWriteLongTokens: 0,
                outputTokens: 0, cacheLifetime: nil, startsTurn: false, limitRefusal: words, agent: state.agent
            ))
        default:
            return .none
        }
    }

    /// Whether a `codex_error_info` names the usage limit, as a plain value
    /// or as the key of one carrying details.
    static func isUsageLimit(_ info: Any?) -> Bool {
        if let text = info as? String { return text == usageLimitError }
        if let object = info as? [String: Any] { return object[usageLimitError] != nil }
        return false
    }

    func sessionNames(_ sessions: Set<String>, config: URL) -> [String: String] {
        guard let text = try? String(contentsOf: config.appendingPathComponent(Self.sessionIndexFile), encoding: .utf8)
        else { return [:] }
        return Self.sessionNames(inIndex: text, sessions: sessions)
    }

    /// The last name `session_index.jsonl` gives each of `sessions`.
    static func sessionNames(inIndex text: String, sessions: Set<String>) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, sessions.contains(id),
                  let name = (row["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { continue }
            names[id] = name.isEmpty ? nil : name
        }
        return names
    }
}
