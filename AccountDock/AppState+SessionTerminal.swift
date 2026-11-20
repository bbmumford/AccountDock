import Foundation

private let terminalLog = FileLog("SessionTerminal")

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
        case .notIdle, .busy, .notStopped, .cancelled:
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
        // A pinned session's model changes only at the user's request.
        for sessionID in pendingModelFallbacks.keys where sessionPins.isPinned(sessionID) {
            pendingModelFallbacks[sessionID] = nil
        }
        for (sessionID, model) in sessionPins.applicableFallbacks(pendingModelFallbacks) {
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

    // MARK: - Sessions the CLI left waiting at a limit

    /// What a session left waiting at a limit is told once the wait is
    /// closed. Its subagents, workflows and other lanes of work were refused
    /// by the same limit, and some report that they finished when they
    /// stopped on the error, so it is told to check and restart them.
    nonisolated static let leftWaitingPrompt = "Continue where you stopped: the usage limit that stopped this session no longer applies, as its slot now serves an account with room. Resume all your work, and check every subagent, workflow, background task and lane of work you started: requests made while the limit applied were refused, so some may report that they completed when they actually stopped on the error. Restart or resume each one that stopped, without repeating work that already completed."

    /// How long after a refusal its session is still looked at.
    nonisolated static let leftWaitingWindow: TimeInterval = 6 * 60 * 60

    /// The slot sessions to look at for a wait their CLI keeps at a limit:
    /// each refused at a usage limit (`refusals`, from the transcripts)
    /// within `leftWaitingWindow`, whose slot now serves another account
    /// (`slotAccount`) that can serve it (`canServe`), and not already
    /// resumed for that refusal (`handled`, by the refusal's time). A
    /// session the user paused (`userHeld`, `PauseFile.userHeld`) waits for
    /// the user and is never told to go on. With the account each now runs
    /// on.
    nonisolated static func leftWaitingCandidates(sessions: [String], refusals: [String: SessionRefusal],
                                                  slotAccount: (String) -> UUID?, canServe: (UUID) -> Bool,
                                                  handled: [String: Date], userHeld: Set<String> = [],
                                                  now: Date) -> [String: UUID] {
        sessions.reduce(into: [:]) { result, session in
            guard !userHeld.contains(session),
                  let refusal = refusals[session], now.timeIntervalSince(refusal.at) < leftWaitingWindow,
                  handled[session] != refusal.at, let serving = slotAccount(session),
                  serving != refusal.account, canServe(serving) else { return }
            result[session] = serving
        }
    }

    /// Resumes the slot sessions whose CLI was left waiting for a usage
    /// limit to reset after AccountDock moved their slot to an account that
    /// can serve them (`leftWaitingCandidates`): the CLI's own wait would
    /// keep each idle until the reset of an account it no longer reads. In
    /// agterm, the wait is closed and the session told to go on
    /// (`SessionTerminalActions.resumeWaitingAtLimit`), once per refusal,
    /// and recorded. A session whose screen shows no such wait, as one
    /// mid-turn, is left alone. With the policy's
    /// `resumeSessionsLeftWaiting`, for providers with slot isolation. Runs
    /// on every quota cycle after `maintainSessionSlots`, which moves the
    /// slots.
    func resumeSessionsLeftWaiting(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders {
            guard let isolation = SessionSlots(provider)?.isolation,
                  failoverConfig.policy(for: provider).resumeSessionsLeftWaiting else { continue }
            let planner = FailoverPlanner(settings: plannerSettings(provider))
            let live = liveSessions[provider] ?? []
            let running = Set(live.map(\.sessionID))
            let userHeld = running.subtracting(Self.automaticallyReleasable(running, pause: AgentPauseGate.read(provider)))
                .subtracting(AgentPauseGate.resumedSessions(provider))
            let candidates = Self.leftWaitingCandidates(
                sessions: live.map(\.sessionID), refusals: sessionRefusals,
                slotAccount: { self.slotAccount(forSession: $0, provider: provider) },
                canServe: { !self.accountCannotServe($0, provider: provider, planner: planner, now: now, wholeAllowance: true) },
                handled: leftWaitingResumed, userHeld: userHeld, now: now
            )
            for (sessionID, serving) in candidates {
                guard let session = live.first(where: { $0.sessionID == sessionID }),
                      let refusal = sessionRefusals[sessionID] else { continue }
                let outcome = await SessionTerminalActions.resumeWaitingAtLimit(
                    session, isolation: isolation, terminal: sessionTerminal, prompt: Self.leftWaitingPrompt)
                guard outcome == .resumed else { continue }
                leftWaitingResumed[sessionID] = refusal.at
                let name = sessionNames[sessionID].map { "\($0) (\(Self.eventName(of: session)))" } ?? Self.eventName(of: session)
                let on = accounts.first { $0.id == serving }.map { messageName($0) } ?? "another account"
                failoverEvents.record(provider, "Resumed \(name), which the CLI had left waiting for a reset, now that its slot is on \(on).")
            }
        }
    }

    // MARK: - Sessions outside a slot

    /// The sessions among `sessions` whose process reads no slot of its own
    /// (`slotDirectoryByProcess`): started by full path, from an IDE or the
    /// desktop app, or while AccountDock was not running. They share the CLI's own
    /// sign-in and cannot be moved one at a time.
    nonisolated static func unisolated(_ sessions: [AgentSession], slotDirectoryByProcess: [Int32: String]) -> [AgentSession] {
        sessions.filter { session in session.processID.map { slotDirectoryByProcess[$0] == nil } ?? false }
    }

    /// Finds the sessions running outside a slot of every provider whose
    /// sessions are served from slots, with the terminal each runs in, for
    /// the usage tab, and records each once. A session in a background
    /// worker (`BackgroundSessionProcesses.workers`) is listed as such, with
    /// its `BackgroundSessionState`; its terminal is its attach client's.
    /// Runs on every quota cycle after `maintainSessionSlots`, which reads
    /// the slots processes use.
    func noteUnisolatedSessions() async {
        var byProvider: [AIProviderType: [AgentSession]] = [:]
        var terminals: [String: String] = [:]
        var background: [String: BackgroundSessionState] = [:]
        var running = Set<String>()
        var served = false
        for provider in AIProviderType.isolatedProviders where sessionSlotsInUse(provider) {
            served = true
            let byProcess = sessionSlotStates[provider]?.directoryByProcess ?? [:]
            let found = Self.unisolated(liveSessions[provider] ?? [], slotDirectoryByProcess: byProcess)
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
            if !found.isEmpty { byProvider[provider] = found }
            for session in found where unisolatedNoted.insert(session.sessionID).inserted {
                failoverEvents.record(provider, background[session.sessionID] != nil
                    ? "\(Self.eventName(of: session)) runs in \(provider.capabilities.displayName)'s background service, whose workers read the shared sign-in, not a slot of its own: it cannot be moved on its own. Restart it in its own slot from the usage tab once it is idle."
                    : "\(Self.eventName(of: session)) runs outside a slot of its own (started by full path, from an IDE or the desktop app, or while AccountDock was not running): it shares the sign-in and cannot be moved on its own. AccountDock restarts it in a slot of its own once it is idle between turns in agterm; outside agterm, quit it and resume it from a terminal.")
            }
            running.formUnion((liveSessions[provider] ?? []).map(\.sessionID))
        }
        if unisolatedSessions != byProvider { unisolatedSessions = byProvider }
        if unisolatedTerminals != terminals { unisolatedTerminals = terminals }
        if backgroundSessionStates != background { backgroundSessionStates = background }
        if served { unisolatedNoted.formIntersection(running) }
    }

    /// What decides whether a session in a background worker can be
    /// restarted now; nil when its process is no worker or the provider has
    /// no background service. Its transcripts are read off the main thread.
    func backgroundSessionState(_ session: AgentSession, provider: AIProviderType) async -> BackgroundSessionState? {
        let processes = backgroundProcesses(provider)
        guard provider.capabilities.backgroundSessions != nil, let pid = session.processID,
              processes.isWorker(pid) else { return nil }
        let id = session.sessionID
        let root = provider.capabilities.transcriptDirectory.map {
            URL(fileURLWithPath: (provider.configDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent($0, isDirectory: true)
        }
        let changed = await Task.detached(priority: .utility) {
            root.flatMap { BackgroundSessionState.transcriptChangedAt(session: id, root: $0) }
        }.value
        return BackgroundSessionState(transcriptChangedAt: changed, shellRunning: processes.hasShell(under: pid),
                                      attachProcess: processes.attachClient(of: id))
    }

    /// Why `session` cannot be restarted in its own slot now; nil when it
    /// can. `terminal` is the terminal session it runs in, when reachable:
    /// for a session in a background worker, its attach client's, and
    /// `background` says what else must hold for one: its transcripts
    /// quiet for `BackgroundSessionState.quietPeriod` and no shell under
    /// its worker. A background session `refused` at a usage limit since
    /// its last served request counts as idle with quiet transcripts: its
    /// turns all fail, so a restart loses none of them; the shell under its
    /// worker and its attach client's footer still hold it.
    nonisolated static func restartBlocker(_ session: AgentSession, terminal: String?,
                                           background: BackgroundSessionState? = nil, refused: Bool = false,
                                           now: Date = Date()) -> String? {
        let failingInBackground = refused && background != nil
        if !failingInBackground {
            if session.isWorking { return "Its turn is under way; it can restart once the turn ends." }
            if !session.isIdle { return "It has not finished a turn yet; it can restart once one ends." }
        }
        if let background {
            if !failingInBackground, !background.transcriptsQuiet(now: now) {
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
        case .busy: "\(session) was not restarted: its transcripts, a shell under it or work its terminal reports are still active."
        case .notInTerminal: "\(session) was not restarted: it does not run in agterm."
        case .refused: "\(session) was not restarted: agterm did not take the text."
        case .notStopped: "\(session) was not restarted: its background session could not be stopped."
        case .cancelled: "\(session) was not restarted: asked to exit, it still had background work running, so it was kept running."
        }
    }

    /// Ends an idle session that reads no slot and resumes it from its
    /// agterm session, so the launcher gives it a slot of its own. A
    /// session in a background worker is stopped with the CLI's stop
    /// command and resumed in its attach client's terminal, judged again
    /// from a fresh read of the processes; one refused at a usage limit
    /// since its last served request (`sessionRefusals`) counts as idle
    /// (`restartBlocker`). At the user's request, from the usage tab, for a
    /// background session stuck on an account that can no longer serve it
    /// (`handleStuckBackgroundSessions`), and for every session outside a
    /// slot once it is idle (`restartUnisolatedSessions`), which passes
    /// `automaticEvent`: the event for a restart typed, given the session's
    /// name, with any other outcome logged rather than recorded, since the
    /// restart is tried again. Returns whether it was typed.
    @discardableResult
    func restartInOwnSlot(_ sessionID: String, automaticEvent: ((String) -> String)? = nil) async -> Bool {
        guard let (provider, session) = liveSession(sessionID), let slots = SessionSlots(provider) else { return false }
        let outcome: SessionTerminalActions.Outcome
        if let support = slots.background, backgroundProcesses(provider).isWorker(session.processID) {
            await refreshSlotProcesses()
            guard let state = await backgroundSessionState(session, provider: provider) else { return false }
            let stopper = slots.realExecutable(preferred: slots.isolation.preferredExecutable) ?? slots.executable
            outcome = await SessionTerminalActions.restartBackground(
                session, state: state, isolation: slots.isolation, stopper: stopper, support: support,
                control: backgroundSessionControl, terminal: sessionTerminal, refused: sessionRefusals[sessionID] != nil
            )
        } else {
            outcome = await SessionTerminalActions.restartInOwnSlot(session, isolation: slots.isolation,
                                                                    terminal: sessionTerminal)
        }
        let name = Self.eventName(of: session)
        if let automaticEvent {
            if outcome == .typed {
                failoverEvents.record(provider, automaticEvent(name))
            } else {
                terminalLog.info("[restartInOwnSlot] \(Self.restartEvent(outcome, session: name))")
            }
        } else {
            failoverEvents.record(provider, Self.restartEvent(outcome, session: name))
        }
        return outcome == .typed
    }

    /// `restartInOwnSlot` for every idle unisolated session of `provider`
    /// in agterm. Returns how many were restarted.
    @discardableResult
    func restartIdleUnisolatedSessions(_ provider: AIProviderType) async -> Int {
        var restarted = 0
        for session in unisolatedSessions[provider] ?? []
        where Self.restartBlocker(session, terminal: unisolatedTerminals[session.sessionID],
                                  background: backgroundSessionStates[session.sessionID],
                                  refused: sessionRefusals[session.sessionID] != nil) == nil {

            if await restartInOwnSlot(session.sessionID) { restarted += 1 }
        }
        return restarted
    }

    /// The sessions among `sessions` (those outside a slot of their own)
    /// that `restartUnisolatedSessions` restarts now: not in the CLI's
    /// background service (`background`), whose restart turns the session
    /// into a terminal one and stays the user's choice or
    /// `handleStuckBackgroundSessions`'s; idle between turns in agterm
    /// (`restartBlocker` with their `terminals`); and not restarted by any
    /// rule within `stuckRestartSpacing` (`lastRestart`).
    nonisolated static func automaticRestarts(_ sessions: [AgentSession], background: Set<String>,
                                              terminals: [String: String], lastRestart: [String: Date],
                                              now: Date) -> [String] {
        sessions.filter { session in
            let id = session.sessionID
            return !background.contains(id)
                && (lastRestart[id].map { now.timeIntervalSince($0) >= stuckRestartSpacing } ?? true)
                && restartBlocker(session, terminal: terminals[id], now: now) == nil
        }.map(\.sessionID)
    }

    /// The account a session `restartUnisolatedSessions` restarts is named
    /// for in the resume file: its pin when it has one, else, unless it
    /// takes back a slot offered to it (`takesBack`, which serves its
    /// pin or the account it had), the account whose sign-in it shares
    /// (`shared`), so it continues where it ran.
    nonisolated static func automaticRestartAccount(pinned: UUID?, takesBack: Bool, shared: UUID?) -> UUID? {
        if let pinned { return takesBack ? nil : pinned }
        return takesBack ? nil : shared
    }

    /// The event for a session `restartUnisolatedSessions` restarted.
    nonisolated static func automaticRestartEvent(session: String, takesBack: Bool, account: String?, pinned: Bool) -> String {
        let continues = takesBack ? "it continues in the slot it had before"
            : account.map { pinned ? "it continues on \($0), where it is pinned" : "it continues on \($0)" }
            ?? "it continues on the account its slot is given"
        return "Restarted \(session) in a slot of its own without being asked: it ran on the shared sign-in, so it could not be moved on its own; \(continues)."
    }

    /// Restarts each session outside a slot of its own that
    /// `automaticRestarts` picks in a slot of its own, typed into its
    /// agterm session as `restartInOwnSlot` types it, so each rebuilds its
    /// prompt cache at most once there and can then be moved alone. A
    /// session whose slot AccountDock offers back to it
    /// (`SessionSlotState.reclaimOffered`) takes that slot back through the
    /// resume file; any other is named in it (`slotRestartResumes`) for
    /// `automaticRestartAccount`: a pinned session always for its pin. Each
    /// restart is an event. Called on every quota cycle after
    /// `noteUnisolatedSessions`, which lists the sessions and their
    /// terminals.
    func restartUnisolatedSessions(now: Date = Date()) async {
        var live = Set<String>()
        for provider in AIProviderType.isolatedProviders where sessionSlotsInUse(provider) {
            live.formUnion((liveSessions[provider] ?? []).map(\.sessionID))
            guard failoverConfig.policy(for: provider).restartSessionsOutsideSlots else { continue }
            var last = unisolatedRestartAt
            last.merge(stayingRestartAt) { max($0, $1) }
            last.merge(stuckBackgroundRestartedAt) { max($0, $1) }
            let due = Self.automaticRestarts(unisolatedSessions[provider] ?? [], background: Set(backgroundSessionStates.keys),
                                             terminals: unisolatedTerminals, lastRestart: last, now: now)
            guard !due.isEmpty else { continue }
            let offered = Set((sessionSlotStates[provider]?.reclaimOffered ?? [:]).values)
            let shared = liveCredentialOwners[provider]?.account ?? activeAccount(for: provider)?.id
            for id in due {
                unisolatedRestartAt[id] = now
                let pinned = sessionPins.account(of: id)
                let takesBack = offered.contains(id)
                let target = Self.automaticRestartAccount(pinned: pinned, takesBack: takesBack, shared: shared)
                var named = false
                if let target, slotRestartResumes[id] == nil {
                    slotRestartResumes[id] = SlotRestartResume(provider: provider, account: target, at: now)
                    named = true
                }
                let account = target.flatMap { target in accounts.first { $0.id == target } }.map { messageName($0) }
                let typed = await restartInOwnSlot(id, automaticEvent: { name in
                    Self.automaticRestartEvent(session: name, takesBack: takesBack, account: account, pinned: pinned != nil)
                })
                if !typed, named { slotRestartResumes[id] = nil }
            }
        }
        unisolatedRestartAt = unisolatedRestartAt.filter { live.contains($0.key) }
    }

    /// The running session with `id` and its provider.
    func liveSession(_ id: String) -> (AIProviderType, AgentSession)? {
        for (provider, sessions) in liveSessions {
            if let session = sessions.first(where: { $0.sessionID == id }) { return (provider, session) }
        }
        return nil
    }
}
