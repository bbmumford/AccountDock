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
    /// Every limit the provider applies, including weekly limits scoped to
    /// one model. Absent from older responses and from other providers.
    var limits: [UsageLimit]? = nil
    /// The share of the weekly allowance each scoped limit may use, keyed by
    /// the scoped limit's index in `limits`.
    var weeklyScopedShares: [WeeklyScopedShare]? = nil
    /// The limit resets the account holds, in the form every provider
    /// shares; nil when the reading did not ask for them or the provider
    /// does not offer them.
    var limitResets: LimitResets? = nil

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
        case limits
        case weeklyScopedShares = "weekly_scoped_shares"
        case limitResets = "limit_resets"
    }

    /// Where a provider's own reply lists its limit resets, read by the
    /// provider's module when the reading carries no `limit_resets`.
    private enum ProviderResetKeys: String, CodingKey {
        case anthropic = "cedar_ember"
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
            extraUsage: extraUsage,
            limits: limits,
            weeklyScopedShares: weeklyScopedShares,
            limitResets: limitResets
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

    /// Keeps a locally established countdown when a provider temporarily
    /// returns its moving "unused" placeholder after a successful probe.
    /// Any real provider countdown always wins.
    func preservingEstablishedCountdowns(from previous: UsageAPIResponse?) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: fiveHour.preservingEstablishedCountdown(from: previous?.fiveHour),
            sevenDay: sevenDay.preservingEstablishedCountdown(from: previous?.sevenDay),
            sevenDayOauthApps: sevenDayOauthApps,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayCowork: sevenDayCowork,
            iguanaNecktie: iguanaNecktie,
            extraUsage: extraUsage,
            limits: limits,
            weeklyScopedShares: weeklyScopedShares,
            limitResets: limitResets
        )
    }

    func pinningWarmupCountdowns(
        session: Bool,
        weekly: Bool,
        startedAt: Date = Date()
    ) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: session ? fiveHour?.pinningCountdown(startedAt: startedAt) : fiveHour,
            sevenDay: weekly ? sevenDay?.pinningCountdown(startedAt: startedAt) : sevenDay,
            sevenDayOauthApps: sevenDayOauthApps,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            sevenDayCowork: sevenDayCowork,
            iguanaNecktie: iguanaNecktie,
            extraUsage: extraUsage,
            limits: limits,
            weeklyScopedShares: weeklyScopedShares,
            limitResets: limitResets
        )
    }
}

extension UsageAPIResponse {
    /// Decodes the limit list leniently: a limit shape this version does not
    /// know must never discard the windows the planner depends on.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try values.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try values.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
        sevenDayOauthApps = try? values.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOauthApps)
        sevenDayOpus = try? values.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try? values.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayCowork = try? values.decodeIfPresent(UsageWindow.self, forKey: .sevenDayCowork)
        iguanaNecktie = try? values.decodeIfPresent(UsageWindow.self, forKey: .iguanaNecktie)
        extraUsage = try? values.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        limits = (try? values.decodeIfPresent([LossyLimit].self, forKey: .limits))?.map(\.limit)
        weeklyScopedShares = try? values.decodeIfPresent([WeeklyScopedShare].self, forKey: .weeklyScopedShares)
        let providerResets = try? decoder.container(keyedBy: ProviderResetKeys.self)
        limitResets = (try? values.decodeIfPresent(LimitResets.self, forKey: .limitResets))
            ?? (try? providerResets?.decodeIfPresent(AnthropicLimitResets.Reply.self, forKey: .anthropic))
                .map(AnthropicLimitResets.resets(from:))
    }

    /// Whether a reading shows the account has no session window: it carries
    /// the long window without one. The provider reports both together, so
    /// the absence is the account's plan rather than a partial reading; a
    /// later reading with a session window brings it back.
    var reportsNoSessionWindow: Bool { fiveHour == nil && sevenDay != nil }

    func replacingSevenDay(_ window: UsageWindow?) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: fiveHour, sevenDay: window, sevenDayOauthApps: sevenDayOauthApps,
            sevenDayOpus: sevenDayOpus, sevenDaySonnet: sevenDaySonnet, sevenDayCowork: sevenDayCowork,
            iguanaNecktie: iguanaNecktie, extraUsage: extraUsage,
            limits: limits, weeklyScopedShares: weeklyScopedShares,
            limitResets: limitResets
        )
    }

    /// Weekly limits that apply only to one model, with the share of the
    /// whole weekly allowance each may use.
    var modelWeeklyLimits: [ModelWeeklyLimit] {
        guard let limits else { return [] }
        return limits.enumerated().compactMap { index, limit in
            guard limit.kind == "weekly_scoped",
                  let model = limit.scope?.model?.displayName ?? limit.scope?.model?.id,
                  let percent = limit.percent else { return nil }
            let share = weeklyScopedShares?.first { $0.limitIndex == index }
            return ModelWeeklyLimit(
                model: model,
                percent: percent,
                resetsAt: limit.resetsAt,
                allowancePercentOfWeekly: share?.allowancePercentOfWeekly ?? 100,
                usedPercentOfWeekly: share?.usedPercentOfWeekly
            )
        }
    }

    /// The weekly window as it applies to work on `model`: the whole weekly
    /// limit, or a model's own weekly limit when that leaves less room.
    /// Room is measured in percent of the whole weekly allowance, the unit
    /// `QuotaTrend` learns burn rates in, so the result plugs into the same
    /// projection as the whole-allowance window.
    func weeklyWindow(forModel model: String?) -> UsageWindow? {
        guard let all = sevenDay, let used = all.utilization else { return sevenDay }
        guard let model = model?.lowercased(), !model.isEmpty else { return all }
        var room = 100 - used
        var reset = all.resetsAt
        for limit in modelWeeklyLimits where model.contains(limit.model.lowercased()) {
            if let reset = UsageWindow(utilization: nil, resetsAt: limit.resetsAt).resetsAtDate, reset <= Date() { continue }
            let scopedRoom = limit.usedPercentOfWeekly.map { limit.allowancePercentOfWeekly - $0 }
                ?? (100 - limit.percent) * limit.allowancePercentOfWeekly / 100
            if scopedRoom < room {
                room = max(0, scopedRoom)
                reset = limit.resetsAt ?? reset
            }
        }
        return UsageWindow(utilization: min(100, 100 - room), resetsAt: reset, windowSeconds: all.windowSeconds)
    }
}

