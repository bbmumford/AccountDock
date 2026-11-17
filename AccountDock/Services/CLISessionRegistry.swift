import Foundation

/// The sessions a CLI's own running processes say they hold: Claude Code
/// writes one file per interactive process once its session has started,
/// `<config directory>/<cliSessionRegistry>/<pid>.json`, naming the process,
/// its session ID, its folder, when it started and whether a turn is under
/// way. Read only, never written.
///
/// AccountDock's own lifecycle records are what it knows sessions by, but a
/// session can run with none it still counts: one quiet at its prompt for
/// longer than `AgentSessions.liveLifetime`, or one resumed in a process
/// whose hooks have not written yet. `AgentSessions.live` takes this
/// registry so such a session is still a session, listed by a pause and
/// named by its ID. A CLI process in a slot that the registry does not list
/// has no session yet, such as one waiting at a prompt before its session
/// starts, and sends no request; `AppState.slotRunDirectories` leaves it
/// out of the runs that are planned and charged.
enum CLISessionRegistry {
    struct Entry: Equatable, Sendable {
        var pid: Int32
        var sessionID: String
        var workingDirectory: String?
        /// When the process started its session.
        var startedAt: Date?
        /// Whether the CLI reports a turn under way.
        var busy: Bool?
    }

    /// The provider's registry folder; nil for a CLI that keeps none
    /// (`ProviderCapabilities.cliSessionRegistry`).
    static func directory(_ provider: AIProviderType,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let folder = provider.capabilities.cliSessionRegistry else { return nil }
        let config = provider.capabilities.configDirectory
        let base = config.hasPrefix("~/")
            ? home.appendingPathComponent(String(config.dropFirst(2)), isDirectory: true)
            : URL(fileURLWithPath: (config as NSString).expandingTildeInPath, isDirectory: true)
        return base.appendingPathComponent(folder, isDirectory: true)
    }

    /// The provider's registry now, by process ID; nil when it keeps none,
    /// or its folder cannot be read, so a reader falls back to what it
    /// knows without one.
    static func read(_ provider: AIProviderType) -> [Int32: Entry]? {
        directory(provider).flatMap { read(directory: $0) }
    }

    /// Every entry in `directory`, by process ID; nil when the folder cannot
    /// be listed. A file that is not one process's entry (another kind of
    /// file the CLI keeps there, or one half written) is skipped.
    static func read(directory: URL) -> [Int32: Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var entries: [Int32: Entry] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let entry = entry(data) else { continue }
            entries[entry.pid] = entry
        }
        return entries
    }

    /// One process's entry from its file's contents.
    static func entry(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let session = object["sessionId"] as? String, !session.isEmpty else { return nil }
        let started = (object["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let status = object["status"] as? String
        return Entry(pid: pid, sessionID: session, workingDirectory: object["cwd"] as? String, startedAt: started,
                     busy: status.map { $0 == "busy" })
    }
}
