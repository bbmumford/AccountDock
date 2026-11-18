import Foundation

/// Pinning a session to its subscription (`SessionPins`): from an account
/// card's session list, the Sessions page, a tile's session button and the
/// requests interface, and the one-click ways out for a pinned session its
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
        movePins[sessionID] = nil
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
        movePins[sessionID] = nil
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
        settleMovePins(provider, now: now)
        guard !sessionPins.sessions.isEmpty || !sessionPins.slots.isEmpty else { return }
        let before = sessionPins
        for session in sessionPins.adopt(sessionsBySlot: sessionsBySlot) {
            let name = liveSession(session).map { Self.eventName(of: $0.1) } ?? "session \(session.prefix(8))"
            let account = sessionPins.account(of: session).flatMap { id in accounts.first { $0.id == id } }
            failoverEvents.record(provider, "Pinned \(name) to \(account.map { messageName($0) } ?? "its account"), where it was opened.")
        }
        // A session whose record says it ended keeps no pin: a resume starts
        // it on whatever slot the launcher gives it.
        let open = AgentSessions.records(provider).filter { $0.value.event != "SessionEnd" }
        for session in sessionPins.prune(provider, recorded: Set(open.keys), now: now) {
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

    /// Unpins a session and moves it to the account with most room for its
    /// model, as any move by hand (`moveSession`), which pins it there
    /// unless balancing would place it there itself. Returns whether it
    /// moved.
    @discardableResult
    func unpinAndMove(_ sessionID: String, now: Date = Date()) async -> Bool {
        guard let (provider, _) = liveSession(sessionID) else { return false }
        unpinSession(sessionID)
        let outcome = await moveSession(sessionID, to: nil, now: now)
        if !outcome.ok {
            failoverEvents.record(provider, "Session \(sessionID.prefix(8)) stays where it is: \(outcome.detail)")
        }
        return outcome.ok
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
        case .notIdle, .busy, .cancelled: "\(name) was not switched to \(choice.label): its turn is under way; try again once it ends."
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

    // MARK: - A pinned session off its pin

    /// A pinned session found running on another account than its pin, as
    /// the Sessions page flags it (`SessionRow.pinDrift`).
    struct PinDrift: Equatable {
        /// "Pinned to ICARE but running on cybrio".
        var text: String
        /// Why `restorePin` cannot put it back now; nil when it can.
        var blocker: String?
    }

    /// The account a session pinned to `pinned` runs on when that is not
    /// its pin, and whether that is through the shared sign-in: the account
    /// its one-session slot serves (`slotServing`) when it reads one
    /// (`inSlot`), else the active account (`active`), which a session
    /// reads when it has no slot or its slot's directory is gone and serves
    /// nothing. Nil when it runs on its pin.
    nonisolated static func pinDriftAccount(pinned: UUID, inSlot: Bool, slotServing: UUID?,
                                            active: UUID?) -> (account: UUID?, shared: Bool)? {
        if inSlot, let slotServing { return slotServing == pinned ? nil : (slotServing, false) }
        return active == pinned ? nil : (active, true)
    }

    /// The one-session slot a running session's process names, whether or
    /// not its directory is still on disk; nil for one on the shared
    /// sign-in.
    func sessionSlotPath(_ session: AgentSession, slots: SessionSlots) -> String? {
        session.processID.flatMap { slotDirectoryByProcess[$0] }.flatMap { slots.isSessionSlot($0) ? $0 : nil }
    }

    /// Whether `session`, pinned, runs off its pin, and what keeps
    /// `restorePin` from putting it back now; nil when it runs on its pin
    /// or is not pinned. Read by `sessionRows`.
    func pinDrift(_ provider: AIProviderType, session: AgentSession) -> PinDrift? {
        guard let pinned = sessionPins.account(of: session.sessionID), let slots = SessionSlots(provider) else { return nil }
        let slot = sessionSlotPath(session, slots: slots)
        guard let drift = Self.pinDriftAccount(pinned: pinned, inSlot: slot != nil,
                                               slotServing: slot.flatMap { slotDirectoryServing[$0] },
                                               active: activeAccount(for: provider)?.id) else { return nil }
        func name(_ id: UUID?) -> String {
            id.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "another account"
        }
        let running = drift.shared ? "\(name(drift.account)) through the shared sign-in" : name(drift.account)
        return PinDrift(text: "Pinned to \(name(pinned)) but running on \(running)",
                        blocker: pinRestoreBlocker(session, inSlot: slot != nil, restarts: slots.isolation.movesNeedRestart))
    }

    /// Why a pinned session off its pin cannot be put back now; nil when
    /// it can. One reading a slot its CLI reads again (`restarts` false) is
    /// put back by writing the slot, at any moment; any other is put back
    /// by restarting it between turns, from its terminal (`restartBlocker`).
    func pinRestoreBlocker(_ session: AgentSession, inSlot: Bool, restarts: Bool) -> String? {
        if inSlot, !restarts { return nil }
        if inSlot {
            if session.isWorking { return "Its turn is under way; it can restart once the turn ends." }
            if !session.isIdle { return "It has not finished a turn yet; it can restart once one ends." }
            return nil
        }
        let id = session.sessionID
        return Self.restartBlocker(session, terminal: unisolatedTerminals[id], background: backgroundSessionStates[id],
                                   refused: sessionRefusals[id] != nil)
    }

    /// Puts a pinned session running off its pin (`pinDrift`) back on its
    /// pinned account, at the user's request from the Sessions page; the
    /// pin itself stays. A session reading a slot its CLI reads again is
    /// served by a slot pass run now: one whose slot's directory is gone
    /// gets it back (`restoreMissingSlots`), and every pinned session's
    /// slot is written for its pin (`slotChoice`). Any other, on the shared
    /// sign-in or of a CLI that moves only by restarting, is ended between
    /// turns and resumed in a slot of the pinned account
    /// (`prepareResumeSlot`, `restartInOwnSlot`). The outcome is recorded.
    @discardableResult
    func restorePin(_ sessionID: String, now: Date = Date()) async -> SessionMoveOutcome {
        guard let (provider, session) = liveSession(sessionID), let pinned = sessionPins.account(of: sessionID),
              let account = accounts.first(where: { $0.id == pinned && $0.provider == provider }),
              let slots = SessionSlots(provider) else {
            return SessionMoveOutcome(ok: false, detail: "The session is no longer running, or no longer pinned to a saved account.")
        }
        defer { refreshSessions() }
        let name = messageName(account)
        let subject = Self.eventName(of: session)
        let slot = sessionSlotPath(session, slots: slots)
        if let slot, !slots.isolation.movesNeedRestart {
            await maintainSessionSlots(now: now)
            let restored = slotDirectoryServing[slot] == pinned
            failoverEvents.record(provider, restored
                ? "Restored the pinned \(subject) to \(name) at the user's request; it reads \(name) from its next request."
                : "\(subject) was not restored to \(name), where it is pinned: its slot could not be written for \(name).")
            return SessionMoveOutcome(ok: restored, detail: restored ? "It reads \(name) again from its next request."
                                      : "Its slot could not be written for \(name).", account: account)
        }
        if let blocker = pinRestoreBlocker(session, inSlot: slot != nil, restarts: slots.isolation.movesNeedRestart) {
            return SessionMoveOutcome(ok: false, detail: "It goes back to \(name) by restarting in a slot there: \(blocker)",
                                      account: account)
        }
        guard await prepareResumeSlot(sessionID, slots: slots, on: account, reason: "restorePin") else {
            return SessionMoveOutcome(ok: false, detail: "No slot of \(name) could be made ready for it.", account: account)
        }
        slotRestartResumes[sessionID] = SlotRestartResume(provider: provider, account: pinned, at: now)
        guard await restartInOwnSlot(sessionID) else {
            slotRestartResumes[sessionID] = nil
            return SessionMoveOutcome(ok: false, detail: "It goes back to \(name) only by restarting, which did not happen; the events say why.",
                                      account: account)
        }
        return SessionMoveOutcome(ok: true, detail: "Restarted in a slot on \(name), where it is pinned.", account: account)
    }
}
