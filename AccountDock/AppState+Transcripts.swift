import Foundation

/// Learns the token use, model, name and usage-limit refusals of sessions
/// the router does not carry from their transcripts, for every provider
/// with a `ProviderCapabilities.transcriptSource`, so `SessionPacer` paces
/// and moves them as it does routed sessions.
extension AppState {
    /// One refusal of a session's request at a usage limit.
    struct SessionRefusal: Equatable {
        var at: Date
        /// The account serving the session when it was refused.
        var account: UUID
        /// The provider's words.
        var words: String
        /// The account the session was attributed to when its refusal was
        /// read, when the reset it states names another (`account`); kept
        /// so `verifyRefusals` names the account again as readings arrive.
        var attributed: UUID? = nil
        /// False while the refusal's stated reset is no window of `account`
        /// by readings older than the refusal and the read that would
        /// settle it is held back (`verifyRefusals`); `recordedLimitRefusal`
        /// does not count it until then (`refusalCounts`).
        var verified = true
    }

    /// How far apart two refusals of one session must be to be recorded as
    /// two events; a session refused at a limit usually tries again at once.
    nonisolated static let refusalEventSpacing: TimeInterval = 10 * 60

    /// Whether a refusal at `at` is recorded as an event: it is recent, so
    /// the transcripts read back at launch add none, and the session's last
    /// refusal is `refusalEventSpacing` older or there was none.
    nonisolated static func refusalIsNews(at: Date, last: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(at) < refusalEventSpacing else { return false }
        return last.map { at.timeIntervalSince($0) >= refusalEventSpacing } ?? true
    }

    /// Marks a session as refused at a usage limit by `account`, and says so
    /// in the events once for each run of refusals.
    func noteRefusal(of session: String, by account: UUID, words: String, at: Date,
                     provider: AIProviderType, now: Date) {
        let last = sessionRefusals[session]?.at
        guard last.map({ $0 < at }) ?? true else { return }
        sessionRefusals[session] = SessionRefusal(at: at, account: account, words: words)
        guard Self.refusalIsNews(at: at, last: last, now: now) else { return }
        let record = liveSessions[provider]?.first { $0.sessionID == session }
        let who = sessionNames[session].map { "\($0) (\(Self.eventName(of: record)))" } ?? Self.eventName(of: record)
        let name = accounts.first { $0.id == account }.map { messageName($0) } ?? "its account"
        failoverEvents.record(provider, "\(who) was refused at a usage limit on \(name): \(words) It stops until it is told to go on.")
    }

    /// Records each request the providers' sessions made since the last
    /// cycle on the account serving the session (`SessionAttribution`).
    /// Requests of sessions the router served within
    /// `SessionAttribution.routerWindow` are left out while it runs, as the
    /// router already recorded them, and so are those made while a moved
    /// slot settles. An account that refused a request at a usage limit is
    /// read whole at once, when it has not been since: a model's own limit
    /// is known only from such a reading, and `maintainSessionSlots` and
    /// `evaluateFailover`, which run next, move the sessions the account
    /// can no longer serve. Called from `runQuotaCycle` after
    /// `refreshSessions`. The transcripts are read whether or not request
    /// cost is learned, since every request, its agent's included, is
    /// handed to the credential audit (`recordTranscriptRequest`), and a
    /// refusal whose words name a reset is compared with the account the
    /// session is believed to read (`noteProcessCredential`). A request of
    /// a session in a slot that moved is attributed to the account the slot
    /// served at the request's own time, and a refusal whose stated reset
    /// matches another account's window and not the attributed one's is
    /// that other account's: a session refused just after its slot moved
    /// was still on the account it left, and the account it moved to must
    /// not be taken to have refused it. Each refusal is then checked
    /// against fresh readings (`verifyRefusals`), together with those whose
    /// check an earlier cycle could not finish.
    func ingestTranscriptRequests(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders where provider.capabilities.transcriptSource != nil {
            let requests = await TranscriptRequestFeed.shared.newRequests(provider, now: now)
            let refused = recordTranscriptRequests(requests, provider: provider, now: now)
            // Checked again until they count anyway (`refusalCounts`).
            let unsettled = sessionRefusals.filter { _, refusal in
                !Self.refusalCounts(verified: refusal.verified, at: refusal.at, now: now)
                    && accounts.contains { $0.id == refusal.account && $0.provider == provider }
            }.map(\.key)
            let sessions = refused + unsettled.filter { !refused.contains($0) }
            if !sessions.isEmpty { await verifyRefusals(provider, sessions: sessions, now: now) }
        }
    }

