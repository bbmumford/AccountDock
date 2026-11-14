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
        case .notIdle, .busy, .notStopped:
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
    /// records each once. A session in a background worker
    /// (`BackgroundSessionProcesses.workers`) is listed as such, with its
    /// `BackgroundSessionState`; its terminal is its attach client's. Runs
    /// on every quota cycle after `maintainSessionSlots`, which reads the
    /// slots processes use.
    func noteUnisolatedSessions() async {
        guard let provider = AIProviderType.routedProvider, provider.capabilities.sessionSlots != nil,
              sessionSlotsInUse else {
            if !unisolatedSessions.isEmpty { unisolatedSessions = [:] }
            if !unisolatedTerminals.isEmpty { unisolatedTerminals = [:] }
            if !backgroundSessionStates.isEmpty { backgroundSessionStates = [:] }
            return
        }
        let found = Self.unisolated(liveSessions[provider] ?? [], slotDirectoryByProcess: slotDirectoryByProcess)
        var terminals: [String: String] = [:]
        var background: [String: BackgroundSessionState] = [:]
        for session in found {
            if let state = await backgroundSessionState(session, provider: provider) {
                background[session.sessionID] = state
                if let client = state.attachProcess, let terminal = await sessionTerminal.terminalSession(ofProcess: client) {
                    terminals[session.sessionID] = terminal
                }
            } else if let pid = session.processID, let terminal = await sessionTerminal.terminalSession(ofProcess: pid) {
                terminals[session.sessionID] = terminal
            }
        }
        let byProvider = found.isEmpty ? [:] : [provider: found]
        if unisolatedSessions != byProvider { unisolatedSessions = byProvider }
        if unisolatedTerminals != terminals { unisolatedTerminals = terminals }
        if backgroundSessionStates != background { backgroundSessionStates = background }
        for session in found where unisolatedNoted.insert(session.sessionID).inserted {
            failoverEvents.record(provider, background[session.sessionID] != nil
                ? "\(Self.eventName(of: session)) runs in \(provider.capabilities.displayName)'s background service, whose workers read the shared sign-in, not a slot of its own: it cannot be moved on its own. Restart it in its own slot from the usage tab once it is idle."
                : "\(Self.eventName(of: session)) runs outside a slot of its own (started by full path, from an IDE or the desktop app, or before the pool was ready): it shares the sign-in and cannot be moved on its own. Restart it in its own slot from the usage tab, or quit it and resume it from a terminal.")
        }
        unisolatedNoted.formIntersection(Set((liveSessions[provider] ?? []).map(\.sessionID)))
    }

    /// What decides whether a session in a background worker can be
    /// restarted now; nil when its process is no worker or the provider has
    /// no background service. Its transcripts are read off the main thread.
    func backgroundSessionState(_ session: AgentSession, provider: AIProviderType) async -> BackgroundSessionState? {
        guard provider.capabilities.backgroundSessions != nil, let pid = session.processID,
              backgroundProcesses.isWorker(pid) else { return nil }
        let id = session.sessionID
        let root = provider.capabilities.transcriptDirectory.map {
            URL(fileURLWithPath: (provider.configDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent($0, isDirectory: true)
        }
        let changed = await Task.detached(priority: .utility) {
            root.flatMap { BackgroundSessionState.transcriptChangedAt(session: id, root: $0) }
        }.value
        return BackgroundSessionState(transcriptChangedAt: changed, shellRunning: backgroundProcesses.hasShell(under: pid),
                                      attachProcess: backgroundProcesses.attachClient(of: id))
    }

    /// Why `session` cannot be restarted in its own slot now; nil when it
    /// can. `terminal` is the terminal session it runs in, when reachable:
    /// for a session in a background worker, its attach client's, and
    /// `background` says what else must hold for one: its transcripts
    /// quiet for `BackgroundSessionState.quietPeriod` and no shell under
    /// its worker.
    nonisolated static func restartBlocker(_ session: AgentSession, terminal: String?,
                                           background: BackgroundSessionState? = nil, now: Date = Date()) -> String? {
        if session.isWorking { return "Its turn is under way; it can restart once the turn ends." }
        if !session.isIdle { return "It has not finished a turn yet; it can restart once one ends." }
        if let background {
            if !background.transcriptsQuiet(now: now) {
                return "It or one of its subagents wrote to its transcript in the last two minutes; it can restart once they are quiet."
            }
            if background.shellRunning {
                return "A shell its Bash tool started is still running under it; it can restart once that ends."
            }
            if terminal == nil {
                return "It runs in the background and no attach client of it runs in agterm, so AccountDock cannot resume it there: stop it and resume it from a terminal."
            }
            return nil
        }
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
        case .busy: "\(session) was not restarted: its transcripts or a shell under it are still active."
        case .notInTerminal: "\(session) was not restarted: it does not run in agterm."
        case .refused: "\(session) was not restarted: agterm did not take the text."
        case .notStopped: "\(session) was not restarted: its background session could not be stopped."
        }
    }

    /// Ends an idle session that reads no slot and resumes it from its
    /// agterm session, so the launcher gives it a slot of its own. A
    /// session in a background worker is stopped with the CLI's stop
    /// command and resumed in its attach client's terminal, judged again
    /// from a fresh read of the processes. Only at the user's request, from
    /// the usage tab. Returns whether it was typed.
    @discardableResult
    func restartInOwnSlot(_ sessionID: String) async -> Bool {
        guard let (provider, session) = liveSession(sessionID),
              let executable = provider.capabilities.cliExecutableName else { return false }
        let outcome: SessionTerminalActions.Outcome
        if let support = provider.capabilities.backgroundSessions, backgroundProcesses.isWorker(session.processID) {
            await refreshSlotProcesses()
            guard let state = await backgroundSessionState(session, provider: provider) else { return false }
            let stopper = SessionSlots(provider)?.realExecutable(preferred: ClaudeService.shared.claudePath) ?? executable
            outcome = await SessionTerminalActions.restartBackground(
                session, state: state, executable: executable, stopper: stopper, support: support,
                control: backgroundSessionControl, terminal: sessionTerminal
            )
        } else {
            outcome = await SessionTerminalActions.restartInOwnSlot(session, executable: executable, terminal: sessionTerminal)
        }
        failoverEvents.record(provider, Self.restartEvent(outcome, session: Self.eventName(of: session)))
        return outcome == .typed
    }

    /// `restartInOwnSlot` for every idle unisolated session of `provider`
    /// in agterm. Returns how many were restarted.
    @discardableResult
    func restartIdleUnisolatedSessions(_ provider: AIProviderType) async -> Int {
        var restarted = 0
        for session in unisolatedSessions[provider] ?? []
        where Self.restartBlocker(session, terminal: unisolatedTerminals[session.sessionID],
                                  background: backgroundSessionStates[session.sessionID]) == nil {
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
