import Foundation

/// Kimi Code's transcripts: each agent's event log,
/// `sessions/<workspace>/<session>/agents/<agent>/wire.jsonl`, `main` for
/// the session's own agent and one directory for each subagent, whose
/// requests are the session's. Every row is an event,
/// `{"type", …, "time"}` with `time` in milliseconds:
///
/// - `turn.prompt`: a prompt, so the next request starts a turn;
/// - `usage.record`: one model request, its `model` and `usage`
///   (`inputOther`, `inputCacheRead`, `inputCacheCreation`, `output`);
/// - `turn.ended` with `reason` `failed`: its `error` payload says why; a
///   usage limit is `code` `provider.rate_limit` or the
///   `APIProviderQuotaExhaustedError`, in the words of `message`.
///
/// A session's title is in `<session>/state.json`, `title`, which reads
/// `New Session` until it has one.
struct KimiTranscriptSource: ProviderTranscriptSource {
    let directory = "sessions"
    static let wireFile = "wire.jsonl"
    static let mainAgent = "main"
    static let stateFile = "state.json"
    static let untitled = "New Session"
    static let rateLimitCode = "provider.rate_limit"
    static let quotaExhaustedName = "APIProviderQuotaExhaustedError"

    /// Walks only the levels event logs sit at: a session directory also
    /// holds blobs, tool output and file history, which a full walk would
    /// visit on every read.
    func files(under root: URL, cutoff: Date, now: Date, listing: inout TranscriptListing) -> [TranscriptFile] {
        let fm = FileManager.default
        func children(_ directory: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        var found: [TranscriptFile] = []
        for workspace in children(root) {
            for session in children(workspace) {
                for agent in children(session.appendingPathComponent("agents", isDirectory: true)) {
                    let wire = agent.appendingPathComponent(Self.wireFile)
                    guard let modified = (try? wire.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                          modified > cutoff, let file = Self.transcriptFile(wire) else { continue }
                    found.append(file)
                }
            }
        }
        return found
    }

    /// The session and agent a `…/<session>/agents/<agent>/wire.jsonl`
    /// belongs to; nil for any other file.
    static func transcriptFile(_ url: URL) -> TranscriptFile? {
        guard url.lastPathComponent == wireFile else { return nil }
        let agent = url.deletingLastPathComponent()
        let agents = agent.deletingLastPathComponent()
        guard agents.lastPathComponent == "agents" else { return nil }
        let session = agents.deletingLastPathComponent().lastPathComponent
        guard !session.isEmpty else { return nil }
        return TranscriptFile(url: url, session: session, subagent: agent.lastPathComponent != mainAgent)
    }

    func row(_ row: [String: Any], file: TranscriptFile, state: inout TranscriptReadState) -> TranscriptRow {
        guard let millis = (row["time"] as? NSNumber)?.doubleValue else { return .none }
        let at = Date(timeIntervalSince1970: millis / 1000)
        switch row["type"] as? String {
        case "turn.prompt":
            let trigger = row["trigger"] as? String
            return !file.subagent && (trigger == nil || trigger == "normal") ? .prompt : .none
        case "usage.record":
            guard let usage = row["usage"] as? [String: Any] else { return .none }
            let other = Self.int(usage["inputOther"])
            let read = Self.int(usage["inputCacheRead"])
            let write = Self.int(usage["inputCacheCreation"])
            let output = Self.int(usage["output"])
            guard other + read + write + output > 0 else { return .none }
            let model = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .request(TranscriptRequest(
                session: file.session, at: at, contextTokens: other + read + write, cacheWriteTokens: write,
                cacheWriteLongTokens: 0, outputTokens: output, cacheLifetime: nil, startsTurn: false,
                model: file.subagent ? nil : model, cacheReadTokens: read, subagent: file.subagent
            ), key: nil)
        case "turn.ended":
            guard row["reason"] as? String == "failed", let error = row["error"] as? [String: Any],
                  error["code"] as? String == Self.rateLimitCode || error["name"] as? String == Self.quotaExhaustedName
            else { return .none }
            return .refusal(TranscriptRequest(
                session: file.session, at: at, contextTokens: 0, cacheWriteTokens: 0, cacheWriteLongTokens: 0,
                outputTokens: 0, cacheLifetime: nil, startsTurn: false,
                limitRefusal: error["message"] as? String ?? "", subagent: file.subagent
            ))
        default:
            return .none
        }
    }

    /// Each session's title from its `state.json`, found under any
    /// workspace directory of `sessions`.
    func sessionNames(_ sessions: Set<String>, config: URL) -> [String: String] {
        let root = config.appendingPathComponent(directory, isDirectory: true)
        let workspaces = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
        var names: [String: String] = [:]
        for session in sessions {
            for workspace in workspaces {
                let file = workspace.appendingPathComponent(session, isDirectory: true).appendingPathComponent(Self.stateFile)
                guard let data = try? Data(contentsOf: file) else { continue }
                if let name = Self.title(inState: data) { names[session] = name }
                break
            }
        }
        return names
    }

    /// The title a session's `state.json` holds; nil while it has none.
    static func title(inState data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != untitled else { return nil }
        return title
    }
}
