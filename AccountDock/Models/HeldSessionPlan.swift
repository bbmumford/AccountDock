import Foundation

/// What a session no lane admits does (`SessionPacer.admitToLanes` left it
/// waiting): wait for the earliest lane, its own account or another, or move
/// now to a lane with room when that serves more. Waiting is the default.
/// Built by `AppState.planHeldSessions` for each such session every cycle
/// it is weighed; read by `noteLaneAdmission` (the wait it records and its
/// event), `strandedPlacements` (a move, or the lane once its reset is
/// verified) and the Sessions page row.
///
/// The earliest lane is the account whose 5-hour window, week, or limit
/// resets first with room for the session for an hour, by the measure lane
/// admission uses: its arrival's cache rewrite (none on its own account) and
/// an hour of its rate, beside an hour of the sessions already there, within
/// `SessionPacer.windowFitShare` of the room the reset leaves.
///
/// A move now is weighed against that wait by the work each serves until an
/// hour past the earliest lane's reset (`horizon`), each account alone
/// (`CapacityOutlook.servedAlone`): what the session adds where it goes,
/// less what the sessions already there lose once it fills that account
/// early, less its cache rewrite. Only a session whose own account resets
/// after its prompt cache expires may move: one whose account resets sooner
/// keeps its cache by waiting.
struct HeldSessionPlan: Equatable {
    enum Choice: Equatable {
        case wait
        case move
    }

    /// The held session as the plan weighs it.
    struct Session: Equatable {
        let id: String
        /// The account it runs on, which cannot serve it now.
        var account: UUID
        /// Weighted tokens per hour it is expected to use.
        var tokensPerHour: Double
        var contextTokens: Int
        var cacheLifetime: TimeInterval?
        var lastSeen: Date?
    }

    var choice: Choice
    /// Where it goes: the earliest lane when it waits, the lane it moves to.
    var lane: UUID
    var laneName: String
    /// When it starts there: the lane's reset when it waits, now when it
    /// moves.
    var at: Date
    /// Which reset frees the lane it waits for.
    var refill: CapacityOutlook.Event.Kind
    /// Its own account, and when that serves it again.
    var ownName: String
    var ownBack: Date?
    /// Until when the work is weighed, and the work each choice adds there
    /// in weighted tokens.
    var horizon: Date
    var servedWaiting: Double
    var servedMoving: Double?

    // MARK: - Deciding

    /// The plan for `session` over `accounts` (its own among them), with
    /// `base` the weighted tokens per hour of the sessions on each account
    /// and `lanes` the accounts that can take it now; nil when no account
    /// has room for it within `CapacityOutlook.defaultHorizon`, so it waits
    /// on its own account as before.
    static func decide(_ session: Session, accounts: [CapacityOutlook.Account], base: [UUID: Double], lanes: Set<UUID>,
                       now: Date, pacer: SessionPacer = SessionPacer()) -> HeldSessionPlan? {
        guard let wait = earliestLane(session, accounts: accounts, base: base, now: now, pacer: pacer),
              let lane = accounts.first(where: { $0.id == wait.lane }) else { return nil }
        let own = accounts.first { $0.id == session.account }
        let ownBack = own.flatMap { pacer.bindingReset($0.pacer, now: now) }
        let horizon = wait.at.addingTimeInterval(SessionPacer.newSessionRunway)
        func gain(on account: CapacityOutlook.Account, from start: Date) -> Double {
            // Its whole context written into a new account's cache, as
            // `SessionPacer.arrivalCost` charges it.
            let arrival = account.id == session.account ? 0
                : SessionSizing.arrivalTokens(session.contextTokens, cacheLifetime: session.cacheLifetime) * pacer.moveCostFactor
            let with = CapacityOutlook.servedAlone(account, base: base[account.id] ?? 0, extra: session.tokensPerHour,
                                                   extraFrom: start, arrival: arrival, now: now, until: horizon,
                                                   pacer: pacer).served
            let without = CapacityOutlook.servedAlone(account, base: base[account.id] ?? 0, now: now, until: horizon,
                                                      pacer: pacer).served
            return with - without
        }
        let waiting = gain(on: lane, from: wait.at)
        var plan = HeldSessionPlan(choice: .wait, lane: lane.id, laneName: lane.name, at: wait.at, refill: wait.refill,
                                   ownName: own?.name ?? "its account", ownBack: ownBack, horizon: horizon,
                                   servedWaiting: waiting)
        // A session whose own account resets within its cache's lifetime
        // keeps that cache by waiting.
        let cacheEnds = (session.lastSeen ?? now).addingTimeInterval(session.cacheLifetime ?? SessionPacer.defaultCacheLifetime)
        guard ownBack.map({ $0 > cacheEnds }) ?? true else { return plan }
        var best: (account: CapacityOutlook.Account, gain: Double)?
        for account in accounts where lanes.contains(account.id) && account.id != session.account {
            let moved = gain(on: account, from: now)
            if best.map({ moved > $0.gain }) ?? true { best = (account, moved) }
        }
        guard let best else { return plan }
        plan.servedMoving = best.gain
        // A tie, or a gain of under a minute of the session's work, waits.
        guard best.gain > waiting + session.tokensPerHour / 60 else { return plan }
        plan.choice = .move
        plan.lane = best.account.id
        plan.laneName = best.account.name
        plan.at = now
        return plan
    }

