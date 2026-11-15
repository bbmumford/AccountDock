import Foundation

/// Where one running session stands, as the Sessions page and the account
/// cards' session lists show it beside its controls. Derived from the
/// provider's pause files (`AgentPauseGate`) and what `AppState` knows of
/// the session (`derive`).
enum SessionRowState: Equatable {
    /// Running, and nothing holds it.
    case running
    /// Held in the gate now, waiting before its next request.
    case waiting
    /// The pause holds it; it stops at its next tool call or new turn.
    case stopsAtNextStep
    /// The user let it go on while the pause holds other sessions.
    case resumedWhileOthersPaused
    /// The provider refused its last request at a usage limit, and nothing
    /// has served it since (`AppState.sessionRefusals`).
    case refusedAtLimit
    /// It reads the shared sign-in, not a one-session slot of its own, so
    /// it moves with the active account and cannot be pinned.
    case notIsolated

    /// Whether a pause holds it, so its control plays it rather than
    /// pausing it.
    var isPaused: Bool { self == .waiting || self == .stopsAtNextStep }

    var label: String {
        switch self {
        case .running: "running"
        case .waiting: "paused (waiting)"
        case .stopsAtNextStep: "paused (stops at its next step)"
        case .resumedWhileOthersPaused: "resumed while others paused"
        case .refusedAtLimit: "refused at a limit"
        case .notIsolated: "not isolated"
        }
    }

    /// The state of each of `sessions`, the provider's running sessions,
    /// from its pause files in `directory`. `refused` are those
    /// `AppState.sessionRefusals` holds; `isolated` those reading a slot of
    /// their own, nil for a provider whose sessions run in no slots (none
    /// of them then counts as not isolated). A held session shows as
    /// paused whatever else applies, then a resumed one, then a refusal.
    static func derive(_ provider: AIProviderType, sessions: [String], refused: Set<String>, isolated: Set<String>?,
                       directory: URL = AgentPauseGate.pauseDirectory) -> [String: SessionRowState] {
        let pause = AgentPauseGate.read(provider, directory: directory)
        let held = AgentPauseGate.heldSessions(provider, running: Set(sessions), directory: directory)
        let waiting = pause == nil ? [] : AgentPauseGate.waitingSessions(provider, directory: directory)
        let resumed = pause == nil ? [] : AgentPauseGate.resumedSessions(provider, directory: directory)
        return sessions.reduce(into: [:]) { states, id in
            let state: SessionRowState = if held.contains(id) {
                waiting.contains(id) ? .waiting : .stopsAtNextStep
            } else if resumed.contains(id) {
                .resumedWhileOthersPaused
            } else if refused.contains(id) {
                .refusedAtLimit
            } else if let isolated, !isolated.contains(id) {
                .notIsolated
            } else {
                .running
            }
            states[id] = state
        }
    }
}

/// One account as a destination in a session's move menu.
struct SessionMoveCandidate: Equatable {
    let account: UUID
    let name: String
    /// Percent used of the session window and of the long window; nil when
    /// not read.
    let sessionUsed: Double?
    let weeklyUsed: Double?
    let needsSignIn: Bool
    /// It cannot serve the session's model now (`AppState.accountCannotServe`).
    let atLimit: Bool
    /// Failover leaves it out (`ProviderFailoverPolicy.excludedAccountIDs`).
    let excluded: Bool
    /// Why it cannot serve the provider's CLI at all, such as a plan that
    /// does not include it (`Account.cliUnavailableReason`); nil when it can.
    var cannotServe: String? = nil
    /// It has room by its last reading but is past its failover threshold
    /// or forecast to reach its limit soon (`AppState.sessionMoveMenu`).
    var nearLimit = false
}

/// A session's move menu: one entry per account of its provider, each
/// with its room and, when it cannot take the session, why. Built by
/// `build`; `AppState.sessionMoveMenu` gives it the accounts, and the
/// session controls show it.
struct SessionMoveMenu: Equatable {
    /// How the session reaches the account chosen.
    enum Kind: Equatable {
        /// Its slot is moved (`AppState.moveSession`).
        case move
        /// It is pinned; choosing an account unpins it first.
        case unpinAndMove
        /// It reads the shared sign-in; it is restarted in a slot of its
        /// own on the account chosen.
        case restartInSlot
    }

    struct Option: Equatable, Identifiable {
        let account: UUID
        let name: String
        let sessionLeft: Double?
        let weeklyLeft: Double?
        /// Why it cannot take the session; nil when it can.
        let blocker: String?
        /// Whether the move pins the session there (`SessionMoveRules.pins`).
        let pins: Bool
        /// What the user should know before moving it there, when it can
        /// take it: failover excludes it, or it is at or near its limit.
        var warning: String? = nil
        var id: UUID { account }
    }

    var kind: Kind
    /// The account the session is pinned to, by name, while it is pinned.
    var pinnedTo: String?
    var options: [Option]

