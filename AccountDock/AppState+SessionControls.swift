import Foundation

/// A session the user moved by hand, pinned to `account` once its slot
/// serves it (`AppState.settleMovePins`).
struct MovePin: Equatable {
    var provider: AIProviderType
    var account: UUID
    var at: Date
}

/// One running session as the Sessions page lists it.
struct SessionRow: Identifiable, Equatable {
    let provider: AIProviderType
    /// The session ID.
    let id: String
    /// Its name, else its folder, then its model (`AppState.sessionLabel`).
    let label: String
    /// The account serving it: its slot's, or the shared sign-in and the
    /// active account it follows.
    let account: String
    let state: SessionRowState
    let pinned: Bool
    /// It reads a one-session slot of its own.
    let inSlot: Bool
    /// A pause can hold it: its provider has a pause gate and it started
    /// after the gate was installed (`AppState.sessionsWithoutGate`).
    let gated: Bool
    /// The user paused it one at a time (`AgentPauseGate.PauseFile.chosen`):
    /// it waits until played, whatever its account's room.
    var pausedByYou = false
    /// While a pause holds it for its account's limit, when that account is
    /// expected to serve it again (`AppState.pausedSessions`).
    var resumeAt: Date? = nil
}

/// One provider's part of the Sessions page: its running sessions, each
/// with its move menu, the heading's status line and which heading
/// controls apply. `AppState.sessionsSection` builds it from the live
/// sessions and the pause files, and `SessionsView` draws it; the
/// screenshot renderer hands that view sample sections instead.
struct SessionsSection: Identifiable, Equatable {
    struct Entry: Identifiable, Equatable {
        let row: SessionRow
        /// Its move menu (`AppState.sessionMoveMenu`); nil while the
        /// provider's sessions run in no slots.
        let moveMenu: SessionMoveMenu?
        var id: String { row.id }
    }

    let provider: AIProviderType
    let entries: [Entry]
    /// How many sessions are paused and since when
    /// (`AppState.sessionPauseLine`).
    let pauseLine: String
    let canPauseAll: Bool
    let canResumeAll: Bool
    /// Its sessions run in one-session slots, so they can be rebalanced
    /// (`AppState.rebalanceAvailable`).
    let canRebalance: Bool
    var id: AIProviderType { provider }
}

/// The per-session controls of the Sessions page and the account cards'
/// session lists: pausing and playing one session or all of a provider's,
/// moving one by hand, and the pins those moves leave.
extension AppState {
    /// How long a move's pin waits for the session to reach its
    /// destination; a move by restarting waits for the session to be idle.
    nonisolated static let movePinLifetime: TimeInterval = 6 * 60 * 60

    /// The providers the Sessions page lists: those with a pause gate or
    /// with sessions in one-session slots.
    var sessionControlProviders: [AIProviderType] {
        AIProviderType.implementedProviders.filter {
            $0.capabilities.pauseGate != nil || $0.capabilities.sessionIsolation != nil
        }
    }

