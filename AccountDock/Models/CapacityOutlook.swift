import Foundation

/// How long a provider's sessions keep running at their current rates, and
/// when they run again: the Outlook under each provider on the Sessions page
/// and the usage tab (`CapacityOutlookView`), built by
/// `AppState.capacityOutlook`.
///
/// `project` plays the sessions' total rate forward over the accounts that
/// can serve them, in steps of at most `step` that also stop at every reset,
/// until the sessions run again after a stretch with every account spent,
/// or for `horizon`. Each step:
/// - every 5-hour window whose reset has passed starts again empty, and every
///   weekly allowance whose reset has passed starts again full;
/// - the demand of the step is served from the accounts with room in the
///   order session balancing spends them (`priority`): first those whose
///   weekly allowance would expire unused (`SessionPacer.useBy`), then by
///   weekly balancing's latest start; each up to what its 5-hour window and
///   weekly allowance still hold (`roomBy`), with the pacer's limit leaving
///   in-flight turns their room;
/// - what no account can serve pauses; within a step the served part runs
///   first, so a step where the last room runs out splits at that moment.
///
/// Assumptions: rates stay as they are now (a session idle for its last hour
/// counts at its near-zero current rate); use the router does not see and
/// the cache rewrite of moving a session are not counted; an account at its
/// limit (`Availability.atLimit`) serves nothing until it serves again
/// (`SessionPacer.bindingReset`); excluded and unavailable accounts never
/// serve.
struct CapacityOutlook: Equatable {
    /// Whether an account takes part, from failover's policy and
    /// `FailoverPlanner.servingVerdict`.
    enum Availability: Equatable {
        /// Below its limits, or near one.
        case serves
        /// At a limit by its reading, or refused there: it serves again from
        /// the reset that frees it.
        case atLimit
        /// Excluded from failover: it never serves the pool.
        case excluded
        /// Needs signing in, or has no reading or entitlement to trust.
        case unavailable
    }

    struct Account: Equatable {
        /// Its windows, resets and token cost as the pacer takes them
        /// (`AppState.pacerAccount`).
        var pacer: SessionPacer.Account
        var name: String
        /// 5-hour window percent one weekly percent costs, which sizes the
        /// weekly allowance a new week brings in the unit of
        /// `SessionPacer.Account.weeklyRemaining`.
        var sessionPerWeekly: Double = FailoverPlanner.defaultSessionPerWeekly
        var availability: Availability = .serves
        var id: UUID { pacer.id }
    }

    struct Session: Equatable {
        let id: String
        /// As the Sessions page names it (`AppState.sessionLabel`).
        var label: String
        /// Weighted tokens per hour it is expected to keep using.
        var tokensPerHour: Double
    }

    /// Something that changes what the accounts can serve.
    struct Event: Equatable {
        enum Kind: Equatable {
            /// A 5-hour window starts again empty.
            case windowRefill
            /// A weekly allowance starts again full.
            case newWeek
            /// An account's 5-hour window reaches its limit.
            case windowSpent
            /// An account's weekly allowance reaches its limit.
            case weekSpent
            /// No account has room left: every session pauses.
            case allPaused
        }

        var at: Date
        var kind: Kind
        var account: UUID?
        var name: String?
        /// For a spent window or week, when the account serves again.
        var back: Date?
        /// For a refill while every session is paused, how long the sessions
        /// run on what it brings; nil for one that comes before the pause.
        var runs: TimeInterval?

        var isRefill: Bool { kind == .windowRefill || kind == .newWeek }
    }

    /// A stretch of the projection: the sessions run or are paused.
    struct Segment: Equatable {
        var start: Date
        var end: Date
        var running: Bool
    }

    /// The projection without the heaviest session: when everything would
    /// pause then; nil when nothing would within `horizon`.
    struct WhatIf: Equatable {
        var session: Session
        var allPausedAt: Date?
    }