    /// The menu for a session served by `current` (nil when unknown),
    /// pinned to `pinnedTo` or not, on the shared sign-in (`shared`) or in
    /// a slot. `balancingChoice` is the account balancing would place it on
    /// now (`SessionMoveRules.balancingChoice`): a move anywhere else pins
    /// it. A session on the shared sign-in may be restarted in a slot of
    /// the account it follows; any other session is already on `current`.
    ///
    /// A move by hand may go to any account that can serve the CLI: one
    /// failover excludes, or one at or near its limit, is offered with a
    /// `warning`, since the user chose it. Only an account that cannot
    /// serve at all (it needs signing in, or `cannotServe`) and the one the
    /// session runs on are refused. `pausesAtLimit` is the provider's
    /// pausing at the limit, which decides what a session pinned to an
    /// account at its limit does there.
    static func build(candidates: [SessionMoveCandidate], current: UUID?, pinnedTo: (id: UUID, name: String)?,
                      shared: Bool, balancingChoice: UUID?, pausesAtLimit: Bool = true) -> SessionMoveMenu {
        let kind: Kind = shared ? .restartInSlot : pinnedTo != nil ? .unpinAndMove : .move
        let options = candidates.map { candidate -> Option in
            let blocker: String? = if !shared, candidate.account == current {
                pinnedTo?.id == candidate.account ? "pinned here" : "it runs here now"
            } else {
                SessionMoveRules.blocker(needsSignIn: candidate.needsSignIn, cannotServe: candidate.cannotServe)
            }
            return Option(account: candidate.account, name: candidate.name,
                          sessionLeft: candidate.sessionUsed.map { max(0, 100 - $0) },
                          weeklyLeft: candidate.weeklyUsed.map { max(0, 100 - $0) },
                          blocker: blocker,
                          pins: SessionMoveRules.pins(destination: candidate.account, balancingChoice: balancingChoice,
                                                      excluded: candidate.excluded),
                          warning: blocker == nil ? warning(candidate, pausesAtLimit: pausesAtLimit) : nil)
        }
        return SessionMoveMenu(kind: kind, pinnedTo: pinnedTo?.name, options: options)
    }

    /// What a move onto `candidate` brings with it: failover excludes the
    /// account, so the move pins the session there, or the account is at
    /// or near its limit, where the pinned session waits until it has room
    /// (paused by AccountDock when `pausesAtLimit`).
    static func warning(_ candidate: SessionMoveCandidate, pausesAtLimit: Bool) -> String? {
        var parts: [String] = []
        if candidate.excluded { parts.append("excluded from failover — the move pins it there") }
        let waits = pausesAtLimit ? "pauses" : "waits"
        if candidate.atLimit {
            parts.append("at its limit — it \(waits) there until the account has room")
        } else if candidate.nearLimit {
            parts.append("near its limit — it \(waits) there once the account reaches it")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// The menu item's action, naming the account.
    func title(_ option: Option) -> String {
        switch kind {
        case .move: "Move to \(option.name)"
        case .unpinAndMove: "Unpin and move to \(option.name)"
        case .restartInSlot: "Restart in a slot on \(option.name)"
        }
    }

    /// The account's room and what the move does to the pin, or why it
    /// cannot take the session. `sessionWindow` and `longWindow` name the
    /// provider's windows (`ProviderCapabilities`).
    func detail(_ option: Option, sessionWindow: String, longWindow: String) -> String {
        if let blocker = option.blocker { return blocker }
        var parts: [String] = []
        if let left = option.sessionLeft { parts.append("\(Int(left.rounded()))% of \(sessionWindow.lowercased()) left") }
        if let left = option.weeklyLeft { parts.append("\(Int(left.rounded()))% of \(longWindow.lowercased()) left") }
        if parts.isEmpty { parts.append("not read yet") }
        if let warning = option.warning { parts.append(warning) }
        // An excluded account's warning already says the move pins it.
        if option.warning?.contains("pins it there") != true {
            parts.append(option.pins ? "pins it here" : "balancing agrees; stays unpinned")
        }
        return parts.joined(separator: " · ")
    }
}

/// Whether a session the user moves by hand is pinned at its destination:
/// a session following the active account or placed by balancing is
/// pinned where the user put it, so failover and balancing do not move it
/// straight back, unless balancing would place it there itself.
enum SessionMoveRules {
    /// Where balancing would place `session` now: `SessionPacer.place`,
    /// with every other running session (`running`) where it is, among
    /// `destinations`, charging each the session's cache rewrite. Nil when
    /// no destination can take it.
    static func balancingChoice(_ session: SessionPacer.RebalanceSession, pacer: SessionPacer,
                                accounts: [SessionPacer.Account], running: [SessionPacer.RebalanceSession],
                                destinations: Set<UUID>, now: Date,
                                sharedGroup: SessionPacer.SharedGroup? = nil) -> UUID? {
        pacer.place([session], accounts: accounts, running: running.filter { $0.id != session.id },
                    destinations: destinations, now: now, sharedGroup: sharedGroup)[session.id]
    }

    /// Whether a move to `destination` pins the session: unless balancing
    /// would place it there too. A move onto an account failover excludes
    /// (`excluded`) always pins it: balancing never places a session there,
    /// and would move an unpinned one straight off.
    static func pins(destination: UUID, balancingChoice: UUID?, excluded: Bool = false) -> Bool {
        excluded || balancingChoice != destination
    }

    /// Why a move by hand cannot go to an account, or nil when it can: the
    /// account needs signing in, or cannot serve the provider's CLI at all
    /// (`cannotServe`, from `Account.cliUnavailableReason`). Room, limits
    /// and failover's exclusion never refuse a move by hand. Read by
    /// `SessionMoveMenu.build` and `AppState.moveSession`.
    static func blocker(needsSignIn: Bool, cannotServe: String?) -> String? {
        needsSignIn ? "needs signing in" : cannotServe
    }
}
