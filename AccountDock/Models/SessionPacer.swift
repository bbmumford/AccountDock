import Foundation

/// Each routed session's recent token use, for `SessionPacer`. Tokens are
/// weighted as `TurnCostModel` weighs them and decay with a 20-minute time
/// constant, so a session's rate follows its current pace and fades while it
/// is idle. Saved with the learned models (`AppState.saveLearningIfDue`),
/// so a pause that spans an app restart keeps its sessions' forecasts.
struct SessionRates: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var account: UUID
        var decayedTokens: Double
        var lastSeen: Date
        var firstSeen: Date
        var contextTokens: Int
        var cacheLifetime: TimeInterval?
        /// The session's requests within the last `demandWindow`.
        var requests: [Request] = []
        /// When its current turn began, when known.
        var lastTurnStart: Date?
    }

    struct Request: Codable, Equatable {
        var at: Date
        var tokens: Double
    }

    static let timeConstant: TimeInterval = 20 * 60
    /// How long a quiet session's history is kept. A paused session sends
    /// nothing for as long as the pause lasts, which can be days when every
    /// weekly allowance is out, and its forecast needs that history.
    static let retention: TimeInterval = 8 * 24 * 60 * 60
    /// The span a session's demand is averaged over.
    static let demandWindow: TimeInterval = 60 * 60
    /// A session seen for less time than this has its demand averaged over
    /// this long, so its first few requests do not read as a sustained rate.
    static let minimumDemandSpan: TimeInterval = 15 * 60
    var entries: [String: Entry] = [:]
    /// Weighted tokens per hour that sessions took with them when they left
    /// each account, decaying with `timeConstant` from when they left.
    /// An account's rate learned from its readings follows a move only over
    /// several readings; until it does, this much of it is gone.
    private(set) var departures: [UUID: Departure] = [:]

    struct Departure: Codable, Equatable {
        var tokensPerHour: Double
        var at: Date
    }

    mutating func record(session: String?, account: UUID, context: Int, cacheWrite: Int, output: Int,
                         cacheWriteLong: Int = 0, cacheLifetime: TimeInterval?, startsTurn: Bool? = nil, at date: Date) {
        guard let session else { return }
        if let previous = entries[session], previous.account != account {
            let gone = departed(previous.account, now: date) + tokensPerHour(session, now: date)
            departures[previous.account] = Departure(tokensPerHour: gone, at: date)
        }
        let weight = TurnCostModel.weighted(context: context, cacheWrite: cacheWrite, output: output, cacheWriteLong: cacheWriteLong)
        let existing = entries[session]
        let previous = existing.map { $0.decayedTokens * Self.decay(since: $0.lastSeen, now: date) } ?? 0
        let requests = (existing?.requests ?? []).filter { $0.at > date.addingTimeInterval(-Self.demandWindow) }
            + [Request(at: date, tokens: weight)]
        entries[session] = Entry(account: account, decayedTokens: previous + weight, lastSeen: date,
                                 firstSeen: existing?.firstSeen ?? date, contextTokens: context,
                                 cacheLifetime: cacheLifetime ?? existing?.cacheLifetime, requests: requests,
                                 lastTurnStart: startsTurn == true ? date : existing?.lastTurnStart)
        let cutoff = date.addingTimeInterval(-Self.retention)
        entries = entries.filter { $0.value.lastSeen > cutoff }
    }

    static func decay(since date: Date, now: Date) -> Double {
        exp(-max(0, now.timeIntervalSince(date)) / timeConstant)
    }

    /// Weighted tokens per hour that left `account` with its sessions, as
    /// much of it as its readings may not show yet.
    func departed(_ account: UUID, now: Date) -> Double {
        guard let departure = departures[account] else { return 0 }
        return departure.tokensPerHour * Self.decay(since: departure.at, now: now)
    }

    /// Weighted tokens per hour the session used on average over the hour
    /// before `end`, idle time included: a session that waits on its user
    /// between turns uses little, one working on its own uses steadily.
    /// For a paused session `end` is when the pause began, so the time it
    /// was held does not count. Nil for a session never seen.
    func demand(_ session: String, until end: Date) -> Double? {
        guard let entry = entries[session] else { return nil }
        let span = min(Self.demandWindow, max(Self.minimumDemandSpan, end.timeIntervalSince(entry.firstSeen)))
        let start = end.addingTimeInterval(-span)
        let tokens = entry.requests.filter { $0.at > start && $0.at <= end }.reduce(0) { $0 + $1.tokens }
        return tokens / (span / 3600)
    }

    /// The demand of a session held by a pause that began at `pausedAt`,
    /// measured up to when the session was held: the pause's start, or its
    /// last request when it was resumed during the pause and held again,
    /// since only the hour before its latest request is kept.
    func heldDemand(_ session: String, pausedAt: Date) -> Double? {
        guard let entry = entries[session] else { return nil }
        let heldAt = max(pausedAt, entry.requests.last?.at ?? pausedAt)
        return demand(session, until: heldAt)
    }

    /// Restarts a resumed session's rate at its forecast demand, so it counts
    /// against the account it continues on before its first request there.
    mutating func resume(_ session: String, tokensPerHour: Double, at date: Date) {
        guard var entry = entries[session] else { return }
        entry.decayedTokens = tokensPerHour * Self.timeConstant / 3600
        entry.lastSeen = date
        entries[session] = entry
    }

    /// Weighted tokens per hour the session is using now.
    func tokensPerHour(_ session: String, now: Date) -> Double {
        guard let entry = entries[session] else { return 0 }
        return entry.decayedTokens * Self.decay(since: entry.lastSeen, now: now) / (Self.timeConstant / 3600)
    }
}

