import Foundation

// MARK: - Usage API Response (from /api/oauth/usage)

struct UsageAPIResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let sevenDayCowork: UsageWindow?
    let iguanaNecktie: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }

    /// Clears utilization for windows whose last provider-confirmed reset has
    /// passed. This keeps a last-good snapshot useful when credentials expire
    /// or the provider cannot be queried, without displaying pre-reset usage
    /// indefinitely. The reset timestamp is removed because the next rolling
    /// window is not known until the provider reports it.
    func expiringPassedResets(at date: Date = Date()) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: fiveHour?.expiringPassedReset(at: date),
            sevenDay: sevenDay?.expiringPassedReset(at: date),
            sevenDayOauthApps: sevenDayOauthApps?.expiringPassedReset(at: date),
            sevenDayOpus: sevenDayOpus?.expiringPassedReset(at: date),
            sevenDaySonnet: sevenDaySonnet?.expiringPassedReset(at: date),
            sevenDayCowork: sevenDayCowork?.expiringPassedReset(at: date),
            iguanaNecktie: iguanaNecktie?.expiringPassedReset(at: date),
            extraUsage: extraUsage
        )
    }

    func hasPassedReset(at date: Date = Date()) -> Bool {
        [
            fiveHour, sevenDay, sevenDayOauthApps, sevenDayOpus,
            sevenDaySonnet, sevenDayCowork, iguanaNecktie,
        ].compactMap { $0?.resetsAtDate }.contains { $0 <= date }
    }

    var nextResetDate: Date? {
        [
            fiveHour, sevenDay, sevenDayOauthApps, sevenDayOpus,
            sevenDaySonnet, sevenDayCowork, iguanaNecktie,
        ].compactMap { $0?.resetsAtDate }.min()
    }
}

struct UsageWindow: Codable {
    let utilization: Double?
    let resetsAt: String?
    let windowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case windowSeconds = "window_seconds"
    }

    init(utilization: Double?, resetsAt: String?, windowSeconds: Int? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    func expiringPassedReset(at date: Date = Date()) -> UsageWindow {
        guard let reset = resetsAtDate, reset <= date else { return self }
        return UsageWindow(utilization: 0, resetsAt: nil, windowSeconds: windowSeconds)
    }

    var resetTimeString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE h:mm a"
            return formatter.string(from: date)
        } else if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }

    /// Compact countdown rendering for narrow menu-bar modules.
    /// Always returns a fixed-shape string ("now", "5m", "2h 14m", "4d 6h").
    /// Never falls back to a date format — the menu bar can't afford the width.
    var compactResetString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = Int(date.timeIntervalSinceNow)
        guard remaining > 0 else { return "now" }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3600
        let minutes = (remaining % 3600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// How much of the rate-limit window has already elapsed, as a 0–100
    /// percentage: `1 − remaining / windowSeconds`, clamped to [0, 100].
    /// `windowSeconds` is the fixed window length (5h = 18000, 7d = 604800).
    /// Returns nil if there's no reset timestamp. Compared against the usage
    /// bar this shows whether you're burning faster or slower than the clock.
    func elapsedPercent(windowSeconds: Double) -> Double? {
        guard windowSeconds > 0, let date = resetsAtDate else { return nil }
        let elapsed = 1.0 - (date.timeIntervalSinceNow / windowSeconds)
        return min(max(elapsed, 0), 1) * 100
    }
}

/// Fixed rate-limit window lengths, in seconds.
enum RateLimitWindow {
    static let fiveHourSeconds: Double = 5 * 60 * 60       // 18,000
    static let sevenDaySeconds: Double = 7 * 24 * 60 * 60  // 604,800
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - Stats Cache (matches ~/.claude/stats-cache.json)

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]?
    let totalSessions: Int?
    let totalMessages: Int?
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct DailyActivity: Codable, Identifiable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int

    var id: String { date }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

struct LongestSession: Codable {
    let sessionId: String?
    let duration: Int?
    let messageCount: Int?
    let timestamp: String?
}

// MARK: - Computed Usage Summary

struct UsageSummary {
    let weeklyMessages: Int
    let weeklySessionCount: Int
    let weeklyToolCalls: Int
    let todayMessages: Int
    let todaySessionCount: Int
    let todayToolCalls: Int
    let totalMessages: Int
    let totalSessions: Int
    let dailyActivity: [DailyActivity]

    static let empty = UsageSummary(
        weeklyMessages: 0,
        weeklySessionCount: 0,
        weeklyToolCalls: 0,
        todayMessages: 0,
        todaySessionCount: 0,
        todayToolCalls: 0,
        totalMessages: 0,
        totalSessions: 0,
        dailyActivity: []
    )
}

// MARK: - Session Info (from ~/.claude/sessions/*.json)

struct SessionInfo: Codable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String?
    let startedAt: Double?

    var id: String { sessionId }

    var startDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }
}
