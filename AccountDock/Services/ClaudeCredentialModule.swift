import Foundation

/// Claude's credential steps: saved copies are `KeychainService` account
/// backups, renewed through `ClaudeService.refreshStoredToken`, and the
/// live credential is Claude Code's shared Keychain slot, whose account
/// `~/.claude.json` names and Claude's profile endpoint confirms.
@MainActor
struct ClaudeCredentialModule: ProviderCredentialModule, LiveCredentialModule {
    let keychain: KeychainService
    let service: ClaudeService

    var liveCredential: LiveCredentialModule? { self }

    func hasSavedCopy(_ account: Account) -> Bool? {
        if keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil { return true }
        return keychain.backupStoreAvailable ? false : nil
    }

    func renewSavedCopy(_ account: Account) async -> CredentialRenewal {
        guard let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) else {
            return keychain.backupStoreAvailable ? .rejected : .unavailable
        }
        do {
            let renewed = try await service.refreshStoredToken(backup.token)
            return keychain.saveAccountBackup(
                token: renewed,
                oauthAccount: backup.oauthAccount,
                forAccountId: account.id.uuidString
            ) ? .renewed : .unavailable
        } catch ClaudeService.UsageError.expired {
            return .rejected
        } catch {
            return .unavailable
        }
    }

    func savedCopyLasts(_ account: Account, for interval: TimeInterval) -> Bool {
        guard let token = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token else { return false }
        return !Self.expires(token, within: interval)
    }

    /// Whether a Claude credential JSON's access token expires within
    /// `interval`; an unreadable expiry counts as expiring.
    nonisolated static func expires(_ tokenJSON: String, within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let data = tokenJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return true }
        return Date(timeIntervalSince1970: expiresAt / 1000) <= now.addingTimeInterval(interval)
    }

    // MARK: - Live credential

    func read() -> String? {
        keychain.readClaudeToken().flatMap { AccountBackup.isCompleteCredential($0) ? $0 : nil }
    }

    func owner(of credential: String) async throws -> CredentialOwner {
        guard let accessToken = ClaudeService.extractAccessToken(from: credential) else { throw LiveCredentialError.rejected }
        do {
            let identity = try await service.getProfileIdentity(accessToken: accessToken)
            return CredentialOwner(providerAccountID: identity.accountUUID, email: identity.email)
        } catch ClaudeService.UsageError.expired {
            throw LiveCredentialError.rejected
        }
    }

    func rateLimitTier(of credential: String) -> String? {
        ClaudeService.rateLimitTier(from: credential)
    }

    func signedInEmail() -> String? {
        keychain.readOAuthAccount()?["emailAddress"]?.value as? String
    }

    func providerAccountID(ofSavedCopy account: Account) -> String? {
        keychain.getAccountBackup(forAccountId: account.id.uuidString)?.oauthAccount["accountUuid"]?.value as? String
    }

    func savedCopy(_ account: Account) -> String? {
        keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
    }

    /// The active account's copy takes the identity `~/.claude.json` holds,
    /// and only while it names that account; any other account keeps the
    /// identity saved with its copy.
    func save(_ credential: String, asCopyOf account: Account) -> Bool {
        let oauthAccount: [String: AnyCodable]?
        if account.isActive {
            let live = keychain.readOAuthAccount()
            let email = live?["emailAddress"]?.value as? String
            oauthAccount = email?.caseInsensitiveCompare(account.email) == .orderedSame ? live : nil
        } else {
            oauthAccount = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.oauthAccount
        }
        guard let oauthAccount else { return false }
        return keychain.saveAccountBackup(token: credential, oauthAccount: oauthAccount, forAccountId: account.id.uuidString)
    }

    /// `~/.claude.json` is shared by every Claude Code session, including
    /// those `SessionSlots` starts on other accounts, and each writes its own
    /// account there; the identity saved with the account's copy is put back.
    func restoreSignedInIdentity(of account: Account) -> Bool {
        guard let identity = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.oauthAccount,
              (identity["emailAddress"]?.value as? String)?.caseInsensitiveCompare(account.email) == .orderedSame
        else { return false }
        return keychain.writeOAuthAccount(identity)
    }

    func install(savedCopyOf account: Account) -> Bool {
        guard let token = savedCopy(account), AccountBackup.isCompleteCredential(token) else { return false }
        return keychain.writeClaudeToken(token)
    }

    /// Claude Code holds its token in memory and reloads it only when the
    /// modification time of `.credentials.json` in its config directory
    /// changes, which it checks before each request; a Keychain write alone
    /// reaches no running session.
    func signalRunningSessions() {
        let path = (AIProviderType.claudeCode.configDirectory as NSString)
            .expandingTildeInPath + "/.credentials.json"
        _ = Self.touchIfPresent(path)
    }

    /// Sets a file's modification time without changing its contents. A
    /// missing file is not created: Claude Code then re-reads the Keychain
    /// at every check, and the file would be taken for a stored credential.
    @discardableResult
    nonisolated static func touchIfPresent(_ path: String, now: Date = Date()) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)) != nil
    }
}