    /// Records one provider's new transcript requests for
    /// `ingestTranscriptRequests`. Returns the sessions whose refusal was
    /// recorded.
    private func recordTranscriptRequests(_ requests: [TranscriptRequest], provider: AIProviderType, now: Date) -> [String] {
        guard !requests.isEmpty else { return [] }
        let learns = learnsRequestCost(provider)
        let attribution = sessionAttribution(provider, now: now)
        let processes = sessionProcesses(provider)
        var refused: [String] = []
        for request in requests {
            if let name = request.sessionName, sessionNames[request.session] != name { sessionNames[request.session] = name }
            if let model = request.model { noteSessionModel(request.session, model: model, at: request.at) }
            let process = processes[request.session]
            var decision = attribution.decide(session: request.session, process: process)
            // A slot that moved serves the request with the account it
            // held at the request's own time (`servingSlotAccount`).
            if let current = decision, current.source == .slot,
               let then = slotAccount(forSession: request.session, process: process, at: request.at),
               then != current.account {
                decision = SessionAttribution.Decision(account: then, source: .slot, observedAt: request.at)
            }
            recordTranscriptRequest(provider, request, decision: decision)
            let attributedBefore = decision?.account
            // A refusal is the account's whose window its stated reset
            // matches, when that is not the attributed account's.
            if let words = request.limitRefusal, let attributed = decision?.account {
                let refusing = Self.refusingAccount(words: words, at: request.at, attributed: attributed,
                                                    windows: resetWindows(provider))
                if refusing.byReset {
                    decision = SessionAttribution.Decision(account: refusing.account, source: decision?.source ?? .slot,
                                                           observedAt: request.at)
                    credentialAudit.record(.served, provider, account: attributed, outcome: "reattributed",
                                           reason: "ingestTranscriptRequests.refusal", session: request.session,
                                           process: process, source: "refusalReset", observedAt: request.at,
                                           detail: "Refused with a reset matching \(refusing.account.uuidString)'s window, not the attributed account's.")
                }
            }
            if let words = request.limitRefusal, request.agent == nil,
               let named = account(namedByRefusal: words, at: request.at, provider: provider) {
                noteProcessCredential(provider, session: request.session, process: process,
                                      observed: named, source: "refusalReset", observedAt: request.at)
            }
            guard learns, let decision else { continue }
            if let words = request.limitRefusal {
                noteRefusal(of: request.session, by: decision.account, words: words, at: request.at,
                            provider: provider, now: now)
                if sessionRefusals[request.session]?.at == request.at {
                    sessionRefusals[request.session]?.attributed = attributedBefore == decision.account ? nil : attributedBefore
                    if !refused.contains(request.session) { refused.append(request.session) }
                }
                continue
            }
            if let refusal = sessionRefusals[request.session], refusal.at < request.at {
                sessionRefusals[request.session] = nil
            }
            if decision.source == .router, routerInUse { continue }
            if decision.source == .slot,
               sessionSlotIsSettling(request.session, provider: provider, reportedAt: request.at) { continue }
            recordTurnUsage(request, account: decision.account)
        }
        return refused
    }

    // MARK: - Checking refusals against readings

    /// How many readings `verifyRefusals` takes in one cycle.
    nonisolated static let refusalReadsPerCycle = 4
    /// How many accounts in use whose readings predate a refusal are read
    /// for it in one round, when the account it names does not show its
    /// stated reset (`refusalVerification`).
    nonisolated static let refusalStaleReads = 2
    /// How long a refusal whose account is unsettled waits for the reading
    /// that settles it before it counts on the account it names anyway:
    /// the longest cool-down a throttle imposes
    /// (`UsageRequestBudget.longestCooldown`).
    nonisolated static let refusalVerificationWait: TimeInterval = 5 * 60

