import Foundation

/// "Pace sessions to the resets" (`ProviderFailoverPolicy.paceToResets`):
/// keeps a provider's total use at what its accounts can carry until
/// capacity materially returns, by holding its lowest-ranked sessions and
/// releasing them as room allows, instead of every session running flat
/// out and all of them stopping together.
///
/// `target` finds that total rate with the Outlook's simulation
/// (`CapacityOutlook.run`); `rank` and `choose` pick the sessions that run
/// within it; `decide` keeps the running set steady between changes.
/// `AppState.paceSessionsToResets` applies each decision through the pause
/// gate every quota cycle.
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

    /// When `target` lasts until, in words: "Mon 8:00 am (bytrix's new
    /// week)".
    static func until(_ target: Target, now: Date) -> String {
        UsageFormat.clock(target.until, now: now) + (target.untilAccount.map { " (\($0)'s new week)" } ?? "")
    }

    // MARK: - Choosing the sessions

    /// One running session as pacing weighs it, built by
    /// `AppState.pacingCandidates`.
    struct Candidate: Equatable {
        /// Why a session runs whatever the target.
        enum Fixed: Equatable {
            /// Pinned to its subscription (`SessionPins`).
            case pinned
            /// The user marked it a priority session (`SessionPriorities`).
            case priority
            /// The user played it while pacing held it, within `playLasts`.
            case played
            /// No pause gate holds it: it started before the gate was
            /// installed (`AppState.sessionsWithoutGate`).
            case cannotHold
        }

        let id: String
        var label: String
        /// Weighted tokens per hour it is expected to use while it runs.
        var tokensPerHour: Double
        var fixed: Fixed? = nil
        /// The user's last prompt to it (`AgentSession.humanPromptAt`), or
        /// play of it, whichever is later; nil when neither is known.
        var lastPrompt: Date? = nil
    }

    /// A prompt from the user within this long makes the session one the
    /// user is working in, which outranks one running on its own.
    static let interactionWindow: TimeInterval = 60 * 60

    /// `candidates` in the order pacing keeps them running: fixed sessions
    /// first; then those the user prompted within `interactionWindow`, the
    /// most recently prompted first; then the rest. Within each, lighter
    /// before heavier, so more sessions keep moving.
    static func rank(_ candidates: [Candidate], now: Date) -> [Candidate] {
        func tier(_ candidate: Candidate) -> Int {
            if candidate.fixed != nil { return 0 }
            if let prompt = candidate.lastPrompt, now.timeIntervalSince(prompt) <= interactionWindow { return 1 }
            return 2
        }
        return candidates.sorted { lhs, rhs in
            let (left, right) = (tier(lhs), tier(rhs))
            if left != right { return left < right }
            if left == 1, let first = lhs.lastPrompt, let second = rhs.lastPrompt, first != second { return first > second }
            if lhs.tokensPerHour != rhs.tokensPerHour { return lhs.tokensPerHour < rhs.tokensPerHour }
            return lhs.id < rhs.id
        }
    }

    /// The sessions that run within `target` weighted tokens per hour:
    /// every fixed one, then each of `ranked` in order whose rate still fits
    /// beside those chosen before it; one that does not fit is passed over
    /// for the lighter ones after it. A session using nothing always runs:
    /// holding it saves nothing. Pacing never holds every session: with
    /// none chosen, the lightest runs.
    static func choose(_ ranked: [Candidate], target: Double) -> Set<String> {
        var running = Set<String>()
        var total = 0.0
        for candidate in ranked where candidate.fixed != nil {
            running.insert(candidate.id)
            total += max(0, candidate.tokensPerHour)
        }
        for candidate in ranked where candidate.fixed == nil {
            let rate = max(0, candidate.tokensPerHour)
            guard rate == 0 || total + rate <= target else { continue }
            running.insert(candidate.id)
            total += rate
        }
        if running.isEmpty, let lightest = ranked.min(by: { lhs, rhs in
            lhs.tokensPerHour == rhs.tokensPerHour ? lhs.id < rhs.id : lhs.tokensPerHour < rhs.tokensPerHour
        }) {
            running.insert(lightest.id)
        }
        return running
    }

    // MARK: - Keeping the set steady

    /// What pacing holds, kept per provider in `AppState.pacedDecisions`.
    struct Decision: Equatable {
        /// The sessions pacing holds.
        var held: Set<String>
        /// When the running set was last chosen.
        var decidedAt: Date
        var target: Target
    }

    /// The running set changes at most this often, so sessions are not
    /// held and released from minute to minute as rates move.
    static let changeInterval: TimeInterval = 15 * 60
    /// A user's play of a held session keeps it running this long, as a
    /// fixed session, before it is ranked with the others again: long
    /// enough for the work the user released it for, as a play elsewhere
    /// lasts until a limit. The play also counts as the user's latest
    /// prompt to it.
    static let playLasts: TimeInterval = 60 * 60
    /// The running sessions' total may exceed the target by this factor
    /// before the set changes sooner than `changeInterval`: a session
    /// working much harder than it did would otherwise run the accounts out
    /// before capacity returns.
    static let overshoot = 1.25

    /// The decision this cycle, from `previous`: the sessions `choose`
    /// leaves out are held, but only when `changeInterval` has passed since
    /// the last change, a held session became fixed (the user played it, so
    /// it runs now and the others are chosen around it, or marked it
    /// priority), or the sessions running would use more than `overshoot`
    /// times the target. Otherwise the held set stays, less sessions that
    /// ended or became fixed; a session that started since runs until the
    /// next change.
    static func decide(previous: Decision?, candidates: [Candidate], target: Target, now: Date) -> Decision {
        let ids = Set(candidates.map(\.id))
        let ideal = ids.subtracting(choose(rank(candidates, now: now), target: target.tokensPerHour))
        guard let previous else { return Decision(held: ideal, decidedAt: now, target: target) }
        guard mayChange(previous, candidates: candidates, target: target, now: now) else {
            return Decision(held: kept(previous, candidates: candidates), decidedAt: previous.decidedAt, target: target)
        }
        return Decision(held: ideal, decidedAt: now, target: target)
    }

    /// Whether the next decision needs a fresh target: there is none yet,
    /// or the running set may change now (`mayChange`, judged against the
    /// last target). `AppState.paceSessionsToResets` keeps the last target
    /// otherwise, since each costs a dozen projections.
    static func needsTarget(previous: Decision?, candidates: [Candidate], now: Date) -> Bool {
        guard let previous else { return true }
        return mayChange(previous, candidates: candidates, target: previous.target, now: now)
    }

    /// `decide`'s rule for changing the running set before
    /// `changeInterval` has passed: a held session became fixed (the user
    /// played it or marked it priority), or the sessions running would use
    /// more than `overshoot` times the target.
    private static func mayChange(_ previous: Decision, candidates: [Candidate], target: Target, now: Date) -> Bool {
        if now.timeIntervalSince(previous.decidedAt) >= changeInterval { return true }
        let fixed = Set(candidates.filter { $0.fixed != nil }.map(\.id))
        if !previous.held.intersection(fixed).isEmpty { return true }
        let held = kept(previous, candidates: candidates)
        let running = candidates.filter { !held.contains($0.id) }.reduce(0) { $0 + max(0, $1.tokensPerHour) }
        return running > target.tokensPerHour * overshoot
    }

    /// The sessions `previous` held that still run and are not fixed.
    private static func kept(_ previous: Decision, candidates: [Candidate]) -> Set<String> {
        previous.held.intersection(candidates.filter { $0.fixed == nil }.map(\.id))
    }

    /// The pause gate's reason for a pause pacing starts.
    static let holdReason = "paced: waiting for room so the others can run until the resets"
}
