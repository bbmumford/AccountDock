import Foundation

/// What renewing an account's saved credential found. Only `rejected` says
/// the sign-in is dead; `unavailable` covers network and server failures
/// and a store still waiting for access, which say nothing about it.
enum CredentialRenewal: Equatable, Sendable { case renewed, rejected, unavailable }

/// The account a live credential belongs to, as its provider reports it.
struct CredentialOwner: Equatable, Sendable {
    /// The provider's own identifier for the account, when it reports one.
    let providerAccountID: String?
    let email: String?
}

enum LiveCredentialError: Error {
    /// The provider refused the credential, so it names no account.
    case rejected
}

/// A provider's part in AccountDock's credential process. The process, in
/// `AppState+Credentials`, is the same for every provider: when a saved
/// copy is renewed, the renewal before every switch, what a rejection means
/// for failover and the account views, and when a renewed live credential
/// is adopted. A module does only what needs the provider's own storage or
/// endpoints. `AppState.credentialModule(for:)` registers one per provider.
@MainActor
protocol ProviderCredentialModule {
    /// Whether AccountDock holds a saved copy of the account's credential;
    /// nil while the store cannot be read yet, such as a Keychain waiting
    /// for the user to allow access.
    func hasSavedCopy(_ account: Account) -> Bool?
    /// Renews the account's saved copy without changing the credential the
    /// CLI's running sessions use, and saves the renewed copy.
    func renewSavedCopy(_ account: Account) async -> CredentialRenewal
    /// Whether the saved copy's access token is still valid `interval` from
    /// now.
    func savedCopyLasts(_ account: Account, for interval: TimeInterval) -> Bool
    /// The live credential the CLI's sessions share and renew in place;
    /// nil when the provider keeps none.
    var liveCredential: LiveCredentialModule? { get }
}

/// The steps for a live credential that every running session of a CLI
/// renews in place, including sessions still running on an account that
/// was switched away from. Used by `AppState.adoptRenewedCredentials`.
@MainActor
protocol LiveCredentialModule {
    /// The live credential, when it can be read and is complete.
    func read() -> String?
    /// The account the credential belongs to. Throws
    /// `LiveCredentialError.rejected` when the provider refuses it.
    func owner(of credential: String) async throws -> CredentialOwner
    /// The email of the identity the CLI is signed in as, which a session
    /// renewing its credential does not change.
    func signedInEmail() -> String?
    /// The provider's identifier for the account its saved copy belongs to.
    func providerAccountID(ofSavedCopy account: Account) -> String?
    /// The account's saved copy of the credential.
    func savedCopy(_ account: Account) -> String?
    /// Saves a live credential as the account's copy.
    func save(_ credential: String, asCopyOf account: Account) -> Bool
    /// Makes the account's saved copy the live credential.
    func install(savedCopyOf account: Account) -> Bool
    /// Writes the identity saved with the account's copy as the one the CLI
    /// is signed in as, for when a session on another account rewrote it.
    func restoreSignedInIdentity(of account: Account) -> Bool
    /// The plan's rate-limit tier named in a credential, if any.
    func rateLimitTier(of credential: String) -> String?
    /// Tells running sessions the live credential changed, so each uses it
    /// from its next request; without this they keep the token they hold.
    func signalRunningSessions()
}
