import Foundation

/// Learns the token use of sessions the router does not carry from their
/// transcripts, so `SessionPacer` paces and moves them as it does routed
/// sessions.
extension AppState {
    /// One refusal of a session's request at a usage limit.
    struct SessionRefusal: Equatable {
        var at: Date
        /// The account serving the session when it was refused.
        var account: UUID
        /// The provider's words.
        var words: String
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
    /// `refreshSessions`.
    func ingestTranscriptRequests(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders
        where provider.capabilities.transcriptDirectory != nil && learnsRequestCost(provider) {
            let requests = await TranscriptRequestFeed.shared.newRequests(provider, now: now)
            guard !requests.isEmpty else { continue }
            let attribution = sessionAttribution(provider, now: now)
            let processes = sessionProcesses(provider)
            var refusedAt: [UUID: Date] = [:]
            for request in requests {
                if let model = request.model { noteSessionModel(request.session, model: model, at: request.at) }
                guard let decision = attribution.decide(session: request.session, process: processes[request.session]) else { continue }
                if let words = request.limitRefusal {
                    refusedAt[decision.account] = max(refusedAt[decision.account] ?? .distantPast, request.at)
                    noteRefusal(of: request.session, by: decision.account, words: words, at: request.at,
                                provider: provider, now: now)
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
            for (id, at) in refusedAt {
                guard let account = accounts.first(where: { $0.id == id }),
                      (accountWholeReadings[id]?.at ?? .distantPast) < at else { continue }
                await fetchUsageNow(account, priority: .critical)
            }
        }
    }
}
