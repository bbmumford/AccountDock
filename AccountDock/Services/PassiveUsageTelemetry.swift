import Foundation

/// One quota reading obtained without calling a provider usage endpoint.
struct PassiveUsageObservation: Sendable {
    enum Source: String, Sendable {
        /// `cachedUsageUtilization` that Claude Code writes into `~/.claude.json`.
        case claudeUsageCache
        /// Rate limits Claude Code hands to its status-line command per response.
        case claudeStatusLine
        /// `token_count.rate_limits` recorded in a Codex rollout.
        case codexRollout

        /// The provider whose accounts the source's readings belong to.
        var provider: AIProviderType {
            switch self {
            case .claudeUsageCache, .claudeStatusLine: .claudeCode
            case .codexRollout: .codex
            }
        }

        /// Whether every reading names its account, so one that does not
        /// cannot be attributed.
        var alwaysNamesAccount: Bool { self == .claudeUsageCache }

        /// Whether a running session writes the source's reading with each
        /// response, so a new one arrives every few seconds while it works:
        /// `AppState.liveReadingAt` lets such a reading stand over the
        /// forecast (`FailoverPlanner.liveReadingShowsRoom`).
        var reportsWithEachResponse: Bool { self != .claudeUsageCache }
    }

    /// How a reading names the account it belongs to.
    enum AccountKey: Equatable {
        /// The provider's own identifier for the account.
        case providerAccountID(String)
        /// The credential directory of the session that reported it.
        case credentialLocation(String)
    }

    let source: Source
    let usage: UsageAPIResponse
    let observedAt: Date
    /// Claude account UUID reported alongside the reading, when the source has one.
    let claudeAccountUUID: String?
    /// Codex home whose rollout produced the reading; nil for `~/.codex`.
    let codexHome: String?
    /// Process that produced the reading, when known.
    let processKey: String?
    /// The provider reported that a limit has already been reached.
    let limitReached: Bool
    /// Model the reporting session was using, when the source says.
    var model: String? = nil
    /// The name the reporting session shows for itself, when the source
    /// says; `AppState.sessionNames` keeps it for the account cards.
    var sessionName: String? = nil
    /// The one-session slot directory the reporting session reads, when the
    /// source says; `AppState.slotSessionsByDirectory` names the session of
    /// a slot whose process left no session record by it.
    var slotDirectory: String? = nil

    var accountKey: AccountKey? {
        claudeAccountUUID.map(AccountKey.providerAccountID) ?? codexHome.map(AccountKey.credentialLocation)
    }

    func with(usage: UsageAPIResponse) -> PassiveUsageObservation {
        PassiveUsageObservation(
            source: source, usage: usage, observedAt: observedAt,
            claudeAccountUUID: claudeAccountUUID, codexHome: codexHome,
            processKey: processKey, limitReached: limitReached, model: model, sessionName: sessionName,
            slotDirectory: slotDirectory
        )
    }
}

/// Reads quota data that Claude Code and Codex already record on disk, so the
/// failover monitor rarely needs its own usage request. Each reader only
/// touches files whose modification time changed since the previous read.
final class PassiveUsageTelemetry: @unchecked Sendable {
    static let shared = PassiveUsageTelemetry()

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let collectLock = NSLock()
    private var claudeConfigModified: Date?
    private var seenFileDates: [String: Date] = [:]

