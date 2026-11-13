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

    /// Whether `account`'s saved copy is its own, asked of the provider once
    /// for each copy (`savedCopyVerified`); `readClaudeUsage` asks before it
    /// uses one. A copy that is another saved account's is handed to that
    /// account when it is newer than the one held there, removed from
    /// `account`, and `account` is marked as needing sign-in with its
    /// reading cleared. A check that cannot be made counts as its own, so a
    /// network failure never costs an account its sign-in. The check spends
    /// background request allowance, and waits for a later reading when
    /// there is none; `forced`, a reading the user asked for, makes it
    /// regardless.
    func savedCopyIsOwn(_ account: Account, tokenJSON: String, accessToken: String, forced: Bool = false) async -> Bool {
        let digest = Self.credentialDigest(tokenJSON)
        if savedCopyVerified[account.id] == digest { return true }
        guard forced || spendUsageRequest(account.provider, .background),
              let email = try? await claudeService.getProfileIdentity(accessToken: accessToken).email else { return true }
        let owner = Self.savedCopyOwner(profileEmail: email, account: account, accounts: accounts)
        guard owner != .own else {
            savedCopyVerified[account.id] = digest
            return true
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
        return false
    }
}
