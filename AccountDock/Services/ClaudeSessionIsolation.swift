import CryptoKit
import Foundation

/// Claude Code's slots. `CLAUDE_SECURESTORAGE_CONFIG_DIR` names a directory,
/// and Claude Code then reads its credential from the Keychain item
/// `keychainService(base:directory:)` names for it instead of its default
/// item; everything else it keeps in `~/.claude` as usual, so every slot
/// shares its settings, hooks and transcripts. It reads the item again
/// before each request, so a rewritten slot needs no signal.
struct ClaudeSessionIsolation: ProviderSessionIsolation {
    /// The service of Claude Code's default credential item.
    static let defaultService = "Claude Code-credentials"

    let executable = "claude"
    let directoryVariable = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    let passThroughVariables = ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR",
                                "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
    let passThroughCommands = ["auth", "login", "logout", "setup-token"]
    let background: BackgroundSessionSupport? = BackgroundSessionSupport(
        workerCommands: ["bg-pty-host", "bg-spare"],
        attachCommand: "attach",
        stopCommand: "stop",
        managementCommands: ["attach", "stop", "logs", "rm", "agents", "daemon"],
        backgroundFlag: "--bg"
    )
    /// Claude Code's own installer puts it here.
    let installDirectories = [".claude/local"]

    var preferredExecutable: String? { ClaudeService.shared.claudePath }

    var resumeArgumentScript: String {
        SessionSlots.resumeArgumentScript(options: ["--resume", "-r"], inlineOptions: ["--resume"])
    }

    func resumeCommand(sessionID: String) -> String {
        "\(executable) --resume \(SessionSlots.shellQuoted(sessionID))"
    }

    // MARK: - Credential

    /// The stored credential JSON without any refresh token, with every
    /// non-ASCII character escaped as `SecurityToolKeychain` writes it, so
    /// `readCredential` returns it unchanged.
    func slotCredential(from credential: String) -> SlotCredential? {
        Self.accessOnly(credential).map { SlotCredential(contents: SecurityToolKeychain.asciiOnly($0)) }
    }

    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? {
        await state.claudeCredential(account, minimumLifetime: minimumLifetime).flatMap(slotCredential(from:))
    }

    /// The credential JSON without any `refreshToken`, or nil when it is not
    /// a JSON object.
    static func accessOnly(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object.removeValue(forKey: "refreshToken")
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: strip(root), options: [.sortedKeys]) else { return nil }
        return String(data: stripped, encoding: .utf8)
    }

    // MARK: - Keychain

    /// The Keychain service Claude Code reads for a slot directory: the
    /// default service, `-`, and the first eight hexadecimal digits of the
    /// SHA-256 of the path in Unicode normalization form C.
    static func keychainService(base: String, directory: String) -> String {
        let digest = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
        return base + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    func store(for directory: URL) -> SecurityToolKeychain {
        SecurityToolKeychain(service: Self.keychainService(base: Self.defaultService, directory: directory.path))
    }

    func prepareSlot(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        store(for: directory).apply(writes: [(NSUserName(), credential.contents)])
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        store(for: directory).read(account: NSUserName()).map(SlotCredential.init(contents:))
    }

    func removeSlot(_ directory: URL) {
        _ = store(for: directory).apply(writes: [], deletes: [NSUserName()])
    }

    func signalReread(_ directory: URL) {}
}