    /// What one refusal needs before anything moves for it, from the
    /// readings held now: the account it is the refusal of
    /// (`refusingAccount` from `attributed` over the stored `windows`);
    /// whether that account rests on readings that neither postdate the
    /// refusal nor show the reset it states (`doubtful`); and the accounts
    /// to read first. That account is read while its whole reading
    /// (`wholeAt`) is older than the refusal. Once it has been read and
    /// shows no window resetting at the stated time, the accounts sessions
    /// use (`inUse`) whose readings predate the refusal are read, oldest
    /// first: the reset is that of an account a session's token belongs
    /// to, whose stored windows are out of date.
    nonisolated static func refusalVerification(words: String, at: Date, attributed: UUID,
                                                windows: [(id: UUID, resets: [Date])], wholeAt: [UUID: Date],
                                                inUse: [UUID], calendar: Calendar = .current)
        -> (account: UUID, doubtful: Bool, read: [UUID]) {
        let owner = refusingAccount(words: words, at: at, attributed: attributed, windows: windows, calendar: calendar).account
        let reset = refusalResetDate(words, at: at, calendar: calendar)
        let corroborated = reset.map { reset in
            windows.first { $0.id == owner }?.resets.contains { abs($0.timeIntervalSince(reset)) < 10 * 60 } ?? false
        } ?? true
        func unread(_ id: UUID) -> Bool { (wholeAt[id] ?? .distantPast) < at }
        if unread(owner) { return (owner, !corroborated, [owner]) }
        guard !corroborated else { return (owner, false, []) }
        let stale = inUse.filter { $0 != owner && unread($0) }
            .sorted { (wholeAt[$0] ?? .distantPast) < (wholeAt[$1] ?? .distantPast) }
        return (owner, !stale.isEmpty, Array(stale.prefix(refusalStaleReads)))
    }

    /// Whether a refusal counts on its account yet (`recordedLimitRefusal`):
    /// once the account is settled (`SessionRefusal.verified`), or after
    /// `refusalVerificationWait` while the reading that would settle it is
    /// still held back.
    nonisolated static func refusalCounts(verified: Bool, at: Date, now: Date) -> Bool {
        verified || now.timeIntervalSince(at) >= refusalVerificationWait
    }

    /// Settles which account refused each of `sessions` before
    /// `maintainSessionSlots` and `evaluateFailover` move anything for it:
    /// reads the accounts `refusalVerification` names, from the critical
    /// allowance for the account the refusal names and the candidate one
    /// for the others, and moves the refusal to the account its stated
    /// reset names once read, which can need another round, up to
    /// `refusalReadsPerCycle` readings a cycle. A refusal still doubtful
    /// when its reading is held back stays unverified and is checked again
    /// at the next cycle (`ingestTranscriptRequests`). Each move is recorded
    /// in the credential audit.
    func verifyRefusals(_ provider: AIProviderType, sessions: [String], now: Date) async {
        var reads = 0
        let processes = sessionProcesses(provider)
        for session in sessions {
            guard var refusal = sessionRefusals[session],
                  now.timeIntervalSince(refusal.at) < Self.refusalStanding else { continue }
            let attributed = refusal.attributed ?? refusal.account
            var step = refusalStep(provider, refusal: refusal, attributed: attributed)
            for _ in 0..<3 where !step.read.isEmpty && reads < Self.refusalReadsPerCycle {
                var readAny = false
                for id in step.read where reads < Self.refusalReadsPerCycle {
                    guard let account = accounts.first(where: { $0.id == id }) else { continue }
                    reads += 1
                    if await fetchUsageNow(account, priority: id == step.account ? .critical : .candidate) { readAny = true }
                }
                guard readAny else { break }
                step = refusalStep(provider, refusal: refusal, attributed: attributed)
            }
            if step.account != refusal.account {
                credentialAudit.record(.served, provider, account: refusal.account, outcome: "reattributed",
                                       reason: "verifyRefusals", session: session, process: processes[session],
                                       source: "refusalReset", observedAt: refusal.at,
                                       detail: "Refused with a reset matching \(step.account.uuidString)'s window as read, not this account's.")
                refusal.account = step.account
            }
            refusal.attributed = step.account == attributed ? nil : attributed
            refusal.verified = !step.doubtful
            guard sessionRefusals[session]?.at == refusal.at else { continue }
            sessionRefusals[session] = refusal
        }
    }

    /// `refusalVerification` for `refusal` on the provider's readings now.
    private func refusalStep(_ provider: AIProviderType, refusal: SessionRefusal,
                             attributed: UUID) -> (account: UUID, doubtful: Bool, read: [UUID]) {
        let inUse = accounts.filter { account in
            account.provider == provider
                && (account.isActive || accountSessions[account.id]?.isEmpty == false || slotServedAccounts.contains(account.id))
        }.map(\.id)
        return Self.refusalVerification(words: refusal.words, at: refusal.at, attributed: attributed,
                                        windows: resetWindows(provider), wholeAt: accountWholeReadings.mapValues(\.at),
                                        inUse: inUse)
    }
}
