import Foundation

/// What a model request costs in session percent, learned from the token
/// counts the router reports and the utilization changes that follow.
///
/// Tokens are weighted by their relative price: uncached and cache-read
/// input at 1 and 0.1, cache writes at 1.25 (2 for the one-hour cache) and
/// output at 5. The share of
/// context read from cache versus sent uncached is not reported separately,
/// so context outside cache writes is counted at the cache-read rate.
struct TurnCostModel: Codable, Equatable {
    /// Session percent per million weighted tokens.
    var percentPerMillion: Double?
    /// The same, measured on each account alone. Plans of different sizes
    /// count the same tokens as different shares of their windows.
    var accountPercentPerMillion: [UUID: Double]?
    /// Weighted tokens of requests served since the account's last usage
    /// reading, by account.
    var pending: [UUID: Double] = [:]
    var lastSession: [UUID: Double] = [:]
    /// Mean weighted tokens per request and last context size, by session.
    var sessionWeighted: [String: Double] = [:]
    var sessionContext: [String: Int] = [:]
    var sessionAccount: [String: UUID] = [:]
    var sessionSeen: [String: Date] = [:]

    static let smoothing = 0.3
    /// Plan-wide default until a ratio is measured: about 1% of a session per
    /// two million weighted tokens.
    static let defaultPercentPerMillion = 0.5

    static func weighted(context: Int, cacheWrite: Int, output: Int, cacheWriteLong: Int = 0) -> Double {
        let long = min(max(0, cacheWriteLong), cacheWrite)
        return Double(max(0, context - cacheWrite)) * 0.1 + Double(cacheWrite - long) * 1.25 + Double(long) * 2
            + Double(output) * 5
    }

    var ratio: Double { percentPerMillion ?? Self.defaultPercentPerMillion }

    /// The account's own ratio once measured, otherwise the plan-wide one.
    func ratio(for account: UUID) -> Double { accountPercentPerMillion?[account] ?? ratio }

    mutating func recordRequest(session: String?, account: UUID, context: Int, cacheWrite: Int, output: Int,
                                cacheWriteLong: Int = 0, at date: Date) {
        let weight = Self.weighted(context: context, cacheWrite: cacheWrite, output: output, cacheWriteLong: cacheWriteLong)
        pending[account, default: 0] += weight
        guard let session else { return }
        sessionWeighted[session] = sessionWeighted[session].map { $0 * (1 - Self.smoothing) + weight * Self.smoothing } ?? weight
        sessionContext[session] = context
        sessionAccount[session] = account
        sessionSeen[session] = date
        if sessionSeen.count > 500 {
            let cutoff = date.addingTimeInterval(-6 * 60 * 60)
            for (key, seen) in sessionSeen where seen < cutoff {
                sessionSeen[key] = nil; sessionWeighted[key] = nil; sessionContext[key] = nil; sessionAccount[key] = nil
            }
        }
    }

    /// Learns the ratio from a new session-utilization reading of `account`.
    /// A falling value is a new window and only restarts the measurement.
    mutating func recordReading(account: UUID, session: Double) {
        defer { lastSession[account] = session }
        guard let previous = lastSession[account] else { pending[account] = 0; return }
        let weight = pending[account] ?? 0
        guard session >= previous else { pending[account] = 0; return }
        // Whole-percent readings need a clear rise and enough tokens.
        guard session - previous >= 2, weight >= 200_000 else { return }
        let sample = (session - previous) / (weight / 1_000_000)
        guard sample.isFinite, sample > 0 else { return }
        percentPerMillion = percentPerMillion.map { $0 * (1 - Self.smoothing) + sample * Self.smoothing } ?? sample
        var perAccount = accountPercentPerMillion ?? [:]
        perAccount[account] = perAccount[account].map { $0 * (1 - Self.smoothing) + sample * Self.smoothing } ?? sample
        accountPercentPerMillion = perAccount
        pending[account] = 0
    }

    /// Session percent the session's next request is expected to use.
    func expectedRequestCost(session: String) -> Double {
        (sessionWeighted[session] ?? 400_000) / 1_000_000 * ratio
    }

