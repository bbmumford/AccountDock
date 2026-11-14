import Foundation

/// Pinning a session to its subscription (`SessionPins`): from an account
/// card's session list, a tile's session button, the requests interface and
/// Settings → Failover, and the one-click ways out for a pinned session its
/// account refuses at the limit.
extension AppState {
    /// The account serving the one-session slot `session` reads; nil when
    /// it reads none, as a session on the shared sign-in does.
    func slotAccount(ofSession session: String, provider: AIProviderType) -> UUID? {
        guard let root = SessionSlots(provider)?.sessionRoot.path,
              let pid = liveSessions[provider]?.first(where: { $0.sessionID == session })?.processID,
              let directory = slotDirectoryByProcess[pid], directory.hasPrefix(root + "/") else { return nil }
        return slotDirectoryServing[directory]
    }

    /// Pins a running slot session to the account its slot serves, and
    /// records it.
    @discardableResult
    func pinSession(_ sessionID: String, now: Date = Date()) -> SessionPins.Outcome {
        guard let (provider, session) = liveSession(sessionID) else { return .notInSlot }
        let outcome = sessionPins.pin(sessionID, slotAccount: slotAccount(ofSession: sessionID, provider: provider),
                                      provider: provider, at: now)
        if case .pinned(let id) = outcome {
            sessionPins.save()
            let name = accounts.first { $0.id == id }.map { messageName($0) } ?? "its account"
            failoverEvents.record(provider, "Pinned \(Self.eventName(of: session)) to \(name): failover, pacing, rebalancing and the model fallback leave it there.")
        }
        return outcome
    }

    /// Unpins a session, and records it.
    @discardableResult
    func unpinSession(_ sessionID: String) -> SessionPins.Outcome {
        let provider = sessionPins.sessions[sessionID].flatMap { AIProviderType(rawValue: $0.provider) }
        let outcome = sessionPins.unpin(sessionID)
        if case .unpinned = outcome {
            sessionPins.save()
            pinnedKeptAtLimit.remove(sessionID)
            let name = liveSession(sessionID).map { Self.eventName(of: $0.1) } ?? "session \(sessionID.prefix(8))"
            if let provider { failoverEvents.record(provider, "Unpinned \(name): failover and balancing may move it again.") }
        }
        return outcome
    }

    /// Pins the session each pinned slot now serves and drops the pins of
    /// sessions whose record is gone. Run by `serveSessionSlots` with the
    /// session reading each slot.
    func maintainPins(_ provider: AIProviderType, sessionsBySlot: [String: String], now: Date) {
        guard !sessionPins.sessions.isEmpty || !sessionPins.slots.isEmpty else { return }
        let before = sessionPins
        for session in sessionPins.adopt(sessionsBySlot: sessionsBySlot) {
            let name = liveSession(session).map { Self.eventName(of: $0.1) } ?? "session \(session.prefix(8))"
            let account = sessionPins.account(of: session).flatMap { id in accounts.first { $0.id == id } }
            failoverEvents.record(provider, "Pinned \(name) to \(account.map { messageName($0) } ?? "its account"), where it was opened.")
        }
        for session in sessionPins.prune(provider, recorded: Set(AgentSessions.records(provider).keys), now: now) {
            pinnedKeptAtLimit.remove(session)
        }
        if sessionPins != before { sessionPins.save() }
    }

    /// The account with most room for the session's model, other than
    /// `current`: the destination of a move asked for without one, by the
    /// requests interface and by "Unpin and move".
    func moveDestination(_ provider: AIProviderType, current: UUID?, model: String?, now: Date) -> Account? {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        return accounts
            .filter {
                $0.provider == provider && $0.id != current && !needsSignIn($0) && !policy.excludedAccountIDs.contains($0.id)
                    && !accountCannotServe($0.id, provider: provider, planner: planner, now: now, model: model)
            }
            .min { (plannedUsage($0, now: now, model: model)?.sevenDay?.utilization ?? 100)
                < (plannedUsage($1, now: now, model: model)?.sevenDay?.utilization ?? 100) }
    }

