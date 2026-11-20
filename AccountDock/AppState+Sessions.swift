import AppKit

/// The sessions each provider's CLI is running, from the lifecycle records
/// every provider's hooks write, and the account serving each one.
extension AppState {
    /// Reads every provider's live sessions and assigns each to the account
    /// serving it (`SessionAttribution`). Sessions the router served within
    /// `SessionAttribution.routerWindow` are counted even without a
    /// lifecycle record. A CLI that keeps its own registry of the sessions
    /// its processes hold (`CLISessionRegistry`) has it read too, so a
    /// session quiet for longer than `AgentSessions.liveLifetime`, or one
    /// whose hooks have not written for its process, is still live.
    func refreshSessions(now: Date = Date()) {
        var live: [AIProviderType: [AgentSession]] = [:]
        var byAccount: [UUID: Set<String>] = [:]
        for provider in AIProviderType.implementedProviders {
            let registry = CLISessionRegistry.read(provider) ?? [:]
            let sessions = Self.excludingNonSessions(AgentSessions.live(provider, now: now, registry: registry),
                                                     background: backgroundProcesses(provider))
            live[provider] = sessions
            let attribution = sessionAttribution(provider, now: now)
            for session in sessions {
                if let decision = attribution.decide(session: session.sessionID, process: session.processID) {
                    byAccount[decision.account, default: []].insert(session.sessionID)
                    recordServed(provider, session: session, decision: decision, now: now)
                }
            }
        }
        for (account, sessions) in routedSessions {
            byAccount[account, default: []].formUnion(sessions)
            for session in sessions {
                guard let provider = accounts.first(where: { $0.id == account })?.provider else { continue }
                credentialAudit.recordServed(provider, session: session, account: account, source: "router",
                                             model: sessionModel(session, now: now),
                                             observedAt: routedSessionSeen[session]?.at)
            }
        }
        if live != liveSessions { liveSessions = live }
        if byAccount != accountSessions { accountSessions = byAccount }
        // Names of sessions that have ended are dropped once there are many.
        if sessionNames.count > 256 {
            let running = Set(live.values.flatMap { $0.map(\.sessionID) })
            sessionNames = sessionNames.filter { running.contains($0.key) }
        }
        // A refusal and a credential flag are kept while their session runs.
        if !sessionRefusals.isEmpty || !flaggedCredentialProcesses.isEmpty || !refusalEventsNoted.isEmpty {
            let running = Set(live.values.flatMap { $0.map(\.sessionID) })
            let kept = sessionRefusals.filter { running.contains($0.key) }
            if kept.count != sessionRefusals.count { sessionRefusals = kept }
            refusalEventsNoted = refusalEventsNoted.filter { running.contains($0.key) }
            let flagged = Self.flagsOfRunningSessions(flaggedCredentialProcesses, live: running)
            if flagged.count != flaggedCredentialProcesses.count { flaggedCredentialProcesses = flagged }
        }
    }

    /// `sessions` less any whose record names a process of the CLI's
    /// background service that is no session, such as an attach client
    /// (`BackgroundSessionProcesses.nonSessions`): the session it shows
    /// runs in a worker with a record of its own.
    nonisolated static func excludingNonSessions(_ sessions: [AgentSession],
                                                 background: BackgroundSessionProcesses) -> [AgentSession] {
        guard !background.nonSessions.isEmpty else { return sessions }
        return sessions.filter { session in session.processID.map { !background.nonSessions.contains($0) } ?? true }
    }