/// Paces the sessions the router serves from several accounts to each
/// account's 5-hour window. An account whose sessions together would reach
/// its limit before the window resets, and stay there longer than their
/// prompt cache lasts, gives sessions up to accounts that can carry them
/// within their own windows, at those sessions' next turns. One that would
/// reach its limit only shortly before the reset keeps its sessions and
/// their cache; the router holds one refused there when the reset is close
/// (`RouterLogic.holdUntil`). New sessions go to the accounts with the most
/// unused rate. Consumed by `AppState.buildPool`.
///
/// An allowance only one model's sessions draw on (`Account.scoped`) is
/// paced the same way for those sessions alone: an account whose sessions
/// on that model would run its allowance out gives up sessions on that
/// model, a session only moves to an account with room for its model, and
/// `Plan.modelWeights` says where a new session on the model starts.
struct SessionPacer {
    /// What is left of an allowance only one model's sessions draw on, in
    /// 5-hour window percent like `Account.weeklyRemaining`.
    struct ScopedAllowance: Equatable {
        var remaining: Double
        var resetsAt: Date
    }

    struct Account: Equatable {
        let id: UUID
        /// 5-hour window percent used now; 0 when no window is running.
        var utilization: Double
        /// Nil when no window is running; the next request starts one.
        var resetsAt: Date?
        /// Window percent per hour the account consumes, observed from its
        /// readings, including use the router does not see, less what
        /// sessions that just left it took (`SessionRates.departed`).
        var burnPerHour: Double
        /// The account's share of new sessions before pacing; 0 takes none.
        var baseWeight: Double
        /// What is left of the weekly allowance, in 5-hour window percent;
        /// nil when the account reports no weekly window.
        var weeklyRemaining: Double? = nil
        var weeklyResetsAt: Date? = nil
        /// Window percent per million weighted tokens on this account
        /// (`TurnCostModel.ratio(for:)`).
        var percentPerMillion = TurnCostModel.defaultPercentPerMillion
        /// False when only the weekly allowance limits the account; its
        /// rates are still in 5-hour window percent, the unit of
        /// `weeklyRemaining`.
        var hasSessionWindow = true
        /// Allowances only one model's sessions draw on, by the lowercased
        /// name a session's model must contain (`scopedKeys`).
        var scoped: [String: ScopedAllowance] = [:]
    }

    struct Session: Equatable {
        let id: String
        var account: UUID
        /// Weighted tokens per hour (`SessionRates.tokensPerHour`).
        var tokensPerHour: Double
        var contextTokens: Int
        var lastSeen: Date
        var cacheLifetime: TimeInterval?
        /// When the session's current turn began (`SessionRates.Entry`).
        var lastTurnStart: Date? = nil
        /// The model the session uses; nil when it has not said.
        var model: String? = nil
        /// Weighted tokens per hour over its last hour, idle time included
        /// (`SessionRates.demand`); unlike `tokensPerHour`, it does not fade
        /// to nothing while the session waits between turns.
        var recentTokensPerHour: Double? = nil
    }

    /// The sessions on the CLI's shared sign-in, which no slot of their own
    /// isolates: they all run on the active account and move together
    /// whenever it changes, so neither `plan` nor `rebalance` moves them,
    /// and each counts their load on the account carrying them, from when
    /// to when (`shares`).
    struct SharedGroup: Equatable {
        /// The active account, which carries the group now.
        var account: UUID
        /// Weighted tokens per hour the group is expected to keep using.
        var tokensPerHour: Double
        /// The group's context, which a switch writes into the next
        /// account's cache.
        var contextTokens: Int
        /// The model of each of its sessions that has said one; a model's
        /// own allowance carries the share of the group's rate its sessions
        /// make up.
        var models: [String]
        /// The account the active account would switch to next
        /// (`FailoverPlanner.nextSwitch`), and when; nil while it would keep
        /// the active account for the whole horizon, as with failover off
        /// or the active account locked.
        var nextAccount: UUID? = nil
        var switchAt: Date? = nil
        /// How many sessions the group holds, for the events.
        var sessionCount = 0
    }

    /// The part of the shared group's load one account carries: its rate,
    /// in that account's window percent, from `from` until `until` (nil
    /// for as long as any of its windows runs), and `arrival`, the cache
    /// rewrite it costs once at `from`.
    struct SharedShare: Equatable {
        var percentPerHour: Double
        var from: Date
        var until: Date?
        var arrival: Double = 0
        /// The fraction of the rate each of the account's model allowances
        /// carries, by its key.
        var scopedFractions: [String: Double] = [:]

        /// Window percent the share spends between `now` and `end`.
        func percent(from now: Date, until end: Date, fraction: Double = 1) -> Double {
            let start = max(now, from)
            let stop = min(end, until ?? end)
            let running = stop > start ? stop.timeIntervalSince(start) / 3600 * percentPerHour * fraction : 0
            let arrives = from > now && from < end ? arrival * fraction : 0
            return running + arrives
        }
    }

    /// How an account's windows go at its sessions' current rate.
    struct Outlook: Equatable {
        /// Window percent per hour that uses the rest of each window exactly
        /// by its reset; the smaller of the 5-hour and weekly rates.
        var allowedPerHour: Double
        var burnPerHour: Double
        /// When the account reaches the first of its limits; nil when it
        /// reaches none before that window resets.
        var limitAt: Date?
        /// When the window whose limit comes first resets; the 5-hour
        /// window's reset when neither is reached.
        var windowEndsAt: Date
        /// How long it would stay at its limit before the window resets.
        var waitAtLimit: TimeInterval { limitAt.map { windowEndsAt.timeIntervalSince($0) } ?? 0 }
    }