    var now: Date
    var horizon: TimeInterval
    /// From `now` to the end of the span the outlook shows: a little past the
    /// resume, or `horizon` without one.
    var segments: [Segment] = []
    /// When every session pauses; nil when they run through `horizon`.
    var allPausedAt: Date?
    /// The refill the sessions run again from after `allPausedAt`; nil when
    /// none comes within `horizon`.
    var resume: Event?
    /// Refills, spent windows and weeks and the pause, in time order, up to
    /// the resume.
    var events: [Event] = []
    /// The sessions' total rate and how many sessions there are.
    var tokensPerHour = 0.0
    var sessionCount = 0
    /// The three sessions using the most, heaviest first.
    var biggest: [Session] = []
    var whatIf: WhatIf?

    /// A running stretch after every session paused that lasts at least this
    /// long is where they resume; a shorter one is a burst on a window's last
    /// room or a small plan's window, and they pause again after it.
    static let resumeRun: TimeInterval = 30 * 60

    /// Whether sessions run from `event` on: a running stretch starts within
    /// a minute of it, or one is under way then. A refill after which every
    /// session still waits, as a new week while the 5-hour window is still
    /// at its limit, brings no room. Read by the Outlook's bar and list.
    func bringsRoom(_ event: Event) -> Bool {
        segments.contains { segment in
            segment.running && segment.start <= event.at.addingTimeInterval(60) && segment.end > event.at.addingTimeInterval(30)
        }
    }
    static let defaultStep: TimeInterval = 5 * 60
    static let defaultHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// A week renews this long after its last reset.
    static let weekLength: TimeInterval = 7 * 24 * 60 * 60

    /// The outlook for `sessions` on `accounts` from `now`, with the what-if
    /// for the heaviest session when the others would still run then.
    static func project(accounts: [Account], sessions: [Session], now: Date, pacer: SessionPacer = SessionPacer(),
                        step: TimeInterval = CapacityOutlook.defaultStep,
                        horizon: TimeInterval = CapacityOutlook.defaultHorizon) -> CapacityOutlook {
        let rate = sessions.reduce(0) { $0 + max(0, $1.tokensPerHour) }
        let run = simulate(accounts, rate: rate, now: now, pacer: pacer, step: step, horizon: horizon)
        let ranked = sessions.filter { $0.tokensPerHour > 0 }
            .sorted { $0.tokensPerHour == $1.tokensPerHour ? $0.id < $1.id : $0.tokensPerHour > $1.tokensPerHour }
        var outlook = CapacityOutlook(now: now, horizon: horizon, segments: run.segments, allPausedAt: run.allPausedAt,
                                      resume: run.resume, events: run.events, tokensPerHour: rate,
                                      sessionCount: sessions.count, biggest: Array(ranked.prefix(3)))
        if let heaviest = ranked.first, ranked.count > 1, let paused = run.allPausedAt, paused > now {
            let without = simulate(accounts, rate: rate - heaviest.tokensPerHour, now: now, pacer: pacer, step: step,
                                   horizon: horizon)
            outlook.whatIf = WhatIf(session: heaviest, allPausedAt: without.allPausedAt)
        }
        return outlook
    }

    // MARK: - Simulation

    private struct Run {
        var segments: [Segment] = []
        var events: [Event] = []
        var allPausedAt: Date?
        var resume: Event?
    }

    /// An account as the simulation spends it.
    private struct State {
        var account: Account
        /// It serves nothing before this.
        var blockedUntil: Date?
        var id: UUID { account.id }
    }

