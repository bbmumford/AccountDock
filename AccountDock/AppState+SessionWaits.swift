import Foundation

/// Sessions kept on the account they run on and held there by the pause
/// gate, instead of being moved, until that account serves them again.
/// Each is one more session a pause at a limit lists, judged by its own
/// account (`limitPauseScope`), beside pinned sessions and those whose
/// account is at its limit with nowhere to go.
extension AppState {
    /// One session kept on its account (`sessionWaits`).
    struct SessionWait: Equatable {
        enum Reason: Equatable {
            /// The account resets before the session's prompt cache
            /// expires: it continues there with its cache rather than
            /// writing its whole context into another account's cache.
            case cacheOutlastsReset
        }

        var account: UUID
        var reason: Reason
        /// When the account is expected to serve again.
        var until: Date
        var since: Date
        /// It runs on the shared sign-in, so it waits on the active account
        /// and failover's plan makes no switch while it does.
        var shared = false
        /// The user played it: it goes on, and this wait neither keeps it on
        /// the account nor holds it again until the account serves again.
        var played = false
    }

    /// The provider's sessions a wait keeps on their account now, with
    /// that account; played ones are none. Read by `serveSessionSlots`,
    /// `paced`, `strandedPlacements`, `limitPauseScope`, the automatic
    /// rebalance and `admitPausedSessions`.
    func waitingSessions(_ provider: AIProviderType) -> [String: UUID] {
        (sessionWaits[provider] ?? [:]).reduce(into: [:]) { result, entry in
            if !entry.value.played { result[entry.key] = entry.value.account }
        }
    }

    /// When the reset is due that the sessions on the shared sign-in wait
    /// on the active account for; nil while none waits. Read by
    /// `plan(provider:ladder:current:canVerify:)` for
    /// `FailoverPlanner.Settings.sharedSignInWaitsUntil`.
    func sharedSignInWaitsUntil(_ provider: AIProviderType, active: UUID) -> Date? {
        (sessionWaits[provider] ?? [:]).values.filter { $0.shared && !$0.played && $0.account == active }.map(\.until).max()
    }

    /// Whether a session whose account is at or near its limit keeps its
    /// prompt cache by waiting there for `reset`: the cache its last request
    /// wrote at `lastSeen`, lasting `cacheLifetime` (an hour when unknown,
    /// the lifetime the router asks for), outlasts the reset by
    /// `resetHoldMargin`, so the request it makes after the reset reads the
    /// cache rather than writing it again.
    nonisolated static func cacheOutlastsReset(reset: Date, lastSeen: Date, cacheLifetime: TimeInterval?,
                                               now: Date) -> Bool {
        reset > now && reset.addingTimeInterval(resetHoldMargin)
            <= lastSeen.addingTimeInterval(cacheLifetime ?? SessionPacer.defaultCacheLifetime)
    }

    /// How long before its cache expires a session's account must reset for
    /// it to wait there: its first request after the reset must still find
    /// the cache.
    nonisolated static let resetHoldMargin: TimeInterval = 60

    /// Whether the sessions on the shared sign-in wait on the active
    /// account together: those whose caches outlast its reset
    /// (`heldContext`) hold at least half the context of all of them
    /// (`totalContext`). They move together when the active account
    /// changes, so they all wait or none does, and the wait is worth it
    /// when most of what a switch would rewrite is kept.
    nonisolated static func sharedSignInWaits(heldContext: Int, totalContext: Int) -> Bool {
        heldContext > 0 && heldContext * 2 >= totalContext
    }