    struct Plan: Equatable {
        /// Pool weight for new sessions, by account.
        var weights: [UUID: Double] = [:]
        /// Sessions to move at their next turn: the account each moves to.
        var moves: [String: UUID] = [:]
        /// Accounts giving sessions up, with how they would have gone.
        var shedding: [UUID: Outlook] = [:]
        /// Pool weight for a new session on a model with an allowance of
        /// its own, by that allowance's key and then by account. All zero
        /// when no account has any of the allowance left.
        var modelWeights: [String: [UUID: Double]] = [:]
        /// Accounts giving up sessions on one model, by that model's
        /// allowance, with how the allowance would have gone.
        var scopedShedding: [UUID: [String: Outlook]] = [:]
    }

    /// The window percent treated as the limit, which leaves the in-flight
    /// turns room.
    var limit = 100 - FailoverPlanner.minimumUsableHeadroom
    var window = FailoverPlanner.sessionWindow
    /// Assumed when no session on an account said how long its cache lasts.
    static let defaultCacheLifetime: TimeInterval = 60 * 60
    /// Sessions idle longer than this carry no rate worth moving.
    static let activeWithin: TimeInterval = 30 * 60
    /// A turn running longer than this is an autonomous run whose end, and
    /// so its move, is not near.
    static let longTurn: TimeInterval = 15 * 60
    /// A session quiet this long is between turns.
    static let betweenTurns: TimeInterval = 2 * 60

    /// Whether the session's move takes effect soon: a move applies when
    /// its next turn starts, which a long autonomous turn puts off.
    func movable(_ session: Session, now: Date) -> Bool {
        guard let start = session.lastTurnStart else { return true }
        return now.timeIntervalSince(start) <= Self.longTurn || now.timeIntervalSince(session.lastSeen) > Self.betweenTurns
    }

    /// The account's outlook at `burn` percent per hour, after `spent`
    /// percent more than its readings show. The weekly allowance binds when
    /// it runs out before the 5-hour window's does.
    func outlook(_ account: Account, spent: Double = 0, burn: Double, now: Date, shared: SharedShare? = nil) -> Outlook {
        func projected(_ remaining: Double, until end: Date) -> Outlook {
            self.projected(remaining, burn: burn, until: end, now: now, shared: shared)
        }
        if !account.hasSessionWindow, let weeklyLeft = account.weeklyRemaining,
           let weeklyEnd = account.weeklyResetsAt, weeklyEnd > now {
            return projected(weeklyLeft - spent, until: weeklyEnd)
        }
        let session = projected(remaining(account, now: now) - spent,
                             until: account.resetsAt.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(window))
        guard let weeklyLeft = account.weeklyRemaining, let weeklyEnd = account.weeklyResetsAt, weeklyEnd > now else { return session }
        let weekly = projected(weeklyLeft - spent, until: weeklyEnd)
        let first = [session, weekly].compactMap { outlook in outlook.limitAt.map { ($0, outlook) } }.min { $0.0 < $1.0 }?.1
        return Outlook(allowedPerHour: min(session.allowedPerHour, weekly.allowedPerHour), burnPerHour: burn,
                       limitAt: first?.limitAt, windowEndsAt: first?.windowEndsAt ?? session.windowEndsAt)
    }

    /// How `remaining` percent goes at `burn` percent per hour until `end`,
    /// with `shared`, the shared group's share, spent beside it over its own
    /// span. The rate allowed is what the rest of the window leaves once
    /// the share is set aside, and `burnPerHour` stays the account's own.
    func projected(_ remaining: Double, burn: Double, until end: Date, now: Date,
                   shared: SharedShare? = nil, fraction: Double = 1) -> Outlook {
        let hours = max(end.timeIntervalSince(now), 60) / 3600
        let held = shared?.percent(from: now, until: end, fraction: fraction) ?? 0
        let limitAt = shared.map { Self.limitTime(remaining, burn: burn, shared: $0, fraction: fraction, now: now) }
            ?? (burn > 0 ? now.addingTimeInterval(max(0, remaining) / burn * 3600) : nil)
        return Outlook(allowedPerHour: max(0, remaining - held) / hours, burnPerHour: burn,
                       limitAt: limitAt.flatMap { $0 < end ? $0 : nil }, windowEndsAt: end)
    }

    /// When `remaining` percent is spent at `burn` percent per hour plus
    /// the share's rate over its span and its arrival cost at its start;
    /// nil when it never is.
    static func limitTime(_ remaining: Double, burn: Double, shared: SharedShare, fraction: Double, now: Date) -> Date? {
        var left = max(0, remaining)
        let from = max(now, shared.from)
        let until = shared.until.map { max(from, $0) }
        // Before the share starts, during it, and after it.
        var segments: [(start: Date, end: Date?, rate: Double, lump: Double)] = []
        if from > now { segments.append((now, from, burn, 0)) }
        if let until {
            if until > from { segments.append((from, until, burn + shared.percentPerHour * fraction, shared.from > now ? shared.arrival * fraction : 0)) }
            segments.append((until, nil, burn, 0))
        } else {
            segments.append((from, nil, burn + shared.percentPerHour * fraction, shared.from > now ? shared.arrival * fraction : 0))
        }
        for segment in segments {
            if segment.lump > 0 {
                if segment.lump >= left { return segment.start }
                left -= segment.lump
            }
            let length = segment.end.map { $0.timeIntervalSince(segment.start) / 3600 }
            if segment.rate > 0 {
                let needed = left / segment.rate
                if length.map({ needed <= $0 }) ?? true { return segment.start.addingTimeInterval(needed * 3600) }
            }
            guard let length else { return nil }
            left -= segment.rate * length
        }
        return nil
    }