    /// What an account card shows when the pointer rests on its session
    /// count: one line for each of `sessions`, in name order.
    func sessionSummary(_ sessions: Set<String>, now: Date = Date()) -> String {
        var records = liveSessions.values.flatMap { $0 }.reduce(into: [String: AgentSession]()) { $0[$1.sessionID] = $1 }
        // A session not running now is named from its last record, so a list
        // that holds it (pins, refusals) still shows its folder.
        for id in sessions where records[id] == nil {
            for provider in AIProviderType.implementedProviders {
                if let record = AgentSessions.records(provider)[id] { records[id] = record; break }
            }
        }
        return sessions.map { id in
            let label = Self.sessionLabel(id: id, name: sessionNames[id], directory: records[id]?.workingDirectory,
                                          model: sessionModel(id, now: now).map { CostParser.shortModelName($0) })
            guard let refusal = sessionRefusals[id] else { return label }
            let by = accounts.first { $0.id == refusal.account }.map { messageName($0) } ?? "its account"
            return "\(label) — refused at a limit on \(by) at \(UsageFormat.clock(refusal.at)), not served since"
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
    /// before the pause hook was installed. A CLI that reads its hooks only
    /// when it starts runs these without the gate: a pause cannot hold them,
    /// and they reach the limit until they are restarted. None for a CLI that
    /// picks up hooks while running (`PauseGateSupport.readsHooksLive`).
    func sessionsWithoutGate(_ provider: AIProviderType) -> [AgentSession] {
        guard gatedProviders.contains(provider), provider.capabilities.pauseGate?.readsHooksLive != true,
              let installed = AgentPauseGate.installedAt(provider) else { return [] }
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
    /// showing the session. Nil while it has not yet reached the gate.
    let gateProcess: Int32?
    let workingDirectory: String?
    /// The name the session shows for itself (`AppState.sessionNames`).
    var name: String? = nil
    /// The account the session runs on: its slot's, else the active one.
    var account: UUID? = nil
    /// When that account is expected to serve it again; nil when unknown.
    var resumeAt: Date? = nil

    var id: String { "\(provider.capabilities.storageKey)-\(sessionID)" }

    /// Whether it is held in the gate now rather than due to stop at its
    /// next tool call or turn.
    var isWaiting: Bool { gateProcess != nil }

    /// The session's own name, else the provider and its folder, as menus
    /// show it.
    var label: String {
        if let name { return name }
        let provider = provider.capabilities.displayName
        guard let workingDirectory else { return "\(provider) session \(sessionID.prefix(8))" }
        return "\(provider) session in \((workingDirectory as NSString).abbreviatingWithTildeInPath)"
    }
}

extension AppState {
    /// Every session the provider's current pause holds: those waiting in
    /// the gate now and those it stops at their next tool call or turn,
    /// excluding those already resumed. The pause banner and each account
    /// card's session list offer to resume each one on its own
    /// (`resumeSession`, which the gate honours whether or not the session
    /// has reached it yet).
    func pausedSessions(_ provider: AIProviderType) -> [WaitingSession] {
        let now = Date()
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let active = activeAccount(for: provider)?.id
        return Self.pausedSessions(
            provider, pause: AgentPauseGate.read(provider), gates: AgentPauseGate.waitingGates(provider),
            resumed: AgentPauseGate.resumedSessions(provider), records: AgentSessions.records(provider),
            running: Set((liveSessions[provider] ?? []).map(\.sessionID)), names: sessionNames,
            account: { self.slotAccount(forSession: $0, provider: provider) ?? active },
            resumeAt: { id in
                self.accounts.first { $0.id == id }.flatMap { planner.availableAt(self.quotaState(for: $0, now: now), now: now) }
            }
        )
    }

    /// The sessions `pause` holds, from the gate's own files: those waiting
    /// in it now (`gates`, by the process ID each `.waiting` marker holds)
    /// and those listed, or every `running` one while the pause holds every
    /// new turn, less those resumed. Each names the account it runs on
    /// (`account`) and when that account serves it again (`resumeAt`, else
    /// the pause's own estimate). Reads no state of the app's, so a pause
    /// found after a relaunch is shown the same way.
    nonisolated static func pausedSessions(
        _ provider: AIProviderType, pause: AgentPauseGate.PauseFile?, gates: [String: Int32], resumed: Set<String>,
        records: [String: AgentSession], running: Set<String>, names: [String: String],
        account: (String) -> UUID?, resumeAt: (UUID) -> Date?
    ) -> [WaitingSession] {
        guard let pause else { return [] }
        let held = Set(pause.sessions).union(gates.keys)
        // A pause that holds new turns holds every running session.
        let all = pause.holdsNewTurns == true ? held.union(running) : held
        return all.subtracting(resumed).map { session in
            let on = account(session)
            return WaitingSession(provider: provider, sessionID: session, gateProcess: gates[session],
                                  workingDirectory: records[session]?.workingDirectory, name: names[session],
                                  account: on, resumeAt: on.flatMap(resumeAt) ?? pause.resumeAt)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

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

    /// Lets one session go on while every other session stays held. The
    /// play is one release (`UserResume`), recorded against the account
    /// serving the session whether or not that account is at its limit:
    /// once the account the session runs on, that one or the one a slot
    /// move takes it to, is at or near its limit, the session is held again
    /// (`reholdUserResumedSessions`, `holdAtLimit`), except for the limit of
    /// the account it was played on while it stays there. A later pause
    /// holds it again too. When it was the last session the pause held, the
    /// pause ends (`AgentPauseGate.playOne`), as "Resume all" would end it.
    /// `anyway` when the user pressed play a second time although no
    /// account has room (`pressPlay`): the event says it will be refused.
    /// The user's controls reach it through `pressPlay`.
    func resumeSession(_ session: WaitingSession, anyway: Bool = false) {
        let provider = session.provider
        let chosenOnly = AgentPauseGate.read(provider)?.holdsOnlyChosenSessions == true
        let running = Set((liveSessions[provider] ?? []).map(\.sessionID))
        // A pinned session played while its account is at its threshold or
        // limit runs on there until the account has room again
        // (`holdPinnedSessionsAtLimit`).
        if let account = pinnedSessionAccounts(provider)[session.sessionID],
           pinnedHold(account, planner: FailoverPlanner(settings: plannerSettings(provider)), now: Date()) != nil {
            pinnedHoldsPlayed[session.sessionID] = account
        }
        notePlayedWait(provider, session: session.sessionID)
        let ended = AgentPauseGate.playOne(provider, session: session.sessionID, running: running,
                                           continuation: continuationDescription(provider))
        if ended {
            endPause(provider, keepingChosen: false)
            if !chosenOnly {
                suspensionContexts[provider] = nil
                notePauseOverride(provider)
            }
            failoverEvents.record(provider, anyway
                ? Self.playAnywayEvent(session.label) + " No session is paused any more, so the pause is over."
                : "Resumed the \(session.label) at the user's request; no session is paused any more, so the pause is over.")
            objectWillChange.send()
            return
        }
        if let account = servingAccount(provider, session: session.sessionID)
            ?? session.account.flatMap({ id in accounts.first { $0.id == id } }) {
            let spent = isNearLimit(account, planner: FailoverPlanner(settings: plannerSettings(provider)))
            userResumes[provider, default: [:]][session.sessionID] = UserResume(playedOn: account.id, spent: spent)
        }
        refreshPauseStatus(provider)
        failoverEvents.record(provider, anyway ? Self.playAnywayEvent(session.label)
                                  : "Resumed the \(session.label) at the user's request; other sessions stay paused.")
        // The pause file changed though the pause's counts may not have.
        objectWillChange.send()
    }

    /// The resume shortcut: plays the one waiting session shown by the
    /// frontmost app, found through the gate process's ancestors, by the
    /// same two-step rule as the play buttons (`pressPlay`). When that app
    /// shows several, or none, a menu lists the candidates instead, so a
    /// session in another window is never resumed unasked; a candidate
    /// whose first press found no room shows why there.
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
                pressPlayFromShortcut(shown[0])
                return
            }
            if !shown.isEmpty { candidates = shown }
        }
        let notes = candidates.reduce(into: [String: String]()) { notes, session in
            if let note = playNotes[session.sessionID] { notes[session.sessionID] = note.text }
        }
        SessionResumeMenu.show(candidates, notes: notes, returningTo: front) { [weak self] in
            self?.pressPlayFromShortcut($0)
        }
    }
}