struct UsageLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?
    let isActive: Bool?

    struct Scope: Codable {
        let model: Model?
    }

    struct Model: Codable {
        let id: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

/// One element of `limits`. An element that does not decode becomes an
/// empty limit rather than failing the list, so `limit_index` positions in
/// `weekly_scoped_shares` stay aligned.
private struct LossyLimit: Decodable {
    let limit: UsageLimit
    init(from decoder: Decoder) throws {
        limit = (try? UsageLimit(from: decoder)) ?? UsageLimit(
            kind: nil, group: nil, percent: nil, severity: nil, resetsAt: nil, scope: nil, isActive: nil
        )
    }
}

struct WeeklyScopedShare: Codable {
    let limitIndex: Int
    let usedPercentOfWeekly: Double?
    let allowancePercentOfWeekly: Double

    enum CodingKeys: String, CodingKey {
        case limitIndex = "limit_index"
        case usedPercentOfWeekly = "used_percent_of_weekly"
        case allowancePercentOfWeekly = "allowance_percent_of_weekly"
    }
}

struct ModelWeeklyLimit: Equatable {
    let model: String
    let percent: Double
    let resetsAt: String?
    let allowancePercentOfWeekly: Double
    let usedPercentOfWeekly: Double?
}

private extension Optional where Wrapped == UsageWindow {
    func preservingEstablishedCountdown(from previous: UsageWindow?) -> UsageWindow? {
        guard let current = self else { return nil }
        guard current.isUnusedUnstartedWindow,
              let previous,
              previous.resetsAtDate.map({ $0 > Date() }) == true else { return current }
        return UsageWindow(
            utilization: current.utilization,
            resetsAt: previous.resetsAt,
            windowSeconds: current.windowSeconds ?? previous.windowSeconds
        )
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

    /// Shared because `resetsAtDate` runs for every window on each menu-bar
    /// redraw and planner pass, and building a formatter costs far more than
    /// parsing with one. `ISO8601DateFormatter` is thread-safe and these are
    /// never changed after they are made.
    nonisolated(unsafe) private static let fractionalResetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSecondResetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return Self.parseProviderDate(resetsAt)
    }

    /// A provider timestamp, with or without fractional seconds.
    static func parseProviderDate(_ text: String) -> Date? {
        fractionalResetFormatter.date(from: text) ?? wholeSecondResetFormatter.date(from: text)
    }

    /// A provider-confirmed window that has not yet been started. This is the
    /// only safe state for a one-time bootstrap probe: zero use and no running
    /// countdown. Missing utilization is treated as unknown, never as zero.
    var isUnusedUnstartedWindow: Bool {
        guard let utilization else { return false }
        return utilization <= 0 && resetsAtDate == nil
    }

    func expiringPassedReset(at date: Date = Date()) -> UsageWindow {
        guard let reset = resetsAtDate, reset <= date else { return self }
        return UsageWindow(utilization: 0, resetsAt: nil, windowSeconds: windowSeconds)
    }

    func pinningCountdown(startedAt: Date) -> UsageWindow {
        guard isUnusedUnstartedWindow, let windowSeconds, windowSeconds > 0 else { return self }
        return UsageWindow(
            utilization: utilization,
            resetsAt: ISO8601DateFormatter().string(
                from: startedAt.addingTimeInterval(TimeInterval(windowSeconds))
            ),
            windowSeconds: windowSeconds
        )
    }

    var resetTimeString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }

    /// A complete, unambiguous label for the usage UI. Longer quota windows
    /// include the calendar date so a weekday cannot be mistaken for the next
    /// occurrence of that day.
    var resetLabelString: String? {
        guard let date = resetsAtDate else { return nil }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "Resets now" }
        guard remaining > 86_400 else {
            return resetTimeString.map { "Resets in \($0)" }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM yyyy 'at' h:mm a"
        return "Resets on \(formatter.string(from: date))"
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
    /// Decimal places of `usedCredits` and `monthlyLimit`, which are minor
    /// currency units.
    var decimalPlaces: Int? = nil

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case decimalPlaces = "decimal_places"
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