    private static func simulate(_ accounts: [Account], rate: Double, now: Date, pacer: SessionPacer,
                                 step: TimeInterval, horizon: TimeInterval) -> Run {
        var states = accounts.compactMap { account -> State? in
            switch account.availability {
            case .serves: return State(account: account, blockedUntil: nil)
            case .atLimit:
                return State(account: account,
                             blockedUntil: pacer.bindingReset(account.pacer, now: now) ?? now.addingTimeInterval(pacer.window))
            case .excluded, .unavailable: return nil
            }
        }
        var run = Run()
        var end = now.addingTimeInterval(horizon)
        var time = now
        // The running stretch after the pause, and the refill it began with.
        var stretch: (start: Date, cause: Int?)?
        while time < end {
            // Resets due now, each kept with the tokens it frees now: a new
            // week that renews the allowance, whether or not its 5-hour
            // window has room yet, and a window or an unblocking that frees
            // room.
            var refills: [(event: Int, tokens: Double)] = []
            for index in states.indices {
                let before = room(states[index], at: time.addingTimeInterval(-1), pacer: pacer)
                let weeklyBefore = states[index].account.pacer.weeklyRemaining ?? 0
                let reset = applyResets(&states[index], at: time, pacer: pacer)
                guard reset.window || reset.week || reset.unblocked else { continue }
                let gained = max(0, room(states[index], at: time, pacer: pacer) - before)
                let renewed = reset.week
                    && (states[index].account.pacer.weeklyRemaining ?? 0) - weeklyBefore >= SessionPacer.minimumLeftover
                guard renewed || gained >= SessionPacer.minimumLeftover else { continue }
                run.events.append(Event(at: time, kind: renewed ? .newWeek : .windowRefill, account: states[index].id,
                                        name: states[index].account.name))
                refills.append((run.events.count - 1, pacer.millions(gained, on: states[index].account.pacer)))
            }
            // The step ends at the next reset when one comes sooner.
            var next = min(time.addingTimeInterval(step), end)
            for state in states {
                let resets = [state.account.pacer.resetsAt, state.account.pacer.weeklyResetsAt, state.blockedUntil]
                for reset in resets.compactMap({ $0 }) where reset > time && reset < next { next = reset }
            }
            let wanted = rate * next.timeIntervalSince(time) / 3600
            var served = 0.0
            if wanted > 0 {
                let order = states.indices
                    .map { index -> (index: Int, rank: (free: Bool, by: Date, window: Date), tokens: Double) in
                        let left = room(states[index], at: time, pacer: pacer)
                        return (index, priority(states[index], at: time, pacer: pacer),
                                left > 1e-9 ? pacer.millions(left, on: states[index].account.pacer) * 1_000_000 : 0)
                    }
                    .filter { $0.tokens > 0 }
                    .sorted { lhs, rhs in
                        if lhs.rank.free != rhs.rank.free { return lhs.rank.free }
                        if lhs.rank.by != rhs.rank.by { return lhs.rank.by < rhs.rank.by }
                        if lhs.rank.window != rhs.rank.window { return lhs.rank.window < rhs.rank.window }
                        if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                        return states[lhs.index].id.uuidString < states[rhs.index].id.uuidString
                    }
                for entry in order where served < wanted {
                    let taken = min(wanted - served, entry.tokens)
                    let percent = Allowance.percent(millions: taken / 1_000_000,
                                                    percentPerMillion: states[entry.index].account.pacer.percentPerMillion)
                    spend(&states[entry.index], percent: percent, at: time, pacer: pacer)
                    served += taken
                    guard taken >= entry.tokens * (1 - 1e-9) else { continue }
                    // Spent within the step, once the accounts before it in
                    // the order were.
                    let at = time.addingTimeInterval(served / rate * 3600)
                    let state = states[entry.index]
                    run.events.append(Event(at: at, kind: spentKind(state, at: at, pacer: pacer), account: state.id,
                                            name: state.account.name, back: pacer.bindingReset(state.account.pacer, now: at)))
                }
            }
            let fraction = wanted > 0 ? min(1, served / wanted) : 1
            let runEnd = time.addingTimeInterval(fraction * next.timeIntervalSince(time))
            append(&run.segments, Segment(start: time, end: runEnd, running: true))
            append(&run.segments, Segment(start: runEnd, end: next, running: false))
            let short = fraction < 1 - 1e-9
            if run.allPausedAt == nil {
                if short {
                    run.allPausedAt = runEnd
                    run.events.append(Event(at: runEnd, kind: .allPaused))
                }
            } else if run.resume == nil {
                if stretch == nil, runEnd > time {
                    // What the sessions run on: the refill freeing the most
                    // tokens now, a new week on a tie.
                    let cause = refills.max { lhs, rhs in
                        if lhs.tokens != rhs.tokens { return lhs.tokens < rhs.tokens }
                        return run.events[lhs.event].kind != .newWeek && run.events[rhs.event].kind == .newWeek
                    }
                    stretch = (time, cause?.event)
                }
                if let current = stretch {
                    let length = runEnd.timeIntervalSince(current.start)
                    if length >= resumeRun {
                        if let cause = current.cause {
                            run.events[cause].runs = length
                            run.resume = run.events[cause]
                        } else {
                            run.resume = Event(at: current.start, kind: .windowRefill)
                        }
                        // Runs on far enough to show the sessions running
                        // again past the resume.
                        let tail = max(10 * 60, current.start.timeIntervalSince(now) * 0.05)
                        end = min(end, max(next, current.start.addingTimeInterval(tail)))
                    } else if short {
                        if let cause = current.cause { run.events[cause].runs = length }
                        stretch = nil
                    }
                }
            }
            time = next
        }
        run.events.sort { $0.at == $1.at ? rank($0.kind) < rank($1.kind) : $0.at < $1.at }
        if let resume = run.resume {
            // Nothing after the resume is part of the outlook but a short
            // stretch showing the sessions running again.
            run.events.removeAll { $0.at > resume.at }
            let shown = resume.at.addingTimeInterval(max(10 * 60, resume.at.timeIntervalSince(now) * 0.05))
            run.segments = run.segments.compactMap { segment in
                guard segment.start < shown else { return nil }
                var trimmed = segment
                trimmed.end = min(segment.end, shown)
                return trimmed
            }
        }
        return run
    }

