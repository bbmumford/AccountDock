import Foundation

/// Learns the token use of sessions the router does not carry from their
/// transcripts, so `SessionPacer` paces and moves them as it does routed
/// sessions.
extension AppState {
    /// Records each request the providers' sessions made since the last
    /// cycle on the account that served it: the account serving the
    /// session's slot, else the owner of the live credential, else the
    /// active account. Requests of sessions the router served in the last
    /// ten minutes are left out, as the router already recorded them.
    /// Called from `runQuotaCycle` after `refreshSessions`.
    func ingestTranscriptRequests(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders
        where provider.capabilities.transcriptDirectory != nil && learnsRequestCost(provider) {
            let requests = await TranscriptRequestFeed.shared.newRequests(provider, now: now)
            guard !requests.isEmpty else { continue }
            let shared = liveCredentialOwner(provider) ?? activeAccount(for: provider)?.id
            for request in requests {
                if let model = request.model { noteSessionModel(request.session, model: model, at: request.at) }
                if routerInUse, let seen = routedSessionSeen[request.session],
                   now.timeIntervalSince(seen.at) < 10 * 60 { continue }
                if sessionSlotIsSettling(request.session, provider: provider, reportedAt: request.at) { continue }
                guard let account = slotAccount(forSession: request.session, provider: provider) ?? shared else { continue }
                recordTurnUsage(request, account: account)
            }
        }
    }
}