    /// The shared group's share of each account that carries it: the
    /// active account until the projected switch, the next one after it,
    /// or the active account throughout when no switch is projected. Each
    /// share's rate is in its account's window percent, and its model
    /// allowances carry the part of it their models make up.
    func shares(_ group: SharedGroup?, accounts: [Account], now: Date) -> [UUID: SharedShare] {
        guard let group, group.tokensPerHour > 0 || group.contextTokens > 0 else { return [:] }
        func share(on id: UUID, from: Date, until: Date?, arrival: Bool) -> SharedShare? {
            guard let account = accounts.first(where: { $0.id == id }) else { return nil }
            var fractions: [String: Double] = [:]
            let models = group.models.map { $0.lowercased() }
            if !models.isEmpty {
                for key in account.scoped.keys {
                    let using = models.filter { $0.contains(key) }.count
                    if using > 0 { fractions[key] = Double(using) / Double(models.count) }
                }
            }
            return SharedShare(percentPerHour: percent(group.tokensPerHour, on: account), from: from, until: until,
                               arrival: arrival ? moveCost(group.contextTokens, to: account) : 0,
                               scopedFractions: fractions)
        }
        var result: [UUID: SharedShare] = [:]
        if let next = group.nextAccount, next != group.account, let at = group.switchAt {
            result[group.account] = share(on: group.account, from: .distantPast, until: max(now, at), arrival: false)
            result[next] = share(on: next, from: max(now, at), until: nil, arrival: true)
        } else {
            result[group.account] = share(on: group.account, from: .distantPast, until: nil, arrival: false)
        }
        return result
    }

    /// The allowances of `account` that only `session`'s model draws on.
    func scopedKeys(_ session: Session, on account: Account) -> [String] {
        guard let model = session.model?.lowercased(), !account.scoped.isEmpty else { return [] }
        return account.scoped.keys.filter { model.contains($0) }.sorted()
    }

    func remaining(_ account: Account, now: Date) -> Double {
        let running = account.resetsAt.map { $0 > now } ?? false
        return limit - (running ? account.utilization : 0)
    }

    /// Window percent per hour `tokensPerHour` costs on the account.
    func percent(_ tokensPerHour: Double, on account: Account) -> Double {
        tokensPerHour / 1_000_000 * account.percentPerMillion
    }

    /// Window percent a session spends writing `contextTokens` into the
    /// cache of the account it moves to.
    func moveCost(_ contextTokens: Int, to account: Account) -> Double {
        Double(contextTokens) * (1.25 - 0.1) / 1_000_000 * account.percentPerMillion
    }

    /// Weighted tokens per hour freed per cache token rewritten, which orders
    /// the sessions an account gives up.
    private func relief(_ session: Session) -> Double {
        session.tokensPerHour / Double(max(session.contextTokens, 10_000))
    }