    /// Window percent the account can spend at `time`: what its 5-hour
    /// window and weekly allowance both still hold (`SessionPacer.roomBy`),
    /// nothing while it is blocked.
    private static func room(_ state: State, at time: Date, pacer: SessionPacer) -> Double {
        if let blocked = state.blockedUntil, blocked > time { return 0 }
        return max(0, pacer.roomBy(state.account.pacer, time, spent: 0, now: time))
    }

    /// Starts each window whose reset has passed again: a 5-hour window
    /// empty, not running until it is next spent, and a weekly allowance full
    /// with its reset a week on.
    private static func applyResets(_ state: inout State, at time: Date,
                                    pacer: SessionPacer) -> (window: Bool, week: Bool, unblocked: Bool) {
        var result = (window: false, week: false, unblocked: false)
        if let reset = state.account.pacer.resetsAt, reset <= time {
            state.account.pacer.resetsAt = nil
            state.account.pacer.utilization = 0
            result.window = true
        }
        if state.account.pacer.weeklyRemaining != nil, var reset = state.account.pacer.weeklyResetsAt, reset <= time {
            while reset <= time { reset = reset.addingTimeInterval(weekLength) }
            state.account.pacer.weeklyResetsAt = reset
            state.account.pacer.weeklyRemaining = pacer.limit * state.account.sessionPerWeekly
            result.week = true
        }
        if let blocked = state.blockedUntil, blocked <= time {
            state.blockedUntil = nil
            result.unblocked = true
        }
        return result
    }

    /// Spends `percent` of the account's windows at `time`; a 5-hour window
    /// not running starts there.
    private static func spend(_ state: inout State, percent: Double, at time: Date, pacer: SessionPacer) {
        if state.account.pacer.hasSessionWindow {
            if state.account.pacer.resetsAt.map({ $0 <= time }) ?? true {
                state.account.pacer.resetsAt = time.addingTimeInterval(pacer.window)
                state.account.pacer.utilization = 0
            }
            state.account.pacer.utilization += percent
        }
        if let weekly = state.account.pacer.weeklyRemaining {
            state.account.pacer.weeklyRemaining = weekly - percent
        }
    }

    /// Which limit a spent account reached: its weekly allowance when that
    /// has no more left than its 5-hour window.
    private static func spentKind(_ state: State, at time: Date, pacer: SessionPacer) -> Event.Kind {
        let account = state.account.pacer
        guard let weekly = account.weeklyRemaining, let reset = account.weeklyResetsAt, reset > time else { return .windowSpent }
        guard account.hasSessionWindow else { return .weekSpent }
        return weekly <= pacer.remaining(account, now: time) + 1e-9 ? .weekSpent : .windowSpent
    }

