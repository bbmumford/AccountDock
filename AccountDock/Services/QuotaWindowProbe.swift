import Foundation

/// Reads an account's live quota windows and starts an unstarted window with
/// the smallest request its provider accepts. Each provider supplies one
/// probe; the warm-up flow in `AppState.performWindowWarmup` is the same for
/// every provider, so a new provider only adds its case here.
struct QuotaWindowProbe {
    let liveUsage: () async throws -> UsageAPIResponse
    let startWindow: () async throws -> Void

    /// The credential a probe uses: the live one when the caller decided
    /// the account reads it (`AppState.readsLiveCredential`), its saved
    /// copy otherwise, so a warm-up never spends another account's window.
    static func credential(readsLive: Bool, live: () -> String?, saved: () -> String?) -> String? {
        readsLive ? live() : saved()
    }
}

extension AppState {
    /// The probe for `account`'s provider; nil when the provider has no
    /// usage reading or no request that starts a window. `readsLive` is
    /// `readsLiveCredential(account)`. Every probe read is recorded as a
    /// `probe` and every window start as a `warmup` of `account`, with the
    /// token it spent when AccountDock holds it.
    func quotaWindowProbe(for account: Account, readsLive: Bool) -> QuotaWindowProbe? {
        let audit = credentialAudit
        func recorded<T: Sendable>(_ action: CredentialAuditAction, token: String?,
                         _ work: () async throws -> T) async throws -> T {
            do {
                let value = try await work()
                audit.record(action, account.provider, account: account.id, accessToken: token, outcome: "ok",
                             reason: "performWindowWarmup", detail: readsLive ? "live credential" : "saved copy")
                return value
            } catch {
                audit.record(action, account.provider, account: account.id, accessToken: token, outcome: "failed",
                             reason: "performWindowWarmup",
                             detail: (readsLive ? "live credential: " : "saved copy: ") + error.localizedDescription)
                throw error
            }
        }
        switch account.provider {
        case .claudeCode:
            let accessToken: () throws -> String = { [keychain] in
                let tokenJSON = QuotaWindowProbe.credential(
                    readsLive: readsLive,
                    live: { keychain.readClaudeToken(reason: "performWindowWarmup", account: account.id) },
                    saved: { keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: "performWindowWarmup")?.token }
                )
                guard let tokenJSON, let token = ClaudeService.extractAccessToken(from: tokenJSON) else {
                    throw ClaudeService.UsageError.expired
                }
                return token
            }
            return QuotaWindowProbe(
                liveUsage: {
                    let token = try accessToken()
                    return try await recorded(.probe, token: token) { try await self.claudeService.getUsageLimits(accessToken: token) }
                },
                startWindow: {
                    let token = try accessToken()
                    try await recorded(.warmup, token: token) { try await self.claudeService.warmQuotaWindow(accessToken: token) }
                }
            )
        case .codex:
            // Codex's probe runs in the account's own home whichever
            // credential its sessions read.
            let token = { account.credentialLocation.flatMap(CodexService.accessToken(codexHome:)) }
            return QuotaWindowProbe(
                liveUsage: {
                    try await recorded(.probe, token: token()) {
                        try await self.codexService.getUsageLimits(codexHome: account.credentialLocation)
                    }
                },
                startWindow: {
                    try await recorded(.warmup, token: token()) {
                        try await self.codexService.warmQuotaWindow(codexHome: account.credentialLocation)
                    }
                }
            )
        case .kimi:
            guard let location = account.credentialLocation else { return nil }
            return QuotaWindowProbe(
                liveUsage: {
                    try await recorded(.probe, token: nil) {
                        try await self.kimiService.getUsageLimits(location: location, isActive: readsLive)
                    }
                },
                startWindow: {
                    try await recorded(.warmup, token: nil) {
                        try await self.kimiService.warmQuotaWindow(location: location, isActive: readsLive)
                    }
                }
            )
        case .gemini:
            return nil
        }
    }
}