    /// `sharedGroup` is the load of the sessions on the shared sign-in,
    /// which are not among `sessions`: the account carrying it, now or from
    /// the projected switch, counts it (`shares`), so it gives up slot
    /// sessions, takes none, and takes fewer new sessions, as that load
    /// requires; the group itself never moves. `fixed` sessions, pinned to
    /// their account, never move either and count as load on it.
    func plan(accounts: [Account], sessions: [Session], now: Date, sharedGroup: SharedGroup? = nil,
              fixed: Set<String> = []) -> Plan {
        let ids = Set(accounts.map(\.id))
        let active = sessions.filter { ids.contains($0.account) && now.timeIntervalSince($0.lastSeen) <= Self.activeWithin }
        let shares = shares(sharedGroup, accounts: accounts, now: now)
        var spent: [UUID: Double] = [:]
        var burn: [UUID: Double] = [:]
        // The same two for each allowance only one model's sessions draw on.
        var scopedSpent: [UUID: [String: Double]] = [:]
        var scopedBurn: [UUID: [String: Double]] = [:]
        for account in accounts {
            let own = active.filter { $0.account == account.id }
            let sessionsBurn = own.reduce(0) { $0 + percent($1.tokensPerHour, on: account) }
            // The readings of the account carrying the shared group now
            // include the group's rate, which its share counts instead.
            let carried = sharedGroup?.account == account.id ? shares[account.id]?.percentPerHour ?? 0 : 0
            burn[account.id] = max(account.burnPerHour - carried, sessionsBurn)
            for session in own {
                for key in scopedKeys(session, on: account) {
                    scopedBurn[account.id, default: [:]][key, default: 0] += percent(session.tokensPerHour, on: account)
                }
            }
        }
        func cacheLifetime(_ id: UUID) -> TimeInterval {
            active.filter { $0.account == id }.compactMap(\.cacheLifetime).max() ?? Self.defaultCacheLifetime
        }
        func current(_ account: Account) -> Outlook {
            outlook(account, spent: spent[account.id] ?? 0, burn: burn[account.id] ?? 0, now: now, shared: shares[account.id])
        }
        // Nil once the allowance's reset has passed: it no longer limits
        // anything, and the account's next reading carries the new one.
        func currentScoped(_ account: Account, _ key: String, spending: Double = 0, burning: Double = 0) -> Outlook? {
            guard let allowance = account.scoped[key], allowance.resetsAt > now else { return nil }
            let share = shares[account.id]
            let fraction = share?.scopedFractions[key] ?? 0
            return projected(allowance.remaining - (scopedSpent[account.id]?[key] ?? 0) - spending,
                             burn: (scopedBurn[account.id]?[key] ?? 0) + burning, until: allowance.resetsAt, now: now,
                             shared: fraction > 0 ? share : nil, fraction: fraction)
        }
        func waitsTooLong(_ outlook: Outlook, on account: Account) -> Bool {
            outlook.limitAt != nil && outlook.waitAtLimit > cacheLifetime(account.id)
        }
        func sheds(_ account: Account) -> Bool {
            waitsTooLong(current(account), on: account)
        }
        func shedsScoped(_ account: Account, _ key: String) -> Bool {
            currentScoped(account, key).map { waitsTooLong($0, on: account) } ?? false
        }
        var plan = Plan()
        for account in accounts {
            if sheds(account) { plan.shedding[account.id] = current(account) }
            for key in account.scoped.keys.sorted() where shedsScoped(account, key) {
                plan.scopedShedding[account.id, default: [:]][key] = currentScoped(account, key)
            }
        }
        // The allowance that reaches its limit soonest gives sessions up
        // first, an account's whole allowance and each model's own alike:
        // those relieving the most rate per cache rewrite first, until it no
        // longer would wait at its limit longer than its sessions' cache.
        // Sessions whose next turn comes soon go before those deep in a long
        // turn, whose relief would arrive only when that turn ends. A
        // model's allowance gives up only sessions on that model.
        var sources: [(account: Account, key: String?, limitAt: Date)] = []
        for account in accounts {
            if let outlook = plan.shedding[account.id] { sources.append((account, nil, outlook.limitAt ?? .distantFuture)) }
            for key in (plan.scopedShedding[account.id] ?? [:]).keys.sorted() {
                sources.append((account, key, plan.scopedShedding[account.id]?[key]?.limitAt ?? .distantFuture))
            }
        }
        for source in sources.sorted(by: { $0.limitAt < $1.limitAt }) {
            let candidates = active.filter { session in
                session.account == source.account.id && plan.moves[session.id] == nil && !fixed.contains(session.id)
                    && (source.key.map { scopedKeys(session, on: source.account).contains($0) } ?? true)
            }.sorted {
                let (first, second) = (movable($0, now: now), movable($1, now: now))
                return first == second ? relief($0) > relief($1) : first
            }
            for session in candidates where session.tokensPerHour > 0 {
                guard source.key.map({ shedsScoped(source.account, $0) }) ?? sheds(source.account) else { break }
                var best: (id: UUID, spare: Double)?
                for destination in accounts where destination.id != source.account.id
                    && plan.shedding[destination.id] == nil && destination.baseWeight > 0 {
                    let keys = scopedKeys(session, on: destination)
                    guard !keys.contains(where: { plan.scopedShedding[destination.id]?[$0] != nil }) else { continue }
                    let cost = moveCost(session.contextTokens, to: destination)
                    let rate = percent(session.tokensPerHour, on: destination)
                    let after = outlook(destination, spent: (spent[destination.id] ?? 0) + cost,
                                        burn: (burn[destination.id] ?? 0) + rate, now: now, shared: shares[destination.id])
                    guard after.limitAt == nil else { continue }
                    // The destination must carry the session within its
                    // model's own allowance too.
                    let scoped = keys.compactMap { currentScoped(destination, $0, spending: cost, burning: rate) }
                    guard !scoped.contains(where: { $0.limitAt != nil }) else { continue }
                    let spare = ([after] + scoped).map { $0.allowedPerHour - $0.burnPerHour }.min() ?? 0
                    if best.map({ spare > $0.spare }) ?? true { best = (destination.id, spare) }
                }
                guard let best, let target = accounts.first(where: { $0.id == best.id }) else { continue }
                plan.moves[session.id] = best.id
                let leaving = percent(session.tokensPerHour, on: source.account)
                burn[source.account.id, default: 0] -= leaving
                for key in scopedKeys(session, on: source.account) {
                    scopedBurn[source.account.id, default: [:]][key, default: 0] -= leaving
                }
                let arriving = percent(session.tokensPerHour, on: target)
                let cost = moveCost(session.contextTokens, to: target)
                burn[best.id, default: 0] += arriving
                spent[best.id, default: 0] += cost
                for key in scopedKeys(session, on: target) {
                    scopedBurn[best.id, default: [:]][key, default: 0] += arriving
                    scopedSpent[best.id, default: [:]][key, default: 0] += cost
                }
            }
        }
        // A session started now is expected to use `typicalNewSessionRate`.
        // An account that could not carry one more such session for
        // `newSessionRunway` takes none while another account can: the
        // session would be refused there, or moved and made to write its
        // cache again, within the hour. `key` adds the allowance of the
        // model the session uses.
        let typical = Self.typicalNewSessionRate(active)
        // How long the account carries one more such session before it
        // reaches a limit; nil when it reaches none before its resets.
        func runway(_ account: Account, _ key: String?) -> TimeInterval? {
            let rate = percent(typical, on: account)
            let whole = outlook(account, spent: spent[account.id] ?? 0, burn: (burn[account.id] ?? 0) + rate, now: now,
                                shared: shares[account.id])
            let scoped = key.flatMap { currentScoped(account, $0, burning: rate) }
            return ([whole] + [scoped].compactMap { $0 }).compactMap { $0.limitAt?.timeIntervalSince(now) }.min()
        }
        // `weight` for the accounts that carry another session. When none
        // of those it gives a weight to does, the session goes where it
        // lasts longest, among every account that takes new sessions: one
        // lasting under half as long as the best takes none. All zero only
        // when `weight` is, which the caller answers with another rule.
        func weighted(_ key: String? = nil, _ weight: (Account) -> Double) -> [UUID: Double] {
            let all = accounts.reduce(into: [UUID: Double]()) { $0[$1.id] = weight($1) }
            guard all.values.contains(where: { $0 > 0 }) else { return all }
            let runways = accounts.reduce(into: [UUID: TimeInterval]()) {
                $0[$1.id] = min(runway($1, key) ?? Self.newSessionRunway, Self.newSessionRunway)
            }
            let carrying = all.filter { $0.value > 0 && (runways[$0.key] ?? 0) >= Self.newSessionRunway }
            if !carrying.isEmpty { return all.mapValues { _ in 0 }.merging(carrying) { $1 } }
            let taking = accounts.filter { $0.baseWeight > 0 }
            let among = taking.isEmpty ? accounts : taking
            let best = among.compactMap { runways[$0.id] }.max() ?? 0
            return accounts.reduce(into: [UUID: Double]()) { result, account in
                let lasts = runways[account.id] ?? 0
                let eligible = best > 0 && lasts >= best / 2 && among.contains { $0.id == account.id }
                result[account.id] = eligible ? max(account.baseWeight, 0.01) * lasts / Self.newSessionRunway : 0
            }
        }
        // New sessions go by unused rate to accounts that stay within their
        // windows. When every account would reach a limit before its reset,
        // they go by how much of its present rate each account's allowance
        // sustains until then, so the accounts run out as late as they can:
        // one running short soonest for its reset takes the fewest.
        plan.weights = weighted { account in
            let outlook = current(account)
            let open = account.baseWeight > 0 && plan.shedding[account.id] == nil && outlook.limitAt == nil
            return open ? account.baseWeight * max(0, outlook.allowedPerHour - outlook.burnPerHour) : 0
        }
        if !plan.weights.values.contains(where: { $0 > 0 }) {
            let candidates = accounts.filter { $0.baseWeight > 0 }
            let among = Set((candidates.isEmpty ? accounts : candidates).map(\.id))
            plan.weights = weighted { account in
                among.contains(account.id) ? max(account.baseWeight, 0.01) * Self.sustainedShare(current(account)) : 0
            }
        }
        // A new session on a model with an allowance of its own goes the
        // same way by the smaller of the two unused rates, so none starts
        // where that model's allowance is spent while another account has
        // some left.
        for key in Set(accounts.flatMap { $0.scoped.keys }).sorted() {
            var weights = weighted(key) { account in
                let outlooks = [current(account)] + [currentScoped(account, key)].compactMap { $0 }
                let open = account.baseWeight > 0 && plan.shedding[account.id] == nil
                    && plan.scopedShedding[account.id]?[key] == nil && !outlooks.contains { $0.limitAt != nil }
                let unused = outlooks.map { $0.allowedPerHour - $0.burnPerHour }.min() ?? 0
                return open ? account.baseWeight * max(0, unused) : 0
            }
            if !weights.values.contains(where: { $0 > 0 }) {
                let candidates = accounts.filter { $0.baseWeight > 0 }
                let among = Set((candidates.isEmpty ? accounts : candidates).map(\.id))
                weights = weighted(key) { account in
                    guard among.contains(account.id) else { return 0 }
                    let shares = [current(account)] + [currentScoped(account, key)].compactMap { $0 }
                    return max(account.baseWeight, 0.01) * (shares.map(Self.sustainedShare).min() ?? 0)
                }
            }
            plan.modelWeights[key] = weights
        }
        return plan
    }