    /// Where the account comes in the order the step's demand is served in,
    /// as session balancing spends allowances: first the accounts whose
    /// weekly allowance would expire unused even with every 5-hour window
    /// filled (`SessionPacer.useBy`), soonest use-by time first, each up to
    /// its window's limit; then the rest by the latest moment continuous use
    /// still spends their week before it resets
    /// (`Allowance.latestStart`, weekly balancing's order), and on a tie the
    /// 5-hour window that resets first.
    private static func priority(_ state: State, at time: Date,
                                 pacer: SessionPacer) -> (free: Bool, by: Date, window: Date) {
        let account = state.account.pacer
        let windowEnd = account.resetsAt.flatMap { $0 > time ? $0 : nil } ?? time.addingTimeInterval(pacer.window)
        if let useBy = pacer.useBy(account, now: time) { return (true, useBy, windowEnd) }
        guard let weekly = account.weeklyRemaining, let weeklyEnd = account.weeklyResetsAt, weeklyEnd > time else {
            return (false, .distantFuture, windowEnd)
        }
        let perWeekly = max(state.account.sessionPerWeekly, 1e-9)
        let start = Allowance.latestStart(weeklyUsed: pacer.limit - weekly / perWeekly, resetsAt: weeklyEnd,
                                          sessionPerWeekly: account.hasSessionWindow ? perWeekly : nil)
        return (false, start, windowEnd)
    }

    private static func append(_ segments: inout [Segment], _ segment: Segment) {
        guard segment.end > segment.start else { return }
        if var last = segments.last, last.running == segment.running, last.end >= segment.start {
            last.end = segment.end
            segments[segments.count - 1] = last
        } else {
            segments.append(segment)
        }
    }

    /// Events at the same moment: refills, then what runs out, then the
    /// pause.
    private static func rank(_ kind: Event.Kind) -> Int {
        switch kind {
        case .newWeek: 0
        case .windowRefill: 1
        case .windowSpent: 2
        case .weekSpent: 3
        case .allPaused: 4
        }
    }
}

// MARK: - One account alone

extension CapacityOutlook {
    /// Work an account takes on from `from`: `tokensPerHour` from then on,
    /// after its arrival writes `arrivalTokens` into the account's cache.
    /// The charges of a cycle's `LaneLedger`, as `servedAlone` and
    /// `carries` step through them.
    struct Load: Equatable {
        var from: Date
        var tokensPerHour: Double
        var arrivalTokens: Double = 0
    }

