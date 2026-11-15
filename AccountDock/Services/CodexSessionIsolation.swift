import Foundation

private let log = FileLog("CodexSessionIsolation")

/// Codex's slots. Every slot runs in Codex's own home, `~/.codex`, so all
/// its sessions share their rollouts, history, settings and hooks; only the
/// credential differs, and it lives in the slot directory,
/// `credential.json`.
///
/// Codex reads that credential through a model provider of AccountDock's,
/// given on its command line (`slotArguments`): a provider named `OpenAI`,
/// which Codex treats as its own (the Codex backend's model list, remote
/// compaction, web search), at the ChatGPT Codex endpoint, whose bearer
/// token comes from a command Codex runs again every
/// `tokenRereadMilliseconds` and after a refused request. The command
/// prints the slot's access token, but only while the slot still serves
/// the account the session started on (`accountVariable`, sent as
/// `ChatGPT-Account-ID`); otherwise it fails, and the request goes without
/// a token rather than with another account's. Codex's own sign-in is set
/// to `ephemeral` storage, so a slot's session never reads `auth.json`,
/// never renews its refresh token, and asks for no sign-in.
///
/// A slot's credential holds one account's access token and its expiry and
/// no refresh token: Codex never renews a command-given token itself, so
/// AccountDock renews each account (`currentSlotCredential`) and rewrites
/// the slots before the token expires. A session reads only the account it
/// started on, so moving it to another is a restart (`movesNeedRestart`):
/// it is ended between turns with `/exit` and resumed with
/// `codex resume <id>` in a slot written for the new account.
struct CodexSessionIsolation: ProviderSessionIsolation {
    let executable = "codex"
    /// Names the slot directory in a session's environment; read by the
    /// token command and by `SessionSlots.directoriesByProcess`.
    let directoryVariable = "ACCOUNTDOCK_CODEX_SLOT"
    /// The account the session started on, read from the slot at launch;
    /// Codex sends it as `ChatGPT-Account-ID` with every request.
    static let accountVariable = "ACCOUNTDOCK_CODEX_ACCOUNT_ID"
    /// The slot file holding the credential (`SlotCredential.contents`).
    static let credentialFile = "credential.json"
    /// The model provider the slot arguments define.
    static let providerID = "accountdock"
    /// The ChatGPT Codex endpoint Codex's built-in provider uses with a
    /// ChatGPT sign-in.
    static let baseURL = "https://chatgpt.com/backend-api/codex"
    /// How often Codex runs the token command again while a session runs,
    /// so a rewritten token is used within this time.
    static let tokenRereadMilliseconds = 60_000
    /// Another home, an API key, or an access token of Codex's own each
    /// decide the credential already.
    let passThroughVariables = ["CODEX_HOME", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
    /// Sign-in and sign-out, and the commands that manage servers, plugins,
    /// the installation and saved sessions, or start a service other
    /// clients run their sessions through; none starts a session of its own
    /// on the user's terminal.
    let passThroughCommands = ["login", "logout", "mcp", "plugin", "app", "app-server", "remote-control",
                               "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "archive",
                               "delete", "unarchive", "cloud", "exec-server", "features", "help"]
    let background: BackgroundSessionSupport? = nil
    /// Codex's own installer puts it here.
    let installDirectories = [".codex/packages/standalone/current/bin"]
    var preferredExecutable: String? { CodexService.shared.binaryPath }
    let movesNeedRestart = true

    // MARK: - Launch

    /// The token command, run by Codex with the session's environment: the
    /// slot's access token while the slot serves `accountVariable`'s
    /// account, and a failure otherwise.
    static let tokenScript = #"f="$ACCOUNTDOCK_CODEX_SLOT/credential.json"; [ "$(/usr/bin/plutil -extract account_id raw -o - "$f")" = "$ACCOUNTDOCK_CODEX_ACCOUNT_ID" ] && exec /usr/bin/plutil -extract access_token raw -o - "$f""#

    /// The override that selects the slot provider, which marks a slot's
    /// process in `ps` output (`CodexService.isRestartableCodexCommand`).
    static let providerArgument = #"model_provider="\#(providerID)""#

    /// The `-c` overrides that make Codex read the slot, the same for every
    /// slot: the slot is named by the environment.
    static let slotArguments = arguments(baseURL: baseURL)

    /// The base URL of Codex's requests while AccountDock's router bridges
    /// them: the `openai_base_url` `ProviderRequestHold` writes into
    /// Codex's config. A slot session reads the slot provider's base URL
    /// instead of that key, so it is given this one while the key is set,
    /// and reaches the bridge as a session on Codex's own sign-in does.
    static var routedBaseURL: String { ProviderPassthrough.baseURL(key: AIProviderType.codex.capabilities.pauseGate?.key ?? "codex") }

    /// `slotArguments` with the slot provider's requests going to `baseURL`.
    static func arguments(baseURL: String) -> [String] {
        [
        providerArgument,
        #"model_providers.\#(providerID).name="OpenAI""#,
        #"model_providers.\#(providerID).base_url="\#(baseURL)""#,
        #"model_providers.\#(providerID).wire_api="responses""#,
        #"model_providers.\#(providerID).requires_openai_auth=false"#,
        #"model_providers.\#(providerID).auth.command="/bin/sh""#,
        #"model_providers.\#(providerID).auth.args=['-c','\#(tokenScript)']"#,
        #"model_providers.\#(providerID).auth.refresh_interval_ms=\#(tokenRereadMilliseconds)"#,
        #"model_providers.\#(providerID).env_http_headers.ChatGPT-Account-ID="\#(accountVariable)""#,
        #"cli_auth_credentials_store="ephemeral""#,
        ].flatMap { ["-c", $0] }
    }

    /// The launcher line that sets `b` to the slot provider's base URL as
    /// the session starts: `routedBaseURL` when Codex's config names it as
    /// `openai_base_url`, the ChatGPT Codex endpoint otherwise.
    static var baseURLLines: [String] {
        let config = "$HOME/" + (AIProviderType.codex.capabilities.requestHold?.settingsFile ?? ".codex/config.toml")
        return [
            #"b=$(/usr/bin/sed -n 's/^[[:space:]]*openai_base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' ""# + config
                + #"" 2>/dev/null | /usr/bin/head -n 1)"#,
            "[ \"$b\" = \(SessionSlots.shellQuoted(routedBaseURL)) ] || b=\(SessionSlots.shellQuoted(baseURL))",
        ]
    }

    /// Exports the slot directory and the account its credential names,
    /// then puts `slotArguments` before the user's; a slot whose credential
    /// names no account runs the CLI unchanged.
    func launcherExportLines(slot: String) -> [String] {
        let account = Self.accountVariable
        // Stands for the base URL the launcher reads as the session starts.
        let marker = "\u{1}"
        return [
            "\(directoryVariable)=\(slot)",
            "\(account)=$(/usr/bin/plutil -extract account_id raw -o - \"\(slot)/\(Self.credentialFile)\" 2>/dev/null) || exec \"$real\" \"$@\"",
            "[ -n \"$\(account)\" ] || exec \"$real\" \"$@\"",
            "export \(directoryVariable) \(account)",
        ] + Self.baseURLLines + [
            "set -- " + Self.arguments(baseURL: marker).map { argument in
                argument.contains(marker)
                    ? "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: marker, with: "$b") + "\""
                    : SessionSlots.shellQuoted(argument)
            }.joined(separator: " ") + " \"$@\"",
        ]
    }

    func launchAssignments(forSlot directory: URL) -> [(name: String, value: String)] {
        var assignments = [(name: directoryVariable, value: directory.path)]
        if let account = readCredential(in: directory).flatMap({ Self.field("account_id", in: $0.contents) }) {
            assignments.append((Self.accountVariable, account))
        }
        return assignments
    }

    /// The arguments of a session AccountDock starts in a slot, with the
    /// router's base URL while `ProviderRequestHold` bridges Codex.
    func launchArguments(forSlot directory: URL) -> [String] {
        Self.arguments(baseURL: ProviderRequestHold.isRouted(.codex) ? Self.routedBaseURL : Self.baseURL)
    }

    /// `codex resume <id>` and `codex exec resume <id>`: the first argument
    /// after `resume` that is no option.
    var resumeArgumentScript: String {
        """
        for argument in "$@"; do
          case "$previous" in resume) case "$argument" in -*) ;; *) resumed=$argument ;; esac ;; esac
          previous=$argument
        done
        """
    }

    func resumeCommand(sessionID: String) -> String {
        "\(executable) resume \(SessionSlots.shellQuoted(sessionID))"
    }

    // MARK: - Screen

    /// Lines at the bottom of the screen read for Codex's status rows; the
    /// transcript above them may quote either.
    static let footerLines = 8

    /// Codex shows `N background terminal(s) running · /ps to view` while
    /// commands it started run on, and `esc to interrupt` while a turn is
    /// under way; `/exit` would end both.
    func screenReportsRunningWork(_ screen: String) -> Bool {
        let lines = screen.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.suffix(Self.footerLines)
        return lines.contains { line in
            line.range(of: #"\b[1-9][0-9]* background terminals? running\b"#, options: .regularExpression) != nil
                || line.contains("esc to interrupt")
        }
    }

    /// Codex exits on `/exit` without asking about running work.
    func screenAsksAboutRunningWork(_ screen: String) -> Bool { false }

    /// Escape closes Codex's pickers; `screenAsksAboutRunningWork` never
    /// asks for it.
    let keepRunningKey = "\u{1B}"

    // MARK: - Credential

    /// Time the active account's token must still last when a slot is
    /// served with it, so it is renewed here well before Codex sessions
    /// outside slots, which renew it in its last minutes, would.
    static let liveRenewalLifetime: TimeInterval = 30 * 60
    /// Time any token served to a slot must still last: one maintenance
    /// pass replaces it before Codex is refused.
    static let minimumServedLifetime: TimeInterval = 2 * 60

    /// `credential`, the text of a Codex `auth.json` as AccountDock stores
    /// it, as the slot holds it: the access token, the account it was
    /// issued for and its expiry in whole seconds, keys sorted, so
    /// `readCredential` returns it unchanged. Nil without any of the three.
    func slotCredential(from credential: String) -> SlotCredential? {
        guard let data = credential.data(using: .utf8),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let account = CodexService.accountID(ofAuth: credential),
              let expiry = CodexService.accessTokenExpiry(ofAuth: credential) else { return nil }
        let slot: [String: Any] = [
            "access_token": accessToken,
            "account_id": account,
            "expires_at": Int(expiry.timeIntervalSince1970.rounded(.down)),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: slot, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return SlotCredential(contents: String(decoding: encoded, as: UTF8.self))
    }

    /// The account's credential as `CodexService.slotSourceCredential`
    /// reads it, renewed first when it lasts less than `minimumLifetime`,
    /// or for the account whose credential Codex's home holds less than
    /// `liveRenewalLifetime`. An inactive account's managed copy is renewed
    /// by `AppState.renewSavedCredential`, the active account's by
    /// `CodexService.renewLiveCredentialForSlots`, both inside
    /// `AppState.credentialGate`, so one refresh token is presented once.
    /// The pass that called this writes the token to every slot it serves.
    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? {
        guard let home = account.credentialLocation else { return nil }
        let service = state.codexService
        let isActive = state.readsLiveCredential(account)
        guard let stored = service.slotSourceCredential(codexHome: home, isActive: isActive,
                                                        reason: "currentSlotCredential") else { return nil }
        let required = isActive ? max(minimumLifetime, Self.liveRenewalLifetime) : minimumLifetime
        var current = stored
        if !Self.lasts(stored, for: required) {
            await state.credentialGate.run {
                if isActive {
                    switch await service.renewLiveCredentialForSlots(codexHome: home, lasting: required,
                                                                       reason: "currentSlotCredential.live") {
                    case .renewed: state.clearNeedsSignIn(account)
                    case .rejected: state.noteCredentialRejected(account)
                    case .unavailable: break
                    }
                } else {
                    _ = await state.renewSavedCredential(account, reason: "currentSlotCredential.saved")
                }
            }
            guard let renewed = service.slotSourceCredential(codexHome: home, isActive: isActive,
                                                             reason: "currentSlotCredential.renewed") else { return nil }
            current = renewed
        }
        guard Self.lasts(current, for: Self.minimumServedLifetime) else {
            log.warning("No access token of \(state.messageName(account)) lasts long enough to serve a slot")
            return nil
        }
        return slotCredential(from: current)
    }

    /// Whether the access token in an `auth.json`'s text is valid
    /// `interval` from now.
    static func lasts(_ credential: String, for interval: TimeInterval, now: Date = Date()) -> Bool {
        CodexService.accessTokenExpiry(ofAuth: credential).map { $0 > now.addingTimeInterval(interval) } ?? false
    }

    /// A string field of a slot credential.
    static func field(_ key: String, in contents: String) -> String? {
        guard let data = contents.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Slot

    func prepareSlot(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Written to a new file set to 0600, then renamed over the old one, so
    /// the token command never reads half a credential.
    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        do {
            try PrivateFile.writeAtomically(Data(credential.contents.utf8),
                                            to: directory.appendingPathComponent(Self.credentialFile), mode: 0o600)
        } catch {
            log.error("Slot credential not written: \(error.localizedDescription)")
            return false
        }
        return readCredential(in: directory) == credential
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        (try? String(contentsOf: directory.appendingPathComponent(Self.credentialFile), encoding: .utf8))
            .map(SlotCredential.init(contents:))
    }

    /// The credential lives in the slot directory, which
    /// `SessionSlots.remove` deletes.
    func removeSlot(_ directory: URL) {}

    /// Codex runs the token command again on its own every
    /// `tokenRereadMilliseconds` and after a refused request.
    func signalReread(_ directory: URL) {}
}