    /// When `id`, at or near its limit (refused at it, or reaching it within
    /// `suspensionLead`), serves again (`FailoverPlanner.heldAvailableAt`,
    /// which after a refusal takes the fuller window's reset); nil while it
    /// can serve, or when it cannot serve for another reason, such as a
    /// sign-in, which no reset ends.
    func limitReset(_ id: UUID, planner: FailoverPlanner, now: Date) -> Date? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        let state = quotaState(for: account, now: now)
        let serving = planner.servingView(state)
        switch planner.servingVerdict(serving, now: now, lead: Self.suspensionLead) {
        case .ineligible: return nil
        case .canServe: if !state.refusedAtLimit { return nil }
        case .atLimit, .nearLimit: break
        }
        return planner.heldAvailableAt(serving, now: now)
    }

    /// Whether `id` serves its waiting sessions again: a fresh reading shows
    /// it can serve with `suspensionLead` to spare, and no refusal since.
    func servesAgain(_ id: UUID, planner: FailoverPlanner, now: Date) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return true }
        let state = quotaState(for: account, now: now)
        return !state.refusedAtLimit && planner.isFresh(state, now: now)
            && planner.servingVerdict(planner.servingView(state), now: now, lead: Self.suspensionLead) == .canServe
    }

    /// Keeps each session whose account is at or near its limit on that
    /// account, held by the pause gate, when the account resets before the
    /// session's prompt cache expires: it continues there after the reset
    /// with its cache, rather than writing its whole context into another
    /// account's. A session in a slot waits on its slot's account, one the
    /// router serves from its pool on the account serving it, and the
    /// sessions on the shared sign-in on the active account, all of them or
    /// none (`sharedSignInWaits`), failover making no switch meanwhile.
    ///
    /// Runs every quota cycle before the slots are served, so no rule moves
    /// such a session that cycle: `serveSessionSlots` keeps its slot there,
    /// `paced` and the automatic rebalance leave it, `strandedPlacements`
    /// and `limitPauseScope` place it nowhere, and `admitPausedSessions`
    /// lets it go only where it is. The session joins the pause in effect,
    /// or a pause at a limit listing it (`pinnedHoldPause`), at its next
    /// tool call and new turn; `rescopeLimitPause` lets it go once its
    /// account serves again (`servesAgain`), and its wait ends then, or
    /// `accountHoldGrace` after the reset with no reading showing it.
    ///
    /// Only with the policy's `waitForResetWithinCache` and pausing at the
    /// limit: the gate is what holds the session, and without it the
    /// session moves as before. Not while the user's "Resume all" holds
    /// pauses off (`pauseOverrideUntil`) or a route target serves the
    /// provider. A session with less context than `heldCacheMinimumContext`
    /// rewrites it elsewhere for less than its idle wait costs. Under the
    /// router, a reset within its own hold of a refused request
    /// (`RouterLogic.maximumHold`) is left to it. Pinned sessions have their
    /// own hold (`holdPinnedSessionsAtLimit`).
    func holdSessionsForImminentReset(_ provider: AIProviderType, now: Date = Date()) async {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        await endAccountHoldIfDue(provider, planner: planner, now: now)
        let live = liveSessions[provider] ?? []
        let liveIDs = Set(live.map(\.sessionID))
        // A wait ends when its account serves again, or once the grace after
        // its reset has passed without a reading showing it.
        var waits = (sessionWaits[provider] ?? [:]).filter { id, wait in
            liveIDs.contains(id) && wait.until.addingTimeInterval(Self.accountHoldGrace) > now
                && !servesAgain(wait.account, planner: planner, now: now)
        }
        guard policy.waitForResetWithinCache, pausingProviders.contains(provider), routedStatus[provider] == nil,
              pauseOverrideUntil[provider].map({ $0 <= now }) ?? true,
              let active = activeAccount(for: provider)?.id else {
            sessionWaits[provider] = nil
            return
        }
        // A wait on the shared sign-in ends when the active account changes.
        waits = waits.filter { !$0.value.shared || $0.value.account == active }
        let pinned = pinnedSessionAccounts(provider)
        let slotted = slotSessionIDs(provider)
        let pooled = provider == AIProviderType.routedProvider && policy.distributeSessions && routerInUse
        var resets: [UUID: Date?] = [:]
        func reset(_ id: UUID) -> Date? {
            if let known = resets[id] { return known }
            let value = limitReset(id, planner: planner, now: now)
            resets[id] = value
            return value
        }
        var sharedIDs: [String] = []
        var sharedContext = 0
        var sharedKept = 0
        var added: [String] = []
        for session in live where pinned[session.sessionID] == nil {
            let id = session.sessionID
            let entry = sessionRates.entries[id]
            let account: UUID
            let shared: Bool
            if slotted.contains(id), let slot = slotAccount(forSession: id, provider: provider) {
                (account, shared) = (slot, false)
            } else if pooled, let entry {
                (account, shared) = (entry.account, false)
            } else {
                (account, shared) = (active, true)
            }
            if shared {
                sharedIDs.append(id)
                sharedContext += entry?.contextTokens ?? 0
            }
            guard waits[id] == nil, let entry, entry.contextTokens >= Self.heldCacheMinimumContext,
                  let until = reset(account), !pooled || until.timeIntervalSince(now) > RouterLogic.maximumHold,
                  Self.cacheOutlastsReset(reset: until, lastSeen: entry.lastSeen, cacheLifetime: entry.cacheLifetime,
                                          now: now) else { continue }
            if shared {
                sharedKept += entry.contextTokens
            } else {
                waits[id] = SessionWait(account: account, reason: .cacheOutlastsReset, until: until, since: now)
                added.append(id)
            }
        }
        var sharedAdded: [String] = []
        let groupWaits = waits.values.contains { $0.shared }
            || Self.sharedSignInWaits(heldContext: sharedKept, totalContext: sharedContext)
        if groupWaits, let until = waits.values.first(where: \.shared)?.until ?? reset(active) {
            for id in sharedIDs where waits[id] == nil {
                waits[id] = SessionWait(account: active, reason: .cacheOutlastsReset, until: until, since: now, shared: true)
                sharedAdded.append(id)
            }
        }
        sessionWaits[provider] = waits.isEmpty ? nil : waits
        guard !added.isEmpty || !sharedAdded.isEmpty else { return }
        writeWaits(provider, added + sharedAdded, reason: "sessions wait for their account's reset, which comes before their prompt caches expire", now: now)
        for id in added.sorted() {
            guard let wait = waits[id] else { continue }
            let name = liveSession(id).map { Self.eventName(of: $0.1) } ?? "session \(id.prefix(8))"
            let on = accounts.first { $0.id == wait.account }.map { messageName($0) } ?? "its account"
            failoverEvents.record(provider, Self.resetHoldEvent(session: name, account: on, reset: wait.until, now: now))
        }
        if let first = sharedAdded.first, let wait = waits[first] {
            let on = accounts.first { $0.id == active }.map { messageName($0) } ?? "the active account"
            failoverEvents.record(provider, Self.sharedResetHoldEvent(count: sharedAdded.count, account: on, reset: wait.until,
                                                                      now: now))
        }
    }

    /// Lists `sessions` in the provider's pause: the pause in effect, or a
    /// pause at a limit holding them alone at their next tool call and new
    /// turn (`pinnedHoldPause`). A session the user resumed in this pause is
    /// left to run.
    func writeWaits(_ provider: AIProviderType, _ sessions: [String], reason: String, now: Date) {
        let existing = AgentPauseGate.read(provider)
        let resumed = AgentPauseGate.resumedSessions(provider)
        let due = sessions.filter { !(existing?.sessions.contains($0) ?? false) && !resumed.contains($0) }.sorted()
        guard let pause = Self.pinnedHoldPause(existing: existing, adding: due, at: now, reason: reason) else { return }
        AgentPauseGate.write(pause, for: provider)
        refreshPauseStatus(provider)
    }

    /// The event for a session held on its account for a reset that comes
    /// before its cache expires.
    nonisolated static func resetHoldEvent(session: String, account: String, reset: Date, now: Date) -> String {
        "Holding \(session) on \(account) until its reset at \(UsageFormat.clock(reset, now: now)): sooner than its "
            + "cache expires, so it keeps its cache."
    }

    /// The event for the sessions on the shared sign-in held on the active
    /// account for its reset.
    nonisolated static func sharedResetHoldEvent(count: Int, account: String, reset: Date, now: Date) -> String {
        "Holding the \(count) session(s) on the shared sign-in on \(account) until its reset at "
            + "\(UsageFormat.clock(reset, now: now)): sooner than their caches expire, so they keep their caches. "
            + "Failover does not switch the active account until then."
    }

    /// Marks the wait of a session the user played as played
    /// (`SessionWait.played`). Called by `resumeSession`.
    func notePlayedWait(_ provider: AIProviderType, session: String) {
        sessionWaits[provider]?[session]?.played = true
    }

    /// Ends a pause that names one account (`PauseFile.account`), which
    /// `rescopeLimitPause` and `capacityEndsPause` leave to this rule and
    /// a pause file on disk may still hold after a relaunch:
    /// its sessions continue once that account reset and a fresh reading
    /// shows it can serve, or `accountHoldGrace` after the reset; with
    /// resuming as capacity allows, `admitPausedSessions` places them.
    private func endAccountHoldIfDue(_ provider: AIProviderType, planner: FailoverPlanner, now: Date) async {
        guard let pause = AgentPauseGate.read(provider), let id = pause.account else { return }
        if resumesAsCapacityAllows(provider) {
            await admitPausedSessions(provider, planner: planner)
        } else if let account = accounts.first(where: { $0.id == id }) {
            let state = quotaState(for: account, now: now)
            let reset = (pause.resumeAt ?? now) <= now
            let usable = planner.isFresh(state, now: now)
                && planner.servingVerdict(state, now: now, lead: Self.suspensionLead) == .canServe
            if reset && usable || (pause.resumeAt ?? now).addingTimeInterval(Self.accountHoldGrace) <= now {
                let resumed = await releasePausedAgents(provider)
                failoverEvents.record(provider, "\(messageName(account)) reset; \(resumed) held session(s) continue on it.")
            }
        }
    }
}
