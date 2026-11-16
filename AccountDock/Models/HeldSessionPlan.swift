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
    /// `base` the weighted tokens per hour of the sessions on each account,
    /// `ledger` what this cycle already sent or planned onto each (its
    /// charges count from when each starts, the session's own left out) and
    /// `lanes` the accounts that can take it now; nil when no account has
    /// room for it within `CapacityOutlook.defaultHorizon`, or none within a
    /// 5-hour window of the reset that frees its own account, so it waits
    /// on its own account as before.
    static func decide(_ session: Session, accounts: [CapacityOutlook.Account], base: [UUID: Double], lanes: Set<UUID>,
                       ledger: LaneLedger? = nil, now: Date, pacer: SessionPacer = SessionPacer()) -> HeldSessionPlan? {
        func loads(_ id: UUID) -> [CapacityOutlook.Load] { ledger?.loads(on: id, excluding: session.id) ?? [] }
        guard let wait = earliestLane(session, accounts: accounts, base: base, ledger: ledger, now: now, pacer: pacer),
              let lane = accounts.first(where: { $0.id == wait.lane }) else { return nil }
        let own = accounts.first { $0.id == session.account }
        let ownBack = own.flatMap { pacer.bindingReset($0.pacer, now: now) }
        // Its own account serves it again within a window of its reset, even
        // for less than the hour; a lane that frees up only after that is
        // no better plan.
        if wait.lane != session.account, let ownBack, wait.at > ownBack.addingTimeInterval(pacer.window) { return nil }
        let horizon = wait.at.addingTimeInterval(SessionPacer.newSessionRunway)
        func gain(on account: CapacityOutlook.Account, from start: Date) -> Double {
            // Its whole context written into a new account's cache, as
            // `SessionPacer.arrivalCost` charges it.
            let arrival = account.id == session.account ? 0
                : SessionSizing.arrivalTokens(session.contextTokens, cacheLifetime: session.cacheLifetime) * pacer.moveCostFactor
            let with = CapacityOutlook.servedAlone(account, base: base[account.id] ?? 0, loads: loads(account.id),
                                                   extra: session.tokensPerHour, extraFrom: start, arrival: arrival,
                                                   now: now, until: horizon, pacer: pacer).served
            let without = CapacityOutlook.servedAlone(account, base: base[account.id] ?? 0, loads: loads(account.id),
                                                      now: now, until: horizon, pacer: pacer).served
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
    /// sessions on it running until then and everything `ledger` charges
    /// it, each from when it starts there; the soonest wins, its own account
    /// on a tie. Room for an hour is `CapacityOutlook.carries`: the
    /// session's arrival (none on its own account) and an hour of its rate
    /// beside all of that, within `SessionPacer.windowFitShare` of the room
    /// the reset leaves, so a lane is planned only as full as its fresh
    /// window holds.
    static func earliestLane(_ session: Session, accounts: [CapacityOutlook.Account], base: [UUID: Double],
                             ledger: LaneLedger? = nil, now: Date,
                             pacer: SessionPacer) -> (lane: UUID, at: Date, refill: CapacityOutlook.Event.Kind)? {
        var best: (lane: UUID, at: Date, refill: CapacityOutlook.Event.Kind, own: Bool)?
        let end = now.addingTimeInterval(CapacityOutlook.defaultHorizon)
        for account in accounts where account.availability == .serves || account.availability == .atLimit {
            let own = account.id == session.account
            let arrival = own ? 0 : arrivalTokens(session, pacer: pacer)
            let loads = ledger?.loads(on: account.id, excluding: session.id) ?? []
            for reset in CapacityOutlook.resets(account, now: now, until: end, pacer: pacer) {
                if let current = best, reset.at > current.at || (reset.at == current.at && (current.own || !own)) { break }
                let adding = CapacityOutlook.Load(from: reset.at, tokensPerHour: session.tokensPerHour, arrivalTokens: arrival)
                guard CapacityOutlook.carries(account, base: base[account.id] ?? 0, loads: loads, adding: adding,
                                              until: reset.at.addingTimeInterval(SessionPacer.newSessionRunway),
                                              now: now, pacer: pacer) else { continue }
                best = (account.id, reset.at, reset.kind, own)
                break
            }
        }
        return best.map { ($0.lane, $0.at, $0.refill) }
    }

    /// Weighted tokens the session's arrival writes into another account's
    /// cache: its whole context (`SessionSizing.arrivalTokens`) times the
    /// provider's `moveCostFactor`, as `SessionPacer.arrivalCost` charges it.
    static func arrivalTokens(_ session: Session, pacer: SessionPacer) -> Double {
        SessionSizing.arrivalTokens(session.contextTokens, cacheLifetime: session.cacheLifetime) * pacer.moveCostFactor
    }

    /// The plans of `sessions`, made together: the heaviest first, each by
    /// `decide` against `ledger`, which then charges its lane for it (a
    /// wait from the lane's reset, a move from now with its arrival); a
    /// session no lane carries is charged to its own account from the reset
    /// that frees it. So a lane's fresh window is planned for only the
    /// sessions it holds for the hour, the next go to the next lane by its
    /// reset, and the rest wait for their own accounts. Read by
    /// `AppState.planHeldSessions`.
    static func planTogether(_ sessions: [Session], accounts: [CapacityOutlook.Account], base: [UUID: Double],
                             lanes: Set<UUID>, ledger: inout LaneLedger, now: Date,
                             pacer: SessionPacer = SessionPacer()) -> [String: HeldSessionPlan] {
        let ordered = sessions.sorted {
            $0.tokensPerHour != $1.tokensPerHour ? $0.tokensPerHour > $1.tokensPerHour : $0.id < $1.id
        }
        var plans: [String: HeldSessionPlan] = [:]
        for session in ordered {
            guard let plan = decide(session, accounts: accounts, base: base, lanes: lanes, ledger: ledger, now: now,
                                    pacer: pacer) else {
                let own = accounts.first { $0.id == session.account }
                let back = own.flatMap { pacer.bindingReset($0.pacer, now: now) } ?? now
                ledger.charge(LaneLedger.Charge(session: session.id, lane: session.account,
                                                tokensPerHour: session.tokensPerHour, from: max(back, now), kind: .held))
                continue
            }
            plans[session.id] = plan
            let arrival = plan.lane == session.account ? 0 : arrivalTokens(session, pacer: pacer)
            ledger.charge(LaneLedger.Charge(session: session.id, lane: plan.lane, tokensPerHour: session.tokensPerHour,
                                            arrivalTokens: arrival, from: plan.choice == .move ? now : plan.at,
                                            kind: plan.choice == .move ? .placed : .planned))
        }
        return plans
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

    /// One event for the waits planned together (`planTogether`), each
    /// lane's sessions by the reset that frees it, the earliest in full:
    /// "At 12:50 am fluxon's fresh window takes platform-execution and
    /// continues-field (≈ 60 min of its window); 5 others wait for hexorda
    /// at 1:10 am, bytrix and cybrio at 1:30 am." `lasting` is how long each
    /// lane's fresh window lasts the sessions planned onto it
    /// (`CapacityOutlook.lasting`); waits on a session's own account and
    /// the `unplanned` sessions no lane carries wait for their own accounts.
    /// Nil with nothing waiting. Recorded by `AppState.planHeldSessions`
    /// when it changes.
    static func summary(_ waits: [(name: String, plan: HeldSessionPlan)], lasting: [UUID: TimeInterval],
                        unplanned: Int, now: Date) -> String? {
        struct Group {
            var lane: UUID
            var name: String
            var at: Date
            var refill: CapacityOutlook.Event.Kind
            var sessions: [String]
        }
        var groups: [Group] = []
        var own = unplanned
        for (name, plan) in waits {
            guard plan.laneName != plan.ownName else {
                own += 1
                continue
            }
            if let index = groups.firstIndex(where: { $0.lane == plan.lane && abs($0.at.timeIntervalSince(plan.at)) < 60 }) {
                groups[index].sessions.append(name)
            } else {
                groups.append(Group(lane: plan.lane, name: plan.laneName, at: plan.at, refill: plan.refill, sessions: [name]))
            }
        }
        groups.sort { $0.at != $1.at ? $0.at < $1.at : $0.name < $1.name }
        func list(_ items: [String]) -> String {
            items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
        guard let first = groups.first else {
            return own > 0 ? "\(own) held session(s) wait for their own accounts: no other lane carries them for an hour." : nil
        }
        let window = first.refill == .newWeek ? "new week" : "fresh window"
        var text = "At \(UsageFormat.clock(first.at, now: now)) \(first.name)'s \(window) takes \(list(first.sessions.sorted()))"
        if let lasts = lasting[first.lane] {
            text += " (≈ \(Int((lasts / 300).rounded()) * 5) min of its window)"
        }
        let rest = Array(groups.dropFirst())
        let others = rest.reduce(0) { $0 + $1.sessions.count }
        if others > 0 {
            var byTime: [(at: Date, names: [String])] = []
            for group in rest {
                if let index = byTime.firstIndex(where: { abs($0.at.timeIntervalSince(group.at)) < 60 }) {
                    byTime[index].names.append(group.name)
                } else {
                    byTime.append((group.at, [group.name]))
                }
            }
            let lanes = byTime.map { "\(list($0.names.sorted())) at \(UsageFormat.clock($0.at, now: now))" }
            text += "; \(others) other\(others == 1 ? "" : "s") wait\(others == 1 ? "s" : "") for \(lanes.joined(separator: ", "))"
        }
        if own > 0 {
            text += "; \(own) wait\(own == 1 ? "s" : "") for \(own == 1 ? "its own account" : "their own accounts")"
        }
        return text + "."
    }

    /// Whether `other` says the same: the same choice, lane and minute, so
    /// a plan weighed again each cycle records its event once.
    func same(as other: HeldSessionPlan?) -> Bool {
        guard let other else { return false }
        return choice == other.choice && lane == other.lane && abs(at.timeIntervalSince(other.at)) < 60
            || choice == .move && other.choice == .move && lane == other.lane
    }
}
