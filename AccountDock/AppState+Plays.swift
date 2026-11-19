import Foundation

/// The user's play of one held session (`resumeSession`) is one release,
/// not a lasting exemption. The session runs on whatever account serves it:
/// the one it was played on, or the one a slot move then takes it to, as
/// the stranded placement does for a played session whose account cannot
/// serve it. Once that account is at or near its limit, by its 5-hour
/// window, its weekly allowance or its sessions' runway, the session is
/// held again like any other session, or moved to an account with room by
/// the rule that holds it, before the provider refuses it. The only limit a
/// play lets it run into is the one the user played it through: the limit
/// of the account it was played on, while it stays there and that account
/// has had no room since. A later play releases it again the same way.
extension AppState {
    /// One session the user played in the current pause (`userResumes`).
    struct UserResume: Equatable {
        /// The account serving the session when the user played it.
        var playedOn: UUID
        /// The account serving it when last judged (`following`): the one
        /// it was played on, or the one it moved to since.
        var account: UUID
        /// `account` was at or near its limit when the user played the
        /// session there, and has had no room since: the user chose to run
        /// it into that limit, so no rule holds it for it.
        var spent: Bool

        init(playedOn: UUID, spent: Bool) {
            self.playedOn = playedOn
            account = playedOn
            self.spent = spent
        }

        /// The play once the session is seen on `serving`, which is at or
        /// near its limit or not (`nearLimit`). On another account the play
        /// covers no limit there; on the same one, room again ends what it
        /// covered, so the account's next limit holds the session.
        func following(_ serving: UUID, nearLimit: Bool) -> UserResume {
            var next = self
            next.spent = serving == account && spent && nearLimit
            next.account = serving
            return next
        }

        /// Whether the play still lets the session run past a rule holding
        /// it for its account's limit, with the session on `serving` now
        /// (nil when unknown: the account it was last judged on).
        func releases(serving: UUID?) -> Bool {
            spent && (serving ?? account) == account
        }
    }

    /// A play a rule ended by holding its session again (`endPlays`).
    struct EndedPlay: Equatable {
        let session: String
        /// The account it ran on when held again; nil when unknown.
        let account: UUID?
        /// It ran there after moving off the account it was played on.
        let moved: Bool
    }

    /// `reholdUserResumedSessions`' rule: each of `plays` whose session the
    /// gate still lets run (`resumed`) is judged on the account serving it
    /// now (`serving`, nil when unknown) through `UserResume.following`; it
    /// is held again when that account is at or near its limit
    /// (`nearLimit`) and the play does not cover it. Returns the plays that
    /// stand, updated, and those ended, with the account each ran on.
    nonisolated static func judgePlays(_ plays: [String: UserResume], resumed: Set<String>,
                                       serving: (String) -> UUID?, nearLimit: (UUID) -> Bool)
        -> (standing: [String: UserResume], heldAgain: [(session: String, play: UserResume)]) {
        var standing: [String: UserResume] = [:]
        var heldAgain: [(session: String, play: UserResume)] = []
        for (session, play) in plays.sorted(by: { $0.key < $1.key }) where resumed.contains(session) {
            let account = serving(session) ?? play.account
            let near = nearLimit(account)
            let next = play.following(account, nearLimit: near)
            if near && !next.spent {
                heldAgain.append((session, next))
            } else {
                standing[session] = next
            }
        }
        return (standing, heldAgain)
    }

    /// Lists `sessions` in the provider's pause for a rule holding them at
    /// their account's limit: in the pause in effect, or in a pause at a
    /// limit holding them alone at their next tool call and new turn
    /// (`pinnedHoldPause`, for `reason`). One the pause lists already is
    /// left, and so is one resumed in it whose release stands
    /// (`releaseStands`, asked of resumed sessions only): an admission of
    /// AccountDock's, which `reholdSessionsNearLimit` judges, or a play
    /// still covering its account's limit. A resumed one whose release no
    /// longer stands loses its marker (`AgentPauseGate.clearResumed`), so
    /// the gate holds it again, also under a pause holding every new turn.
    /// Returns the sessions newly listed that were not resumed, empty when
    /// the pause in effect holds them already, and the resumed ones held
    /// again. Read by `holdAtLimit`.
    nonisolated static func listHolds(_ provider: AIProviderType, _ sessions: [String], reason: String, now: Date,
                                      releaseStands: (String) -> Bool,
                                      directory: URL = AgentPauseGate.pauseDirectory)
        -> (listed: [String], replayed: [String]) {
        let existing = AgentPauseGate.read(provider, directory: directory)
        let resumed = AgentPauseGate.resumedSessions(provider, directory: directory)
        let due = sessions.filter { session in
            !(existing?.sessions.contains(session) ?? false) && !(resumed.contains(session) && releaseStands(session))
        }.sorted()
        var listed: [String] = []
        if let pause = pinnedHoldPause(existing: existing, adding: due, at: now, reason: reason) {
            AgentPauseGate.write(pause, for: provider, directory: directory)
            listed = due.filter { !resumed.contains($0) }
        }
        let replayed = due.filter(resumed.contains)
        AgentPauseGate.clearResumed(provider, sessions: replayed, directory: directory)
        return (listed, replayed)
    }

