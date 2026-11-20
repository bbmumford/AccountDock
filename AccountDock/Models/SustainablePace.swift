import Foundation

/// "Pace sessions to the resets" (`ProviderFailoverPolicy.paceToResets`):
/// keeps a provider's total use at what its accounts can carry until
/// capacity materially returns, by holding its lowest-ranked sessions and
/// releasing them as room allows, instead of every session running flat
/// out and all of them stopping together.
///
/// `target` finds that total rate with the Outlook's simulation
/// (`CapacityOutlook.run`).
///
/// Assumptions, those of the Outlook: each session keeps the rate it is
/// expected to use (`AppState.capacityOutlookSessions`), use the router
/// does not see and the cache rewrites of moves are not counted, and the
/// accounts' token costs are the learned ones blended toward their plan
/// sizes (`AppState.accountRatio`).
enum SustainablePace {
    // MARK: - Target

    /// The total rate the accounts carry, and until when.
    struct Target: Equatable {
        /// Weighted tokens per hour the accounts serve from now until
        /// `until` with no stretch in which every session waits.
        var tokensPerHour: Double
        /// When capacity materially returns: the first new week of an
        /// account at or after the flat-out projection's pause, else the end
        /// of the horizon.
        var until: Date
        /// The account whose new week that is; nil at the horizon's end.
        var untilAccount: String?
        /// The sessions' total at the rates they are expected to use, and
        /// when every session pauses at it.
        var flatOutTokensPerHour: Double
        var flatOutPausedAt: Date
    }

    /// The step of the search's projections: coarser than the Outlook's,
    /// since a target runs one projection per halving; resets still split
    /// steps exactly.
    static let searchStep: TimeInterval = 15 * 60
    /// Halvings of the search between nothing and the flat-out rate, which
    /// find the target within 1/4096 of that rate.
    static let searchHalvings = 12

    /// The rate the accounts carry: the highest uniform total at which the
    /// projection (`CapacityOutlook.run`) has no stretch with every session
    /// paused before capacity materially returns, found by halving between
    /// nothing and `flatOut`, the sessions' total now. Capacity materially
    /// returns at the first new week of an account at or after the moment
    /// everything pauses at `flatOut`: a 5-hour window refilling before
    /// then brings room that the weekly allowances behind it may not, so
    /// pacing to it would spend those allowances at the windows' pace and
    /// stop everything later all the same. Each account's room counts as
    /// the projection counts it: its weekly allowance, capped by what its
    /// 5-hour windows deliver before its weekly reset, refills on the way
    /// included. Nil when nothing needs pacing: the sessions use nothing,
    /// they run through the horizon flat out, or every session already
    /// waits (no account has room, which the limit pauses handle), or the
    /// accounts carry no rate at all.
    static func target(accounts: [CapacityOutlook.Account], flatOut: Double, now: Date,
                       pacer: SessionPacer = SessionPacer(), step: TimeInterval = searchStep,
                       horizon: TimeInterval = CapacityOutlook.defaultHorizon) -> Target? {
        guard flatOut > 0 else { return nil }
        let flat = CapacityOutlook.run(accounts, demand: .init(tokensPerHour: flatOut), now: now, pacer: pacer,
                                       horizon: horizon, reach: .newWeekAfterPause)
        guard let paused = flat.allPausedAt, paused > now.addingTimeInterval(60) else { return nil }
        let until = flat.newWeekAfterPause?.at ?? now.addingTimeInterval(horizon)
        func carries(_ rate: Double) -> Bool {
            let run = CapacityOutlook.run(accounts, demand: .init(tokensPerHour: rate), now: now, pacer: pacer,
                                          step: step, horizon: until.timeIntervalSince(now), reach: .firstPause)
            return run.allPausedAt.map { $0 >= until.addingTimeInterval(-step) } ?? true
        }
        var low = 0.0, high = flatOut
        for _ in 0..<searchHalvings {
            let middle = (low + high) / 2
            if carries(middle) { low = middle } else { high = middle }
        }
        guard low > 0 else { return nil }
        return Target(tokensPerHour: low, until: until, untilAccount: flat.newWeekAfterPause?.name,
                      flatOutTokensPerHour: flatOut, flatOutPausedAt: paused)
    }
}
