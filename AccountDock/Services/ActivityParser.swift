import Foundation

/// Provides today's coding activity stats from Claude Code session JSONL files.
/// All parsing is done by the unified `UsageIndex`; this is a thin facade.
final class ActivityParser: Sendable {
    static let shared = ActivityParser()
    private init() {}

    /// Today's stats aggregated from the persistent usage index.
    /// Caller must ensure `UsageIndex.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getTodayStats() async -> ActivityStats {
        return await UsageIndex.shared.activityStatsToday()
    }
}
