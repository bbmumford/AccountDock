import AppKit

/// The sessions each provider's CLI is running, from the lifecycle records
/// every provider's hooks write, and the account serving each one.
extension AppState {
    /// Reads every provider's live sessions and assigns each to the account
    /// serving it: the one serving its slot, the one the router last served
    /// it from, or else its provider's active account. Sessions the router
    /// served in the last ten minutes are counted even without a lifecycle
    /// record.
    func refreshSessions(now: Date = Date()) {
        var live: [AIProviderType: [AgentSession]] = [:]
        var byAccount: [UUID: Set<String>] = [:]
        for provider in AIProviderType.implementedProviders {
            let sessions = AgentSessions.live(provider, now: now)
            live[provider] = sessions
            let active = activeAccount(for: provider)?.id
            for session in sessions {
                if let account = session.processID.flatMap(slotAccount(forProcess:))
                    ?? routedSessionSeen[session.sessionID]?.account ?? active {
                    byAccount[account, default: []].insert(session.sessionID)
                }
            }
        }
        for (account, sessions) in routedSessions {
            byAccount[account, default: []].formUnion(sessions)
        }
        if live != liveSessions { liveSessions = live }
        if byAccount != accountSessions { accountSessions = byAccount }
    }

    /// Live sessions of a provider AccountDock pauses whose CLI started
    /// before the pause hook was installed. A CLI reads its hooks when it
    /// starts, so these run without the gate: a pause cannot hold them, and
    /// they reach the limit until they are restarted.
    func sessionsWithoutGate(_ provider: AIProviderType) -> [AgentSession] {
        guard pausingProviders.contains(provider), let installed = AgentPauseGate.installedAt(provider) else { return [] }
        return (liveSessions[provider] ?? []).filter { session in
            session.processID.flatMap(ProcessAncestry.startTime(of:)).map { $0 < installed } ?? false
        }
    }

    /// Sessions of `provider` whose turn is under way.
    func workingSessionCount(_ provider: AIProviderType) -> Int {
        liveSessions[provider]?.filter(\.isWorking).count ?? 0
    }
}

/// A session held in the pause gate now, which the user can resume on its
/// own from the pause banner or with `SessionResumeShortcut`.
struct WaitingSession: Identifiable, Equatable {
    let provider: AIProviderType
    let sessionID: String
    /// The gate process holding it; its ancestors include the terminal app
    /// showing the session.
    let gateProcess: Int32?
    let workingDirectory: String?

    var id: String { "\(provider.capabilities.storageKey)-\(sessionID)" }

    /// The provider and the folder the session works in, as menus show it.
    var label: String {
        let name = provider.capabilities.displayName
        guard let workingDirectory else { return "\(name) session \(sessionID.prefix(8))" }
        return "\(name) session in \((workingDirectory as NSString).abbreviatingWithTildeInPath)"
    }
}

extension AppState {
    /// Sessions waiting in the gate now, for `provider` or for every provider
    /// with a pause gate, excluding those already resumed.
    func waitingSessions(_ provider: AIProviderType? = nil) -> [WaitingSession] {
        let providers = provider.map { [$0] } ?? AgentPauseGate.providers
        return providers.flatMap { provider -> [WaitingSession] in
            let gates = AgentPauseGate.waitingGates(provider)
            let resumed = AgentPauseGate.resumedSessions(provider)
            let records = AgentSessions.records(provider)
            return AgentPauseGate.waitingSessions(provider).subtracting(resumed).sorted().map { session in
                WaitingSession(provider: provider, sessionID: session, gateProcess: gates[session],
                               workingDirectory: records[session]?.workingDirectory)
            }
        }
    }

    /// Lets one session go on while every other session stays held. Resumed
    /// onto an account with room, it is held again once that account nears
    /// its limit (`reholdUserResumedSessions`); resumed onto one already at
    /// its limit, it runs for the rest of the pause and may reach it. A
    /// later pause holds it again either way.
    func resumeSession(_ session: WaitingSession) {
        let provider = session.provider
        AgentPauseGate.resume(provider, session: session.sessionID)
        if let account = servingAccount(provider, session: session.sessionID),
           !isNearLimit(account, planner: FailoverPlanner(settings: plannerSettings(provider))) {
            userResumes[provider, default: [:]][session.sessionID] = account.id
        }
        if var pause = AgentPauseGate.read(provider), pause.sessions.contains(session.sessionID) {
            pause.sessions.removeAll { $0 == session.sessionID }
            AgentPauseGate.write(pause, for: provider)
        }
        refreshPauseStatus(provider)
        failoverEvents.record(provider, "Resumed the \(session.label) at the user's request; other sessions stay paused.")
    }

    /// The resume shortcut: resumes the one waiting session shown by the
    /// frontmost app, found through the gate process's ancestors. When that
    /// app shows several, or none, a menu lists the candidates instead, so
    /// a session in another window is never resumed unasked.
    func resumeFrontmostSession() {
        let waiting = waitingSessions()
        guard !waiting.isEmpty else {
            NSSound.beep()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        var candidates = waiting
        if let front, front.processIdentifier != NSRunningApplication.current.processIdentifier {
            let shown = waiting.filter { session in
                session.gateProcess.map { ProcessAncestry.isDescendant($0, of: front.processIdentifier) } ?? false
            }
            if shown.count == 1 {
                resumeSession(shown[0])
                return
            }
            if !shown.isEmpty { candidates = shown }
        }
        SessionResumeMenu.show(candidates, returningTo: front) { [weak self] in self?.resumeSession($0) }
    }
}
