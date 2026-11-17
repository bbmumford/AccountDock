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
    ///
    /// The sets stay steady from one cycle to the next: the sessions
    /// `previous` planned to wait for a lane are planned first, lane by lane
    /// in the order those resets come, so each keeps its lane while it
    /// still fits there, and the rest follow, heaviest first. That plan is
    /// replaced by the one made heaviest first only when it puts at least
    /// `replanMargin` percent more of a lane's window to work
    /// (`prefersReplan`): rates that drift a little between cycles would
    /// otherwise swap sessions in and out of a lane's set every cycle. A
    /// planned session that has gone (ended, placed, or no longer held)
    /// leaves its room to the next sessions by rate. Ties keep the steady
    /// plan, and every order is by rate, then ID.
    static func planTogether(_ sessions: [Session], accounts: [CapacityOutlook.Account], base: [UUID: Double],
                             lanes: Set<UUID>, ledger: inout LaneLedger, now: Date,
                             pacer: SessionPacer = SessionPacer(),
                             previous: [String: HeldSessionPlan] = [:]) -> [String: HeldSessionPlan] {
        let byRate = sessions.sorted {
            $0.tokensPerHour != $1.tokensPerHour ? $0.tokensPerHour > $1.tokensPerHour : $0.id < $1.id
        }
        var freshLedger = ledger
        let fresh = plan(byRate, accounts: accounts, base: base, lanes: lanes, ledger: &freshLedger, now: now,
                         pacer: pacer)
        let kept = byRate.filter { previous[$0.id]?.choice == .wait }
        guard !kept.isEmpty else {
            ledger = freshLedger
            return fresh
        }
        let rank = Dictionary(byRate.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let steadyOrder = kept.sorted { lhs, rhs in
            guard let left = previous[lhs.id], let right = previous[rhs.id] else { return false }
            if left.at != right.at { return left.at < right.at }
            if left.lane != right.lane { return left.lane.uuidString < right.lane.uuidString }
            return (rank[lhs.id] ?? 0) < (rank[rhs.id] ?? 0)
        } + byRate.filter { previous[$0.id]?.choice != .wait }
        var steadyLedger = ledger
        let steady = plan(steadyOrder, accounts: accounts, base: base, lanes: lanes, ledger: &steadyLedger, now: now,
                          pacer: pacer)
        if prefersReplan(fresh, over: steady, sessions: sessions, accounts: accounts, pacer: pacer) {
            ledger = freshLedger
            return fresh
        }
        ledger = steadyLedger
        return steady
    }

    /// How much more of a lane's window, in percent of it, a plan made
    /// afresh must put to work before it replaces the steady one
    /// (`planTogether`).
    static let replanMargin = 10.0

    /// Whether `fresh` replaces `steady`: at the first lane window, by the
    /// reset its sessions wait for, whose planned set differs between the
    /// two, `fresh` puts at least `replanMargin` percent of that window
    /// more to work for the hour: an hour of each planned session's rate,
    /// less the cache its arrival rewrites (none on its own account), so a
    /// set that fits more work there, or the same work for less rewriting,
    /// counts as more. A lane's later windows are windows of their own.
    static func prefersReplan(_ fresh: [String: HeldSessionPlan], over steady: [String: HeldSessionPlan],
                              sessions: [Session], accounts: [CapacityOutlook.Account], pacer: SessionPacer) -> Bool {
        struct Window: Hashable {
            var lane: UUID
            var minute: Int
        }
        func groups(_ plans: [String: HeldSessionPlan]) -> [Window: Set<String>] {
            plans.reduce(into: [:]) { result, entry in
                let window = Window(lane: entry.value.lane, minute: summaryMinute(entry.value.at))
                result[window, default: []].insert(entry.key)
            }
        }
        let freshLanes = groups(fresh), steadyLanes = groups(steady)
        let order = Set(freshLanes.keys).union(steadyLanes.keys).sorted { lhs, rhs in
            lhs.minute != rhs.minute ? lhs.minute < rhs.minute : lhs.lane.uuidString < rhs.lane.uuidString
        }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func work(_ ids: Set<String>?, on lane: CapacityOutlook.Account) -> Double {
            (ids ?? []).reduce(0) { total, id in
                guard let session = byID[id] else { return total }
                let arrival = lane.id == session.account ? 0 : arrivalTokens(session, pacer: pacer)
                let tokens = session.tokensPerHour * SessionPacer.newSessionRunway / 3600 - arrival
                return total + tokens * lane.pacer.percentPerMillion / 1_000_000
            }
        }
        for window in order where freshLanes[window] != steadyLanes[window] {
            guard let lane = accounts.first(where: { $0.id == window.lane }) else { return false }
            return work(freshLanes[window], on: lane) - work(steadyLanes[window], on: lane) >= replanMargin
        }
        return false
    }

    /// The plans of `ordered`, each by `decide` against `ledger` in turn,
    /// which then charges its lane for it (`planTogether`).
    private static func plan(_ ordered: [Session], accounts: [CapacityOutlook.Account], base: [UUID: Double],
                             lanes: Set<UUID>, ledger: inout LaneLedger, now: Date,
                             pacer: SessionPacer) -> [String: HeldSessionPlan] {
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

    /// The time of a planned reset as the summary event's record of the plan
    /// keeps it (`AppState.noteHeldPlanSummary`): to the nearest five
    /// minutes, since readings report one reset seconds apart on either side
    /// of a minute (8:39:59 and 8:40:00) and the same plan would otherwise be
    /// recorded again each time.
    static func summaryMinute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 300).rounded()) * 5
    }
}