    /// Sessions that sent a request since `date`.
    func sessions(activeSince date: Date) -> [String] {
        sessionSeen.filter { $0.value >= date }.map(\.key)
    }

    /// Session percent spent re-reading every active session's context
    /// into the cache of the account it moves to, when work moves accounts.
    func switchCost(sessionsOn account: UUID?, now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-15 * 60)
        let context = sessionContext.filter { key, _ in
            (sessionSeen[key] ?? .distantPast) > cutoff && (account == nil || sessionAccount[key] == account)
        }.values.reduce(0, +)
        return Double(context) * (1.25 - 0.1) / 1_000_000 * ratio
    }
}

/// Long-window percent consumed per hour, by hour of the week, learned from
/// usage readings across one provider's accounts.
struct DemandForecast: Codable, Equatable {
    var buckets: [Double?] = Array(repeating: nil, count: 168)
    var currentHour: Int?
    var accumulated = 0.0

    static let smoothing = 0.35

    static func hourOfWeek(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) - 1
        return weekday * 24 + calendar.component(.hour, from: date)
    }

    /// Adds consumption observed at `date`; a finished hour joins its bucket.
    mutating func record(weeklyRise: Double, at date: Date) {
        let hour = Self.hourOfWeek(date)
        if let currentHour, currentHour != hour {
            close(currentHour)
            // Hours without any reading consumed nothing.
            var gap = (currentHour + 1) % 168
            while gap != hour { close(gap, value: 0); gap = (gap + 1) % 168 }
        }
        if currentHour != hour { accumulated = 0 }
        currentHour = hour
        accumulated += max(0, weeklyRise)
    }

    private mutating func close(_ hour: Int, value: Double? = nil) {
        let observed = value ?? accumulated
        buckets[hour] = buckets[hour].map { $0 * (1 - Self.smoothing) + observed * Self.smoothing } ?? observed
    }

    var isTrained: Bool { buckets.compactMap { $0 }.count >= 24 }

    /// Expected long-window percent per hour at `date`. Unlearned hours use
    /// the average of the learned ones.
    func rate(at date: Date) -> Double {
        let learned = buckets.compactMap { $0 }
        let mean = learned.isEmpty ? 0 : learned.reduce(0, +) / Double(learned.count)
        return buckets[Self.hourOfWeek(date)] ?? mean
    }
}

/// What asking for the one-hour prompt cache in place of the client's
/// five-minute one (`ProviderFailoverPolicy.extendCacheLifetime`) saved and
/// cost, in weighted tokens, by day for the last week. Shown under the
/// setting in Failover settings.
struct CacheExtensionLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        var start: Date
        var saved: Double = 0
        var premium: Double = 0
    }

    var days: [Day] = []

    /// A request that came after an idle spell longer than five minutes but
    /// within the hour read its context from the cache instead of writing it
    /// again, which saves 1.25 − 0.1 per cache-read token; every one-hour
    /// cache write costs 2 − 1.25 more than a five-minute one.
    mutating func record(_ event: RouterEvent, after previous: Date?, calendar: Calendar = .current) {
        let gap = previous.map { event.at.timeIntervalSince($0) } ?? 0
        let saved = gap > 5 * 60 && gap <= 60 * 60 ? Double(event.cacheReadTokens ?? 0) * (1.25 - 0.1) : 0
        let premium = Double(event.cacheWriteLongTokens ?? 0) * (2 - 1.25)
        guard saved > 0 || premium > 0 else { return }
        let start = calendar.startOfDay(for: event.at)
        if let index = days.firstIndex(where: { $0.start == start }) {
            days[index].saved += saved
            days[index].premium += premium
        } else {
            days.append(Day(start: start, saved: saved, premium: premium))
        }
        let cutoff = start.addingTimeInterval(-7 * 24 * 60 * 60)
        days.removeAll { $0.start < cutoff }
    }

    var saved: Double { days.reduce(0) { $0 + $1.saved } }
    var premium: Double { days.reduce(0) { $0 + $1.premium } }
}