    /// The account whose room returns first with room for the session for
    /// an hour, and when: each account that takes part, at each of its
    /// resets in turn (its 5-hour window, its week, the reset that frees it
    /// at its limit) within `CapacityOutlook.defaultHorizon`, with the
    /// sessions on it running until then; the soonest wins, its own account
    /// on a tie.
    static func earliestLane(_ session: Session, accounts: [CapacityOutlook.Account], base: [UUID: Double], now: Date,
                             pacer: SessionPacer) -> (lane: UUID, at: Date, refill: CapacityOutlook.Event.Kind)? {
        var best: (lane: UUID, at: Date, refill: CapacityOutlook.Event.Kind, own: Bool)?
        let end = now.addingTimeInterval(CapacityOutlook.defaultHorizon)
        for account in accounts where account.availability == .serves || account.availability == .atLimit {
            let own = account.id == session.account
            let cost = own ? 0 : pacer.arrivalCost(session.contextTokens, cacheLifetime: session.cacheLifetime,
                                                   to: account.pacer)
            let need = cost + pacer.percent(session.tokensPerHour + (base[account.id] ?? 0), on: account.pacer)
                * SessionPacer.newSessionRunway / 3600
            for reset in CapacityOutlook.resets(account, now: now, until: end, pacer: pacer) {
                if let current = best, reset.at > current.at || (reset.at == current.at && (current.own || !own)) { break }
                let room = CapacityOutlook.servedAlone(account, base: base[account.id] ?? 0, now: now, until: reset.at,
                                                       pacer: pacer).room
                guard room * SessionPacer.windowFitShare >= need else { continue }
                best = (account.id, reset.at, reset.kind, own)
                break
            }
        }
        return best.map { ($0.lane, $0.at, $0.refill) }
    }

    /// What a wait planned on an earlier cycle does now.
    enum Due: Equatable {
        /// Its lane's reset has come and the lane serves: the session goes
        /// there.
        case place(UUID)
        /// The reset has come but no reading confirms it yet: the plan
        /// stands for `grace`.
        case stand
        /// Plan it again.
        case replan
    }

    /// `previous`, the plan of an earlier cycle, now: a wait whose reset has
    /// come is placed on its lane once that lane is among `destinations`
    /// (accounts a reading shows serving), stands for `grace` while it is
    /// not, and is planned again after that; any other plan is planned
    /// again. Read by `AppState.planHeldSessions`.
    static func due(_ previous: HeldSessionPlan?, destinations: Set<UUID>, now: Date, grace: TimeInterval) -> Due {
        guard let previous, previous.choice == .wait, previous.at <= now else { return .replan }
        if destinations.contains(previous.lane) { return .place(previous.lane) }
        return now.timeIntervalSince(previous.at) < grace ? .stand : .replan
    }

    // MARK: - Words

    /// The event: "platform-execution waits: no lane carries it for an hour;
    /// it resumes on fluxon at 12:50 am, when fluxon's window resets — 40 min
    /// before bytrix's." or "platform-execution moved to hexorda: it serves
    /// more there before 1:50 am than waiting would."
    func event(session: String, now: Date) -> String {
        switch choice {
        case .move:
            return "\(session) moved to \(laneName): no lane carries it for an hour, but it serves more there before "
                + "\(UsageFormat.clock(horizon, now: now)) than waiting would."
        case .wait:
            let what = refill == .newWeek ? "week" : "window"
            var text = "\(session) waits: no lane carries it for an hour; it resumes on \(laneName) at "
                + "\(UsageFormat.clock(at, now: now)), when \(laneName == ownName ? "its" : "\(laneName)'s") \(what) resets"
            if laneName != ownName, let ownBack, ownBack > at {
                text += " — \(UsageFormat.duration(ownBack.timeIntervalSince(at))) before \(ownName)'s"
            }
            return text + "."
        }
    }

    /// The Sessions page row's note while it waits: "resumes on fluxon about
    /// 12:50 am".
    func rowNote(now: Date) -> String {
        "resumes on \(laneName) about \(UsageFormat.clock(at, now: now))"
    }

    /// Whether `other` says the same: the same choice, lane and minute, so
    /// a plan weighed again each cycle records its event once.
    func same(as other: HeldSessionPlan?) -> Bool {
        guard let other else { return false }
        return choice == other.choice && lane == other.lane && abs(at.timeIntervalSince(other.at)) < 60
            || choice == .move && other.choice == .move && lane == other.lane
    }
}
