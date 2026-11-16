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
    /// How many readings each account's own ratio has learned from
    /// (`recordReading`); an account missing here has none counted. Read by
    /// `ratio(for:sizes:plans:)`, which trusts a ratio that disagrees with
    /// the account's plan size only after `trustedReadings`.
    var accountReadings: [UUID: Int]?
    /// The plan each account's own ratio was learned on (`notePlan`): a
    /// ratio learned on another plan than the account's now is not its own.
    var accountPlans: [UUID: LearnedPlan]?
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

    /// Weighted tokens, as the router counts them (`SessionSizing.weighted`).
    static func weighted(context: Int, cacheWrite: Int, output: Int, cacheWriteLong: Int = 0) -> Double {
        SessionSizing.weighted(context: context, cacheWrite: cacheWrite, output: output, cacheWriteLong: cacheWriteLong)
    }

    var ratio: Double { percentPerMillion ?? Self.defaultPercentPerMillion }

    /// The account's own ratio once measured, otherwise the plan-wide one.
    func ratio(for account: UUID) -> Double { accountPercentPerMillion?[account] ?? ratio }

    /// An account's plan, the profile's first (`Account.currentPlan`,
    /// `Account.currentRateLimitTier`).
    struct LearnedPlan: Codable, Equatable {
        var plan: String?
        var tier: String?

        /// Whether `other` is another plan: a part both name, named
        /// differently. A ratio learned before the tier was known was
        /// learned on the same plan.
        func differs(from other: LearnedPlan) -> Bool {
            func differ(_ lhs: String?, _ rhs: String?) -> Bool {
                guard let lhs, let rhs else { return false }
                return lhs.lowercased() != rhs.lowercased()
            }
            return differ(plan, other.plan) || differ(tier, other.tier)
        }
    }

    /// Readings after which an account's own ratio is trusted even where it
    /// disagrees with its plan size; with smoothing at 0.3 the first
    /// reading then weighs under 3%.
    static let trustedReadings = 10
    /// How far, as a factor either way, an account's own ratio may stray
    /// from what its plan size makes of the other accounts' before it is
    /// blended toward that until `trustedReadings`.
    static let sizeDisagreement = 2.0

    /// Where an account's ratio came from (`ratio(for:sizes:plans:)`).
    enum RatioSource: Equatable {
        /// Measured on the account itself.
        case learned
        /// Measured on the account itself, but more than
        /// `sizeDisagreement` from what its plan size makes of the other
        /// accounts' measured ratios, and from fewer than `trustedReadings`:
        /// blended toward that expectation by how many readings it has.
        case blendedWithPlanSize
        /// From the accounts with a measured ratio and a known plan size,
        /// scaled by the account's plan size.
        case seededFromLearned
        /// From the plan-wide ratio, taken as the ratio of the median plan
        /// size among `sizes`, scaled by the account's plan size.
        case seededFromPlanWide
        /// The plan-wide ratio: the account's plan size is unknown.
        case planWide
    }

    /// The account's ratio, seeded from its plan size until it is measured.
    /// `sizes` holds the relative plan size (`Account.planSize`) of each of
    /// the provider's accounts whose size is known. A plan `s` times
    /// another's size spends a percent on `s` times the tokens, so the seed
    /// is a measured account's ratio times its size over this account's
    /// (the geometric mean over every such account), or, with none
    /// measured, the plan-wide ratio scaled from the median known size.
    /// Learning replaces the seed with the first measurement
    /// (`recordReading`). Read by `AppState.accountRatio`.
    ///
    /// A measured ratio more than `sizeDisagreement` from what the
    /// account's size makes of the other accounts' measured ratios (their
    /// median, so one stray account sets no expectation) is blended toward
    /// that expectation, in proportion to how many of `trustedReadings` it
    /// has learned from: a few readings taken while other accounts' use
    /// moved the window can read a Max 5x account as a Max 20x one, which
    /// would send it four times the work it holds. `plans` holds each
    /// account's plan now (`LearnedPlan`); a ratio learned on another plan
    /// is not used, for the account or as a reference.
    func ratio(for account: UUID, sizes: [UUID: Double],
               plans: [UUID: LearnedPlan] = [:]) -> (ratio: Double, source: RatioSource) {
        func measured(_ id: UUID) -> Double? {
            guard let value = accountPercentPerMillion?[id], value > 0 else { return nil }
            if let learnedOn = accountPlans?[id], let current = plans[id], learnedOn.differs(from: current) { return nil }
            return value
        }
        let size = sizes[account].flatMap { $0 > 0 ? $0 : nil }
        if let own = measured(account) {
            guard let size else { return (own, .learned) }
            let expected = sizes.compactMap { id, other -> Double? in
                guard id != account, other > 0, let ratio = measured(id) else { return nil }
                return ratio * other / size
            }.sorted()
            guard !expected.isEmpty else { return (own, .learned) }
            let middle = expected.count / 2
            let reference = expected.count % 2 == 1 ? expected[middle] : sqrt(expected[middle - 1] * expected[middle])
            let readings = accountReadings?[account] ?? 0
            guard max(own / reference, reference / own) > Self.sizeDisagreement, readings < Self.trustedReadings else {
                return (own, .learned)
            }
            let weight = Double(readings) / Double(Self.trustedReadings)
            return (exp(weight * log(own) + (1 - weight) * log(reference)), .blendedWithPlanSize)
        }
        guard let size else { return (ratio, .planWide) }
        let references = sizes.compactMap { id, referenceSize -> Double? in
            guard referenceSize > 0, let learned = measured(id) else { return nil }
            return log(learned * referenceSize / size)
        }
        if !references.isEmpty {
            return (exp(references.reduce(0, +) / Double(references.count)), .seededFromLearned)
        }
        let known = sizes.values.filter { $0 > 0 }.sorted()
        let median = known.count % 2 == 1 ? known[known.count / 2] : (known[known.count / 2 - 1] + known[known.count / 2]) / 2
        return (ratio * median / size, .seededFromPlanWide)
    }

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
        var readings = accountReadings ?? [:]
        readings[account, default: 0] += 1
        accountReadings = readings
        pending[account] = 0
    }

    /// Notes the plan `account` is on now, before a reading is learned
    /// (`AppState.learnFromReading`). A plan change (another plan or tier)
    /// changes how much work one percent of its window is, five times over
    /// from Pro to Max 5x, so the account's own ratio and its readings are
    /// forgotten and measured again, its plan size seeding it meanwhile.
    /// Returns whether it forgot one.
    @discardableResult
    mutating func notePlan(_ plan: LearnedPlan, for account: UUID) -> Bool {
        var plans = accountPlans ?? [:]
        defer { accountPlans = plans }
        guard let learnedOn = plans[account] else {
            plans[account] = plan
            return false
        }
        guard learnedOn.differs(from: plan) else {
            plans[account] = LearnedPlan(plan: plan.plan ?? learnedOn.plan, tier: plan.tier ?? learnedOn.tier)
            return false
        }
        plans[account] = plan
        let forgot = accountPercentPerMillion?[account] != nil
        accountPercentPerMillion?[account] = nil
        accountReadings?[account] = nil
        pending[account] = 0
        lastSession[account] = nil
        return forgot
    }

    /// Session percent the session's next request is expected to use.
    func expectedRequestCost(session: String) -> Double {
        (sessionWeighted[session] ?? 400_000) / 1_000_000 * ratio
    }

    /// Sessions that sent a request since `date`.
    func sessions(activeSince date: Date) -> [String] {
        sessionSeen.filter { $0.value >= date }.map(\.key)
    }

    /// `sessions(activeSince:)` last served by one of `accounts`, so one
    /// provider's sessions are counted apart from another's.
    func sessions(activeSince date: Date, on accounts: Set<UUID>) -> [String] {
        sessions(activeSince: date).filter { sessionAccount[$0].map(accounts.contains) ?? false }
    }

    /// `switchCost(sessionsOn:now:)` for the sessions last served by any of
    /// `accounts`: one provider's.
    func switchCost(sessionsOnAny accounts: Set<UUID>, now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-15 * 60)
        let context = sessionContext.filter { key, _ in
            (sessionSeen[key] ?? .distantPast) > cutoff && (sessionAccount[key].map(accounts.contains) ?? false)
        }.values.reduce(0, +)
        return SessionSizing.moveCost(context, percentPerMillion: ratio)
    }

    /// Session percent spent re-reading every active session's context
    /// into the cache of the account it moves to, when work moves accounts.
    func switchCost(sessionsOn account: UUID?, now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-15 * 60)
        let context = sessionContext.filter { key, _ in
            (sessionSeen[key] ?? .distantPast) > cutoff && (account == nil || sessionAccount[key] == account)
        }.values.reduce(0, +)
        return SessionSizing.moveCost(context, percentPerMillion: ratio)
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
