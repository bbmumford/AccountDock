import AppKit

/// The sessions each provider's CLI is running, from the lifecycle records
/// every provider's hooks write, and the account serving each one.
extension AppState {
    /// Reads every provider's live sessions and assigns each to the account
    /// serving it (`SessionAttribution`). Sessions the router served within
    /// `SessionAttribution.routerWindow` are counted even without a
    /// lifecycle record.
    func refreshSessions(now: Date = Date()) {
        var live: [AIProviderType: [AgentSession]] = [:]
        var byAccount: [UUID: Set<String>] = [:]
        for provider in AIProviderType.implementedProviders {
            let sessions = AgentSessions.live(provider, now: now)
            live[provider] = sessions
            let attribution = sessionAttribution(provider, now: now)
            for session in sessions {
                if let account = attribution.decide(session: session.sessionID, process: session.processID)?.account {
                    byAccount[account, default: []].insert(session.sessionID)
                }
            }
        }
        for (account, sessions) in routedSessions {
            byAccount[account, default: []].formUnion(sessions)
        }
        if live != liveSessions { liveSessions = live }
        if byAccount != accountSessions { accountSessions = byAccount }
        // Names of sessions that have ended are dropped once there are many.
        if sessionNames.count > 256 {
            let running = Set(live.values.flatMap { $0.map(\.sessionID) })
            sessionNames = sessionNames.filter { running.contains($0.key) }
        }
        // A refusal is kept while its session runs.
        if !sessionRefusals.isEmpty {
            let running = Set(live.values.flatMap { $0.map(\.sessionID) })
            let kept = sessionRefusals.filter { running.contains($0.key) }
            if kept.count != sessionRefusals.count { sessionRefusals = kept }
        }
    }

    /// What an account card shows when the pointer rests on its session
    /// count: one line for each of `sessions`, in name order.
    func sessionSummary(_ sessions: Set<String>, now: Date = Date()) -> String {
        let records = liveSessions.values.flatMap { $0 }.reduce(into: [String: AgentSession]()) { $0[$1.sessionID] = $1 }
        return sessions.map { id in
            let label = Self.sessionLabel(id: id, name: sessionNames[id], directory: records[id]?.workingDirectory,
                                          model: sessionModel(id, now: now).map { CostParser.shortModelName($0) })
            guard let refusal = sessionRefusals[id] else { return label }
            let by = accounts.first { $0.id == refusal.account }.map { messageName($0) } ?? "its account"
            return "\(label) — refused at a limit on \(by) at \(refusal.at.formatted(date: .omitted, time: .shortened)), not served since"
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: "\n")
    }

    /// One session as `sessionSummary` lists it: the name it shows for
    /// itself, else its folder, else the start of its ID, then the model it
    /// uses when that is known.
    nonisolated static func sessionLabel(id: String, name: String?, directory: String?, model: String?) -> String {
        let folder = directory.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let label = name ?? folder ?? "session \(id.prefix(8))"
        return model.map { "\(label) · \($0)" } ?? label
    }

    /// The provider's `SessionAttribution` from what AccountDock knows now:
    /// the slot each process reads, the router's recent sessions, what each
    /// session's status line named, the requests recorded per session, the
    /// last signal, the live credential's owner and the active account.
    func sessionAttribution(_ provider: AIProviderType, now: Date = Date()) -> SessionAttribution {
        var owner: UUID??
        return SessionAttribution(
            slotAccounts: slotDirectoryByProcess.compactMapValues { slotDirectoryServing[$0] },
            routerSeen: routedSessionSeen.mapValues { SessionAttribution.Observation(account: $0.account, at: $0.at) },
            lastServed: sessionServedBy,
            recordedRequests: sessionRates.entries.mapValues { SessionAttribution.Observation(account: $0.account, at: $0.lastSeen) },
            signalledAt: sessionsSignalledAt[provider],
            liveCredentialOwner: { [weak self] in
                if owner == nil { owner = .some(self?.liveCredentialOwner(provider)) }
                return owner ?? nil
            },
            activeAccount: activeAccount(for: provider)?.id,
            now: now
        )
    }

    /// The account serving one session of `provider`, and what decided it.
    func servingDecision(_ provider: AIProviderType, session: String, now: Date = Date()) -> SessionAttribution.Decision? {
        let process = liveSessions[provider]?.first { $0.sessionID == session }?.processID
        return sessionAttribution(provider, now: now).decide(session: session, process: process)
    }

    /// The process of each live session of `provider`, for
    /// `SessionAttribution.decide`.
    func sessionProcesses(_ provider: AIProviderType) -> [String: Int32] {
        (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            if let process = session.processID { result[session.sessionID] = process }
        }
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
