import Foundation

private let restartLog = FileLog("SlotRestarts")

/// A move of a session whose CLI reads only the account it started on,
/// chosen by `AppState.serveSessionSlots` while the session was idle.
struct PendingSlotRestart: Equatable {
    var provider: AIProviderType
    var session: String
    var from: UUID
    var to: UUID
    /// Why it moves, for the event.
    var why: String
    /// Asked for through `AppState.requestedSlotMoves`, which keeps it
    /// until it can be made.
    var requested: Bool
}

/// A session restarted on `account`, until its resumed run has started.
struct SlotRestartResume: Equatable {
    var provider: AIProviderType
    var account: UUID
    var at: Date
}

/// Moves sessions of a CLI that cannot change account while it runs
/// (`ProviderSessionIsolation.movesNeedRestart`): each is ended between
/// turns and resumed by ID through the launcher, which starts the resumed
/// run in a spare slot written for the new account. Everything here is the
/// same for every such provider.
extension AppState {
    /// How long a restarted session's resume keeps naming its new account
    /// in the resume file, for a resumed run slow to start.
    nonisolated static let slotRestartResumeLifetime: TimeInterval = 10 * 60

    /// Applies `pendingSlotRestarts`: for each session still idle and not
    /// pinned, fills a spare slot of the destination, names it in the
    /// resume file for the session, and types the CLI's exit and its resume
    /// command into the session's terminal (`SessionTerminalActions`). The
    /// slot the session leaves keeps its account until it is released.
    /// Called after every `maintainSessionSlots`.
    func applySlotRestarts(now: Date = Date()) async {
        slotRestartResumes = slotRestartResumes.filter { session, restart in
            now.timeIntervalSince(restart.at) < Self.slotRestartResumeLifetime
                && slotAccount(forSession: session, provider: restart.provider) != restart.account
        }
        let pending = pendingSlotRestarts.values.sorted { $0.session < $1.session }
        pendingSlotRestarts = [:]
        for restart in pending {
            await applySlotRestart(restart, now: now)
        }
    }

    private func applySlotRestart(_ restart: PendingSlotRestart, now: Date) async {
        guard let (provider, session) = liveSession(restart.session), provider == restart.provider,
              let slots = SessionSlots(provider), slots.isolation.movesNeedRestart,
              !sessionPins.isPinned(restart.session), session.isIdle, !session.isWorking,
              let destination = accounts.first(where: { $0.id == restart.to && $0.provider == provider }) else {
            if restart.requested { requestedSlotMoves[restart.session] = restart.to }
            return
        }
        guard await prepareResumeSlot(restart.session, slots: slots, on: destination, reason: "applySlotRestarts") else { return }
        let to = restart.to
        slotRestartResumes[restart.session] = SlotRestartResume(provider: provider, account: to, at: now)
        let outcome = await SessionTerminalActions.restartInOwnSlot(session, isolation: slots.isolation,
                                                                    terminal: sessionTerminal)
        let subject = Self.eventName(of: session)
        let name = messageName(destination)
        if outcome == .typed {
            slotRestartsNoted.remove(restart.session)
            quotaTrends[to]?.settle(at: now)
            failoverEvents.record(provider, "Restarted \(subject) in a slot on \(name): \(restart.why).")
            return
        }
        slotRestartResumes[restart.session] = nil
        if restart.requested { requestedSlotMoves[restart.session] = to }
        if let event = Self.slotRestartEvent(outcome, session: subject, to: name, why: restart.why),
           slotRestartsNoted.insert(restart.session).inserted {
            failoverEvents.record(provider, event)
        }
    }

    /// Fills a spare slot of `destination` and names it in the resume file
    /// for `sessionID`, so the launcher starts the session's resumed run
    /// there. Used before a restart that moves a session: by
    /// `applySlotRestart`, and by `restartInSlot` for a session on the
    /// shared sign-in. Returns whether the slot is ready.
    func prepareResumeSlot(_ sessionID: String, slots: SessionSlots, on destination: Account, reason: String) async -> Bool {
        let lifetime: TimeInterval = readsLiveCredential(destination) ? 60 : 2 * 60 * 60
        guard let credential = await slots.isolation.currentSlotCredential(for: destination, minimumLifetime: lifetime,
                                                                            from: self) else {
            restartLog.warning("No credential of \(messageName(destination)) for a restarted session")
            return false
        }
        let to = destination.id
        let ready = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard slots.makeSpare(for: to, credential: credential, reason: reason) else { return false }
            slots.addResume(session: sessionID, path: slots.directory(for: to).path)
            return true
        }.value
        if !ready { restartLog.error("No spare slot of \(messageName(destination)) for a restarted session") }
        return ready
    }

    /// The event for a restart that was not made, once per session; nil for
    /// one tried again at the next idle moment without a word.
    nonisolated static func slotRestartEvent(_ outcome: SessionTerminalActions.Outcome, session: String,
                                             to account: String, why: String) -> String? {
        let move = "\(session) stays where it is: it moves to \(account) (\(why)) only by restarting"
        switch outcome {
        case .typed, .notIdle, .busy:
            return nil
        case .notInTerminal:
            return "\(move), and it does not run in agterm. Quit it and resume it from a terminal to move it."
        case .refused:
            return "\(move), and agterm did not take the text."
        case .cancelled:
            return "\(move), and it still had background work running when asked to exit, so it was kept running."
        case .notStopped:
            return "\(move), and its background session could not be stopped."
        }
    }
}