    /// Unpins a session and moves its slot to the account with most room
    /// for its model, through `requestedSlotMoves`. Returns whether it moved.
    @discardableResult
    func unpinAndMove(_ sessionID: String, now: Date = Date()) async -> Bool {
        guard let (provider, _) = liveSession(sessionID) else { return false }
        unpinSession(sessionID)
        let current = slotAccount(ofSession: sessionID, provider: provider)
        guard let target = moveDestination(provider, current: current, model: sessionModel(sessionID, now: now), now: now) else {
            failoverEvents.record(provider, "No other account has allowance left for session \(sessionID.prefix(8))'s model; it stays where it is.")
            return false
        }
        requestedSlotMoves[sessionID] = target.id
        await maintainSessionSlots(now: now)
        return slotAccount(ofSession: sessionID, provider: provider) == target.id
    }

    /// The model "Switch model" changes a session to: the policy's
    /// `noRoomModelFallback` when it is one the CLI can switch to, else the
    /// first of the CLI's choices the session is not on.
    func switchModelChoice(for sessionID: String, provider: AIProviderType, now: Date = Date()) -> SessionModelChoice? {
        let choices = provider.capabilities.sessionModelChoices
        let current = sessionModel(sessionID, now: now)?.lowercased() ?? ""
        let policy = failoverConfig.policy(for: provider)
        if let model = current.isEmpty ? policy.noRoomModelFallback
                                       : Self.modelFallback(for: current, policy: policy, provider: provider),
           let choice = choices.first(where: { $0.id == model }) { return choice }
        return choices.first { current.isEmpty || !current.hasPrefix($0.id.lowercased()) }
    }

    /// Switches one session's model from its terminal at the user's
    /// request, as the model fallback would, pinned or not.
    @discardableResult
    func switchSessionModel(_ sessionID: String) async -> SessionTerminalActions.Outcome? {
        guard let (provider, session) = liveSession(sessionID),
              let choice = switchModelChoice(for: sessionID, provider: provider) else { return nil }
        let outcome = await SessionTerminalActions.switchModel(session, to: choice.id, terminal: sessionTerminal)
        let name = Self.eventName(of: session)
        let event = switch outcome {
        case .typed: "Switched \(name) to \(choice.label) in its terminal."
        case .notIdle, .busy: "\(name) was not switched to \(choice.label): its turn is under way; try again once it ends."
        case .notInTerminal: "\(name) does not run in agterm, so it could not be switched to \(choice.label); change its model with /model."
        case .refused, .notStopped: "agterm did not take the switch of \(name) to \(choice.label); change its model with /model."
        }
        failoverEvents.record(provider, event)
        return outcome
    }

    /// The pinned sessions of a provider as Settings → Failover lists them:
    /// each one's label (`sessionSummary`) and the account it is pinned to.
    func pinnedSessionRows(_ provider: AIProviderType) -> [(session: String, label: String, account: String)] {
        sessionPins.pinned(provider).map { session, pin in
            (session, sessionSummary([session]),
             accounts.first { $0.id == pin.account }.map { messageName($0) } ?? "a removed account")
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// The requests interface's answer to a pin or unpin: whether it was
    /// done, and in words, naming accounts with `name`.
    nonisolated static func pinRequestOutcome(_ outcome: SessionPins.Outcome, name: (UUID) -> String) -> (ok: Bool, detail: String) {
        switch outcome {
        case .pinned(let id): (true, "Pinned to \(name(id)); nothing automatic moves it.")
        case .alreadyPinned(let id): (true, "Already pinned to \(name(id)).")
        case .notInSlot: (false, "The session runs on the shared sign-in, not in a slot of its own, so it cannot be pinned; restart it in its own slot first.")
        case .unpinned(let id): (true, "Unpinned from \(name(id)); failover and balancing may move it again.")
        case .notPinned: (false, "The session is not pinned.")
        }
    }
}