    /// How long an account must be able to carry one more session of the
    /// running sessions' average rate to take a new one: the default
    /// lifetime of the cache the session would write there.
    static let newSessionRunway: TimeInterval = defaultCacheLifetime
    /// Weighted tokens per hour assumed of a session with no history, as
    /// one about to start.
    static let defaultSessionRate = 20_000_000.0

    /// The rate a session started now is expected to use: the median of the
    /// running sessions' rates over their last hour (the larger of
    /// `recentTokensPerHour` and the current `tokensPerHour`), at least
    /// `defaultSessionRate`. A decayed current rate alone reads near zero
    /// between turns, which would let every account look able to carry
    /// another session.
    static func typicalNewSessionRate(_ sessions: [Session]) -> Double {
        let rates = sessions.map { max($0.tokensPerHour, $0.recentTokensPerHour ?? 0) }.filter { $0 > 0 }.sorted()
        guard !rates.isEmpty else { return defaultSessionRate }
        let middle = rates.count / 2
        let median = rates.count % 2 == 1 ? rates[middle] : (rates[middle - 1] + rates[middle]) / 2
        return max(defaultSessionRate, median)
    }

    /// The share of its present rate an account's allowance sustains until
    /// its window resets, at most `maximumSustainedShare`: an account barely
    /// used counts as sustaining that much rather than without bound.
    static let maximumSustainedShare = 10.0
    static func sustainedShare(_ outlook: Outlook) -> Double {
        guard outlook.allowedPerHour > 0 else { return 0 }
        guard outlook.burnPerHour > 0 else { return maximumSustainedShare }
        return min(maximumSustainedShare, outlook.allowedPerHour / outlook.burnPerHour)
    }

    /// A paused session that could continue.
    struct Candidate: Equatable {
        let id: String
        /// Forecast weighted tokens per hour (`SessionRates.demand`).
        var tokensPerHour: Double
        var contextTokens: Int
        /// The account the session is held on, when that account can still
        /// serve it. A session held mid-turn finishes the turn there, since
        /// another account rejects the turn's thinking.
        var account: UUID?
    }

