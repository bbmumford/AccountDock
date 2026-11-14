import Foundation

/// Acts on running sessions through the terminals they run in
/// (`SessionTerminalActions`, `sessionTerminal`).
extension AppState {
    /// The model a session on `model` is switched to when no account has
    /// allowance left for it: the policy's `noRoomModelFallback`, when it is
    /// one the provider's CLI can switch to and the session is not on it.
    nonisolated static func modelFallback(for model: String, policy: ProviderFailoverPolicy,
                                          provider: AIProviderType) -> String? {
        guard let fallback = policy.noRoomModelFallback,
              provider.capabilities.sessionModelChoices.contains(where: { $0.id == fallback }) else { return nil }
        return model.lowercased().hasPrefix(fallback.lowercased()) ? nil : fallback
    }

    /// The event for one attempt to switch `session` to `model`; nil while
    /// it waits for its turn to end.
    nonisolated static func modelFallbackEvent(_ outcome: SessionTerminalActions.Outcome, session: String,
                                               model: String) -> String? {
        switch outcome {
        case .typed:
            "No account has allowance left for the model \(session) used; switched it to \(model) in its terminal."
        case .notIdle:
            nil
        case .notInTerminal:
            "No account has allowance left for the model \(session) uses, and it does not run in agterm, so it could not be switched to \(model); change its model with /model."
        case .refused:
            "No account has allowance left for the model \(session) uses; agterm did not take the switch to \(model). Change its model with /model."
        }
    }

    /// Switches each session in `pendingModelFallbacks` to its fallback
    /// model once its turn has ended, and records the outcome once. Runs on
    /// every quota cycle after `maintainSessionSlots`, which fills the map.
    func applyModelFallbacks() async {
        guard !pendingModelFallbacks.isEmpty else { return }
        for (sessionID, model) in pendingModelFallbacks {
            guard let (provider, session) = liveSession(sessionID) else {
                pendingModelFallbacks[sessionID] = nil
                continue
            }
            let outcome = await SessionTerminalActions.switchModel(session, to: model, terminal: sessionTerminal)
            let label = provider.capabilities.sessionModelChoices.first { $0.id == model }?.label ?? model
            guard let event = Self.modelFallbackEvent(outcome, session: Self.eventName(of: session), model: label) else { continue }
            pendingModelFallbacks[sessionID] = nil
            failoverEvents.record(provider, event)
        }
    }

    // MARK: - Sessions outside a slot

    /// The sessions among `sessions` whose process reads no slot of its own
    /// (`slotDirectoryByProcess`): started by full path, from an IDE or the
    /// desktop app, or before the pool was fresh. They share the CLI's own
    /// sign-in and cannot be moved one at a time.
    nonisolated static func unisolated(_ sessions: [AgentSession], slotDirectoryByProcess: [Int32: String]) -> [AgentSession] {
        sessions.filter { session in session.processID.map { slotDirectoryByProcess[$0] == nil } ?? false }
    }

    /// Finds the sessions running outside a slot while sessions are served
    /// from slots, with the terminal each runs in, for the usage tab, and
    /// records each once. Runs on every quota cycle after
    /// `maintainSessionSlots`, which reads the slots processes use.
    func noteUnisolatedSessions() async {
        guard let provider = AIProviderType.routedProvider, provider.capabilities.sessionSlots != nil,
              sessionSlotsInUse else {
            if !unisolatedSessions.isEmpty { unisolatedSessions = [:] }
            if !unisolatedTerminals.isEmpty { unisolatedTerminals = [:] }
            return
        }
        let found = Self.unisolated(liveSessions[provider] ?? [], slotDirectoryByProcess: slotDirectoryByProcess)
        var terminals: [String: String] = [:]
        for session in found {
            if let pid = session.processID, let terminal = await sessionTerminal.terminalSession(ofProcess: pid) {
                terminals[session.sessionID] = terminal
            }
        }
        let byProvider = found.isEmpty ? [:] : [provider: found]
        if unisolatedSessions != byProvider { unisolatedSessions = byProvider }
        if unisolatedTerminals != terminals { unisolatedTerminals = terminals }
        for session in found where unisolatedNoted.insert(session.sessionID).inserted {
            failoverEvents.record(provider, "\(Self.eventName(of: session)) runs outside a slot of its own (started by full path, from an IDE or the desktop app, or before the pool was ready): it shares the sign-in and cannot be moved on its own. Restart it in its own slot from the usage tab, or quit it and resume it from a terminal.")
        }
        unisolatedNoted.formIntersection(Set((liveSessions[provider] ?? []).map(\.sessionID)))
    }

    /// Why `session` cannot be restarted in its own slot now; nil when it
    /// can. `terminal` is the terminal session it runs in, when reachable.
    nonisolated static func restartBlocker(_ session: AgentSession, terminal: String?) -> String? {
        if session.isWorking { return "Its turn is under way; it can restart once the turn ends." }
        if !session.isIdle { return "It has not finished a turn yet; it can restart once one ends." }
        if terminal == nil {
            return "It does not run in agterm, so AccountDock cannot type into it: quit it and resume it from a terminal."
        }
        return nil
    }

    /// The event for one attempt to restart `session` in its own slot.
    nonisolated static func restartEvent(_ outcome: SessionTerminalActions.Outcome, session: String) -> String {
        switch outcome {
        case .typed: "Restarted \(session) in its own slot: it was ended and resumed from its terminal through the launcher."
        case .notIdle: "\(session) was not restarted: its turn is under way."
        case .notInTerminal: "\(session) was not restarted: it does not run in agterm."
        case .refused: "\(session) was not restarted: agterm did not take the text."
        }
    }

    /// Ends an idle session that reads no slot and resumes it from its
    /// agterm session, so the launcher gives it a slot of its own. Only at
    /// the user's request, from the usage tab. Returns whether it was typed.
    @discardableResult
    func restartInOwnSlot(_ sessionID: String) async -> Bool {
        guard let (provider, session) = liveSession(sessionID),
              let executable = provider.capabilities.cliExecutableName else { return false }
        let outcome = await SessionTerminalActions.restartInOwnSlot(session, executable: executable, terminal: sessionTerminal)
        failoverEvents.record(provider, Self.restartEvent(outcome, session: Self.eventName(of: session)))
        return outcome == .typed
    }

    /// `restartInOwnSlot` for every idle unisolated session of `provider`
    /// in agterm. Returns how many were restarted.
    @discardableResult
    func restartIdleUnisolatedSessions(_ provider: AIProviderType) async -> Int {
        var restarted = 0
        for session in unisolatedSessions[provider] ?? []
        where Self.restartBlocker(session, terminal: unisolatedTerminals[session.sessionID]) == nil {
            if await restartInOwnSlot(session.sessionID) { restarted += 1 }
        }
        return restarted
    }

    /// The running session with `id` and its provider.
    func liveSession(_ id: String) -> (AIProviderType, AgentSession)? {
        for (provider, sessions) in liveSessions {
            if let session = sessions.first(where: { $0.sessionID == id }) { return (provider, session) }
        }
        return nil
    }
}
