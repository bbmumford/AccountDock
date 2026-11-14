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

    /// The running session with `id` and its provider.
    func liveSession(_ id: String) -> (AIProviderType, AgentSession)? {
        for (provider, sessions) in liveSessions {
            if let session = sessions.first(where: { $0.sessionID == id }) { return (provider, session) }
        }
        return nil
    }
}