    /// Window percent below which what an account has left before its reset
    /// is not worth a session's cache rewrite.
    static let minimumLeftover = 2.0

    /// Where a resumed session continues. A surplus session runs on what the
    /// account would leave unused by its reset, and is held again once the
    /// rest only covers the sessions that fit (`covers`).
    struct Placement: Equatable {
        var account: UUID
        var surplus = false
    }

    /// Whether the account's windows carry `sessions` to their resets.
    func covers(_ account: Account, sessions: [Session], now: Date) -> Bool {
        let burn = sessions.filter { $0.account == account.id }.reduce(0) { $0 + percent($1.tokensPerHour, on: account) }
        return outlook(account, burn: burn, now: now).limitAt == nil
    }

    /// Which paused sessions continue now, and on which account. Sessions are
    /// placed largest forecast first wherever they fit: with the sessions
    /// already running there, the account reaches none of its limits before
    /// the window resets. A small session therefore never takes the room of
    /// one doing most of the work while both cannot fit, and fills what is
    /// left when they can. Then an account with at least `minimumLeftover`
    /// that no waiting session fits takes the largest one that may run there
    /// as surplus, so that window is used before it resets without cutting
    /// the others short. The rest wait for more capacity.
    func admit(_ candidates: [Candidate], accounts: [Account], running: [Session], now: Date) -> [String: Placement] {
        let ids = Set(accounts.map(\.id))
        let active = running.filter { ids.contains($0.account) && now.timeIntervalSince($0.lastSeen) <= Self.activeWithin }
        var spent: [UUID: Double] = [:]
        var burn: [UUID: Double] = [:]
        for account in accounts {
            let sessionsBurn = active.filter { $0.account == account.id }.reduce(0) { $0 + percent($1.tokensPerHour, on: account) }
            burn[account.id] = max(account.burnPerHour, sessionsBurn)
        }
        func options(_ candidate: Candidate) -> [Account] {
            if let own = candidate.account, let account = accounts.first(where: { $0.id == own }) { return [account] }
            return accounts.filter { $0.baseWeight > 0 }
        }
        func cost(_ candidate: Candidate, on account: Account) -> Double {
            candidate.account == account.id ? 0 : moveCost(candidate.contextTokens, to: account)
        }
        func after(_ candidate: Candidate, on account: Account) -> Outlook {
            outlook(account, spent: (spent[account.id] ?? 0) + cost(candidate, on: account),
                    burn: (burn[account.id] ?? 0) + percent(candidate.tokensPerHour, on: account), now: now)
        }
        func place(_ candidate: Candidate, on account: Account, surplus: Bool, into admitted: inout [String: Placement]) {
            admitted[candidate.id] = Placement(account: account.id, surplus: surplus)
            spent[account.id, default: 0] += cost(candidate, on: account)
            burn[account.id, default: 0] += percent(candidate.tokensPerHour, on: account)
        }
        var admitted: [String: Placement] = [:]
        let ordered = candidates.sorted { $0.tokensPerHour == $1.tokensPerHour ? $0.id < $1.id : $0.tokensPerHour > $1.tokensPerHour }
        for candidate in ordered {
            let fits = options(candidate).compactMap { account -> (Account, Double)? in
                let outlook = after(candidate, on: account)
                return outlook.limitAt == nil ? (account, outlook.allowedPerHour - outlook.burnPerHour) : nil
            }
            if let best = fits.max(by: { $0.1 < $1.1 })?.0 { place(candidate, on: best, surplus: false, into: &admitted) }
        }
        for account in accounts {
            let outlook = self.outlook(account, spent: spent[account.id] ?? 0, burn: burn[account.id] ?? 0, now: now)
            let hours = max(outlook.windowEndsAt.timeIntervalSince(now), 0) / 3600
            let unused = outlook.allowedPerHour * hours - outlook.burnPerHour * hours
            guard outlook.limitAt == nil, unused >= Self.minimumLeftover else { continue }
            let waiting = ordered.filter { admitted[$0.id] == nil && options($0).contains { $0.id == account.id } }
            if let largest = waiting.first, cost(largest, on: account) < unused {
                place(largest, on: account, surplus: true, into: &admitted)
            }
        }
        return admitted
    }
}

// MARK: - Rebalancing

extension SessionPacer {
    /// A running session as `rebalance` places it.
    struct RebalanceSession: Equatable {
        let id: String
        var account: UUID
        /// Weighted tokens per hour it is expected to keep using: its rate
        /// over its last hour, at least its current rate, and
        /// `defaultSessionRate` when it has no history.
        var tokensPerHour: Double
        var contextTokens: Int
        var model: String?
        /// False for a session mid-turn: it keeps its account.
        var movable: Bool
    }

    struct Rebalance: Equatable {
        /// The account each moved session goes to.
        var moves: [String: UUID] = [:]
        /// When the first account reaches a limit before and after the
        /// moves; nil when none does before its windows reset.
        var earliestRunOutBefore: Date?
        var earliestRunOutAfter: Date?
    }

