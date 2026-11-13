import Foundation

private let log = FileLog("TranscriptFeed")

/// One model request a CLI session made, as its transcript records it.
struct TranscriptRequest: Equatable, Sendable {
    let session: String
    let at: Date
    /// Input, cache write and cache read tokens together.
    let contextTokens: Int
    let cacheWriteTokens: Int
    /// The part of `cacheWriteTokens` written to the one-hour cache.
    let cacheWriteLongTokens: Int
    let outputTokens: Int
    /// Seconds the prompt cache written by the request lasts; nil when it
    /// wrote none, so the session's previous lifetime still applies.
    let cacheLifetime: TimeInterval?
    /// Whether the request answered a prompt rather than a tool result.
    let startsTurn: Bool
    /// The model the session itself asked; nil for a subagent's request,
    /// which may use another model than its session.
    var model: String? = nil
}

/// Reads each request's token use from the session transcripts a CLI writes
/// under `ProviderCapabilities.transcriptDirectory`, as the CLI appends to
/// them, for `SessionRates` and `TurnCostModel`. Used by
/// `AppState.ingestTranscriptRequests` for sessions the router does not
/// carry.
///
/// Each file is read from where the previous read stopped, up to its last
/// complete line. A response streamed as several content blocks repeats one
/// message's usage on every block, so a message counts once. A session's
/// subagents write their own transcripts under `<session>/subagents`, read
/// as requests of that session: they consume its account, and they never
/// start its turns.
actor TranscriptRequestFeed {
    static let shared = TranscriptRequestFeed()

    /// How far back the first read after launch looks; older requests no
    /// longer change a session's rate.
    static let initialLookback: TimeInterval = 2 * 60 * 60
    /// A file first seen larger than this is read only from this far before
    /// its end: the lookback rarely needs more, and a whole transcript of
    /// hundreds of megabytes would be held in memory at once.
    static let firstReadLimit: UInt64 = 8 * 1024 * 1024

    private struct FileState {
        var offset: UInt64
        /// Whether the session's last row was a prompt, so its next
        /// response starts a turn.
        var awaitingTurn: Bool
        /// The read starts inside a line, which is skipped.
        var skipsPartialLine = false
    }

    /// How often every subagent directory is listed again, quiet or not, so a
    /// transcript appended to after the lookback is still read.
    static let fullScanInterval: TimeInterval = 10 * 60

    /// A subagent directory whose transcripts were all older than the
    /// lookback when it was last listed. It is not listed again while its
    /// modification time stays the same, which keeps the cost of each read
    /// to the directories of sessions working now; its subdirectories are
    /// still visited, since files added to them change only their own time.
    /// They are kept as paths: a `URL` keeps the resource values read when
    /// it was listed, which would hide a later change of their time.
    private struct QuietDirectory {
        var modified: Date
        var subdirectories: [String]
    }

    private var files: [String: FileState] = [:]
    private var counted: Set<String> = []
    private var countedOrder: [String] = []
    private var quietDirectories: [String: QuietDirectory] = [:]
    private var lastFullScan: Date?

    /// Requests appended to the provider's transcripts since the last call.
    /// `configDirectory` replaces the provider's own, for tests.
    func newRequests(_ provider: AIProviderType, configDirectory: String? = nil,
                     now: Date = Date()) -> [TranscriptRequest] {
        guard let directory = provider.capabilities.transcriptDirectory else { return [] }
        let root = URL(fileURLWithPath: configDirectory ?? (provider.configDirectory as NSString).expandingTildeInPath)
            .appendingPathComponent(directory, isDirectory: true)
        let cutoff = now.addingTimeInterval(-Self.initialLookback)
        var requests: [TranscriptRequest] = []
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        func list(_ directory: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        let fullScan = lastFullScan.map { now.timeIntervalSince($0) >= Self.fullScanInterval } ?? true
        if fullScan {
            lastFullScan = now
            quietDirectories = [:]
        }
        for project in projects {
            for entry in list(project) {
                if entry.pathExtension == "jsonl" {
                    requests += readIfChanged(entry, session: entry.deletingPathExtension().lastPathComponent,
                                              subagent: false, cutoff: cutoff)
                    continue
                }
                // `<session>/subagents/*.jsonl`, and the workflow subagents'
                // `<session>/subagents/workflows/<run>/*.jsonl`.
                let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                guard (try? subagents.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                var pending = [subagents]
                while let directory = pending.popLast() {
                    let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantFuture
                    if let quiet = quietDirectories[directory.path], quiet.modified == modified {
                        pending += quiet.subdirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        continue
                    }
                    var subdirectories: [URL] = []
                    var quiet = true
                    for item in list(directory) {
                        if item.pathExtension == "jsonl" {
                            requests += readIfChanged(item, session: entry.lastPathComponent, subagent: true, cutoff: cutoff)
                            let itemModified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate ?? .distantFuture
                            if itemModified > cutoff { quiet = false }
                        } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            subdirectories.append(item)
                        }
                    }
                    pending += subdirectories
                    quietDirectories[directory.path] = quiet
                        ? QuietDirectory(modified: modified, subdirectories: subdirectories.map(\.path)) : nil
                }
            }
        }
        return requests.sorted { $0.at < $1.at }
    }

    private func readIfChanged(_ file: URL, session: String, subagent: Bool, cutoff: Date) -> [TranscriptRequest] {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        let path = file.path
        if files[path] == nil {
            // Files untouched within the lookback hold nothing current; a
            // file seen for the first time otherwise is read whole, as a new
            // session's is, up to `firstReadLimit` before its end.
            guard (values?.contentModificationDate ?? .distantPast) > cutoff else {
                files[path] = FileState(offset: size, awaitingTurn: false)
                return []
            }
            let start = size > Self.firstReadLimit ? size - Self.firstReadLimit : 0
            files[path] = FileState(offset: start, awaitingTurn: false, skipsPartialLine: start > 0)
        }
        guard var state = files[path] else { return [] }
        if size < state.offset { state = FileState(offset: 0, awaitingTurn: false) }
        guard size > state.offset else { return [] }
        let requests = read(file, session: session, subagent: subagent, state: &state, notBefore: cutoff)
        files[path] = state
        return requests
    }

    private func read(_ file: URL, session: String, subagent: Bool, state: inout FileState,
                      notBefore cutoff: Date) -> [TranscriptRequest] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            log.warning("Could not read \(file.lastPathComponent): \(error.localizedDescription)")
            return []
        }
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        state.offset += UInt64(end - data.startIndex + 1)
        var requests: [TranscriptRequest] = []
        var lines = data[data.startIndex...end].split(separator: UInt8(ascii: "\n"))[...]
        if state.skipsPartialLine {
            lines = lines.dropFirst()
            state.skipsPartialLine = false
        }
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch row["type"] as? String {
            case "user":
                if !subagent, Self.isPrompt(row) { state.awaitingTurn = true }
            case "assistant":
                guard let request = Self.request(row, session: session, startsTurn: state.awaitingTurn,
                                                 subagent: subagent) else { continue }
                if let key = Self.messageKey(row) {
                    guard !counted.contains(key) else { continue }
                    remember(key)
                }
                state.awaitingTurn = false
                if request.at >= cutoff { requests.append(request) }
            default:
                continue
            }
        }
        return requests
    }

    private func remember(_ key: String) {
        counted.insert(key)
        countedOrder.append(key)
        if countedOrder.count > 20_000 {
            let drop = countedOrder.prefix(10_000)
            counted.subtract(drop)
            countedOrder.removeFirst(10_000)
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
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
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
            model: subagent ? nil : message["model"] as? String
        )
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