    /// Every running session of `provider`, one row each, in label order.
    func sessionRows(_ provider: AIProviderType, now: Date = Date()) -> [SessionRow] {
        let sessions = liveSessions[provider] ?? []
        let slotsInUse = sessionSlotsInUse(provider)
        let slotAccounts = sessions.reduce(into: [String: UUID]()) { result, session in
            result[session.sessionID] = slotAccount(ofSession: session.sessionID, provider: provider)
        }
        let states = SessionRowState.derive(
            provider, sessions: sessions.map(\.sessionID),
            refused: Set(sessions.map(\.sessionID).filter { sessionRefusals[$0] != nil }),
            isolated: slotsInUse ? Set(slotAccounts.keys) : nil
        )
        let ungated = Set(sessionsWithoutGate(provider).map(\.sessionID))
        let active = activeAccount(for: provider)
        // Each held session's account and expected resume, as the pause
        // banner lists them.
        let held = pausedSessions(provider).reduce(into: [String: WaitingSession]()) { $0[$1.sessionID] = $1 }
        let chosen = Set(AgentPauseGate.read(provider)?.chosenListed ?? [])
        func name(_ id: UUID?) -> String? { id.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } }
        return sessions.map { session in
            let id = session.sessionID
            let account: String
            if let slot = slotAccounts[id] {
                account = name(slot) ?? "an account"
            } else if slotsInUse {
                account = "shared sign-in · " + (active.map { messageName($0) } ?? "no active account")
            } else {
                account = name(servingDecision(provider, session: id, now: now)?.account)
                    ?? active.map { messageName($0) } ?? "unknown account"
            }
            return SessionRow(
                provider: provider, id: id,
                label: Self.sessionLabel(id: id, name: sessionNames[id], directory: session.workingDirectory,
                                         model: sessionModel(id, now: now).map { CostParser.shortModelName($0) }),
                account: account, state: states[id] ?? .running, pinned: sessionPins.isPinned(id),
                inSlot: slotAccounts[id] != nil,
                gated: provider.capabilities.pauseGate != nil && !ungated.contains(id),
                pausedByYou: chosen.contains(id),
                resumeAt: chosen.contains(id) ? nil : held[id]?.resumeAt
            )
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// One session's state, for a list showing a session at a time, such as
    /// an account card's.
    func sessionRowState(_ provider: AIProviderType, session: String) -> SessionRowState {
        let isolated: Set<String>? = sessionSlotsInUse(provider)
            ? (slotAccount(ofSession: session, provider: provider) != nil ? [session] : []) : nil
        return SessionRowState.derive(provider, sessions: [session],
                                      refused: sessionRefusals[session] != nil ? [session] : [],
                                      isolated: isolated)[session] ?? .running
    }

    /// The Sessions page's part for `provider` (`SessionsSection`).
    func sessionsSection(_ provider: AIProviderType, now: Date = Date()) -> SessionsSection {
        let rows = sessionRows(provider, now: now)
        return SessionsSection(
            provider: provider,
            entries: rows.map { SessionsSection.Entry(row: $0, moveMenu: sessionMoveMenu(provider, session: $0.id, now: now)) },
            pauseLine: sessionPauseLine(provider, rows: rows),
            canPauseAll: canPauseAllSessions(provider, rows: rows),
            canResumeAll: canResumeAllSessions(provider),
            canRebalance: rebalanceAvailable(provider)
        )
    }

    /// The provider header's status line: how many of `rows` are paused
    /// and since when, or that none is.
    func sessionPauseLine(_ provider: AIProviderType, rows: [SessionRow]) -> String {
        Self.sessionPauseLine(pausedAt: AgentPauseGate.read(provider)?.pausedAt, rows: rows)
    }

    /// The status line for `rows` under a pause that began at `pausedAt`,
    /// nil while no pause is in effect; shared with the screenshot
    /// renderer's sample sections so both read alike.
    static func sessionPauseLine(pausedAt: Date?, rows: [SessionRow]) -> String {
        guard let pausedAt else {
            return rows.isEmpty ? "No running sessions" : "\(rows.count) running · none paused"
        }
        let paused = rows.filter(\.state.isPaused).count
        return "\(paused) of \(rows.count) paused · since \(UsageFormat.clock(pausedAt))"
    }

    /// Whether "Pause all" would hold anything not held already: no pause
    /// holding new turns is in effect, or one is and a session runs free.
    func canPauseAllSessions(_ provider: AIProviderType, rows: [SessionRow]) -> Bool {
        guard gatedProviders.contains(provider) else { return false }
        return AgentPauseGate.read(provider)?.holdsNewTurns != true || rows.contains { !$0.state.isPaused }
    }

    /// Whether "Resume all" would release anything: a pause is in effect,
    /// or processes are stopped.
    func canResumeAllSessions(_ provider: AIProviderType) -> Bool {
        AgentPauseGate.read(provider) != nil || hasPausedAgents(provider)
    }

    // MARK: - One session

    /// Holds one session at its next tool call and new turn while the
    /// others keep running: a pause of the user's listing only it when no
    /// pause is in effect, which only the user ends; otherwise the pause in
    /// effect holds it again (`AgentPauseGate.pauseOne`).
    func pauseSession(_ provider: AIProviderType, session sessionID: String) {
        guard gatedProviders.contains(provider) else { return }
        // The hook may not be installed yet for a CLI just set up.
        pauseGateSynchronizedAt = nil
        synchronizePauseGateIfDue()
        let started = AgentPauseGate.pauseOne(provider, session: sessionID)
        userResumes[provider]?[sessionID] = nil
        sessionAdmissions[provider]?[sessionID] = nil
        refreshPauseStatus(provider)
        let name = liveSession(sessionID).map { Self.eventName(of: $0.1) } ?? "session \(sessionID.prefix(8))"
        failoverEvents.record(provider, started
            ? "Paused \(name) at the user's request: it waits at its next tool call and its new turns wait at their start, while other sessions keep running, until you play it."
            : "Paused \(name) again at the user's request: the pause in effect holds it at its next tool call.")
        // The pause file changed though the pause's counts may not have.
        objectWillChange.send()
    }

    /// Lets one held session go on (`resumeSession`), ending the pause when
    /// it held no other session.
    func playSession(_ provider: AIProviderType, session sessionID: String) {
        guard let held = pausedSessions(provider).first(where: { $0.sessionID == sessionID }) else { return }
        resumeSession(held)
    }

    // MARK: - Moving by hand

    struct SessionMoveOutcome: Equatable {
        var ok: Bool
        var detail: String
        var account: Account? = nil
    }

    /// Where balancing would place `sessionID` now
    /// (`SessionMoveRules.balancingChoice`), among the accounts rebalancing
    /// weighs (`rebalanceAccounts`), with the provider's other slot sessions
    /// where they run. A session on the shared sign-in is weighed as one on
    /// the account serving it, and is left out of the shared group. Nil
    /// while the provider's sessions run in no slots.
    func balancingChoice(_ sessionID: String, provider: AIProviderType, now: Date = Date()) -> UUID? {
        guard sessionSlotsInUse(provider), let slots = SessionSlots(provider) else { return nil }
        let (pacerAccounts, destinations) = rebalanceAccounts(provider, now: now)
        let running = slotRebalanceSessions(provider, slots: slots, now: now)
        // A session on the shared sign-in, weighed at its own rate as
        // `slotRebalanceSessions` weighs a slot session.
        func shared() -> SessionPacer.RebalanceSession? {
            guard let account = servingDecision(provider, session: sessionID, now: now)?.account
                    ?? activeAccount(for: provider)?.id else { return nil }
            let measured = max(sessionRates.tokensPerHour(sessionID, now: now), sessionRates.demand(sessionID, until: now) ?? 0)
            return SessionPacer.RebalanceSession(
                id: sessionID, account: account, tokensPerHour: measured > 0 ? measured : SessionPacer.defaultSessionRate,
                contextTokens: sessionRates.entries[sessionID]?.contextTokens ?? 0,
                model: sessionModel(sessionID, now: now), movable: true,
                cacheLifetime: sessionRates.entries[sessionID]?.cacheLifetime)
        }
        guard let session = running.first(where: { $0.id == sessionID }) ?? shared() else { return nil }
        let shared = sharedGroup(provider, sessions: pacerSessions(provider, now: now).filter { $0.id != sessionID },
                                 now: now)?.group
        return SessionMoveRules.balancingChoice(
            session, pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor),
            accounts: pacerAccounts, running: running, destinations: destinations, now: now, sharedGroup: shared)
    }