    /// How long `account` lasts carrying `sessions` after `spent` percent
    /// more than its readings show, over its windows and each model's own
    /// allowance the sessions draw on; infinity when it reaches no limit
    /// before they reset.
    func runway(_ account: Account, sessions: [RebalanceSession], spent: Double,
                scopedSpent: [String: Double] = [:], shared: SharedShare? = nil, now: Date) -> TimeInterval {
        let burn = sessions.reduce(0) { $0 + percent($1.tokensPerHour, on: account) }
        var times = [outlook(account, spent: spent, burn: burn, now: now, shared: shared).limitAt]
        for (key, allowance) in account.scoped where allowance.resetsAt > now {
            let users = sessions.filter { session in session.model?.lowercased().contains(key) == true }
            let fraction = shared?.scopedFractions[key] ?? 0
            guard !users.isEmpty || fraction > 0 else { continue }
            let scopedBurn = users.reduce(0) { $0 + percent($1.tokensPerHour, on: account) }
            times.append(projected(allowance.remaining - (scopedSpent[key] ?? 0), burn: scopedBurn,
                                   until: allowance.resetsAt, now: now,
                                   shared: fraction > 0 ? shared : nil, fraction: fraction).limitAt)
        }
        return times.compactMap { $0?.timeIntervalSince(now) }.min() ?? .infinity
    }

    /// Places the movable sessions so the first account to reach a limit
    /// does so as late as possible. `destinations` are the accounts a
    /// session may move to.
    ///
    /// Local search from where the sessions run now: each step takes the
    /// account that runs out first and tries every movable session on it
    /// on every other destination, charging the destination the session's
    /// cache rewrite (`moveCost`), and makes the move that leaves the
    /// latest earliest run-out. A move is made only when it raises that
    /// time, and by more than the cache rewrite costs: the hours gained at
    /// the bottleneck account's burn must exceed the rewrite's window
    /// percent. Each session moves at most once, and a mid-turn session
    /// never. Guarantees: the earliest run-out never gets earlier, every
    /// move pays for its cache rewrite, and the result is a local optimum
    /// (no single further move of a session on the first account to run out
    /// helps), not necessarily the best of all assignments.
    ///
    /// `sharedGroup`, the sessions on the shared sign-in, is no session it
    /// moves: it counts on the active account until the projected switch
    /// and on the next account after it (`shares`), so no session moves
    /// onto room the group will need there.
    func rebalance(accounts: [Account], sessions: [RebalanceSession], destinations: Set<UUID>, now: Date,
                   sharedGroup: SharedGroup? = nil) -> Rebalance {
        var placed = sessions.filter { session in accounts.contains { $0.id == session.account } }
        let shares = shares(sharedGroup, accounts: accounts, now: now)
        var spent: [UUID: Double] = [:]
        var scopedSpent: [UUID: [String: Double]] = [:]
        var moved = Set<String>()
        func runway(_ account: Account) -> TimeInterval {
            self.runway(account, sessions: placed.filter { $0.account == account.id }, spent: spent[account.id] ?? 0,
                        scopedSpent: scopedSpent[account.id] ?? [:], shared: shares[account.id], now: now)
        }
        func earliest() -> (account: Account, runway: TimeInterval)? {
            accounts.map { ($0, runway($0)) }.min { $0.1 < $1.1 }
        }
        func date(_ runway: TimeInterval) -> Date? { runway.isFinite ? now.addingTimeInterval(runway) : nil }
        var result = Rebalance(earliestRunOutBefore: earliest().flatMap { date($0.runway) })
        for _ in 0..<sessions.count {
            guard let bottleneck = earliest(), bottleneck.runway.isFinite else { break }
            let burn = placed.filter { $0.account == bottleneck.account.id }
                .reduce(0) { $0 + percent($1.tokensPerHour, on: bottleneck.account) }
                + (shares[bottleneck.account.id].map { $0.from <= now ? $0.percentPerHour : 0 } ?? 0)
            var best: (index: Int, to: Account, runway: TimeInterval, cost: Double)?
            for (index, session) in placed.enumerated()
            where session.account == bottleneck.account.id && session.movable && !moved.contains(session.id) {
                for destination in accounts where destination.id != session.account && destinations.contains(destination.id) {
                    let cost = moveCost(session.contextTokens, to: destination)
                    var trial = placed
                    trial[index].account = destination.id
                    var trialSpent = spent
                    trialSpent[destination.id, default: 0] += cost
                    var trialScoped = scopedSpent
                    for key in scopedKeys(Session(id: session.id, account: destination.id, tokensPerHour: 0, contextTokens: 0,
                                                  lastSeen: now, cacheLifetime: nil, model: session.model), on: destination) {
                        trialScoped[destination.id, default: [:]][key, default: 0] += cost
                    }
                    let after = accounts.map { account in
                        self.runway(account, sessions: trial.filter { $0.account == account.id },
                                    spent: trialSpent[account.id] ?? 0, scopedSpent: trialScoped[account.id] ?? [:],
                                    shared: shares[account.id], now: now)
                    }.min() ?? .infinity
                    guard after > bottleneck.runway else { continue }
                    let gained = after.isFinite ? (after - bottleneck.runway) / 3600 * burn : .infinity
                    guard gained > cost else { continue }
                    if best.map({ after > $0.runway || (after == $0.runway && cost < $0.cost) }) ?? true {
                        best = (index, destination, after, cost)
                    }
                }
            }
            guard let best else { break }
            let session = placed[best.index]
            placed[best.index].account = best.to.id
            spent[best.to.id, default: 0] += best.cost
            for key in scopedKeys(Session(id: session.id, account: best.to.id, tokensPerHour: 0, contextTokens: 0,
                                          lastSeen: now, cacheLifetime: nil, model: session.model), on: best.to) {
                scopedSpent[best.to.id, default: [:]][key, default: 0] += best.cost
            }
            moved.insert(session.id)
            result.moves[session.id] = best.to.id
        }
        result.earliestRunOutAfter = earliest().flatMap { date($0.runway) }
        return result
    }
}