    /// Weighted tokens `account` serves on its own from `now` until `end`:
    /// `base`, the rate of the sessions on it, throughout, each of `loads`
    /// from its start, and `extra` from `extraFrom` (now when nil), whose
    /// arrival first writes `arrival` tokens into its cache. It serves while
    /// it has room and refuses what it cannot carry until a reset frees
    /// more, the way the main projection steps; none of its work goes
    /// elsewhere, so work added there takes room from the sessions already
    /// on it. Also the window percent it has room for at `end`, once the
    /// resets due then have refilled it. Excluded and unavailable accounts
    /// serve nothing. Read by `HeldSessionPlan`.
    static func servedAlone(_ account: Account, base: Double, loads: [Load] = [], extra: Double = 0,
                            extraFrom: Date? = nil, arrival: Double = 0, now: Date, until end: Date,
                            pacer: SessionPacer,
                            step: TimeInterval = CapacityOutlook.defaultStep) -> (served: Double, room: Double) {
        var state: State
        switch account.availability {
        case .serves: state = State(account: account, blockedUntil: nil)
        case .atLimit:
            state = State(account: account,
                          blockedUntil: pacer.bindingReset(account.pacer, now: now) ?? now.addingTimeInterval(pacer.window))
        case .excluded, .unavailable: return (0, 0)
        }
        func tokens(_ percent: Double) -> Double { pacer.millions(percent, on: state.account.pacer) * 1_000_000 }
        func percent(_ tokens: Double) -> Double {
            Allowance.percent(millions: tokens / 1_000_000, percentPerMillion: state.account.pacer.percentPerMillion)
        }
        let start = max(now, extraFrom ?? now)
        var arrived = extra <= 0 && arrival <= 0
        var loadsArrived = Set<Int>()
        var served = 0.0
        var time = now
        while time < end {
            _ = applyResets(&state, at: time, pacer: pacer)
            for (index, load) in loads.enumerated() where !loadsArrived.contains(index) && load.from <= time {
                loadsArrived.insert(index)
                let written = min(load.arrivalTokens, tokens(room(state, at: time, pacer: pacer)))
                if written > 0 { spend(&state, percent: percent(written), at: time, pacer: pacer) }
            }
            if !arrived, time >= start {
                arrived = true
                let written = min(arrival, tokens(room(state, at: time, pacer: pacer)))
                if written > 0 { spend(&state, percent: percent(written), at: time, pacer: pacer) }
            }
            var next = min(time.addingTimeInterval(step), end)
            let resets = [state.account.pacer.resetsAt, state.account.pacer.weeklyResetsAt, state.blockedUntil, start]
                + loads.map(\.from)
            for reset in resets.compactMap({ $0 }) where reset > time && reset < next { next = reset }
            let rate = base + (time >= start ? extra : 0)
                + loads.filter { $0.from <= time }.reduce(0) { $0 + $1.tokensPerHour }
            let taken = min(rate * next.timeIntervalSince(time) / 3600, tokens(room(state, at: time, pacer: pacer)))
            if taken > 0 { spend(&state, percent: percent(taken), at: time, pacer: pacer) }
            served += max(0, taken)
            time = next
        }
        _ = applyResets(&state, at: end, pacer: pacer)
        return (served, room(state, at: end, pacer: pacer))
    }

    /// Whether `account` carries `adding` from its start until `end`, beside
    /// `base` (from now) and `loads` (each from its start): at every step
    /// from `adding.from` on, everything it then serves, arrivals included,
    /// grown by 1 / `share` to keep the margin lane admission keeps
    /// (`SessionPacer.windowFitShare`), fits the room it has, resets
    /// refilling it on the way. Before `adding.from` the others spend what
    /// they would. An account blocked at its limit carries nothing before
    /// the reset that frees it; excluded and unavailable accounts carry
    /// nothing. The one test every rule that sends sessions to an account
    /// in a cycle applies with that cycle's `LaneLedger`: the held-session
    /// plans, the slot path's fallback and the sessions a pause releases.
    static func carries(_ account: Account, base: Double, loads: [Load], adding: Load, until end: Date, now: Date,
                        pacer: SessionPacer, share: Double = SessionPacer.windowFitShare,
                        step: TimeInterval = CapacityOutlook.defaultStep) -> Bool {
        var state: State
        switch account.availability {
        case .serves: state = State(account: account, blockedUntil: nil)
        case .atLimit:
            state = State(account: account,
                          blockedUntil: pacer.bindingReset(account.pacer, now: now) ?? now.addingTimeInterval(pacer.window))
        case .excluded, .unavailable: return false
        }
        func tokens(_ percent: Double) -> Double { pacer.millions(percent, on: state.account.pacer) * 1_000_000 }
        func percent(_ tokens: Double) -> Double {
            Allowance.percent(millions: tokens / 1_000_000, percentPerMillion: state.account.pacer.percentPerMillion)
        }
        let all = loads + [adding]
        let start = max(now, adding.from)
        let scale = share > 0 ? 1 / share : 1
        var arrived = Set<Int>()
        var time = now
        while time < end {
            _ = applyResets(&state, at: time, pacer: pacer)
            let checking = time >= start
            for (index, load) in all.enumerated() where !arrived.contains(index) && load.from <= time {
                arrived.insert(index)
                guard load.arrivalTokens > 0 else { continue }
                let room = tokens(room(state, at: time, pacer: pacer))
                let need = load.arrivalTokens * (checking ? scale : 1)
                if checking && need > room + 1 { return false }
                spend(&state, percent: percent(min(need, room)), at: time, pacer: pacer)
            }
            var next = min(time.addingTimeInterval(step), end)
            let resets = [state.account.pacer.resetsAt, state.account.pacer.weeklyResetsAt, state.blockedUntil, start]
                + all.map(\.from)
            for reset in resets.compactMap({ $0 }) where reset > time && reset < next { next = reset }
            let rate = base + all.filter { $0.from <= time }.reduce(0) { $0 + $1.tokensPerHour }
            let demand = rate * next.timeIntervalSince(time) / 3600 * (checking ? scale : 1)
            let room = tokens(room(state, at: time, pacer: pacer))
            if checking && demand > room + 1 { return false }
            let taken = min(demand, room)
            if taken > 0 { spend(&state, percent: percent(taken), at: time, pacer: pacer) }
            time = next
        }
        return true
    }

