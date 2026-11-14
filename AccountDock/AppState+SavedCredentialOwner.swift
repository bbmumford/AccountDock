import Foundation

private let ownerLog = FileLog("Credentials")

/// Checks that an account's saved sign-in is that account's. A saved copy
/// is taken from the CLI's live credential, and the identity beside it from
/// the CLI's own file; when the two were written by different switches the
/// copy can be another account's, and everything read or served with it
/// then belongs to that other account.
extension AppState {
    enum SavedCopyOwner: Equatable {
        case own
        /// Another saved account of the provider.
        case other(UUID)
        /// An account AccountDock does not hold.
        case stranger
    }

    /// Whose sign-in the provider says a saved copy is, among `accounts`.
    nonisolated static func savedCopyOwner(profileEmail: String, account: Account, accounts: [Account]) -> SavedCopyOwner {
        if account.matches(email: profileEmail) { return .own }
        if let owner = accounts.first(where: { $0.provider == account.provider && $0.id != account.id && $0.matches(email: profileEmail) }) {
            return .other(owner.id)
        }
        return .stranger
    }

    /// What `savedCopyIsOwn` found.
    enum SavedCopyCheck: Equatable {
        case own
        /// Another account's; removed from the account.
        case notOwn
        /// Not asked yet: no request allowance, or the provider did not
        /// answer. Asked again at the account's next reading.
        case unchecked
    }

    /// Whether a reading made with a saved copy may be recorded and planned
    /// on (`readClaudeUsage`): only once the provider has said the copy is
    /// the account's own. A copy that is another account's reads that
    /// account's usage, and one not yet checked may be.
    nonisolated static func recordsReading(after check: SavedCopyCheck) -> Bool {
        check == .own
    }

    /// Whether `account`'s saved copy is its own, asked of the provider once
    /// for each copy (`savedCopyVerified`); `readClaudeUsage` asks before it
    /// uses one, and records the reading only for `.own`. A copy that is
    /// another saved account's is handed to that account when it is newer
    /// than the one held there, removed from `account`, and `account` is
    /// marked as needing sign-in with its reading cleared. A check that
    /// cannot be made leaves the copy `.unchecked`, which costs the account
    /// nothing but that reading. The check spends background request
    /// allowance, and waits for a later reading when there is none;
    /// `forced`, a reading the user asked for, makes it regardless.
    func savedCopyIsOwn(_ account: Account, tokenJSON: String, accessToken: String, forced: Bool = false) async -> SavedCopyCheck {
        let digest = Self.credentialDigest(tokenJSON)
        if savedCopyVerified[account.id] == digest { return .own }
        guard forced || spendUsageRequest(account.provider, .background),
              let email = try? await claudeService.getProfileIdentity(accessToken: accessToken).email else { return .unchecked }
        let owner = Self.savedCopyOwner(profileEmail: email, account: account, accounts: accounts)
        guard owner != .own else {
            savedCopyVerified[account.id] = digest
            return .own
        }
        var handedTo: Account?
        if case .other(let id) = owner, let other = accounts.first(where: { $0.id == id }),
           let held = keychain.getAccountBackup(forAccountId: id.uuidString) {
            let heldExpiry = Self.claudeAccessToken(held.token)?.1 ?? .distantPast
            let thisExpiry = Self.claudeAccessToken(tokenJSON)?.1 ?? .distantPast
            if thisExpiry > heldExpiry,
               keychain.saveAccountBackup(token: tokenJSON, oauthAccount: held.oauthAccount, forAccountId: id.uuidString) {
                handedTo = other
                savedCopyVerified[id] = digest
                rejectedCredentialAccounts.remove(id)
            }
        }
        keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        forgetUsage(of: account.id)
        let name = messageName(account)
        let moved = handedTo.map { " It was saved for \(messageName($0)), whose sign-in it is." } ?? ""
        ownerLog.error("The saved sign-in of \(account.id.uuidString) belongs to another account; removed from it")
        failoverEvents.record(account.provider, "\(name)'s saved sign-in was another account's, so the usage shown for \(name) was not its own.\(moved) Sign \(name) in again.")
        return .notOwn
    }

    // MARK: - Capturing the live sign-in

    /// What `captureLiveCredential` reads and writes: the CLI's Keychain
    /// slot and identity file, the profile endpoint and the saved copies in
    /// `captureOwnCredential`, fakes in tests.
    struct CredentialCaptureIO {
        /// The credential in the CLI's Keychain slot now.
        var liveToken: () -> String?
        /// The identity `~/.claude.json` holds now.
        var liveIdentity: () -> [String: AnyCodable]?
        /// The email the profile endpoint names for an access token.
        var profileEmail: (String) async throws -> String?
        /// The copy saved for an account.
        var held: (UUID) -> AccountBackup?
        /// Saves a credential and identity as an account's copy.
        var save: (String, [String: AnyCodable], UUID) -> Bool
        /// The wait before the live credential is read again.
        var pause: () async -> Void
    }

