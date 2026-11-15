import Foundation

/// How large a session is, how long its prompt cache lasts, and what moving
/// it to another account costs, counted the same way by the router and the
/// app. The router places sessions with it (`RouterLogic.planMessages`,
/// `ProviderPassthrough.routeServes`); the app paces and holds them with it
/// (`SessionRates`, `SessionPacer.moveCost`, `TurnCostModel`). If the two
/// counted differently, the app would hold a session the router still
/// sends to a route target, or move one the router thinks is warm.
enum SessionSizing {
    /// Tokens weighted by their relative price: uncached and cache-read
    /// input at 0.1 (the share sent uncached is not reported apart from
    /// reads), cache writes at 1.25, or 2 for the one-hour cache, and
    /// output at 5. `cacheWriteLong` is the one-hour part of `cacheWrite`.
    static func weighted(context: Int, cacheWrite: Int, output: Int, cacheWriteLong: Int = 0) -> Double {
        let long = min(max(0, cacheWriteLong), cacheWrite)
        return Double(max(0, context - cacheWrite)) * 0.1 + Double(cacheWrite - long) * 1.25 + Double(long) * 2
            + Double(output) * 5
    }

    /// Weighted tokens a move costs per token of context: the context is
    /// written into the new account's cache instead of read from the old.
    static let rewritePerContextToken = 1.25 - 0.1

    /// Weighted tokens a session of `contextTokens` costs when it moves.
    static func rewriteTokens(_ contextTokens: Int) -> Double {
        Double(max(0, contextTokens)) * rewritePerContextToken
    }

    /// Weighted tokens the first request of a session arriving on another
    /// account costs there: its whole context written into that account's
    /// cache, at 2 a token for the one-hour cache and 1.25 for the
    /// five-minute one (`weighted`). `rewriteTokens` is what a move adds over
    /// staying; this is what the destination's window must hold, which
    /// `SessionPacer.arrivalCost` charges where a window's room decides a
    /// placement.
    static func arrivalTokens(_ contextTokens: Int, cacheLifetime: TimeInterval?) -> Double {
        Double(max(0, contextTokens)) * ((cacheLifetime ?? defaultCacheLifetime) > 5 * 60 ? 2 : 1.25)
    }

    /// Window percent a move of a session of `contextTokens` costs on the
    /// account it moves to, whose token cost is `percentPerMillion`, times
    /// `factor` for a CLI that must be restarted to move.
    static func moveCost(_ contextTokens: Int, percentPerMillion: Double, factor: Double = 1) -> Double {
        Allowance.percent(millions: rewriteTokens(contextTokens) / 1_000_000, percentPerMillion: percentPerMillion) * factor
    }

    /// The context a session's next request carries: the last one measured
    /// from a reply's usage, which the app's session rates hold too; the
    /// request's size at about four bytes a token only while nothing has
    /// been measured.
    static func contextTokens(lastMeasured: Int?, bodyBytes: Int) -> Int {
        if let lastMeasured, lastMeasured > 0 { return lastMeasured }
        return max(0, bodyBytes / 4)
    }

    /// The prompt cache lifetime assumed for a session that never said one.
    static let defaultCacheLifetime: TimeInterval = 60 * 60

    /// When a session's prompt cache expires: `lifetime` after its last
    /// served request, the lifetime its requests last asked for.
    static func cacheExpiresAt(lastServed: Date, lifetime: TimeInterval?) -> Date {
        lastServed.addingTimeInterval(lifetime ?? defaultCacheLifetime)
    }
}
