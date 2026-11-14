import Foundation

/// `claude auth login` run in a directory of its own, so the sign-in never
/// reaches the CLI's live credential or `~/.claude.json`. Running sessions on
/// the shared sign-in renew and write back the live credential and their own
/// identity at any moment, so a sign-in read from there can be theirs.
///
/// The CLI keeps its credential in the Keychain item named for
/// `CLAUDE_SECURESTORAGE_CONFIG_DIR` (`ClaudeSessionIsolation.keychainService`,
/// the item the session slots use), or in `.credentials.json` there where it
/// falls back to a file, and its identity in `.claude.json` inside
/// `CLAUDE_CONFIG_DIR`; both point at the directory. `AppState`'s Claude
/// sign-in and re-authentication read the result, ask the provider whose it
/// is, save it, and the directory and its Keychain item are removed.
struct ClaudeIsolatedLogin {
    struct SignIn: Equatable {
        /// The credential JSON the CLI stored.
        var token: String
        /// The `oauthAccount` it wrote.
        var identity: [String: AnyCodable]
    }

    enum Failure: LocalizedError, Equatable {
        case noCredential
        case incompleteCredential
        case noIdentity

        var errorDescription: String? {
            switch self {
            case .noCredential: "The sign-in left no credential to save. Try again."
            case .incompleteCredential: "The sign-in's credential was incomplete, so it was not saved. Try again."
            case .noIdentity: "The sign-in did not say which account it is. Try again."
            }
        }
    }

    /// Runs `claude auth login` with the directory (`ClaudeService.login(isolatedIn:)`).
    var run: (URL) async throws -> Void
    /// The credential the CLI keeps in the Keychain item for the directory.
    var keychainCredential: (URL) -> String?
    /// Deletes that Keychain item.
    var removeKeychainCredential: (URL) -> Void
    /// Where the directory is made.
    var temporaryRoot = FileManager.default.temporaryDirectory

    /// The variables `run` sets: the CLI's configuration and secure-storage
    /// directories, both the isolated directory. A token or key in the
    /// environment would make the CLI sign in with it instead, so neither
    /// passes.
    static func environment(_ base: [String: String], directory: URL) -> [String: String] {
        var environment = base
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = directory.path
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        environment["ANTHROPIC_API_KEY"] = nil
        return environment
    }

    /// The live CLI, Keychain items and temporary directory.
    static func live(service: ClaudeService) -> ClaudeIsolatedLogin {
        let isolation = ClaudeSessionIsolation()
        return ClaudeIsolatedLogin(
            run: { try await service.login(isolatedIn: $0) },
            keychainCredential: { isolation.store(for: $0).read(account: NSUserName()) },
            removeKeychainCredential: { _ = isolation.store(for: $0).apply(writes: [], deletes: [NSUserName()]) }
        )
    }

    /// Signs in within a new directory and returns what the CLI stored,
    /// removing the directory and its Keychain item whatever happens.
    func signIn() async throws -> SignIn {
        let directory = temporaryRoot.appendingPathComponent("AccountDock-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            removeKeychainCredential(directory)
            try? FileManager.default.removeItem(at: directory)
        }
        try await run(directory)
        guard let token = keychainCredential(directory) ?? Self.fileCredential(in: directory) else { throw Failure.noCredential }
        guard AccountBackup.isCompleteCredential(token) else { throw Failure.incompleteCredential }
        guard let identity = ClaudeIdentityFile(url: directory.appendingPathComponent(".claude.json")).readOAuthAccount() else {
            throw Failure.noIdentity
        }
        return SignIn(token: token, identity: identity)
    }

    /// The credential file the CLI writes in its secure-storage directory
    /// when it does not use the Keychain.
    static func fileCredential(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".credentials.json"), encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a sign-in the provider says is `profileEmail`'s does.
    enum Outcome: Equatable {
        /// A new account.
        case add(email: String)
        /// A saved account's sign-in, renewed.
        case refresh(UUID)
        /// A re-authentication that signed in to another account.
        case wrongAccount(expected: String, actual: String)
    }

    /// `reauthenticating` must be the account signed in to; otherwise the
    /// saved Claude account with that email is refreshed, or a new one added.
    static func outcome(profileEmail: String, accounts: [Account], reauthenticating: Account?) -> Outcome {
        if let reauthenticating {
            return reauthenticating.matches(email: profileEmail)
                ? .refresh(reauthenticating.id)
                : .wrongAccount(expected: reauthenticating.email, actual: profileEmail)
        }
        if let existing = accounts.first(where: { $0.provider == .claudeCode && $0.matches(email: profileEmail) }) {
            return .refresh(existing.id)
        }
        return .add(email: profileEmail)
    }

    /// The plan the credential names (`claudeAiOauth.subscriptionType`).
    static func subscriptionType(of token: String) -> String? {
        guard let data = token.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["subscriptionType"] as? String
    }
}