    /// The move menu of one running session (`SessionMoveMenu`); nil while
    /// the provider's sessions run in no slots, as a move then switches the
    /// active account for every session.
    func sessionMoveMenu(_ provider: AIProviderType, session sessionID: String, now: Date = Date()) -> SessionMoveMenu? {
        guard sessionSlotsInUse(provider), liveSession(sessionID) != nil else { return nil }
        let model = sessionModel(sessionID, now: now)
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let slot = slotAccount(ofSession: sessionID, provider: provider)
        let pinned = sessionPins.account(of: sessionID).map { id in
            (id: id, name: accounts.first { $0.id == id }.map { messageName($0) } ?? "a removed account")
        }
        let candidates = accounts.filter { $0.provider == provider }.map { account in
            let usage = plannedUsage(account, now: now, model: model)
            let state = quotaState(for: account, now: now, model: model)
            let atLimit = accountCannotServe(account.id, provider: provider, planner: planner, now: now, model: model)
            return SessionMoveCandidate(
                account: account.id, name: messageName(account),
                sessionUsed: usage?.fiveHour?.utilization, weeklyUsed: usage?.sevenDay?.utilization,
                needsSignIn: needsSignIn(account),
                atLimit: atLimit,
                excluded: policy.excludedAccountIDs.contains(account.id),
                cannotServe: account.cliUnavailableReason,
                nearLimit: !atLimit && (planner.isTriggered(state, now: now)
                    || planner.servingVerdict(state, now: now, lead: Self.suspensionLead).atOrNearLimit)
            )
        }
        return SessionMoveMenu.build(candidates: candidates, current: slot ?? servingDecision(provider, session: sessionID, now: now)?.account,
                                     pinnedTo: pinned, shared: slot == nil,
                                     balancingChoice: balancingChoice(sessionID, provider: provider, now: now),
                                     pausesAtLimit: policy.suspendAgentsWhenExhausted)
    }

