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
            /// The session is on the shared sign-in, whose active account is
            /// at or near its limit while "Move the active account
            /// automatically" is off, and it cannot restart in a slot of its
            /// own (`holdSharedSessionsOnStayingAccount`).
            case activeAccountStays
            /// Capacity is scarce, and no lane with room admitted the
            /// session (`SessionPacer.admitToLanes`): it waits on its own
            /// account until that serves again or a lane admits it.
            case awaitingLane
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
    /// that account; played ones are none. `admitting` leaves out those
    /// waiting for a lane, which `strandedPlacements` weighs again every
    /// cycle. Read by `serveSessionSlots`,
    /// `paced`, `strandedPlacements`, `limitPauseScope`, the automatic
    /// rebalance and `admitPausedSessions`.
    func waitingSessions(_ provider: AIProviderType, admitting: Bool = false) -> [String: UUID] {
        (sessionWaits[provider] ?? [:]).reduce(into: [:]) { result, entry in
            guard !entry.value.played, !admitting || entry.value.reason != .awaitingLane else { return }
            result[entry.key] = entry.value.account
        }
    }

    /// Records the outcome of `SessionPacer.admitToLanes` for the slot
    /// sessions `strandedPlacements` placed: each one left waiting waits
    /// on its own account (`SessionWait.Reason.awaitingLane`) until it
    /// serves again or a later cycle admits it, held by the pause gate; an
    /// admitted one no longer waits. Records the admission once while it
    /// stays the same (`laneAdmissionNoted`). A run with no session record
    /// (keyed by its slot's path, `isUnrecordedRun`) left waiting is kept
    /// in `admissionHeldRuns` instead: no pause can list it, and its slot
    /// stays on its account rather than going to the pool's fallback.
    func noteLaneAdmission(_ provider: AIProviderType, admission: SessionPacer.LaneAdmission?,
                           candidates: [SessionPacer.RebalanceSession], accounts pacerAccounts: [SessionPacer.Account],
                           now: Date) {
        var waits = sessionWaits[provider] ?? [:]
        let considered = Set(candidates.map(\.id))
        let waiting = Set(admission?.waiting ?? [])
        admissionHeldRuns[provider] = candidates.reduce(into: [String: UUID]()) { runs, session in
            if Self.isUnrecordedRun(session.id), waiting.contains(session.id) { runs[session.id] = session.account }
        }
        // Waits for a lane end for every session weighed again and admitted,
        // or no longer short of room.
        waits = waits.filter { id, wait in
            !Self.isUnrecordedRun(id) && (wait.reason != .awaitingLane || !considered.contains(id) || waiting.contains(id))
        }
        var added: [String] = []
        let pacer = SessionPacer()
        for session in candidates where waiting.contains(session.id) && waits[session.id] == nil
            && !Self.isUnrecordedRun(session.id) {
            let back = pacerAccounts.first { $0.id == session.account }.flatMap { pacer.bindingReset($0, now: now) }
            waits[session.id] = SessionWait(account: session.account, reason: .awaitingLane,
                                            until: back ?? now.addingTimeInterval(FailoverPlanner.sessionWindow), since: now)
            added.append(session.id)
        }
        sessionWaits[provider] = waits.isEmpty ? nil : waits
        if !added.isEmpty {
            writeWaits(provider, added, reason: "no account with room can carry them until its reset", now: now)
        }
        guard let admission else {
            laneAdmissionNoted[provider] = nil
            return
        }
        func name(_ id: UUID) -> String { accounts.first { $0.id == id }.map { messageName($0) } ?? "an account" }
        let fresh = Set(pacerAccounts.filter { $0.hasSessionWindow && $0.utilization < 1 }.map(\.id))
        let event = Self.laneAdmissionEvent(
            admitted: admission.lanes.keys.sorted { name($0) < name($1) }.map { lane in
                (name(lane), admission.placements.values.filter { $0 == lane }.count, admission.lanes[lane] ?? now,
                 admission.untilReset.contains(lane), fresh.contains(lane))
            },
            waiting: admission.waiting.count, total: candidates.count, now: now)
        guard laneAdmissionNoted[provider] != event else { return }
        laneAdmissionNoted[provider] = event
        failoverEvents.record(provider, event)
    }

    /// Whether a key the stranded placement weighs is a run with no session
    /// record: those are keyed by their slot's absolute path, sessions by
    /// their ID.
    nonisolated static func isUnrecordedRun(_ id: String) -> Bool { id.hasPrefix("/") }

    /// The event for an admission while capacity is scarce: how many of the
    /// waiting sessions each lane took and until when they fit there, and
    /// how many wait for their own accounts.
    nonisolated static func laneAdmissionEvent(admitted: [(lane: String, count: Int, until: Date, atReset: Bool, fresh: Bool)],
                                               waiting: Int, total: Int, now: Date) -> String {
        let taken = admitted.filter { $0.count > 0 }
        guard !taken.isEmpty else {
            return "Session balancing admitted none of \(total) waiting session(s): no account with room can carry one until its reset; they wait for their own accounts."
        }
        let parts = taken.map { lane in
            "\(lane.count) of \(total) waiting session(s) to \(lane.lane)'s \(lane.fresh ? "fresh window" : "room"): "
                + "they fit until \(lane.atReset ? "its reset at " : "")\(UsageFormat.clock(lane.until, now: now))"
        }
        return "Session balancing admitted " + parts.joined(separator: "; ") + "; \(waiting) wait for their own accounts."
    }

    /// When the reset is due that the sessions on the shared sign-in wait
    /// on the active account for; nil while none waits. Read by
    /// `plan(provider:ladder:current:canVerify:)` for
    /// `FailoverPlanner.Settings.sharedSignInWaitsUntil`.
    func sharedSignInWaitsUntil(_ provider: AIProviderType, active: UUID) -> Date? {
        (sessionWaits[provider] ?? [:]).values.filter {
            $0.shared && !$0.played && $0.account == active && $0.reason == .cacheOutlastsReset
        }.map(\.until).max()
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
        let slotted = slotSessionIDs(provider)
        let pooled = provider == AIProviderType.routedProvider && policy.distributeSessions && routerInUse
        var waits = currentWaits(provider, slotted: slotted, pooled: pooled, planner: planner, now: now)
        guard policy.waitForResetWithinCache, pausingProviders.contains(provider), routedStatus[provider] == nil,
              pauseOverrideUntil[provider].map({ $0 <= now }) ?? true,
              let active = activeAccount(for: provider)?.id else {
            // Without pausing at the limit no gate holds a waiting session,
            // so none is kept on its account.
            waits = pausingProviders.contains(provider) ? waits.filter { $0.value.reason != .cacheOutlastsReset } : [:]
            sessionWaits[provider] = waits.isEmpty ? nil : waits
            return
        }
        let pinned = pinnedSessionAccounts(provider)
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
        let groupWait = waits.values.first { $0.shared && $0.reason == .cacheOutlastsReset }
        let groupWaits = groupWait != nil || Self.sharedSignInWaits(heldContext: sharedKept, totalContext: sharedContext)
        if groupWaits, let until = groupWait?.until ?? reset(active) {
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

    /// The provider's waits that still stand: the session runs, on the
    /// account it waits on (its slot's, the router's for a pooled one, the
    /// active account for one on the shared sign-in), which cannot serve it
    /// yet (`servesAgain`), and the grace after the reset has not passed. A
    /// move the user made, a switch of the active account or a restart in a
    /// slot of its own therefore ends the wait.
    func currentWaits(_ provider: AIProviderType, slotted: Set<String>, pooled: Bool, planner: FailoverPlanner,
                      now: Date) -> [String: SessionWait] {
        let live = Set((liveSessions[provider] ?? []).map(\.sessionID))
        let active = activeAccount(for: provider)?.id
        return (sessionWaits[provider] ?? [:]).filter { id, wait in
            guard live.contains(id), wait.until.addingTimeInterval(Self.accountHoldGrace) > now,
                  !servesAgain(wait.account, planner: planner, now: now) else { return false }
            if wait.shared { return !slotted.contains(id) && wait.account == active }
            if slotted.contains(id) { return slotAccount(forSession: id, provider: provider) == wait.account }
            return pooled
        }
    }

    /// With "Move the active account automatically" off
    /// (`ProviderFailoverPolicy.activeAccountLocked`), the active account
    /// stays where the user put it, and failover moves none of the sessions
    /// on the shared sign-in when it reaches its limit. Once it is at or
    /// near its limit, each such session that can restart in a slot of its
    /// own (idle in agterm, or a background session nothing holds:
    /// `restartBlocker`) does (`restartInOwnSlot`), at most once every
    /// `stuckRestartSpacing`, so session balancing can place it on an
    /// account with room; the rest wait on the active account
    /// (`SessionWait.Reason.activeAccountStays`), held by the pause gate,
    /// until it serves again, the user moves them or the switch is turned
    /// on. Sessions in slots of their own are session balancing's and keep
    /// moving. Only with pausing at the limit and session slots in use for
    /// the restarts; runs every quota cycle after
    /// `holdSessionsForImminentReset`.
    func holdSharedSessionsOnStayingAccount(_ provider: AIProviderType, now: Date = Date()) async {
        let policy = failoverConfig.policy(for: provider)
        var waits = sessionWaits[provider] ?? [:]
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        guard policy.activeAccountLocked, monitoredProviders.contains(provider), pausingProviders.contains(provider),
              routedStatus[provider] == nil, pauseOverrideUntil[provider].map({ $0 <= now }) ?? true,
              let active = activeAccount(for: provider), atOrNearLimit(active.id, planner: planner, now: now) else {
            waits = waits.filter { $0.value.reason != .activeAccountStays }
            sessionWaits[provider] = waits.isEmpty ? nil : waits
            return
        }
        let slotted = slotSessionIDs(provider)
        let pinned = pinnedSessionAccounts(provider)
        let pooled = provider == AIProviderType.routedProvider && policy.distributeSessions && routerInUse
        guard !pooled else { return }
        // Sessions typed into this cycle restart through the launcher; the
        // next cycle finds them in a slot, or holds them if they are not.
        var typed: Set<String> = []
        if sessionSlotsInUse(provider) {
            for session in unisolatedSessions[provider] ?? [] where waits[session.sessionID] == nil {
                let id = session.sessionID
                guard stayingRestartAt[id].map({ now.timeIntervalSince($0) >= Self.stuckRestartSpacing }) ?? true,
                      Self.restartBlocker(session, terminal: unisolatedTerminals[id], background: backgroundSessionStates[id],
                                          refused: sessionRefusals[id] != nil, now: now) == nil else { continue }
                stayingRestartAt[id] = now
                if await restartInOwnSlot(id) { typed.insert(id) }
            }
        }
        let live = Set((liveSessions[provider] ?? []).map(\.sessionID))
        stayingRestartAt = stayingRestartAt.filter { live.contains($0.key) }
        let until = limitReset(active.id, planner: planner, now: now) ?? now.addingTimeInterval(FailoverPlanner.sessionWindow)
        var added: [String] = []
        for session in liveSessions[provider] ?? [] {
            let id = session.sessionID
            guard !slotted.contains(id), pinned[id] == nil, waits[id] == nil, !typed.contains(id) else { continue }
            waits[id] = SessionWait(account: active.id, reason: .activeAccountStays, until: until, since: now, shared: true)
            added.append(id)
        }
        sessionWaits[provider] = waits.isEmpty ? nil : waits
        guard !added.isEmpty || !typed.isEmpty else { return }
        writeWaits(provider, added, reason: "the active account stays at its limit while moving it automatically is off", now: now)
        failoverEvents.record(provider, Self.stayingAccountEvent(account: messageName(active), waiting: added.count,
                                                                 restarted: typed.count, reset: until, now: now))
    }

    /// Whether `id` is at its limit (refused at it) or within
    /// `suspensionLead` of it, as a pause at a limit judges an account.
    func atOrNearLimit(_ id: UUID, planner: FailoverPlanner, now: Date) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        let state = quotaState(for: account, now: now)
        return state.refusedAtLimit
            || planner.servingVerdict(planner.servingView(state), now: now, lead: Self.suspensionLead).atOrNearLimit
    }

    /// The event for the sessions on the shared sign-in while the active
    /// account stays at its limit with moving it automatically off.
    nonisolated static func stayingAccountEvent(account: String, waiting: Int, restarted: Int, reset: Date,
                                                now: Date) -> String {
        var parts = ["\(account) stays the active account at its limit: moving the active account automatically is off, so failover moves none of the sessions on the shared sign-in."]
        if restarted > 0 {
            parts.append("\(restarted) restart(s) in a slot of their own, so session balancing can place them on an account with room.")
        }
        if waiting > 0 {
            parts.append("\(waiting) wait(s) for its reset at \(UsageFormat.clock(reset, now: now)), or for you to move them.")
        }
        return parts.joined(separator: " ")
    }

    /// Lists `sessions` in the provider's pause: the pause in effect, or a
    /// pause at a limit holding them alone at their next tool call and new
    /// turn (`pinnedHoldPause`). A session resumed in this pause runs on
    /// while its release stands; one the user played whose play no longer
    /// covers its account's limit is held again (`holdAtLimit`).
    func writeWaits(_ provider: AIProviderType, _ sessions: [String], reason: String, now: Date) {
        recordPlaysHeldAgain(provider, holdAtLimit(provider, sessions, reason: reason, now: now).replayed, now: now)
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
