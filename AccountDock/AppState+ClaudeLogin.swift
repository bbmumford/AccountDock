import Foundation

private let loginLog = FileLog("ClaudeLogin")

/// Claude sign-ins for `loginNewAccount` and `reauthenticateAccount`, run
/// isolated from the live sign-in (`ClaudeIsolatedLogin`) and saved only as
/// the account the provider says they are.
extension AppState {
    /// Signs in isolated and asks the profile endpoint whose the credential
    /// is, then decides what it does (`ClaudeIsolatedLogin.outcome`). A
    /// re-authentication that signed in to another account sets
    /// `errorMessage` and saves nothing. The answer is recorded as an
    /// `isolatedLogin` by `reason`, attributed to the account re-authenticated
    /// or refreshed, which teaches the audit the new token's owner.
    func isolatedClaudeSignIn(reauthenticating: Account?, reason: String) async throws
        -> (ClaudeIsolatedLogin.SignIn, ClaudeIsolatedLogin.Outcome) {
        let signIn = try await ClaudeIsolatedLogin.live(service: claudeService).signIn()
        guard let access = ClaudeService.extractAccessToken(from: signIn.token) else {
            credentialAudit.record(.isolatedLogin, .claudeCode, account: reauthenticating?.id, credential: signIn.token,
                                   outcome: "incompleteCredential", reason: reason)
            throw ClaudeIsolatedLogin.Failure.incompleteCredential
        }
        guard let email = try await claudeService.getProfileIdentity(accessToken: access).email else {
            credentialAudit.record(.isolatedLogin, .claudeCode, account: reauthenticating?.id, credential: signIn.token,
                                   outcome: "noIdentity", reason: reason)
            throw ClaudeIsolatedLogin.Failure.noIdentity
        }
        let outcome = ClaudeIsolatedLogin.outcome(profileEmail: email, accounts: accounts, reauthenticating: reauthenticating)
        let attributed: UUID? = switch outcome {
        case .refresh(let id): id
        case .wrongAccount: reauthenticating?.id
        case .add: nil
        }
        let recorded = switch outcome {
        case .refresh: "refresh"
        case .wrongAccount: "wrongAccount"
        case .add: "add"
        }
        credentialAudit.record(.isolatedLogin, .claudeCode, account: attributed, credential: signIn.token,
                               outcome: recorded, reason: reason, owner: email)
        if case .wrongAccount(let expected, let actual) = outcome {
            errorMessage = String(localized: "Logged in as \(actual), but expected \(expected). Credentials not updated.",
                                  bundle: L10n.bundle)
            loginLog.error("Isolated sign-in was \(actual)'s, expected \(expected)")
        }
        return (signIn, outcome)
    }

    /// Saves an isolated sign-in as `account`'s copy, checked by the
    /// provider already (`savedCopyVerified`), and clears the account's
    /// rejection and quarantine. Only the active account's sign-in also
    /// becomes the live one, with its identity, and its running sessions are
    /// told to read it: an account in use whose sign-in was renewed would
    /// otherwise go on presenting the old one. `reason` names the caller.
    func saveIsolatedSignIn(_ signIn: ClaudeIsolatedLogin.SignIn, for account: Account, reason: String) {
        guard keychain.saveAccountBackup(token: signIn.token, oauthAccount: signIn.identity,
                                         forAccountId: account.id.uuidString, reason: reason) else {
            errorMessage = String(localized: "Could not save the sign-in for \(account.email).", bundle: L10n.bundle)
            return
        }
        savedCopyVerified[account.id] = Self.credentialDigest(signIn.token)
        rejectedCredentialAccounts.remove(account.id)
        credentialQuarantine[account.id] = nil
        // Read it at once: an account just signed in has no reading, and a
        // background read can wait for request allowance for many minutes,
        // leaving its card empty.
        let signedIn = account
        Task { _ = await readUsageNow(signedIn) }
        let active = accounts.first { $0.id == account.id }?.isActive ?? account.isActive
        guard active, let module = credentialModule(for: .claudeCode)?.liveCredential else { return }
        if module.install(savedCopyOf: account, reason: reason + ".installActive") {
            _ = module.restoreSignedInIdentity(of: account)
            noteLiveCredentialOwner(.claudeCode, account: account.id)
            module.signalRunningSessions(reason: reason + ".installActive")
            sessionsSignalledAt[.claudeCode] = Date()
        }
    }
}