    enum CaptureOutcome: Equatable {
        case saved
        /// The live credential was, at every read, the account with this
        /// email's.
        case anotherAccounts(String)
        /// No read could be confirmed: no credential, an identity file
        /// naming another account, or no answer from the provider.
        case unconfirmed
    }

    /// How often `captureLiveCredential` reads the live credential before
    /// it gives up.
    nonisolated static let captureAttempts = 4

    /// Saves the live credential as `account`'s copy only once the provider
    /// says it is `account`'s. Running sessions renew the credential in the
    /// CLI's Keychain slot and write their own account into `~/.claude.json`
    /// at any moment, so neither the moment of the read nor the identity
    /// file says whose the credential is. A credential that is another
    /// account's of `accounts` is saved for that account instead when newer
    /// than the copy held there (as `savedCopyIsOwn` hands one on), and the
    /// slot is read again after `io.pause`, up to `captureAttempts` times;
    /// a provider that does not answer ends the capture at once.
    /// The identity saved is the live one when it names `account`, else the
    /// one saved with `account`'s copy; with neither the read does not
    /// count. Returns the outcome and the accounts a credential was handed
    /// to.
    static func captureLiveCredential(for account: Account, accounts: [Account], attempts: Int = captureAttempts,
                                      io: CredentialCaptureIO) async -> (outcome: CaptureOutcome, handedTo: [UUID]) {
        var outcome = CaptureOutcome.unconfirmed
        var handedTo: [UUID] = []
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { await io.pause() }
            guard let token = io.liveToken(), AccountBackup.isCompleteCredential(token),
                  let access = ClaudeService.extractAccessToken(from: token) else { continue }
            // No answer from the provider is not a session's write, which
            // another read could outlast.
            guard let email = try? await io.profileEmail(access) else { return (.unconfirmed, handedTo) }
            switch savedCopyOwner(profileEmail: email, account: account, accounts: accounts) {
            case .own:
                let live = io.liveIdentity().flatMap { account.matches(email: $0["emailAddress"]?.value as? String) ? $0 : nil }
                let saved = (io.held(account.id)?.oauthAccount)
                    .flatMap { account.matches(email: $0["emailAddress"]?.value as? String) ? $0 : nil }
                guard let identity = live ?? saved else { continue }
                return (io.save(token, identity, account.id) ? .saved : .unconfirmed, handedTo)
            case .other(let id):
                outcome = .anotherAccounts(email)
                if let held = io.held(id),
                   (claudeAccessToken(token)?.1 ?? .distantPast) > (claudeAccessToken(held.token)?.1 ?? .distantPast),
                   io.save(token, held.oauthAccount, id) {
                    handedTo.append(id)
                }
            case .stranger:
                outcome = .anotherAccounts(email)
            }
        }
        return (outcome, handedTo)
    }

    /// `captureLiveCredential` on the live slot, identity file and copies,
    /// pausing a second between reads. A copy saved or handed on counts as
    /// checked (`savedCopyVerified`).
    func captureOwnCredential(of account: Account) async -> CaptureOutcome {
        let result = await Self.captureLiveCredential(for: account, accounts: accounts, io: CredentialCaptureIO(
            liveToken: { self.keychain.readClaudeToken() },
            liveIdentity: { self.keychain.readOAuthAccount() },
            profileEmail: { try await self.claudeService.getProfileIdentity(accessToken: $0).email },
            held: { self.keychain.getAccountBackup(forAccountId: $0.uuidString) },
            save: { token, identity, id in
                guard self.keychain.saveAccountBackup(token: token, oauthAccount: identity, forAccountId: id.uuidString) else {
                    return false
                }
                self.savedCopyVerified[id] = Self.credentialDigest(token)
                return true
            },
            pause: { try? await Task.sleep(for: .seconds(1)) }
        ))
        for id in result.handedTo {
            rejectedCredentialAccounts.remove(id)
            ownerLog.info("A live credential captured for \(account.id.uuidString) was \(id.uuidString)'s and was saved for it")
        }
        if result.outcome != .saved {
            ownerLog.error("The live credential could not be saved for \(account.id.uuidString): \(String(describing: result.outcome))")
        }
        return result.outcome
    }

    /// Why a capture for `account` saved nothing, for the user.
    nonisolated static func captureFailure(_ outcome: CaptureOutcome, account: Account) -> String {
        switch outcome {
        case .saved:
            ""
        case .anotherAccounts(let email):
            "The sign-in Claude holds now is \(email)'s, not \(account.email)'s: a running Claude Code session wrote its own over it. Nothing was saved for \(account.email); try again, or close the sessions on the shared sign-in first."
        case .unconfirmed:
            "Claude could not confirm whose the sign-in it holds is, so nothing was saved for \(account.email). Try again."
        }
    }
}