    /// `listHolds` for the provider now, each play it ends ended
    /// (`endPlays`). Used by every rule that holds sessions at their
    /// account's limit: the waits (`writeWaits`), the runway
    /// (`shedSessionsShortOfRunway`) and the pinned holds
    /// (`holdPinnedSessionsAtLimit`), which record their own events.
    func holdAtLimit(_ provider: AIProviderType, _ sessions: [String], reason: String, now: Date)
        -> (listed: [String], replayed: [EndedPlay]) {
        let held = Self.listHolds(provider, sessions, reason: reason, now: now) { session in
            self.userResumes[provider]?[session].map {
                $0.releases(serving: self.servingAccount(provider, session: session)?.id)
            } ?? true
        }
        if !held.listed.isEmpty || !held.replayed.isEmpty { refreshPauseStatus(provider) }
        return (held.listed, endPlays(provider, held.replayed))
    }

    /// Ends the plays of `sessions`, which a rule has just held again: each
    /// record goes (`userResumes`), with what its play let it run past (a
    /// played wait, `SessionWait.played`, and `pinnedHoldsPlayed`), so the
    /// wait holds it again and the user's next play releases it afresh.
    func endPlays(_ provider: AIProviderType, _ sessions: [String]) -> [EndedPlay] {
        sessions.map { session in
            let play = userResumes[provider]?[session]
            let account = servingAccount(provider, session: session)?.id ?? play?.account
            userResumes[provider]?[session] = nil
            sessionWaits[provider]?[session]?.played = false
            pinnedHoldsPlayed[session] = nil
            return EndedPlay(session: session, account: account,
                             moved: play.map { account != nil && account != $0.playedOn } ?? false)
        }
    }

    /// Holds again, at its next tool call, each session the user played
    /// whose play no longer covers its account (`judgePlays`): the account
    /// serving it, the one it was played on or the one its slot moved it to
    /// since, is at or near its limit (`isNearLimit`: refused or at a limit,
    /// or reaching one within `suspensionLead` by its 5-hour window, its
    /// weekly allowance or its sessions' runway). Run by
    /// `reholdSessionsNearLimit` at every evaluation; with no pause in
    /// effect no play is left.
    func reholdUserResumedSessions(_ provider: AIProviderType, planner: FailoverPlanner) {
        guard let plays = userResumes[provider], !plays.isEmpty else { return }
        guard AgentPauseGate.read(provider) != nil else { userResumes[provider] = nil; return }
        let now = Date()
        var near: [UUID: Bool] = [:]
        let judged = Self.judgePlays(plays, resumed: AgentPauseGate.resumedSessions(provider),
                                     serving: { self.servingAccount(provider, session: $0)?.id }) { id in
            if let known = near[id] { return known }
            let value = self.accounts.first { $0.id == id }.map { self.isNearLimit($0, planner: planner, now: now) } ?? false
            near[id] = value
            return value
        }
        // The ended plays stay recorded until `endPlays` reads where each
        // was played.
        userResumes[provider] = judged.standing.merging(judged.heldAgain.map { ($0.session, $0.play) }) { _, ended in ended }
        guard !judged.heldAgain.isEmpty else { return }
        for entry in judged.heldAgain { AgentPauseGate.hold(provider, session: entry.session) }
        refreshPauseStatus(provider)
        recordPlaysHeldAgain(provider, endPlays(provider, judged.heldAgain.map(\.session)), now: now)
    }

    /// Records each of `ended` (`playHeldAgainEvent`), named as the session
    /// names itself, else by its folder and ID.
    func recordPlaysHeldAgain(_ provider: AIProviderType, _ ended: [EndedPlay], now: Date) {
        for play in ended {
            let name = sessionNames[play.session]
                ?? liveSession(play.session).map { Self.eventName(of: $0.1) } ?? "session \(play.session.prefix(8))"
            let account = play.account.flatMap { id in accounts.first { $0.id == id } }
            let refused = account.map { quotaState(for: $0, now: now).refusedAtLimit } ?? false
            failoverEvents.record(provider, Self.playHeldAgainEvent(
                session: name, account: account.map { messageName($0) } ?? "its account", moved: play.moved,
                refused: refused))
        }
    }

    /// The event recording that a session the user played is held again
    /// for the account it ran on: where it ran (the one it was played on,
    /// or the one it moved to after the play) and that the account reached
    /// its limit (`refused`) or is about to.
    nonisolated static func playHeldAgainEvent(session: String, account: String, moved: Bool, refused: Bool) -> String {
        let place = moved ? "where it ran after you resumed it" : "where you resumed it"
        let reach = refused ? "reached its limit" : "is about to reach its limit"
        return "Paused \(session) again: \(account), \(place), \(reach); it continues when an account has room."
    }
}
