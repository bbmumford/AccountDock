import AppKit

/// Playing a held session while no account has room for it takes two
/// presses. The first leaves it held and says why for `playNoteLifetime`:
/// where and about when it resumes, by its held-session plan or its
/// account's reset. A second press while that shows runs it anyway, into
/// the limit. With room somewhere, one press releases it, as one release
/// (`UserResume`). The play buttons of the Sessions page and the account
/// cards (`playSession`) and the resume shortcut
/// (`resumeFrontmostSession`) all press through `pressPlay`.
extension AppState {
    /// Why a first press left a session held (`playNotes`).
    struct PlayNote: Equatable {
        let provider: AIProviderType
        let session: String
        /// The session as the menus name it (`WaitingSession.label`).
        let label: String
        let text: String
        /// When the note stops showing and the next press is a first press
        /// again.
        let until: Date
    }

    /// What one press of a held session's play does (`playPress`).
    enum PlayPress: Equatable {
        /// An account can carry it: it goes on now.
        case release
        /// No account can: it stays held, and the note says why.
        case explain
        /// No account can, and the note of a press moments ago still shows:
        /// it goes on anyway.
        case runAnyway
    }

    /// How long a first press's note shows.
    nonisolated static let playNoteLifetime: TimeInterval = 6

    /// The press's rule: `carried` says whether some account can carry the
    /// session now (`playCarried`); `note` is the one a first press left for
    /// it, live until its `until`. Returns what the press does and the note
    /// it leaves: a new one, with `text` (`noRoomPlayNote`), for a first
    /// press without room, none otherwise.
    nonisolated static func playPress(carried: Bool, note: PlayNote?, provider: AIProviderType, session: String,
                                      label: String, text: () -> String, now: Date) -> (press: PlayPress, note: PlayNote?) {
        if carried { return (.release, nil) }
        if let note, note.session == session, note.until > now { return (.runAnyway, nil) }
        return (.explain, PlayNote(provider: provider, session: session, label: label, text: text(),
                                   until: now.addingTimeInterval(playNoteLifetime)))
    }

    /// The note of a first press without room: "No account has room; it
    /// resumes about 9:00 pm (cybrio's new week). Press again to run it
    /// anyway." `resume` is where and when it is expected to go on (the
    /// account, the time, and whether a new week or a fresh 5-hour window
    /// frees it), nil when unknown.
    nonisolated static func noRoomPlayNote(resume: (account: String, at: Date, newWeek: Bool)?, now: Date) -> String {
        let when = resume.map { resume in
            "it resumes about \(UsageFormat.clock(resume.at, now: now)) (\(resume.account)'s \(resume.newWeek ? "new week" : "fresh window"))"
        } ?? "it resumes when one has room"
        return "No account has room; \(when). Press again to run it anyway."
    }

    /// The event for a session the user ran although no account had room.
    nonisolated static func playAnywayEvent(_ session: String) -> String {
        "Resumed \(session) at your request although no account has room; it will be refused at the limit and wait there."
    }

    /// One press of `session`'s play (`playPress`): released, run anyway
    /// (`resumeSession` with `anyway`), or left held with a note that
    /// clears itself after `playNoteLifetime`. Returns what it did.
    @discardableResult
    func pressPlay(_ pressed: WaitingSession, now: Date = Date()) -> PlayPress {
        let id = pressed.sessionID
        // The shortcut's candidates carry no name, account or resume time.
        let session = pausedSessions(pressed.provider).first { $0.sessionID == id } ?? pressed
        let outcome = Self.playPress(carried: playCarried(session.provider, session: id, now: now), note: playNotes[id],
                                     provider: session.provider, session: id, label: session.label,
                                     text: { self.noRoomPlayNote(session, now: now) }, now: now)
        playNotes[id] = outcome.note
        switch outcome.press {
        case .release: resumeSession(session)
        case .runAnyway: resumeSession(session, anyway: true)
        case .explain:
            guard let note = outcome.note else { break }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.playNoteLifetime))
                if self?.playNotes[id] == note { self?.playNotes[id] = nil }
            }
        }
        return outcome.press
    }

    /// The resume shortcut's press: as `pressPlay`, and a first press that
    /// leaves the session held beeps and posts its note, since the user is
    /// in the session's terminal rather than at a play button.
    func pressPlayFromShortcut(_ session: WaitingSession) {
        guard pressPlay(session) == .explain, let note = playNotes[session.sessionID] else { return }
        NSSound.beep()
        UserAlerts.shared.post(id: "play-note-\(session.sessionID)", title: "\(note.label) stays paused",
                               body: note.text + " (\(SessionResumeShortcut.display))", minimumInterval: 0)
    }

    /// Whether some account can carry `session` if it goes on now: the
    /// account it runs on is neither at nor near its limit
    /// (`atOrNearLimit`), or, for a slot session not pinned, another account
    /// in the failover order has room for it by a fresh reading and carries
    /// it for the hour beside what the cycle's ledger sent there
    /// (`fallbackLane`, the runway rule's choice). A session on the shared
    /// sign-in goes where the active account does, so only that one counts.
    func playCarried(_ provider: AIProviderType, session: String, now: Date) -> Bool {
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let slot = slotAccount(forSession: session, provider: provider)
        guard let own = slot ?? activeAccount(for: provider)?.id else { return true }
        if !atOrNearLimit(own, planner: planner, now: now) { return true }
        guard slot != nil, !sessionPins.isPinned(session), let slots = SessionSlots(provider) else { return false }
        let running = slotRebalanceSessions(provider, slots: slots, now: now)
        guard let entry = running.first(where: { $0.id == session }) else { return false }
        let policy = failoverConfig.policy(for: provider)
        let lanes = accounts.filter { account in
            account.provider == provider && account.id != own && !policy.excludedAccountIDs.contains(account.id)
                && !needsSignIn(account) && freshForArrivals(account.id, now: now)
                && planner.servingVerdict(planner.servingView(quotaState(for: account, now: now)), now: now,
                                          lead: Self.suspensionLead) == .canServe
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard !lanes.isEmpty else { return false }
        return Self.fallbackLane(arriving(entry), from: own, candidates: lanes, usable: { _ in true }, running: running,
                                 accounts: capacityOutlookAccounts(provider, now: now), ledger: laneLedger(provider, now: now),
                                 now: now, pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)) != nil
    }

    /// `noRoomPlayNote` for `session`: its held-session plan's lane and
    /// reset when one waits for it (`heldSessionPlans`), else its own
    /// account and when that serves it again (`WaitingSession.resumeAt`),
    /// a new week when the weekly allowance is what runs out first there
    /// (`FailoverPlanner.limitingWindow`).
    func noRoomPlayNote(_ session: WaitingSession, now: Date) -> String {
        if let plan = heldSessionPlans[session.provider]?[session.sessionID], plan.choice == .wait {
            return Self.noRoomPlayNote(resume: (plan.laneName, plan.at, plan.refill == .newWeek), now: now)
        }
        guard let id = session.account, let account = accounts.first(where: { $0.id == id }),
              let at = session.resumeAt else { return Self.noRoomPlayNote(resume: nil, now: now) }
        let planner = FailoverPlanner(settings: plannerSettings(session.provider))
        let window = planner.limitingWindow(quotaState(for: account, now: now), now: now)
        return Self.noRoomPlayNote(resume: (messageName(account), at, window == .weekly), now: now)
    }
}
