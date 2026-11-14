import Foundation

/// The arithmetic of a usage allowance, in one place for every provider:
/// a window percent as tokens through the account's token cost and back,
/// the room an account has left in its windows, and when spending at a
/// rate uses that room up. `FailoverPlanner`, `SessionPacer`,
/// `QuotaSimulator` and the pace outlook (`AppState.paceOutlook`) all count
/// through it, so an account's room, rate and run-out read the same
/// wherever they are compared.
///
/// Units: a window percent is a percent of that window's allowance; a
/// token cost (`percentPerMillion`) is the window percent one million
/// weighted tokens cost on the account, so it carries the plan's size; and
/// `sessionPerWeekly` is the session-window percent one long-window percent
/// of work costs.
enum Allowance {
    /// The length of a session window.
    static let sessionWindow: TimeInterval = 5 * 60 * 60

    /// Million weighted tokens `percent` of a window holds on an account
    /// whose token cost is `percentPerMillion`; `percent` itself when the
    /// cost is unknown (zero), so an account without one is compared by its
    /// percent.
    static func millions(_ percent: Double, percentPerMillion: Double) -> Double {
        percentPerMillion > 0 ? percent / percentPerMillion : percent
    }

    /// Window percent `millions` million weighted tokens cost on an account
    /// whose token cost is `percentPerMillion`.
    static func percent(millions: Double, percentPerMillion: Double) -> Double {
        millions * percentPerMillion
    }

    /// `percent` of one account's window as the same tokens on another's:
    /// counted at token cost `from` and spent at `to`. A percent of a plan a
    /// twentieth the size is a twentieth of the work. `percent` unchanged
    /// when either cost is unknown.
    static func converted(_ percent: Double, from: Double, to: Double) -> Double {
        guard from > 0, to > 0 else { return percent }
        return percent / from * to
    }

    /// Session-window percent an account can still serve: what its session
    /// window has left, capped by its long window's rest at
    /// `sessionPerWeekly` session percent per long-window percent; never
    /// below zero. `sessionUsed` nil counts the session window as
    /// `sessionRoomWhenUnread`.
    static func sessionRoom(sessionUsed: Double?, weeklyUsed: Double, sessionPerWeekly: Double,
                            sessionRoomWhenUnread: Double = .infinity) -> Double {
        let session = sessionUsed.map { 100 - $0 } ?? sessionRoomWhenUnread
        return max(0, min(session, (100 - weeklyUsed) * sessionPerWeekly))
    }

    /// Long-window percent an account can still serve: the long window's
    /// rest, capped by the session window's rest counted in long-window
    /// percent; never below zero.
    static func weeklyRoom(sessionUsed: Double, weeklyUsed: Double, sessionPerWeekly: Double) -> Double {
        min(max(0, 100 - weeklyUsed), max(0, 100 - sessionUsed) / sessionPerWeekly)
    }

    /// Percent of a window left below `limit`: the window's use counts only
    /// while the window runs (`resetsAt` ahead of `now`).
    static func left(limit: Double = 100, used: Double, resetsAt: Date?, now: Date) -> Double {
        let running = resetsAt.map { $0 > now } ?? false
        return limit - (running ? used : 0)
    }

    /// Percent spent at `perHour` percent per hour from `now` to `end`;
    /// nothing for an end already passed.
    static func spent(perHour: Double, from now: Date, until end: Date) -> Double {
        perHour * max(0, end.timeIntervalSince(now)) / 3600
    }

    /// When `left` percent runs out at `perHour` percent per hour; nil when
    /// nothing is spent.
    static func runOut(left: Double, perHour: Double, now: Date) -> Date? {
        perHour > 0 ? now.addingTimeInterval(max(0, left) / perHour * 3600) : nil
    }

    /// The latest time continuous use must begin for the long window's rest
    /// to be spent before it resets at `resetsAt`, when the session window
    /// caps how fast it drains: one session window spends at most
    /// `100 / sessionPerWeekly` long-window percent. `sessionPerWeekly` nil,
    /// for an account without a session cap, drains at once.
    static func latestStart(weeklyUsed: Double, resetsAt: Date, sessionPerWeekly: Double?) -> Date {
        guard let sessionPerWeekly else { return resetsAt }
        let perHour = (100 / sessionPerWeekly) / (sessionWindow / 3600)
        return resetsAt.addingTimeInterval(-(100 - weeklyUsed) / perHour * 3600)
    }

    /// An account's work as long-window percent per hour: its long-window
    /// rate, or its session rate counted in long-window percent when that
    /// is the faster.
    static func weeklyPace(sessionPerHour: Double, weeklyPerHour: Double, sessionPerWeekly: Double) -> Double {
        max(weeklyPerHour, sessionPerHour / max(1, sessionPerWeekly))
    }
}
