import Foundation

private let loginLog = FileLog("ClaudeLogin")

/// Claude sign-ins for `loginNewAccount` and `reauthenticateAccount`, run
/// isolated from the live sign-in (`ClaudeIsolatedLogin`) and saved only as
/// the account the provider says they are.
extension AppState {
    /// Signs in isolated and asks the profile endpoint whose the credential
    /// is, then decides what it does (`ClaudeIsolatedLogin.outcome`). A
    /// re-authentication that signed in to another account sets
    /// `errorMessage` and saves nothing.
    func isolatedClaudeSignIn(reauthenticating: Account?) async throws
        -> (ClaudeIsolatedLogin.SignIn, ClaudeIsolatedLogin.Outcome) {
        let signIn = try await ClaudeIsolatedLogin.live(service: claudeService).signIn()
        guard let access = ClaudeService.extractAccessToken(from: signIn.token) else {
            throw ClaudeIsolatedLogin.Failure.incompleteCredential
        }
        guard let email = try await claudeService.getProfileIdentity(accessToken: access).email else {
            throw ClaudeIsolatedLogin.Failure.noIdentity
        }
        let outcome = ClaudeIsolatedLogin.outcome(profileEmail: email, accounts: accounts, reauthenticating: reauthenticating)
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
    /// otherwise go on presenting the old one.
    func saveIsolatedSignIn(_ signIn: ClaudeIsolatedLogin.SignIn, for account: Account) {
        guard keychain.saveAccountBackup(token: signIn.token, oauthAccount: signIn.identity,
                                         forAccountId: account.id.uuidString) else {
            errorMessage = String(localized: "Could not save the sign-in for \(account.email).", bundle: L10n.bundle)
            return
        }
        savedCopyVerified[account.id] = Self.credentialDigest(signIn.token)
        rejectedCredentialAccounts.remove(account.id)
        credentialQuarantine[account.id] = nil
        let active = accounts.first { $0.id == account.id }?.isActive ?? account.isActive
        guard active, let module = credentialModule(for: .claudeCode)?.liveCredential else { return }
        if module.install(savedCopyOf: account) {
            _ = module.restoreSignedInIdentity(of: account)
            noteLiveCredentialOwner(.claudeCode, account: account.id)
            module.signalRunningSessions()
            sessionsSignalledAt[.claudeCode] = Date()
        }
    }
}
