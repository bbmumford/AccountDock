import Foundation

/// Consumption rates learned from successive readings of one account.
struct QuotaTrend: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var utilization: Double
        var reset: Date?
        var at: Date
    }

    /// One measured interval's rate, kept for the median.
    struct RateSample: Codable, Equatable {
        var rate: Double
        var at: Date
    }

    var session: Sample?
    var weekly: Sample?
    /// Session percentage per hour while the account was being consumed:
    /// the median of `sessionRates`.
    var sessionBurnPerHour: Double = 0
    /// Long-window percentage per hour while the account was being consumed:
    /// the median of `weeklyRates`.
    var weeklyBurnPerHour: Double = 0
    /// Session percentage bought by one long-window percent.
    var sessionPerWeekly: Double?
    var lastConsumedAt: Date?
    /// Spread of the recent interval rates around their median (a robust
    /// variance, from the median absolute deviation), so a projection can
    /// carry its uncertainty without one burst inflating it.
    var sessionBurnVariance: Double = 0
    var weeklyBurnVariance: Double = 0
    /// The most recent interval rates, newest last, at most `rateSampleCount`.
    var sessionRates: [RateSample]? = nil
    var weeklyRates: [RateSample]? = nil
    /// Readings before this teach no rate: a window just started or paused
    /// sessions just resumed, and each session's first request re-sends its
    /// whole context, a burst that says nothing about the steady burn.
    var settlesAt: Date?
    /// The paired readings `learnRatio` measures the session-to-long ratio from.
    var ratioBase: RatioBase?

    /// Readings closer together than this carry rounding noise, not a rate.
    static let minimumInterval: TimeInterval = 45
    /// Two readings this far apart describe an average, not current burn.
    static let maximumInterval: TimeInterval = 90 * 60
    static let smoothing = 0.5
    /// The burn rate is the median of this many recent intervals, so one
    /// burst cannot set the forecast.
    static let rateSampleCount = 5
    /// An interval older than this no longer describes current burn.
    static let rateSampleLifetime: TimeInterval = 2 * 60 * 60
    /// How long after a window starts or paused sessions resume readings
    /// teach no rate.
    static let settlePeriod: TimeInterval = 5 * 60
    /// An interval runs until its window has risen a whole point, or for
    /// `quietSpan`: readings in whole percent would otherwise give a median
    /// of alternating zeros and one-point steps.
    static let wholePoint = 1.0
    static let quietSpan: TimeInterval = 15 * 60
    /// Without fresh evidence a learned burn rate halves every this long.
    static let decayHalfLife: TimeInterval = 30 * 60
    /// A long window read in whole percent as the only signal: its baseline
    /// holds until it has risen this much or for `coarseHold`, because a
    /// one-point step inside one short interval is rounding that would read
    /// as tens of percent per hour.
    static let coarseMinimumRise = 2.0
    static let coarseHold: TimeInterval = 30 * 60

    mutating func record(_ usage: UsageAPIResponse, at date: Date) {
        let noSessionWindow = usage.fiveHour == nil
        if noSessionWindow {
            session = nil
            sessionBurnPerHour = 0
            sessionBurnVariance = 0
            sessionRates = nil
        }
        if Self.startsWindow(session, usage.fiveHour, at: date) || Self.startsWindow(weekly, usage.sevenDay, at: date) {
            settle(at: date)
        }
        let settling = settlesAt.map { date < $0 } ?? false
        let sessionDelta = Self.advance(&session, window: usage.fiveHour, at: date, settling: settling)
        let weeklyDelta = Self.advance(&weekly, window: usage.sevenDay, at: date, coarse: noSessionWindow, settling: settling)
        if let delta = sessionDelta {
            if delta.rise > 0 { lastConsumedAt = date }
            if delta.learns {
                (sessionBurnPerHour, sessionBurnVariance) = Self.learn(delta.rate, at: date, into: &sessionRates)
            }
        }
        if let delta = weeklyDelta {
            if delta.rise > 0 { lastConsumedAt = date }
            if delta.learns {
                (weeklyBurnPerHour, weeklyBurnVariance) = Self.learn(delta.rate, at: date, into: &weeklyRates)
            }
        }
        learnRatio(usage, at: date)
    }

    /// Both windows move together for the same work, so their ratio is the
    /// plan's session cost of one weekly percent. It is measured between
    /// readings of the same two windows, from `ratioBase` until the long
    /// window has risen two points, since whole-percent rounding makes a
    /// smaller weekly rise unreliable; each window's rate intervals end at
    /// different readings, so they cannot be paired.
    private mutating func learnRatio(_ usage: UsageAPIResponse, at date: Date) {
        guard let sessionWindow = usage.fiveHour, let s = sessionWindow.utilization,
              let weeklyWindow = usage.sevenDay, let w = weeklyWindow.utilization else {
            ratioBase = nil
            return
        }
        let current = RatioBase(
            session: Sample(utilization: s, reset: sessionWindow.resetsAtDate, at: date),
            weekly: Sample(utilization: w, reset: weeklyWindow.resetsAtDate, at: date)
        )
        guard let base = ratioBase, Self.sameWindow(base.session, current.session),
              Self.sameWindow(base.weekly, current.weekly) else {
            ratioBase = current
            return
        }
        let weeklyRise = w - base.weekly.utilization
        guard weeklyRise >= 2 else { return }
        let sessionRise = s - base.session.utilization
        if sessionRise > 0 {
            let ratio = min(30, max(1, sessionRise / weeklyRise))
            sessionPerWeekly = sessionPerWeekly.map { $0 * (1 - Self.smoothing) + ratio * Self.smoothing } ?? ratio
        }
        ratioBase = current
    }

    /// Starts a settle period: readings until `settlePeriod` from `date`
    /// move the baselines without teaching a rate. `AppState.endPause`
    /// calls it for the accounts whose sessions resume.
    mutating func settle(at date: Date) {
        let until = date.addingTimeInterval(Self.settlePeriod)
        settlesAt = max(settlesAt ?? until, until)
    }

    /// Moves the baseline to this reading without learning a rate. Used while
    /// the account's agents are paused, when the absence of a rise says
    /// nothing about how fast the work consumes quota. The settle period it
    /// starts keeps the burst of the sessions' first requests after the pause
    /// out of the learned rate.
    mutating func rebase(_ usage: UsageAPIResponse, at date: Date) {
        settle(at: date)
        ratioBase = nil
        if let window = usage.fiveHour, let value = window.utilization {
            session = Sample(utilization: value, reset: window.resetsAtDate, at: date)
        }
        if let window = usage.sevenDay, let value = window.utilization {
            weekly = Sample(utilization: value, reset: window.resetsAtDate, at: date)
        }
    }

    /// Burn rates decayed for the time since consumption was last observed.
    func currentRates(now: Date) -> (session: Double, weekly: Double) {
        guard let lastConsumedAt else { return (0, 0) }
        let idle = max(0, now.timeIntervalSince(lastConsumedAt))
        let factor = pow(0.5, idle / Self.decayHalfLife)
        return (sessionBurnPerHour * factor, weeklyBurnPerHour * factor)
    }

    /// Standard deviation of the burn rates, decayed like the rates.
    func currentUncertainty(now: Date) -> (session: Double, weekly: Double) {
        guard let lastConsumedAt else { return (0, 0) }
        let factor = pow(0.5, max(0, now.timeIntervalSince(lastConsumedAt)) / Self.decayHalfLife)
        return (sessionBurnVariance.squareRoot() * factor, weeklyBurnVariance.squareRoot() * factor)
    }

    private struct Delta { let rise: Double; let rate: Double; let learns: Bool }

    struct RatioBase: Codable, Equatable { var session: Sample; var weekly: Sample }

    /// Whether `window` begins a window `sample` was not in: its reset
    /// moved, the stored window was unstarted (no use and no reset; it
    /// starts at its first request), or the stored window's reset has passed.
    private static func startsWindow(_ sample: Sample?, _ window: UsageWindow?, at date: Date) -> Bool {
        guard let sample, let window, window.utilization != nil, let next = window.resetsAtDate else { return false }
        guard let previous = sample.reset else { return isUnstarted(sample) }
        return previous <= date || abs(previous.timeIntervalSince(next)) > 10 * 60
    }

    private static func isUnstarted(_ sample: Sample) -> Bool {
        sample.reset == nil && sample.utilization <= 0
    }

    private static func sameWindow(_ a: Sample, _ b: Sample) -> Bool {
        switch (a.reset, b.reset) {
        case let (x?, y?): return abs(x.timeIntervalSince(y)) <= 10 * 60
        case (nil, nil): return true
        default: return false
        }
    }

    private static func advance(_ sample: inout Sample?, window: UsageWindow?, at date: Date,
                                coarse: Bool = false, settling: Bool = false) -> Delta? {
        guard let window, let value = window.utilization else { return nil }
        let next = Sample(utilization: value, reset: window.resetsAtDate, at: date)
        guard let previous = sample else {
            sample = next
            return nil
        }
        let interval = date.timeIntervalSince(previous.at)
        // A different reset, or an unstarted window gaining one, means a new
        // window whose usage restarted from zero.
        if isUnstarted(previous), next.reset != nil {
            sample = next
            return nil
        }
        if let a = previous.reset, let b = next.reset, abs(a.timeIntervalSince(b)) > 10 * 60 {
            sample = next
            return nil
        }
        let rise = max(0, value - previous.utilization)
        if settling {
            sample = next
            return Delta(rise: rise, rate: 0, learns: false)
        }
        // Keep the older baseline until enough time has passed to measure a rate.
        guard interval >= Self.minimumInterval else { return nil }
        if coarse, interval < Self.coarseHold, value - previous.utilization < Self.coarseMinimumRise { return nil }
        if !coarse, interval < Self.quietSpan, value - previous.utilization < Self.wholePoint { return nil }
        sample = next
        guard interval <= Self.maximumInterval else { return nil }
        return Delta(rise: rise, rate: rise / interval * 3600, learns: true)
    }

    /// Adds one interval's rate to `samples` and returns the median of the
    /// recent ones with their robust variance.
    private static func learn(_ rate: Double, at date: Date, into samples: inout [RateSample]?) -> (Double, Double) {
        var recent = (samples ?? []).filter { date.timeIntervalSince($0.at) <= rateSampleLifetime }
        recent.append(RateSample(rate: rate, at: date))
        if recent.count > rateSampleCount { recent.removeFirst(recent.count - rateSampleCount) }
        samples = recent
        let rates = recent.map(\.rate)
        let center = median(rates)
        // 1.4826 times the median absolute deviation estimates the standard
        // deviation of normally spread rates while ignoring a lone outlier.
        let spread = 1.4826 * median(rates.map { abs($0 - center) })
        return (center, spread * spread)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension UsageWindow {
    /// Combines a stored window with a newer reading of the same account.
    /// Usage inside one window only rises, so a lower value from a slower
    /// source for the same window is ignored; a later reset starts a new window.
    /// A newer reading of a window resetting earlier also replaces the stored
    /// one: callers drop windows whose reset has passed, and an account's
    /// windows never overlap, so a stored window resetting later than a live
    /// newer one was another account's, credited here by mistake.
    func merged(withNewer newer: UsageWindow?) -> UsageWindow {
        guard let newer, let newValue = newer.utilization else { return self }
        guard let oldValue = utilization else { return newer }
        switch (resetsAtDate, newer.resetsAtDate) {
        case let (old?, new?) where abs(new.timeIntervalSince(old)) > 10 * 60:
            return newer
        case (nil, _?):
            return newer
        default:
            return UsageWindow(
                utilization: max(oldValue, newValue),
                resetsAt: newer.resetsAt ?? resetsAt,
                windowSeconds: newer.windowSeconds ?? windowSeconds
            )
        }
    }
}

extension UsageAPIResponse {
    /// Applies a passive reading that may carry only some windows. With
    /// `clearingSession`, the source showed the account has no session
    /// window (`reportsNoSessionWindow`), so a stored one is dropped; the
    /// caller decides this from the reading before dropping passed windows,
    /// since a passed session window is not an absent one.
    func merged(withNewer newer: UsageAPIResponse, clearingSession: Bool = false) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: clearingSession ? nil : fiveHour.map { $0.merged(withNewer: newer.fiveHour) } ?? newer.fiveHour,
            sevenDay: sevenDay.map { $0.merged(withNewer: newer.sevenDay) } ?? newer.sevenDay,
            sevenDayOauthApps: newer.sevenDayOauthApps ?? sevenDayOauthApps,
            sevenDayOpus: newer.sevenDayOpus ?? sevenDayOpus,
            sevenDaySonnet: newer.sevenDaySonnet ?? sevenDaySonnet,
            sevenDayCowork: newer.sevenDayCowork ?? sevenDayCowork,
            iguanaNecktie: newer.iguanaNecktie ?? iguanaNecktie,
            extraUsage: newer.extraUsage ?? extraUsage,
            limits: newer.limits ?? limits,
            weeklyScopedShares: newer.weeklyScopedShares ?? weeklyScopedShares,
            limitResets: newer.limitResets ?? limitResets
        )
    }
}

extension UsageAPIResponse {
    /// The reading without windows whose reset has already passed.
    func droppingPassedWindows(at now: Date) -> UsageAPIResponse {
        func live(_ window: UsageWindow?) -> UsageWindow? {
            guard let window else { return nil }
            if let reset = window.resetsAtDate, reset <= now { return nil }
            return window
        }
        return UsageAPIResponse(
            fiveHour: live(fiveHour),
            sevenDay: live(sevenDay),
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