    /// How long `account` serves `base` and `loads` from `start` before it
    /// refuses some of them, at most until `end`: the minutes a planned
    /// lane's fresh window lasts the sessions planned onto it, which the
    /// held-session plans' event names. Zero for an account that serves
    /// nothing.
    static func lasting(_ account: Account, base: Double, loads: [Load], from start: Date, until end: Date, now: Date,
                        pacer: SessionPacer, step: TimeInterval = 60) -> TimeInterval {
        var state: State
        switch account.availability {
        case .serves: state = State(account: account, blockedUntil: nil)
        case .atLimit:
            state = State(account: account,
                          blockedUntil: pacer.bindingReset(account.pacer, now: now) ?? now.addingTimeInterval(pacer.window))
        case .excluded, .unavailable: return 0
        }
        func tokens(_ percent: Double) -> Double { pacer.millions(percent, on: state.account.pacer) * 1_000_000 }
        func percent(_ tokens: Double) -> Double {
            Allowance.percent(millions: tokens / 1_000_000, percentPerMillion: state.account.pacer.percentPerMillion)
        }
        var arrived = Set<Int>()
        var time = now
        while time < end {
            _ = applyResets(&state, at: time, pacer: pacer)
            let counting = time >= start
            for (index, load) in loads.enumerated() where !arrived.contains(index) && load.from <= time {
                arrived.insert(index)
                let room = tokens(room(state, at: time, pacer: pacer))
                if counting && load.arrivalTokens > room + 1 { return time.timeIntervalSince(start) }
                spend(&state, percent: percent(min(load.arrivalTokens, room)), at: time, pacer: pacer)
            }
            var next = min(time.addingTimeInterval(step), end)
            let resets = [state.account.pacer.resetsAt, state.account.pacer.weeklyResetsAt, state.blockedUntil, start]
                + loads.map(\.from)
            for reset in resets.compactMap({ $0 }) where reset > time && reset < next { next = reset }
            let rate = base + loads.filter { $0.from <= time }.reduce(0) { $0 + $1.tokensPerHour }
            let demand = rate * next.timeIntervalSince(time) / 3600
            let room = tokens(room(state, at: time, pacer: pacer))
            if counting && demand > room + 1 {
                let share = rate > 0 ? room / rate * 3600 : 0
                return time.addingTimeInterval(max(0, share)).timeIntervalSince(start)
            }
            spend(&state, percent: percent(min(demand, room)), at: time, pacer: pacer)
            time = next
        }
        return end.timeIntervalSince(start)
    }

    /// The account's resets from `now` until `end`, each with what it renews:
    /// its 5-hour window's (and one every five hours after it), its week's,
    /// and, at its limit, the reset that frees it (`bindingReset`). Read by
    /// `HeldSessionPlan.earliestLane`.
    static func resets(_ account: Account, now: Date, until end: Date,
                       pacer: SessionPacer) -> [(at: Date, kind: Event.Kind)] {
        var result: [Date: Event.Kind] = [:]
        if account.pacer.hasSessionWindow, var reset = account.pacer.resetsAt.flatMap({ $0 > now ? $0 : nil }) {
            while reset <= end && result.count < 64 {
                result[reset] = .windowRefill
                reset = reset.addingTimeInterval(pacer.window)
            }
        }
        if account.pacer.weeklyRemaining != nil, var reset = account.pacer.weeklyResetsAt.flatMap({ $0 > now ? $0 : nil }) {
            while reset <= end {
                result[reset] = .newWeek
                reset = reset.addingTimeInterval(weekLength)
            }
        }
        if account.availability == .atLimit, let freed = pacer.bindingReset(account.pacer, now: now), freed > now,
           freed <= end, result[freed] == nil {
            result[freed] = .windowRefill
        }
        return result.map { (at: $0.key, kind: $0.value) }.sorted { $0.at < $1.at }
    }
}

