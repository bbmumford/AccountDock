import Foundation

/// The account serving each running session of one provider, decided by one
/// rule for every caller: the session counts on the account cards
/// (`AppState.refreshSessions`), the account its transcript requests are
/// learned on (`ingestTranscriptRequests`), the account a resumed session is
/// held again for (`servingAccount`, `reholdSessionsNearLimit`), the account
/// `SessionPacer` counts its rate on (`pacerSessions`) and the account a move
/// starts from (`handleExternalRequests`). `AppState.sessionAttribution`
/// builds it from what each source last saw.
///
/// A session on the CLI's shared sign-in keeps the token it read until it is
/// signalled to read the sign-in again (`moveRunningSessions`), so after the
/// active account changes it is still served by the earlier one. What it
/// last reported, or was last seen spending, therefore outranks the live
/// credential and the active account until its provider's sessions are
/// next signalled.
struct SessionAttribution {
    /// What decided a session's account, strongest first.
    enum Source: Equatable {
        /// The one-session slot its process reads.
        case slot
        /// The router served it within `routerWindow`.
        case router
        /// Its own status line, matched to an account by its reset times
        /// (`AppState.ingestPassiveTelemetry`).
        case lastServed
        /// A request recorded for it in `SessionRates`.
        case recordedRequest
        /// The provider's live credential, which a session reads when it
        /// starts or is signalled.
        case liveCredential
        /// The provider's active account.
        case activeAccount
    }

    struct Decision: Equatable {
        let account: UUID
        let source: Source
        /// When the evidence was seen; nil for the live credential and the
        /// active account, which say only where the session would read its
        /// sign-in now. `reholdSessionsNearLimit` compares it with when a
        /// session was resumed.
        let observedAt: Date?
    }

    /// One account seen serving a session, and when.
    struct Observation: Equatable {
        var account: UUID
        var at: Date
    }

    /// How long a session the router served counts on that account. The
    /// router keeps a session's account while it has room, and
    /// `AppState.applyRouterEvents` forgets sessions it has not seen for as
    /// long.
    static let routerWindow: TimeInterval = 10 * 60

    /// How long what a session reported or spent still names the account
    /// serving it, absent a signal: one session window, the span
    /// `AppState.quotaState` counts an account switched away from as still
    /// consumed by the sessions holding its credential (`lastSwitchedAway`).
    /// Past it the observation is not taken to show which token the session
    /// holds.
    static let servedLifetime: TimeInterval = FailoverPlanner.sessionWindow

    /// The account serving each slot-reading process.
    var slotAccounts: [Int32: UUID] = [:]
    var routerSeen: [String: Observation] = [:]
    var lastServed: [String: Observation] = [:]
    var recordedRequests: [String: Observation] = [:]
    /// When the provider's sessions were last told to read the live
    /// credential again.
    var signalledAt: Date?
    /// Read only when no stronger source decides, since reading it may ask
    /// the credential store.
    var liveCredentialOwner: @MainActor () -> UUID? = { nil }
    var activeAccount: UUID?
    var now: Date

    @MainActor
    func decide(session: String?, process: Int32?) -> Decision? {
        if let process, let account = slotAccounts[process] {
            return Decision(account: account, source: .slot, observedAt: now)
        }
        if let session {
            if let seen = routerSeen[session], now.timeIntervalSince(seen.at) < Self.routerWindow {
                return Decision(account: seen.account, source: .router, observedAt: seen.at)
            }
            if let served = lastServed[session], isCurrent(served) {
                return Decision(account: served.account, source: .lastServed, observedAt: served.at)
            }
            if let recorded = recordedRequests[session], isCurrent(recorded) {
                return Decision(account: recorded.account, source: .recordedRequest, observedAt: recorded.at)
            }
        }
        if let owner = liveCredentialOwner() {
            return Decision(account: owner, source: .liveCredential, observedAt: nil)
        }
        return activeAccount.map { Decision(account: $0, source: .activeAccount, observedAt: nil) }
    }

    /// Whether an observation still names the account serving its session:
    /// made after the provider's sessions were last signalled, and within
    /// `servedLifetime`.
    private func isCurrent(_ observation: Observation) -> Bool {
        guard now.timeIntervalSince(observation.at) < Self.servedLifetime else { return false }
        return signalledAt.map { observation.at > $0 } ?? true
    }
}
