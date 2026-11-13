import Foundation

/// Learns the token use of sessions the router does not carry from their
/// transcripts, so `SessionPacer` paces and moves them as it does routed
/// sessions.
extension AppState {
    /// Records each request the providers' sessions made since the last
    /// cycle on the account serving the session (`SessionAttribution`).
    /// Requests of sessions the router served within
    /// `SessionAttribution.routerWindow` are left out while it runs, as the
    /// router already recorded them, and so are those made while a moved
    /// slot settles. Called from `runQuotaCycle` after `refreshSessions`.
    func ingestTranscriptRequests(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders
        where provider.capabilities.transcriptDirectory != nil && learnsRequestCost(provider) {
            let requests = await TranscriptRequestFeed.shared.newRequests(provider, now: now)
            guard !requests.isEmpty else { continue }
            let attribution = sessionAttribution(provider, now: now)
            let processes = sessionProcesses(provider)
            for request in requests {
                if let model = request.model { noteSessionModel(request.session, model: model, at: request.at) }
                guard let decision = attribution.decide(session: request.session, process: processes[request.session]) else { continue }
                if decision.source == .router, routerInUse { continue }
                if decision.source == .slot,
                   sessionSlotIsSettling(request.session, provider: provider, reportedAt: request.at) { continue }
                recordTurnUsage(request, account: decision.account)
            }
        }
    }
}
