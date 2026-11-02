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

    /// Every recorded session of `provider`, by session ID.
    static func records(_ provider: AIProviderType, directory: URL = directory) -> [String: AgentSession] {
        guard let key = provider.capabilities.pauseGate?.key,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var records: [String: AgentSession] = [:]
        for name in names where name.hasPrefix("\(key)-") && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? decoder.decode(AgentSession.self, from: data) else { continue }
            records[record.sessionID] = record
        }
        return records
    }

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
