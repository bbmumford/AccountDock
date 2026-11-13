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
    /// `readsLiveCredential(account)`.
    func quotaWindowProbe(for account: Account, readsLive: Bool) -> QuotaWindowProbe? {
        switch account.provider {
        case .claudeCode:
            let accessToken: () throws -> String = { [keychain] in
                let tokenJSON = QuotaWindowProbe.credential(
                    readsLive: readsLive,
                    live: { keychain.readClaudeToken() },
                    saved: { keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token }
                )
                guard let tokenJSON, let token = ClaudeService.extractAccessToken(from: tokenJSON) else {
                    throw ClaudeService.UsageError.expired
                }
                return token
            }
            return QuotaWindowProbe(
                liveUsage: { try await self.claudeService.getUsageLimits(accessToken: try accessToken()) },
                startWindow: { try await self.claudeService.warmQuotaWindow(accessToken: try accessToken()) }
            )
        case .codex:
            return QuotaWindowProbe(
                liveUsage: { try await self.codexService.getUsageLimits(codexHome: account.credentialLocation) },
                startWindow: { try await self.codexService.warmQuotaWindow(codexHome: account.credentialLocation) }
            )
        case .kimi:
            guard let location = account.credentialLocation else { return nil }
            return QuotaWindowProbe(
                liveUsage: { try await self.kimiService.getUsageLimits(location: location, isActive: readsLive) },
                startWindow: { try await self.kimiService.warmQuotaWindow(location: location, isActive: readsLive) }
            )
        case .gemini:
            return nil
        }
    }
}
