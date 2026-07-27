import Foundation

/// Parses Claude Code's stats-cache.json and session files to provide usage data.
final class StatsParser: Sendable {
    static let shared = StatsParser()

    private let claudeDir: String

    private init() {
        self.claudeDir = NSHomeDirectory() + "/.claude"
    }

    // MARK: - Usage Summary

    /// Parse the stats cache and compute a usage summary
    func getUsageSummary() -> UsageSummary {
        guard let cache = parseStatsCache() else {
            return .empty
        }

        let activities = cache.dailyActivity ?? []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Today's usage
        let todayStr = formatDate(today)
        let todayActivity = activities.first { $0.date == todayStr }

        // Weekly usage (last 7 days)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!
        let weeklyActivities = activities.filter { activity in
            guard let actDate = activity.parsedDate else { return false }
            return actDate >= weekAgo && actDate <= today
        }

        let weeklyMessages = weeklyActivities.reduce(0) { $0 + $1.messageCount }
        let weeklySessions = weeklyActivities.reduce(0) { $0 + $1.sessionCount }
        let weeklyTools = weeklyActivities.reduce(0) { $0 + $1.toolCallCount }

        return UsageSummary(
            weeklyMessages: weeklyMessages,
            weeklySessionCount: weeklySessions,
            weeklyToolCalls: weeklyTools,
            todayMessages: todayActivity?.messageCount ?? 0,
            todaySessionCount: todayActivity?.sessionCount ?? 0,
            todayToolCalls: todayActivity?.toolCallCount ?? 0,
            totalMessages: cache.totalMessages ?? 0,
            totalSessions: cache.totalSessions ?? 0,
            dailyActivity: activities
        )
    }

    /// Get the last N days of activity for chart display
    func getRecentActivity(days: Int = 7) -> [DailyActivity] {
        guard let cache = parseStatsCache() else { return [] }
        let activities = cache.dailyActivity ?? []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -days, to: today)!

        return activities
            .filter { activity in
                guard let actDate = activity.parsedDate else { return false }
                return actDate >= cutoff
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Active Sessions

    /// Get currently active Claude Code sessions
    func getActiveSessions() -> [SessionInfo] {
        let sessionsDir = claudeDir + "/sessions"
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }

        return files.compactMap { filename -> SessionInfo? in
            guard filename.hasSuffix(".json") else { return nil }
            let path = sessionsDir + "/" + filename
            guard let data = fm.contents(atPath: path) else { return nil }
            return try? JSONDecoder().decode(SessionInfo.self, from: data)
        }
    }

    // MARK: - Private

    private func parseStatsCache() -> StatsCache? {
        let path = claudeDir + "/stats-cache.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(StatsCache.self, from: data)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