// MARK: - Words

extension CapacityOutlook {
    /// Every session is paused now.
    var alreadyPaused: Bool { allPausedAt.map { $0 <= now.addingTimeInterval(60) } ?? false }

    /// Where the span the timeline shows ends.
    var spanEnd: Date { segments.last?.end ?? now.addingTimeInterval(horizon) }

    /// The refills before the pause, the weeks spent up to it and the pause
    /// itself, and the refills during it: the outlook's three lists.
    var refillsBefore: [Event] {
        let pause = allPausedAt ?? .distantFuture
        return events.filter { $0.isRefill && $0.at < pause }
    }
    var runningOut: [Event] {
        guard !alreadyPaused else { return [] }
        let pause = allPausedAt ?? .distantFuture
        return events.filter { ($0.kind == .weekSpent || $0.kind == .allPaused) && $0.at <= pause }
    }
    var comingBack: [Event] {
        guard let pause = allPausedAt else { return [] }
        return events.filter { $0.isRefill && $0.at >= pause }
    }

    /// The bursts: refills during the pause the sessions run on for less than
    /// `resumeRun`.
    var bursts: [Event] { comingBack.filter { $0 != resume && $0.runs != nil } }

    /// "cybrio's new week", "fluxon's 5-hour window".
    static func reason(_ event: Event) -> String {
        let what = event.kind == .newWeek ? "new week" : "5-hour window"
        return event.name.map { "\($0)'s \(what)" } ?? what
    }

    private var horizonDays: Int { Int((horizon / 86_400).rounded()) }

    /// The collapsed Outlook line.
    var line: String {
        guard let paused = allPausedAt else {
            return "Runs through the next \(horizonDays) days at the current rate."
        }
        let back = resume.map { "about \(UsageFormat.clock($0.at, now: now)) (\(Self.reason($0)))" }
        if alreadyPaused {
            return back.map { "All paused · resumes \($0)" } ?? "All paused · nothing resumes within the next \(horizonDays) days"
        }
        let until = "Runs until about \(UsageFormat.clock(paused, now: now))"
        return until + " · then paused " + (back.map { "until \($0)" } ?? "beyond the next \(horizonDays) days")
    }

    /// "~270M tokens/h across 14 sessions".
    var rateLine: String {
        "~\(Self.millions(tokensPerHour)) tokens/h across \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    /// "cf-builder 113M/h · platform-engineer 52M/h"; nil with none using
    /// anything.
    var biggestLine: String? {
        guard !biggest.isEmpty else { return nil }
        return "Biggest users: " + biggest.map { "\($0.label) \(Self.millions($0.tokensPerHour))/h" }.joined(separator: " · ")
    }

    /// What pausing the heaviest session alone would do to the pause.
    var whatIfLine: String? {
        guard let whatIf else { return nil }
        guard let paused = whatIf.allPausedAt else {
            return "Pausing \(whatIf.session.label) alone would keep the others running through the next \(horizonDays) days."
        }
        return "Pausing \(whatIf.session.label) alone would push \"all paused\" to about \(UsageFormat.clock(paused, now: now))."
    }

    /// Million tokens: "270M", "3M", "0.4M".
    static func millions(_ tokens: Double) -> String {
        let value = tokens / 1_000_000
        if value >= 10 || value == 0 { return "\(Int(value.rounded()))M" }
        return String(format: value >= 1 ? "%.0fM" : "%.1fM", value)
    }
}
