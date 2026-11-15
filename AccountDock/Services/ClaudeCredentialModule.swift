import Foundation

/// Claude's credential steps: saved copies are `KeychainService` account
/// backups, renewed through `ClaudeService.refreshStoredToken`, and the
/// live credential is Claude Code's shared Keychain slot, whose account
/// `~/.claude.json` names and Claude's profile endpoint confirms. Reads and
/// writes are recorded by `KeychainService`; renewals, ownership answers and
/// session signals are recorded here in `audit`.
@MainActor
struct ClaudeCredentialModule: ProviderCredentialModule, LiveCredentialModule {
    let keychain: KeychainService
    let service: ClaudeService
    var audit: CredentialAudit = .shared

    var liveCredential: LiveCredentialModule? { self }

    func hasSavedCopy(_ account: Account) -> Bool? {
        if keychain.hasAccountBackup(forAccountId: account.id.uuidString) { return true }
        return keychain.backupStoreAvailable ? false : nil
    }

    func renewSavedCopy(_ account: Account, reason: String) async -> CredentialRenewal {
        let subject = CredentialRenewalClient.AuditSubject(provider: .claudeCode, account: account.id)
        guard let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: reason) else {
            let outcome: CredentialRenewal = keychain.backupStoreAvailable ? .rejected : .unavailable
            audit.recordRenewal(subject, token: nil, previous: nil, outcome: "noSavedCopy", reason: reason)
            return outcome
        }
        do {
            let renewed = try await service.refreshStoredToken(backup.token)
            let saved = keychain.saveAccountBackup(
                token: renewed,
                oauthAccount: backup.oauthAccount,
                forAccountId: account.id.uuidString,
                reason: reason + ".renewal"
            )
            audit.recordRenewal(subject, token: .credential(renewed), previous: .credential(backup.token),
                                outcome: saved ? "renewed" : "notSaved", reason: reason)
            return saved ? .renewed : .unavailable
        } catch {
            let outcome = CredentialRenewalClient.auditOutcome(error, refused: Self.refusesGrant)
            audit.recordRenewal(subject, token: .credential(backup.token), previous: nil, outcome: outcome,
                                reason: reason)
            return outcome == "rejected" ? .rejected : .unavailable
        }
    }

    /// Whether `ClaudeService.refreshStoredToken` failed for a refused grant.
    nonisolated static func refusesGrant(_ error: Error) -> Bool {
        if case ClaudeService.UsageError.expired = error { return true }
        return false
    }


    func savedCopyLasts(_ account: Account, for interval: TimeInterval) -> Bool {
        guard let token = keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: "savedCopyLasts")?.token
        else { return false }
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

    func read(reason: String) -> String? {
        read(reason: reason, account: nil)
    }

    func read(reason: String, account: UUID?) -> String? {
        keychain.readClaudeToken(reason: reason, account: account).flatMap { AccountBackup.isCompleteCredential($0) ? $0 : nil }
    }

    /// Asks the profile endpoint whose `credential` is, and records the
    /// answer as an `ownershipCheck` of the live credential, which teaches
    /// `audit` the token's owner.
    func owner(of credential: String, reason: String) async throws -> CredentialOwner {
        guard let accessToken = ClaudeService.extractAccessToken(from: credential) else { throw LiveCredentialError.rejected }
        do {
            let identity = try await service.getProfileIdentity(accessToken: accessToken)
            audit.record(.ownershipCheck, .claudeCode, live: true, credential: credential, outcome: "answered",
                         reason: reason, owner: identity.email)
            return CredentialOwner(providerAccountID: identity.accountUUID, email: identity.email)
        } catch ClaudeService.UsageError.expired {
            audit.record(.ownershipCheck, .claudeCode, live: true, credential: credential, outcome: "rejected", reason: reason)
            throw LiveCredentialError.rejected
        } catch {
            audit.record(.ownershipCheck, .claudeCode, live: true, credential: credential, outcome: "unavailable",
                         reason: reason)
            throw error
        }
    }

    func rateLimitTier(of credential: String) -> String? {
        ClaudeService.rateLimitTier(from: credential)
    }

    func signedInEmail() -> String? {
        keychain.readOAuthAccount()?["emailAddress"]?.value as? String
    }

    func providerAccountID(ofSavedCopy account: Account) -> String? {
        keychain.savedIdentity(forAccountId: account.id.uuidString)?["accountUuid"]?.value as? String
    }

    func savedCopy(_ account: Account, reason: String) -> String? {
        keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: reason)?.token
    }

    /// The active account's copy takes the identity `~/.claude.json` holds,
    /// and only while it names that account; any other account keeps the
    /// identity saved with its copy.
    func save(_ credential: String, asCopyOf account: Account, reason: String) -> Bool {
        let oauthAccount: [String: AnyCodable]?
        if account.isActive {
            let live = keychain.readOAuthAccount()
            let email = live?["emailAddress"]?.value as? String
            oauthAccount = email?.caseInsensitiveCompare(account.email) == .orderedSame ? live : nil
        } else {
            oauthAccount = keychain.savedIdentity(forAccountId: account.id.uuidString)
        }
        guard let oauthAccount else {
            audit.record(.savedCopyWrite, .claudeCode, account: account.id, credential: credential,
                         outcome: "noIdentity", reason: reason)
            return false
        }
        return keychain.saveAccountBackup(token: credential, oauthAccount: oauthAccount, forAccountId: account.id.uuidString,
                                          reason: reason)
    }

    /// `~/.claude.json` is shared by every Claude Code session, including
    /// those `SessionSlots` starts on other accounts, and each writes its own
    /// account there; the identity saved with the account's copy is put back.
    func restoreSignedInIdentity(of account: Account) -> Bool {
        guard let identity = keychain.savedIdentity(forAccountId: account.id.uuidString),
              (identity["emailAddress"]?.value as? String)?.caseInsensitiveCompare(account.email) == .orderedSame
        else { return false }
        return keychain.writeOAuthAccount(identity)
    }

    func install(savedCopyOf account: Account, reason: String) -> Bool {
        guard let token = savedCopy(account, reason: reason), AccountBackup.isCompleteCredential(token) else { return false }
        return keychain.writeClaudeToken(token, account: account.id, reason: reason)
    }

    /// Claude Code holds its token in memory and reloads it only when the
    /// modification time of `.credentials.json` in its config directory
    /// changes, which it checks before each request; a Keychain write alone
    /// reaches no running session. Recorded as `signalSessions` with the
    /// live credential the sessions are told to read.
    func signalRunningSessions(reason: String) {
        let path = (AIProviderType.claudeCode.configDirectory as NSString)
            .expandingTildeInPath + "/.credentials.json"
        let touched = Self.touchIfPresent(path)
        audit.record(.signalSessions, .claudeCode, live: true, credential: keychain.readClaudeToken(reason: reason),
                     outcome: touched ? "touched" : "noCredentialFile", reason: reason)
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