    static var telemetryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Telemetry", isDirectory: true)
    }

    /// New readings since the previous call, oldest first.
    func collect(codexHomes: [String], now: Date = Date()) -> [PassiveUsageObservation] {
        collectLock.lock(); defer { collectLock.unlock() }
        var result: [PassiveUsageObservation] = []
        if let cached = readClaudeUsageCache() { result.append(cached) }
        result.append(contentsOf: readClaudeStatusLines(now: now))
        result.append(contentsOf: readCodexRollouts(codexHomes: codexHomes, now: now))
        return result.sorted { $0.observedAt < $1.observedAt }
    }

    // MARK: - Claude usage cache

    private func readClaudeUsageCache() -> PassiveUsageObservation? {
        let url = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let modified = modificationDate(url), changed(&claudeConfigModified, to: modified),
              let data = try? Data(contentsOf: url) else { return nil }
        return Self.claudeUsageCacheObservation(from: data)
    }

    static func claudeUsageCacheObservation(from data: Data) -> PassiveUsageObservation? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cache["utilization"],
              let utilizationData = try? JSONSerialization.data(withJSONObject: utilization),
              let usage = try? JSONDecoder().decode(UsageAPIResponse.self, from: utilizationData),
              usage.fiveHour != nil || usage.sevenDay != nil else { return nil }
        return PassiveUsageObservation(
            source: .claudeUsageCache,
            usage: usage,
            observedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            claudeAccountUUID: cache["accountUuid"] as? String,
            codexHome: nil,
            processKey: nil,
            limitReached: [usage.fiveHour, usage.sevenDay].contains { ($0?.utilization ?? 0) >= 100 }
        )
    }

    // MARK: - Claude status line

    private func readClaudeStatusLines(now: Date) -> [PassiveUsageObservation] {
        let directory = Self.telemetryDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var result: [PassiveUsageObservation] = []
        for file in files where file.lastPathComponent.hasPrefix("claude-") && file.pathExtension == "json" {
            guard let modified = modificationDate(file) else { continue }
            // Sessions that ended leave their last payload behind; it no longer
            // describes live consumption and is removed once it is a day old.
            let slotFile = file.deletingPathExtension().appendingPathExtension("slot")
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? fileManager.removeItem(at: file)
                try? fileManager.removeItem(at: slotFile)
                continue
            }
            guard markSeen(file.path, modified),
                  let data = try? Data(contentsOf: file),
                  var observation = Self.statusLineObservation(
                    from: data,
                    observedAt: modified,
                    processKey: String(file.deletingPathExtension().lastPathComponent.dropFirst("claude-".count))
                  ) else { continue }
            observation.slotDirectory = (try? String(contentsOf: slotFile, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
            result.append(observation)
        }
        return result
    }

    static func statusLineObservation(from data: Data, observedAt: Date, processKey: String?) -> PassiveUsageObservation? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String, seconds: Int) -> UsageWindow? {
            guard let value = limits[key] as? [String: Any],
                  let used = (value["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (value["resets_at"] as? NSNumber).map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.doubleValue))
            }
            return UsageWindow(utilization: used, resetsAt: reset, windowSeconds: seconds)
        }
        let session = window("five_hour", seconds: 18_000)
        let weekly = window("seven_day", seconds: 604_800)
        guard session != nil || weekly != nil else { return nil }
        let usage = UsageAPIResponse(
            fiveHour: session, sevenDay: weekly, sevenDayOauthApps: nil, sevenDayOpus: nil,
            sevenDaySonnet: nil, sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
        return PassiveUsageObservation(
            source: .claudeStatusLine,
            usage: usage,
            observedAt: observedAt,
            claudeAccountUUID: nil,
            codexHome: nil,
            processKey: (root["session_id"] as? String) ?? processKey,
            limitReached: [session, weekly].contains { ($0?.utilization ?? 0) >= 100 },
            model: (root["model"] as? [String: Any]).flatMap { ($0["display_name"] as? String) ?? ($0["id"] as? String) },
            sessionName: (root["session_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Codex rollouts

    private func readCodexRollouts(codexHomes: [String], now: Date) -> [PassiveUsageObservation] {
        let systemHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        var result: [PassiveUsageObservation] = []
        for home in [systemHome] + codexHomes {
            for directory in Self.recentRolloutDirectories(home: home, now: now) {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    guard let modified = modificationDate(file),
                          now.timeIntervalSince(modified) < 30 * 60,
                          markSeen(file.path, modified),
                          let observation = Self.latestCodexRateLimits(
                            path: file.path,
                            codexHome: home == systemHome ? nil : home
                          ) else { continue }
                    result.append(observation)
                }
            }
        }
        return result
    }

    /// Rollouts are filed under `sessions/YYYY/MM/DD`; only today's and
    /// yesterday's folders can hold a session that is still writing.
    static func recentRolloutDirectories(home: String, now: Date) -> [URL] {
        let calendar = Calendar.current
        return [0, -1].compactMap { offset -> URL? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
            return URL(fileURLWithPath: home)
                .appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date), isDirectory: true)
        }
    }

    static func latestCodexRateLimits(path: String, codexHome: String?) -> PassiveUsageObservation? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let tail = min(length, 192 * 1024)
        try? handle.seek(toOffset: length - tail)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() where line.contains("\"rate_limits\"") {
            if let observation = codexObservation(
                fromLine: Data(line.utf8),
                codexHome: codexHome,
                processKey: CodexService.sessionID(fromRolloutPath: path)
            ) {
                return observation
            }
        }
        return nil
    }

    static func codexObservation(
        fromLine data: Data,
        codexHome: String?,
        processKey: String? = nil
    ) -> PassiveUsageObservation? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = row["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let stamp = row["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let observedAt = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return nil }

        var windows: [(minutes: Int, window: UsageWindow)] = []
        for key in ["primary", "secondary"] {
            guard let value = limits[key] as? [String: Any],
                  let used = (value["used_percent"] as? NSNumber)?.doubleValue,
                  let minutes = (value["window_minutes"] as? NSNumber)?.intValue else { continue }
            let reset = (value["resets_at"] as? NSNumber).map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.doubleValue))
            }
            windows.append((minutes, UsageWindow(utilization: used, resetsAt: reset, windowSeconds: minutes * 60)))
        }
        guard !windows.isEmpty else { return nil }
        let session = windows.first { $0.minutes == 300 }?.window
        let longWindow = windows.filter { $0.minutes != 300 }.max { $0.minutes < $1.minutes }?.window
        let usage = UsageAPIResponse(
            fiveHour: session, sevenDay: longWindow, sevenDayOauthApps: nil, sevenDayOpus: nil,
            sevenDaySonnet: nil, sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
        )
        let reached = (limits["rate_limit_reached_type"] as? String).map { !$0.isEmpty } ?? false
        return PassiveUsageObservation(
            source: .codexRollout,
            usage: usage,
            observedAt: observedAt,
            claudeAccountUUID: nil,
            codexHome: codexHome,
            processKey: processKey,
            limitReached: reached || [session, longWindow].contains { ($0?.utilization ?? 0) >= 100 }
        )
    }

    // MARK: - Change tracking

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func changed(_ stored: inout Date?, to value: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stored != value else { return false }
        stored = value
        return true
    }

    private func markSeen(_ path: String, _ modified: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard seenFileDates[path] != modified else { return false }
        seenFileDates[path] = modified
        return true
    }
}