    /// A move chosen from a move menu: a pinned session is unpinned first,
    /// then moved as the requests interface moves it (`moveSession`). A
    /// move that is not made is recorded with its reason.
    @discardableResult
    func moveSessionByHand(_ sessionID: String, to accountID: UUID, now: Date = Date()) async -> SessionMoveOutcome {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return SessionMoveOutcome(ok: false, detail: "That account is no longer configured.")
        }
        if sessionPins.isPinned(sessionID) { unpinSession(sessionID) }
        let outcome = await moveSession(sessionID, to: account, now: now)
        if !outcome.ok, let provider = liveSession(sessionID)?.0 {
            let name = liveSession(sessionID).map { Self.eventName(of: $0.1) } ?? "session \(sessionID.prefix(8))"
            failoverEvents.record(provider, "\(name) was not moved to \(messageName(account)): \(outcome.detail)")
        }
        return outcome
    }

    /// Moves one running session to `wanted`, or without one to the
    /// account with most room for its model (`moveDestination`): the
    /// requests interface's `moveSession` and the move menus. A pinned
    /// session is refused; only unpinning frees it. `wanted` may be any
    /// account that can serve the CLI (`SessionMoveRules.blocker`): one
    /// failover excludes, or one at or near its limit, takes the session
    /// as the user asked.
    ///
    /// A session in a slot moves with its slot (`requestedSlotMoves`): at
    /// once for a CLI that reads its slot again, by restarting once idle for
    /// one that moves only that way. A session on the shared sign-in, while
    /// sessions run in slots, is restarted in a slot of its own on the
    /// destination (`prepareResumeSlot`, `restartInOwnSlot`). Without
    /// slots, when no account is named and the active account has room,
    /// reading the sign-in again is the whole move; otherwise the
    /// destination becomes the active account, which moves every session on
    /// the shared sign-in.
    ///
    /// A session moved into a slot is pinned there, so failover and
    /// balancing do not move it straight back, unless balancing would place
    /// it there itself (`SessionMoveRules`; never on an account failover
    /// excludes, which it always pins to); a move by restarting is pinned
    /// once it lands (`movePins`). Each move made is recorded.
    func moveSession(_ sessionID: String, to wanted: Account?, now: Date = Date()) async -> SessionMoveOutcome {
        // The cards and the Sessions page show the session on its new
        // account as soon as its slot is rewritten, not at the next cycle.
        defer { refreshSessions() }
        func outcome(_ ok: Bool, _ detail: String, _ account: Account? = nil) -> SessionMoveOutcome {
            SessionMoveOutcome(ok: ok, detail: detail, account: account)
        }
        guard let (provider, session) = liveSession(sessionID) else { return outcome(false, "No running session has that ID.") }
        let model = sessionModel(sessionID, now: now)
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let slot = session.processID.flatMap { slotDirectoryByProcess[$0] }
        let inSlot = slot.map { slot in SessionSlots(provider).map { slot.hasPrefix($0.sessionRoot.path + "/") } ?? false } ?? false
        let slotsInUse = sessionSlotsInUse(provider)
        let current = sessionAttribution(provider, now: now).decide(session: sessionID, process: session.processID)?.account
        // The limit the session met is learned before anything is chosen.
        if let current, let account = accounts.first(where: { $0.id == current }) { await readUsageNow(account) }
        func hasRoom(_ account: Account) -> Bool {
            !accountCannotServe(account.id, provider: provider, planner: planner, now: now, model: model)
        }
        if sessionPins.isPinned(sessionID) {
            return outcome(false, "The session is pinned to its account; unpin it first.")
        }
        // A move by hand ends the session's wait on its account.
        sessionWaits[provider]?[sessionID] = nil
        let subject = Self.eventName(of: session)
        // A session on the shared sign-in keeps the token it holds until
        // it is told to read the sign-in again, so it can still be on an
        // account that was active earlier. When the active account has
        // room for its model, reading the sign-in again is the whole move.
        if slot == nil, let active = activeAccount(for: provider),
           wanted == nil || !slotsInUse && wanted?.id == active.id,
           credentialModule(for: provider)?.liveCredential != nil, hasRoom(active) {
            moveRunningSessions(provider, reason: "request.moveSession")
            return outcome(true, "Sessions on the shared sign-in were told to read it again; \(messageName(active)) is the active account and has allowance left.", active)
        }
        let target = wanted ?? moveDestination(provider, current: current, model: model, now: now)
        let modelName = model.map { CostParser.shortModelName($0) } ?? "its model"
        guard let target else { return outcome(false, "No other account has allowance left for \(modelName).") }
        // A session on the shared sign-in may take a slot of the account it
        // follows; any other is already where it would go.
        let restartsIntoSlot = !inSlot && slotsInUse
        guard target.id != current || restartsIntoSlot else {
            return outcome(false, "The session is already on \(messageName(target)).", target)
        }
        let name = messageName(target)
        // A move by hand may go anywhere that can serve the CLI, an account
        // failover excludes or one at its limit included.
        if let blocker = SessionMoveRules.blocker(needsSignIn: needsSignIn(target), cannotServe: target.cliUnavailableReason) {
            return outcome(false, "\(name) cannot take the session: \(blocker).", target)
        }
        let pins = SessionMoveRules.pins(destination: target.id,
                                         balancingChoice: balancingChoice(sessionID, provider: provider, now: now),
                                         excluded: policy.excludedAccountIDs.contains(target.id))
        func record(_ how: HandMove) {
            failoverEvents.record(provider, Self.handMoveEvent(how, session: subject, to: name, pins: pins))
        }
        if inSlot, let slot {
            // The user's move is neither a rebalance's window nor automatic.
            requestedSlotMoves[sessionID] = target.id
            requestedWindowUses[sessionID] = nil
            automaticSlotMoves.remove(sessionID)
            if pins { movePins[sessionID] = MovePin(provider: provider, account: target.id, at: now) }
            await maintainSessionSlots(now: now)
            if provider.capabilities.sessionMovesNeedRestart {
                if slotRestartResumes[sessionID]?.account == target.id {
                    record(.restarted)
                    return outcome(true, "Restarted in a slot on \(name): the session was ended between turns and resumed there.", target)
                }
                let waiting = requestedSlotMoves[sessionID] == target.id
                if waiting {
                    record(.restartPending)
                } else {
                    movePins[sessionID] = nil
                }
                return outcome(waiting, "The session moves to \(name) by restarting, once it is idle between turns.", target)
            }
            let moved = slotDirectoryServing[slot] == target.id
            if moved {
                settleMovePins(provider, now: now, announce: false)
                record(.slotRewritten)
            } else {
                movePins[sessionID] = nil
            }
            return outcome(moved, moved ? "Moved to \(name); the session uses it from its next request."
                                        : "The session's slot could not be written for \(name).", target)
        }
        if restartsIntoSlot, let slots = SessionSlots(provider) {
            if let blocker = Self.restartBlocker(session, terminal: unisolatedTerminals[sessionID],
                                                 background: backgroundSessionStates[sessionID],
                                                 refused: sessionRefusals[sessionID] != nil) {
                return outcome(false, "It runs on the shared sign-in and moves by restarting in a slot of \(name): \(blocker)", target)
            }
            guard await prepareResumeSlot(sessionID, slots: slots, on: target, reason: "moveSession") else {
                return outcome(false, "No slot of \(name) could be made ready for it.", target)
            }
            if pins { movePins[sessionID] = MovePin(provider: provider, account: target.id, at: now) }
            slotRestartResumes[sessionID] = SlotRestartResume(provider: provider, account: target.id, at: now)
            guard await restartInOwnSlot(sessionID) else {
                slotRestartResumes[sessionID] = nil
                movePins[sessionID] = nil
                return outcome(false, "It runs on the shared sign-in and moves only by restarting, which did not happen; the events say why.", target)
            }
            record(.slotTaken)
            return outcome(true, "Restarted in a slot of its own on \(name).", target)
        }
        // The session reads a credential it shares with others, which
        // only moves by making the destination the active account.
        guard provider.capabilities.switchReachesRunningSessions
                || credentialModule(for: provider)?.liveCredential != nil else {
            return outcome(false, "The session's sign-in cannot be changed while it runs.")
        }
        if policy.activeAccountLocked { return outcome(false, "Moving the active account automatically is off, so it stays where you put it, and the session shares its sign-in.") }
        let previous = activeAccount(for: provider)?.id
        await switchTo(target, refreshAfter: false)
        let switched = activeAccount(for: provider)?.id == target.id
        if switched {
            moveRunningSessions(provider, from: previous, reason: "request.moveSession")
            record(.activeSwitched)
        }
        return outcome(switched, switched ? "Switched the active account to \(name); every session on the shared sign-in moves with it."
                                          : "The switch to \(name) did not complete.", target)
    }

    /// How a move by hand reached its destination (`moveSession`).
    enum HandMove: Equatable {
        /// Its slot was written for the destination; it uses it from its
        /// next request.
        case slotRewritten
        /// It was ended between turns and resumed in a slot there.
        case restarted
        /// It restarts there once idle between turns.
        case restartPending
        /// It left the shared sign-in for a slot of its own there.
        case slotTaken
        /// The destination became the active account.
        case activeSwitched
    }

    /// The event `moveSession` records for a move made: the session, its
    /// destination, how it got there and, for a move into a slot, whether
    /// it is pinned there (`pins`) or left to balancing, which would place
    /// it there too.
    nonisolated static func handMoveEvent(_ how: HandMove, session: String, to account: String, pins: Bool) -> String {
        let landed = how == .slotRewritten
        let pin = pins
            ? (landed ? "; pinned there, so failover and balancing leave it"
                      : "; it is pinned there once it lands, so failover and balancing leave it")
            : "; balancing would place it there too, so it stays unpinned"
        return switch how {
        case .slotRewritten: "Moved \(session) to \(account) at your request\(pin)."
        case .restarted: "Moved \(session) to \(account) at your request: it was ended between turns and resumed there\(pin)."
        case .restartPending: "Moving \(session) to \(account) at your request: it restarts there once it is idle between turns\(pin)."
        case .slotTaken: "Moved \(session) to \(account) at your request: it left the shared sign-in and was resumed in a slot of its own there\(pin)."
        case .activeSwitched: "Moved \(session) to \(account) at your request by making it the active account; every session on the shared sign-in moves with it."
        }
    }

    /// Pins each session the user moved by hand (`movePins`) once its slot
    /// serves the destination, and forgets a pin whose session was pinned
    /// or unpinned since, or that waited longer than `movePinLifetime`.
    /// `announce` records the pin; `moveSession` names it in its own event.
    /// Run by `maintainPins` on every pass over the provider's slots.
    func settleMovePins(_ provider: AIProviderType, now: Date = Date(), announce: Bool = true) {
        for (session, pin) in movePins where pin.provider == provider {
            if sessionPins.isPinned(session) || now.timeIntervalSince(pin.at) > Self.movePinLifetime {
                movePins[session] = nil
                continue
            }
            guard slotAccount(ofSession: session, provider: provider) == pin.account else { continue }
            movePins[session] = nil
            guard case .pinned(let id) = sessionPins.pin(session, slotAccount: pin.account, provider: provider, at: now) else { continue }
            sessionPins.save()
            if announce {
                let name = liveSession(session).map { Self.eventName(of: $0.1) } ?? "session \(session.prefix(8))"
                let account = accounts.first { $0.id == id }.map { messageName($0) } ?? "its account"
                failoverEvents.record(provider, "Pinned \(name) to \(account), where you moved it: failover and balancing leave it there.")
            }
        }
    }
}
