import Foundation

/// Claude Code's transcripts: `projects/<project>/<session>.jsonl`, one per
/// session, and its subagents' under `<session>/subagents`, including the
/// workflow subagents' `<session>/subagents/workflows/<run>/*.jsonl`, read
/// as requests of that session. A response streamed as several content
/// blocks repeats one message's usage on every block, so a message counts
/// once.
struct ClaudeTranscriptSource: ProviderTranscriptSource {
    let directory = "projects"

    /// Lists every session transcript, and each subagent directory unless
    /// it was quiet when last listed and has not changed since: that keeps
    /// the cost of each read to the directories of sessions working now. A
    /// quiet directory's subdirectories are still visited, since files added
    /// to them change only their own time; every
    /// `TranscriptRequestFeed.fullScanInterval` all are listed again.
    func files(under root: URL, cutoff: Date, now: Date, listing: inout TranscriptListing) -> [TranscriptFile] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        func list(_ directory: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        let fullScan = listing.lastFullScan.map { now.timeIntervalSince($0) >= TranscriptRequestFeed.fullScanInterval } ?? true
        if fullScan {
            listing.lastFullScan = now
            listing.quietDirectories = [:]
        }
        var found: [TranscriptFile] = []
        for project in projects {
            for entry in list(project) {
                if entry.pathExtension == "jsonl" {
                    found.append(TranscriptFile(url: entry, session: entry.deletingPathExtension().lastPathComponent))
                    continue
                }
                let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                guard (try? subagents.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                var pending = [subagents]
                while let directory = pending.popLast() {
                    let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantFuture
                    if let quiet = listing.quietDirectories[directory.path], quiet.modified == modified {
                        pending += quiet.subdirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        continue
                    }
                    var subdirectories: [URL] = []
                    var quiet = true
                    for item in list(directory) {
                        if item.pathExtension == "jsonl" {
                            // The agent is named by its transcript's path under `subagents`.
                            let relative = String(item.deletingPathExtension().path.dropFirst(subagents.path.count + 1))
                            let agent = relative.isEmpty ? item.deletingPathExtension().lastPathComponent : relative
                            found.append(TranscriptFile(url: item, session: entry.lastPathComponent, agent: agent))
                            let itemModified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate ?? .distantFuture
                            if itemModified > cutoff { quiet = false }
                        } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            subdirectories.append(item)
                        }
                    }
                    pending += subdirectories
                    listing.quietDirectories[directory.path] = quiet
                        ? TranscriptListing.QuietDirectory(modified: modified, subdirectories: subdirectories.map(\.path)) : nil
                }
            }
        }
        return found
    }

    func row(_ row: [String: Any], file: TranscriptFile, state: inout TranscriptReadState) -> TranscriptRow {
        switch row["type"] as? String {
        case "user":
            return !file.subagent && Self.isPrompt(row) ? .prompt : .none
        case "assistant":
            if var refusal = Self.limitRefusal(row, session: file.session, subagent: file.subagent) {
                refusal.agent = file.agent
                return .refusal(refusal)
            }
            guard var request = Self.request(row, session: file.session, startsTurn: false, subagent: file.subagent)
            else { return .none }
            request.agent = file.agent
            return .request(request, key: Self.messageKey(row))
        default:
            return .none
        }
    }

    /// Whether a `user` row is a prompt the user typed, rather than a tool
    /// result or a message the CLI inserted.
    static func isPrompt(_ row: [String: Any]) -> Bool {
        if row["isMeta"] as? Bool == true || row["isSidechain"] as? Bool == true { return false }
        let content = (row["message"] as? [String: Any])?["content"]
        if let text = content as? String { return !text.isEmpty }
        if let blocks = content as? [[String: Any]] {
            return !blocks.isEmpty && !blocks.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }

    /// The message's id and request id, which every content block of one
    /// response repeats.
    static func messageKey(_ row: [String: Any]) -> String? {
        let message = row["message"] as? [String: Any]
        let id = (message?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let request = (row["requestId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard id != nil || request != nil else { return nil }
        return "\(id ?? ""):\(request ?? "")"
    }

    /// The request an `assistant` row records; nil for rows without usage
    /// and for responses the CLI made up itself. A subagent's rows are
    /// sidechain rows credited to `session`, its parent; in a session's own
    /// transcript a sidechain row is another session's.
    static func request(_ row: [String: Any], session: String, startsTurn: Bool,
                        subagent: Bool = false) -> TranscriptRequest? {
        guard subagent || row["isSidechain"] as? Bool != true,
              let message = row["message"] as? [String: Any],
              (message["model"] as? String).map({ !$0.isEmpty && $0 != "<synthetic>" }) == true,
              let usage = message["usage"] as? [String: Any],
              let stamp = row["timestamp"] as? String,
              let at = Self.date(stamp) else { return nil }
        let input = int(usage["input_tokens"])
        let write = int(usage["cache_creation_input_tokens"])
        let read = int(usage["cache_read_input_tokens"])
        let creation = usage["cache_creation"] as? [String: Any]
        let long = int(creation?["ephemeral_1h_input_tokens"])
        let short = int(creation?["ephemeral_5m_input_tokens"])
        let lifetime: TimeInterval? = long > 0 ? 3600 : (short > 0 || write > 0 ? 300 : nil)
        return TranscriptRequest(
            session: subagent ? session : (row["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session,
            at: at, contextTokens: input + write + read, cacheWriteTokens: write, cacheWriteLongTokens: long,
            outputTokens: int(usage["output_tokens"]), cacheLifetime: lifetime, startsTurn: startsTurn,
            model: subagent ? nil : message["model"] as? String, cacheReadTokens: read,
            agent: subagent ? "" : nil, agentModel: subagent ? message["model"] as? String : nil
        )
    }

    /// The refusal an `assistant` row records when the provider turned the
    /// request away at a usage limit: the CLI writes it as a response of its
    /// own, marked as an API error of the rate-limit kind, with no usage. It
    /// is credited to a session as `request` credits a row.
    static func limitRefusal(_ row: [String: Any], session: String, subagent: Bool = false) -> TranscriptRequest? {
        guard row["isApiErrorMessage"] as? Bool == true, row["error"] as? String == "rate_limit",
              subagent || row["isSidechain"] as? Bool != true,
              let stamp = row["timestamp"] as? String, let at = Self.date(stamp) else { return nil }
        let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]]
        let words = content?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
        return TranscriptRequest(
            session: subagent ? session : (row["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session,
            at: at, contextTokens: 0, cacheWriteTokens: 0, cacheWriteLongTokens: 0, outputTokens: 0,
            cacheLifetime: nil, startsTurn: false, limitRefusal: words, agent: subagent ? "" : nil
        )
    }
}
