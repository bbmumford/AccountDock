import Foundation

/// A session of a CLI's background service on an account that can no
/// longer serve it (`AppState.stuckBackgroundSessions(_:sessions:...)`).
struct StuckBackgroundSession: Equatable {
    var provider: AIProviderType
    var session: String
    /// The account whose token it holds.
    var account: UUID
    /// Refused at a usage limit since its last served request; it then
    /// counts as idle for its restart (`AppState.restartBlocker`).
    var refused: Bool
}

/// Moves sessions of a CLI's background service off an account that can no
/// longer serve them. A worker keeps the token it read in memory and does
/// not read the shared sign-in again when signalled (`moveRunningSessions`,
/// `signalFlaggedProcesses`), so the move is the restart `restartInOwnSlot`
/// makes: the session is stopped with the CLI's stop command once its
/// attach client's footer reports no work, and resumed in that client's tab
/// through the launcher, which gives it a slot of its own on an account
/// with room. Offered in the events and the usage tab; made without being
/// asked with `ProviderFailoverPolicy.restartStuckBackgroundSessions`.
extension AppState {
    /// How long a restart that did not take waits before it is tried again.
    nonisolated static let stuckRestartSpacing: TimeInterval = 10 * 60

    /// The background sessions among `sessions` (those with a state in
    /// `background`) on an account `cannotServe` names: refused at a usage
    /// limit there since their last served request (`refusals`), or flagged
    /// as holding its token (`flagged`, `noteProcessCredential`).
    nonisolated static func stuckBackgroundSessions(_ provider: AIProviderType, sessions: [AgentSession],
                                                    background: [String: BackgroundSessionState],
                                                    refusals: [String: SessionRefusal],
                                                    flagged: [String: FlaggedCredentialProcess],
                                                    cannotServe: (UUID) -> Bool) -> [StuckBackgroundSession] {
        sessions.compactMap { session in
            let id = session.sessionID
            guard background[id] != nil else { return nil }
            if let refusal = refusals[id], cannotServe(refusal.account) {
                return StuckBackgroundSession(provider: provider, session: id, account: refusal.account, refused: true)
            }
            if let flag = flagged[id], flag.provider == provider, cannotServe(flag.observed) {
                return StuckBackgroundSession(provider: provider, session: id, account: flag.observed, refused: false)
            }
            return nil
        }
    }

    /// Whether the account with `id` can no longer serve a session: at its
    /// limit by its last reading, or refused at it with no reading since
    /// (`FailoverPlanner.servingVerdict`).
    func accountCannotServe(_ id: UUID, now: Date = Date()) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        let planner = FailoverPlanner(settings: plannerSettings(account.provider))
        return planner.servingVerdict(quotaState(for: account, now: now), now: now, lead: 0) == .atLimit
    }

    /// Finds the stuck background sessions of every provider with a
    /// background service whose sessions are served from slots, offers
    /// each one's restart once in the events, and with
    /// `restartStuckBackgroundSessions` on restarts each once nothing holds
    /// it (`restartBlocker`), at most once every `stuckRestartSpacing`.
    /// Called on every quota cycle after `noteUnisolatedSessions`, which
    /// lists the background sessions and their states.
    func handleStuckBackgroundSessions(now: Date = Date()) async {
        var found: [String: StuckBackgroundSession] = [:]
        for provider in AIProviderType.isolatedProviders
        where provider.capabilities.backgroundSessions != nil && sessionSlotsInUse(provider) {
            let sessions = unisolatedSessions[provider] ?? []
            let stuck = Self.stuckBackgroundSessions(provider, sessions: sessions, background: backgroundSessionStates,
                                                     refusals: sessionRefusals, flagged: flaggedCredentialProcesses,
                                                     cannotServe: { accountCannotServe($0, now: now) })
            let restarts = failoverConfig.policy(for: provider).restartStuckBackgroundSessions
            for item in stuck {
                found[item.session] = item
                guard let session = sessions.first(where: { $0.sessionID == item.session }) else { continue }
                if stuckBackgroundNoted.insert(item.session).inserted {
                    let name = accounts.first { $0.id == item.account }.map { messageName($0) } ?? "its account"
                    failoverEvents.record(provider, Self.stuckBackgroundEvent(
                        session: Self.eventName(of: session), account: name, cli: provider.capabilities.displayName,
                        refused: item.refused, restarts: restarts))
                }
                guard restarts,
                      stuckBackgroundRestartedAt[item.session].map({ now.timeIntervalSince($0) >= Self.stuckRestartSpacing }) ?? true,
                      Self.restartBlocker(session, terminal: unisolatedTerminals[item.session],
                                          background: backgroundSessionStates[item.session], refused: item.refused,
                                          now: now) == nil
                else { continue }
                stuckBackgroundRestartedAt[item.session] = now
                if await restartInOwnSlot(item.session) { flaggedCredentialProcesses[item.session] = nil }
            }
        }
        if stuckBackgroundSessions != found { stuckBackgroundSessions = found }
        stuckBackgroundNoted.formIntersection(found.keys)
        stuckBackgroundRestartedAt = stuckBackgroundRestartedAt.filter { found[$0.key] != nil }
    }

    /// The event offering, or announcing, the restart of a stuck background
    /// session.
    nonisolated static func stuckBackgroundEvent(session: String, account: String, cli: String, refused: Bool,
                                                 restarts: Bool) -> String {
        let why = refused ? "was refused at a usage limit on \(account)" : "holds \(account)'s sign-in, which is at its limit"
        let head = "\(session) runs in \(cli)'s background service and \(why). Its worker keeps the token it read, "
            + "so telling it to read its sign-in again does not move it."
        return head + (restarts
            ? " AccountDock restarts it in its own slot once its attach client shows no work running."
            : " Restart it in its own slot from the usage tab, or turn on “Restart stuck background sessions in their own slot” under Failover.")
    }

    /// Whether a flagged process runs in its CLI's background service,
    /// whose worker does not read its sign-in again when signalled.
    func runsInBackgroundService(_ item: FlaggedCredentialProcess) -> Bool {
        backgroundSessionStates[item.session] != nil || backgroundProcesses(item.provider).isWorker(item.process)
    }
}
