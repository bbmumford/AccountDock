import Darwin
import Foundation

/// One CLI session as its lifecycle hooks last recorded it. Every provider's
/// hooks write the same record, named `<pause gate key>-<session>.json`, so
/// session counts, pausing and restarts read sessions the same way for
/// every provider.
struct AgentSession: Decodable, Equatable, Sendable {
    let sessionID: String
    /// The provider's pause-gate key; absent in records written before it
    /// was recorded.
    let provider: String?
    /// The last lifecycle event: `SessionStart`, `UserPromptSubmit`, `Stop`
    /// or `SessionEnd`.
    let event: String?
    let workingDirectory: String?
    let processID: Int32?
    let host: String?
    let observedAt: Date?

    /// Whether a turn is under way: the last event was a prompt.
    var isWorking: Bool { event == "UserPromptSubmit" }
}

enum AgentSessions {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Sessions", isDirectory: true)
    }

    /// A session not heard from for this long is not counted as live, even
    /// when a process with its recorded ID still runs.
    static let liveLifetime: TimeInterval = 12 * 60 * 60

    /// Every recorded session of `provider`, by session ID. A record file is
    /// read again only when its modification time or size changed, since
    /// several readers each refresh call this over thousands of records.
    ///
    /// The live directory's result is shared for `snapshotLifetime`, because
    /// one refresh reaches this from `live`, `byProcess` and the pause checks
    /// and each would otherwise stat every record again.
    static func records(_ provider: AIProviderType, directory: URL = directory) -> [String: AgentSession] {
        guard directory == Self.directory else { return readRecords(provider, directory: directory) }
        let now = Date()
        if let shared = recordCache.snapshot(of: provider, at: now) { return shared }
        let records = readRecords(provider, directory: directory)
        recordCache.storeSnapshot(records, of: provider, at: now)
        return records
    }

    /// How long `records` shares one read of the live directory; well under
    /// the quota cycle that consumes it.
    static let snapshotLifetime: TimeInterval = 5

    private static func readRecords(_ provider: AIProviderType, directory: URL) -> [String: AgentSession] {
        guard let key = provider.capabilities.pauseGate?.key,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
              ) else { return [:] }
        var records: [String: AgentSession] = [:]
        for url in urls where url.lastPathComponent.hasPrefix("\(key)-") && url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = RecordCache.Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
            let record: AgentSession?
            if let cached = recordCache.record(at: url.path, stamp: stamp) {
                record = cached
            } else {
                record = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AgentSession.self, from: $0) }
                recordCache.store(record, at: url.path, stamp: stamp)
            }
            if let record { records[record.sessionID] = record }
        }
        return records
    }

    /// Decoded records by path with the file's modification time and size
    /// when read, for `records`.
    private final class RecordCache: @unchecked Sendable {
        struct Stamp: Equatable {
            let modified: Date?
            let size: Int?
        }

        private let lock = NSLock()
        private var entries: [String: (stamp: Stamp, record: AgentSession?)] = [:]
        private var snapshots: [AIProviderType: (at: Date, records: [String: AgentSession])] = [:]

        func snapshot(of provider: AIProviderType, at now: Date) -> [String: AgentSession]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = snapshots[provider], now.timeIntervalSince(entry.at) < snapshotLifetime else { return nil }
            return entry.records
        }

        func storeSnapshot(_ records: [String: AgentSession], of provider: AIProviderType, at now: Date) {
            lock.lock()
            defer { lock.unlock() }
            snapshots[provider] = (now, records)
        }

        /// The cached decode of `path`, wrapped so an unreadable record also
        /// counts as cached; nil when the file changed since.
        func record(at path: String, stamp: Stamp) -> AgentSession?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[path], entry.stamp == stamp, stamp.modified != nil else { return nil }
            return .some(entry.record)
        }

        func store(_ record: AgentSession?, at path: String, stamp: Stamp) {
            lock.lock()
            defer { lock.unlock() }
            entries[path] = (stamp, record)
        }
    }

    private static let recordCache = RecordCache()

    /// Sessions running now: the process is alive, the session has not
    /// ended, and it was heard from within `liveLifetime`.
    static func live(
        _ provider: AIProviderType,
        directory: URL = directory,
        now: Date = Date(),
        isAlive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 }
    ) -> [AgentSession] {
        records(provider, directory: directory).values.filter { record in
            guard record.event != "SessionEnd", let observedAt = record.observedAt,
                  now.timeIntervalSince(observedAt) < liveLifetime else { return false }
            return record.processID.map(isAlive) ?? false
        }.sorted { $0.sessionID < $1.sessionID }
    }

    /// The newest record of each process, for matching running processes to
    /// their sessions.
    static func byProcess(_ provider: AIProviderType, directory: URL = directory) -> [Int32: AgentSession] {
        records(provider, directory: directory).values.reduce(into: [:]) { result, record in
            guard let pid = record.processID else { return }
            if let existing = result[pid], let old = existing.observedAt, let new = record.observedAt, old > new { return }
            result[pid] = record
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return decoder
    }()
}
