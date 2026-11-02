import Foundation

/// Consumption rates learned from successive readings of one account.
struct QuotaTrend: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var utilization: Double
        var reset: Date?
        var at: Date
    }

    var session: Sample?
    var weekly: Sample?
    /// Session percentage per hour while the account was being consumed.
    var sessionBurnPerHour: Double = 0
    /// Long-window percentage per hour while the account was being consumed.
    var weeklyBurnPerHour: Double = 0
    /// Session percentage bought by one long-window percent.
    var sessionPerWeekly: Double?
    var lastConsumedAt: Date?
    /// Variance of the burn-rate samples around the learned rate, so a
    /// projection can carry its uncertainty.
    var sessionBurnVariance: Double = 0
    var weeklyBurnVariance: Double = 0

    /// Readings closer together than this carry rounding noise, not a rate.
    static let minimumInterval: TimeInterval = 45
    /// Two readings this far apart describe an average, not current burn.
    static let maximumInterval: TimeInterval = 90 * 60
    static let smoothing = 0.5
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
        }
        let sessionDelta = Self.advance(&session, window: usage.fiveHour, at: date)
        let weeklyDelta = Self.advance(&weekly, window: usage.sevenDay, at: date, coarse: noSessionWindow)
        if let delta = sessionDelta {
            let deviation = delta.rate - sessionBurnPerHour
            if sessionBurnPerHour > 0 { sessionBurnVariance = blend(sessionBurnVariance, deviation * deviation) }
            sessionBurnPerHour = blend(sessionBurnPerHour, delta.rate)
            if delta.rise > 0 { lastConsumedAt = date }
        }
        if let delta = weeklyDelta {
            let deviation = delta.rate - weeklyBurnPerHour
            if weeklyBurnPerHour > 0 { weeklyBurnVariance = blend(weeklyBurnVariance, deviation * deviation) }
            weeklyBurnPerHour = blend(weeklyBurnPerHour, delta.rate)
            if delta.rise > 0 { lastConsumedAt = date }
        }
        // Both windows move together for the same work, so their ratio is the
        // plan's session cost of one weekly percent. Whole-percent rounding
        // makes small weekly rises unreliable, hence the two-point minimum.
        if let s = sessionDelta, let w = weeklyDelta, w.rise >= 2, s.rise > 0 {
            let ratio = min(30, max(1, s.rise / w.rise))
            sessionPerWeekly = sessionPerWeekly.map { $0 * (1 - Self.smoothing) + ratio * Self.smoothing } ?? ratio
        }
    }

    /// Moves the baseline to this reading without learning a rate. Used while
    /// the account's agents are paused, when the absence of a rise says
    /// nothing about how fast the work consumes quota.
    mutating func rebase(_ usage: UsageAPIResponse, at date: Date) {
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

    private struct Delta { let rise: Double; let rate: Double }

    private static func advance(_ sample: inout Sample?, window: UsageWindow?, at date: Date, coarse: Bool = false) -> Delta? {
        guard let window, let value = window.utilization else { return nil }
        let next = Sample(utilization: value, reset: window.resetsAtDate, at: date)
        guard let previous = sample else {
            sample = next
            return nil
        }
        let interval = date.timeIntervalSince(previous.at)
        // A different reset means a new window whose usage restarted from zero.
        if let a = previous.reset, let b = next.reset, abs(a.timeIntervalSince(b)) > 10 * 60 {
            sample = next
            return nil
        }
        // Keep the older baseline until enough time has passed to measure a rate.
        guard interval >= Self.minimumInterval else { return nil }
        if coarse, interval < Self.coarseHold, value - previous.utilization < Self.coarseMinimumRise { return nil }
        sample = next
        guard interval <= Self.maximumInterval else { return nil }
        let rise = max(0, value - previous.utilization)
        return Delta(rise: rise, rate: rise / interval * 3600)
    }

    private func blend(_ old: Double, _ new: Double) -> Double {
        old == 0 ? new : old * (1 - Self.smoothing) + new * Self.smoothing
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
            weeklyScopedShares: newer.weeklyScopedShares ?? weeklyScopedShares
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
            weeklyScopedShares: weeklyScopedShares
        )
    }
}
