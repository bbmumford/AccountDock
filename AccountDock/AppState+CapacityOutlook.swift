import Foundation

/// The Outlook under each provider on the Sessions page and the usage tab
/// (`CapacityOutlookView`): how long the provider's sessions keep running at
/// their current rates and when they run again (`CapacityOutlook.project`),
/// from the accounts as the pacer sees them (`pacerAccount`) and each
/// running session's expected rate.
extension AppState {
    /// One provider's outlook with what it was projected from: the usage
    /// refresh it read and when.
    struct CachedCapacityOutlook {
        var refresh: Date?
        var at: Date
        var outlook: CapacityOutlook?
    }

    /// How long an outlook is shown before it is projected again, when no
    /// usage refresh comes sooner. The views redraw every few seconds; the
    /// projection reads the pause files and every account's state.
    nonisolated static let capacityOutlookLifetime: TimeInterval = 60

    /// The provider's outlook, projected again after each usage refresh
    /// (`lastUsageRefresh`) or once `capacityOutlookLifetime` has passed, and
    /// otherwise the one projected last. Nil for a provider with no running
    /// session or none whose rate the router has measured.
    func capacityOutlook(_ provider: AIProviderType, now: Date = Date()) -> CapacityOutlook? {
        if let cached = capacityOutlooks[provider], cached.refresh == lastUsageRefresh, cached.at <= now,
           now.timeIntervalSince(cached.at) < Self.capacityOutlookLifetime {
            return cached.outlook
        }
        let outlook = projectCapacityOutlook(provider, now: now)
        capacityOutlooks[provider] = CachedCapacityOutlook(refresh: lastUsageRefresh, at: now, outlook: outlook)
        return outlook
    }

    /// `CapacityOutlook.project` for the provider now. Every one of its
    /// accounts is passed with whether it takes part: excluded from failover,
    /// needing sign-in or ineligible (`FailoverPlanner.servingVerdict`) it
    /// never serves; at its limit it serves from the reset that frees it.
    /// Each running session counts at the rate pacing expects of it
    /// (`SessionPacer.lightRate`: its last hour's use, at least its current
    /// rate, so one idle for its last hour counts near nothing); one a pause
    /// at a limit or a wait holds at its use over the hour before it was
    /// held (`SessionRates.heldDemand`), as resuming as capacity allows
    /// forecasts it; one the user paused at nothing, since only the user
    /// lets it go.
    func projectCapacityOutlook(_ provider: AIProviderType, now: Date) -> CapacityOutlook? {
        guard let sessions = capacityOutlookSessions(provider, now: now) else { return nil }
        var outlook = CapacityOutlook.project(accounts: capacityOutlookAccounts(provider, now: now), sessions: sessions,
                                              now: now,
                                              pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor))
        outlook.paced = pacedSummary(provider, sessions: sessions, resume: outlook.resume?.at)
        return outlook
    }

    /// Every live session of the provider as the Outlook and pacing to the
    /// resets count it, at the rate described under
    /// `projectCapacityOutlook`; nil while none has a rate the router or
    /// its transcripts measured.
    func capacityOutlookSessions(_ provider: AIProviderType, now: Date) -> [CapacityOutlook.Session]? {
        let live = liveSessions[provider] ?? []
        guard live.contains(where: { sessionRates.entries[$0.sessionID] != nil }) else { return nil }
        let pause = AgentPauseGate.read(provider)
        let userHeld = pause?.userHeld(running: Set(live.map(\.sessionID))) ?? []
        let pacing = pacerSessions(provider, now: now).reduce(into: [String: SessionPacer.Session]()) { $0[$1.id] = $1 }
        // Sessions a pause or a wait holds now: they send nothing, so their
        // last hour reads near nothing, but they run at their working rate
        // once released.
        let held = Set(pause?.sessions ?? []).subtracting(AgentPauseGate.resumedSessions(provider))
            .union(waitingSessions(provider).keys)
        return live.map { session -> CapacityOutlook.Session in
            let id = session.sessionID
            let rate: Double
            if userHeld.contains(id) {
                rate = 0
            } else if held.contains(id) {
                let since = sessionWaits[provider]?[id]?.since ?? pause?.pausedAt ?? now
                rate = sessionRates.heldDemand(id, pausedAt: since) ?? pacing[id].map(SessionPacer.lightRate) ?? 0
            } else if let running = pacing[id] {
                rate = SessionPacer.lightRate(running)
            } else if let pausedAt = pause?.pausedAt {
                rate = sessionRates.heldDemand(id, pausedAt: pausedAt) ?? 0
            } else {
                rate = 0
            }
            return CapacityOutlook.Session(
                id: id,
                label: Self.sessionLabel(id: id, name: sessionNames[id], directory: session.workingDirectory, model: nil),
                tokensPerHour: rate
            )
        }
    }

    /// Every account of the provider as `CapacityOutlook` takes it: as the
    /// pacer sees it (`pacerAccount`), named, with the weekly allowance a new
    /// week brings, and whether it takes part. Read by
    /// `projectCapacityOutlook`, `planHeldSessions` and
    /// `paceSessionsToResets`.
    func capacityOutlookAccounts(_ provider: AIProviderType, now: Date) -> [CapacityOutlook.Account] {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        return accounts.filter { $0.provider == provider }.map { account -> CapacityOutlook.Account in
            let state = quotaState(for: account, now: now, wholeAllowance: true)
            let availability: CapacityOutlook.Availability
            if policy.excludedAccountIDs.contains(account.id) {
                availability = .excluded
            } else if needsSignIn(account) {
                availability = .unavailable
            } else {
                switch planner.servingVerdict(state, now: now, lead: 0) {
                case .canServe, .nearLimit: availability = .serves
                case .atLimit: availability = .atLimit
                case .ineligible: availability = .unavailable
                }
            }
            return CapacityOutlook.Account(
                pacer: pacerAccount(account.id, state: state, weight: 1, planner: planner, now: now),
                name: messageName(account),
                sessionPerWeekly: state.sessionPerWeekly ?? FailoverPlanner.defaultSessionPerWeekly,
                availability: availability
            )
        }
    }
}
