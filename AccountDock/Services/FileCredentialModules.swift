import Foundation

/// Codex's credential steps: an account's saved copy is the `auth.json` in
/// its managed Codex home, renewed through `CodexService.renewCredential`.
/// Codex sessions share no live credential AccountDock adopts; the active
/// account's home is brought up to date by `CodexService` before a switch.
@MainActor
struct CodexCredentialModule: ProviderCredentialModule {
    let service: CodexService

    var liveCredential: LiveCredentialModule? { nil }

    func hasSavedCopy(_ account: Account) -> Bool? {
        account.credentialLocation != nil
    }

    func renewSavedCopy(_ account: Account) async -> CredentialRenewal {
        guard let home = account.credentialLocation else { return .rejected }
        return await service.renewCredential(codexHome: home)
    }

    func savedCopyLasts(_ account: Account, for interval: TimeInterval) -> Bool {
        guard let home = account.credentialLocation else { return false }
        return service.credentialLasts(codexHome: home, for: interval)
    }
}

/// Kimi's credential steps: an account's saved copy is its managed
/// `credentials.json`, renewed through `KimiService.renewCredential`. Kimi
/// sessions share no live credential AccountDock adopts.
@MainActor
struct KimiCredentialModule: ProviderCredentialModule {
    let service: KimiService

    var liveCredential: LiveCredentialModule? { nil }

    func hasSavedCopy(_ account: Account) -> Bool? {
        account.credentialLocation != nil
    }

    func renewSavedCopy(_ account: Account) async -> CredentialRenewal {
        guard let location = account.credentialLocation else { return .rejected }
        return await service.renewCredential(location: location)
    }

    func savedCopyLasts(_ account: Account, for interval: TimeInterval) -> Bool {
        guard let location = account.credentialLocation else { return false }
        return service.credentialLasts(location: location, for: interval)
    }
}
