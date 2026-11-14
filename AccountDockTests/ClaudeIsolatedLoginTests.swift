import XCTest
@testable import AccountDock

/// A Claude sign-in run with its own configuration and secure-storage
/// directory, through a stand-in `claude` that stores what the real CLI
/// stores where it stores it under those variables.
final class ClaudeIsolatedLoginTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDockTests-isolated-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let credential = #"{"claudeAiOauth":{"accessToken":"tok-hexorda","refreshToken":"ref-hexorda","expiresAt":2000000000000,"scopes":["user:inference"],"subscriptionType":"pro"}}"#

    /// A stand-in `claude` that, for `auth login`, writes the credential to
    /// `.credentials.json` in `CLAUDE_SECURESTORAGE_CONFIG_DIR` and the
    /// identity into `.claude.json` in `CLAUDE_CONFIG_DIR`, and records the
    /// directory it was given. It fails unless both name one directory.
    private func fakeClaude() throws -> URL {
        let script = root.appendingPathComponent("claude")
        let body = """
        #!/bin/sh
        [ "$1 $2" = "auth login" ] || exit 2
        dir="$CLAUDE_SECURESTORAGE_CONFIG_DIR"
        [ -n "$dir" ] && [ "$CLAUDE_CONFIG_DIR" = "$dir" ] || exit 3
        [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] || exit 4
        printf '%s' '\(credential)' > "$dir/.credentials.json"
        printf '%s' '{"numStartups":1,"oauthAccount":{"emailAddress":"hexorda@mail.example","organizationName":"Hexorda"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
        printf '%s' "$dir" > "\(root.path)/given-directory"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func login(removed: @escaping (URL) -> Void) throws -> ClaudeIsolatedLogin {
        let script = try fakeClaude()
        let runner = LoginProcessRunner()
        var base = ProcessInfo.processInfo.environment
        base["CLAUDE_CODE_OAUTH_TOKEN"] = "must-not-pass"
        let environment = base
        return ClaudeIsolatedLogin(
            run: { directory in
                _ = try await runner.run(executable: script.path, arguments: ["auth", "login"],
                                         environment: ClaudeIsolatedLogin.environment(environment, directory: directory))
            },
            keychainCredential: { _ in nil },
            removeKeychainCredential: removed,
            temporaryRoot: root
        )
    }

    func testTheSignInIsReadFromItsOwnDirectoryWhichIsThenRemoved() async throws {
        var removed: [URL] = []
        let signIn = try await login(removed: { removed.append($0) }).signIn()
        XCTAssertEqual(signIn.token, credential)
        XCTAssertEqual(signIn.identity["emailAddress"]?.value as? String, "hexorda@mail.example")
        let given = try String(contentsOf: root.appendingPathComponent("given-directory"), encoding: .utf8)
        XCTAssertTrue(given.hasPrefix(root.path + "/AccountDock-login-"), "never the live configuration")
        XCTAssertEqual(removed.map(\.path), [given], "its Keychain item is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: given), "and the directory with it")
        XCTAssertEqual(ClaudeIsolatedLogin.subscriptionType(of: signIn.token), "pro")
    }

    func testTheCLIsKeychainItemIsReadForTheDirectoryWhenItWroteOne() async throws {
        var asked: [URL] = []
        var isolated = try login(removed: { _ in })
        isolated.keychainCredential = { asked.append($0); return #"{"claudeAiOauth":{"accessToken":"kc","refreshToken":"r","expiresAt":2000000000000,"scopes":[]}}"# }
        let signIn = try await isolated.signIn()
        XCTAssertTrue(signIn.token.contains("\"kc\""))
        XCTAssertEqual(asked.count, 1)
        // The item the CLI names for that directory, as the session slots use.
        XCTAssertEqual(ClaudeSessionIsolation().store(for: asked[0]).service,
                       ClaudeSessionIsolation.keychainService(base: "Claude Code-credentials", directory: asked[0].path))
    }

    func testASignInThatStoredNothingFailsAndStillCleansUp() async throws {
        var removed: [URL] = []
        let login = ClaudeIsolatedLogin(run: { _ in }, keychainCredential: { _ in nil },
                                        removeKeychainCredential: { removed.append($0) }, temporaryRoot: root)
        do {
            _ = try await login.signIn()
            XCTFail("nothing to save")
        } catch {
            XCTAssertEqual(error as? ClaudeIsolatedLogin.Failure, .noCredential)
        }
        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed[0].path))
    }

    func testTheProvidersAnswerDecidesWhatTheSignInDoes() {
        let hstles = Account(email: "hstles@mail.example", displayName: "HSTLES", provider: .claudeCode)
        let hexorda = Account(email: "hexorda@mail.example", displayName: "hexorda", provider: .claudeCode)
        let codex = Account(email: "new@mail.example", displayName: "Codex", provider: .codex)
        // A new account.
        XCTAssertEqual(ClaudeIsolatedLogin.outcome(profileEmail: "new@mail.example", accounts: [hstles, codex],
                                                   reauthenticating: nil), .add(email: "new@mail.example"))
        // The account already exists: its sign-in is refreshed.
        XCTAssertEqual(ClaudeIsolatedLogin.outcome(profileEmail: "Hexorda@mail.example", accounts: [hstles, hexorda],
                                                   reauthenticating: nil), .refresh(hexorda.id))
        // Re-authentication of the account signed in to.
        XCTAssertEqual(ClaudeIsolatedLogin.outcome(profileEmail: "hexorda@mail.example", accounts: [hstles, hexorda],
                                                   reauthenticating: hexorda), .refresh(hexorda.id))
        // Re-authentication that signed in to another account saves nothing.
        XCTAssertEqual(ClaudeIsolatedLogin.outcome(profileEmail: "hstles@mail.example", accounts: [hstles, hexorda],
                                                   reauthenticating: hexorda),
                       .wrongAccount(expected: "hexorda@mail.example", actual: "hstles@mail.example"))
    }

    func testTheEnvironmentPointsTheCLIAtTheDirectoryAndPassesNoToken() {
        let directory = URL(fileURLWithPath: "/tmp/AccountDock-login-x")
        let environment = ClaudeIsolatedLogin.environment(["CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k",
                                                           "CLAUDE_CONFIG_DIR": "/Users/me/.claude", "PATH": "/bin"],
                                                          directory: directory)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertEqual(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], directory.path)
        XCTAssertNil(environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(environment["PATH"], "/bin")
    }
}
