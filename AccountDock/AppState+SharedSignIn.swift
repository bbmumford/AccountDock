import Foundation

/// The sessions on the CLI's shared sign-in while others run in one-session
/// slots: they all run on the active account and move together whenever it
/// changes. `SessionPacer` counts them as one group on the account carrying
/// them now and on the account failover would make active next, from when
/// it would (`sharedGroup`), and failover counts each candidate's slot
/// sessions, which stay where they are when the group moves
/// (`withStayingBurns`).
extension AppState {
    /// The provider's live sessions whose process reads a one-session slot.
    func slotSessionIDs(_ provider: AIProviderType) -> Set<String> {
        guard let root = SessionSlots(provider)?.sessionRoot.path else { return [] }
        return Set((liveSessions[provider] ?? []).compactMap { session -> String? in
            guard let pid = session.processID, let directory = slotDirectoryByProcess[pid],
                  directory.hasPrefix(root + "/") else { return nil }
            return session.sessionID
        })
    }

    /// Which of the pacer's `sessions` run on the shared sign-in: those of
    /// the provider's accounts that read no slot, whether their record
    /// shows them running outside one or they left no record, as a run from
    /// an IDE without hooks does. A session whose record shows it ended is
    /// none, though its rate lingers.
    nonisolated static func sharedSessions(_ sessions: [SessionPacer.Session], own: Set<UUID>, slotted: Set<String>,
                                           live: Set<String>, recorded: Set<String>) -> Set<String> {
        Set(sessions.filter { session in
            own.contains(session.account) && !slotted.contains(session.id)
                && (live.contains(session.id) || !recorded.contains(session.id))
        }.map(\.id))
    }

    /// The shared group as `SessionPacer` takes it: its sessions' rate over
    /// their last hour (at least their current rate), context and models,
    /// on the active account, with the switch failover projects
    /// (`nextActiveSwitch`). Nil without a one-session slot service, or
    /// with no session on the shared sign-in.
    func sharedGroup(_ provider: AIProviderType, sessions: [SessionPacer.Session],
                     now: Date) -> (group: SessionPacer.SharedGroup, members: Set<String>)? {
        guard provider.capabilities.sessionSlots != nil, let active = activeAccount(for: provider)?.id else { return nil }
        let own = Set(accounts.filter { $0.provider == provider }.map(\.id))
        let live = Set((liveSessions[provider] ?? []).map(\.sessionID))
        let recorded = Set(AgentSessions.records(provider).keys)
        let recent = sessions.filter { now.timeIntervalSince($0.lastSeen) <= SessionPacer.activeWithin }
        let members = Self.sharedSessions(recent, own: own, slotted: slotSessionIDs(provider), live: live, recorded: recorded)
        guard !members.isEmpty else { return nil }
        let grouped = recent.filter { members.contains($0.id) }
        var group = SessionPacer.SharedGroup(
            account: active,
            tokensPerHour: grouped.reduce(0) { $0 + max($1.tokensPerHour, $1.recentTokensPerHour ?? 0) },
            contextTokens: grouped.reduce(0) { $0 + $1.contextTokens },
            models: grouped.compactMap(\.model),
            sessionCount: grouped.count
        )
        if let next = nextActiveSwitch(provider, now: now) {
            group.nextAccount = next.account
            group.switchAt = next.at
        }
        return (group, members)
    }

    /// The account failover would make active next and when
    /// (`FailoverPlanner.nextSwitch`), from the same states its plan reads;
    /// nil while it would make no switch: the provider is not monitored,
    /// neither threshold failover nor balancing is on, or the active
    /// account is locked.
    func nextActiveSwitch(_ provider: AIProviderType, now: Date) -> FailoverPlanner.NextSwitch? {
        let policy = failoverConfig.policy(for: provider)
        guard Self.failoverMovesActiveAccount(policy, monitored: monitoredProviders.contains(provider)) else { return nil }
        let ladder = accounts.filter { $0.provider == provider && !policy.excludedAccountIDs.contains($0.id) }
        let ordered = policy.accountOrder.compactMap { id in ladder.first { $0.id == id } }
            + ladder.filter { !policy.accountOrder.contains($0.id) }
        guard let current = ordered.first(where: \.isActive) else { return nil }
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let states = withStayingBurns(ordered.map { quotaState(for: $0, now: now) }, provider: provider, now: now)
        guard let currentState = states.first(where: { $0.id == current.id }) else { return nil }
        return planner.nextSwitch(current: currentState, ladder: states,
                                  recoveredIDs: exhaustedFailoverAccounts[provider, default: []], now: now)
    }

    /// Whether failover would ever change the provider's active account:
    /// it is monitored, threshold failover or balancing is on, and the
    /// active account is not locked. Otherwise the shared group stays on
    /// the active account for the whole horizon.
    nonisolated static func failoverMovesActiveAccount(_ policy: ProviderFailoverPolicy, monitored: Bool) -> Bool {
        monitored && (policy.enabled || policy.intelligentBalancingEnabled) && !policy.activeAccountLocked
    }

    /// `states` with each account's slot sessions' rate as the burn that
    /// stays on it whichever account is active
    /// (`QuotaAccountState.stayingSessionBurnPerHour`), in its window
    /// percent by its learned token cost.
    func withStayingBurns(_ states: [QuotaAccountState], provider: AIProviderType, now: Date) -> [QuotaAccountState] {
        let slotted = slotSessionIDs(provider)
        guard !slotted.isEmpty else { return states }
        let processes = sessionProcesses(provider)
        var tokens: [UUID: Double] = [:]
        for id in slotted {
            guard let pid = processes[id], let account = slotAccount(forProcess: pid) else { continue }
            tokens[account, default: 0] += max(sessionRates.tokensPerHour(id, now: now), sessionRates.demand(id, until: now) ?? 0)
        }
        return states.map { state in
            var state = state
            state.stayingSessionBurnPerHour = (tokens[state.id] ?? 0) / 1_000_000 * turnCostModel.ratio(for: state.id)
            return state
        }
    }

    /// What the pacer keeps room for, in words, when the shared group is
    /// projected to move to another account: "AccountDock keeps room on B
    /// for the 4 sessions on the shared sign-in, which move there at about
    /// 3:40 pm." Nil when it stays on the active account.
    func sharedGroupNote(_ group: SessionPacer.SharedGroup?) -> String? {
        guard let group, let next = group.nextAccount, next != group.account, let at = group.switchAt,
              let account = accounts.first(where: { $0.id == next }) else { return nil }
        let sessions = group.sessionCount == 1 ? "the session" : "the \(group.sessionCount) sessions"
        return "AccountDock keeps room on \(messageName(account)) for \(sessions) on the shared sign-in, which move there at about \(at.formatted(date: .omitted, time: .shortened))."
    }

    /// Records `sharedGroupNote` once each time the account the group is
    /// projected to move to changes.
    func noteSharedGroup(_ group: SessionPacer.SharedGroup?, provider: AIProviderType) {
        let next = group.flatMap { $0.nextAccount != $0.account ? $0.nextAccount : nil }
        guard sharedGroupDestination[provider] != next else { return }
        sharedGroupDestination[provider] = next
        if let note = sharedGroupNote(group) { failoverEvents.record(provider, note) }
    }
}
