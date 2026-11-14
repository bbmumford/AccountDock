import Foundation
import Darwin

private let codexLog = FileLog("Codex")

struct CodexIdentity: Sendable {
    let email: String
    let displayName: String
    let accountID: String?
    let planType: String?
}

struct CodexUsageSnapshot: Sendable {
    var usage: UsageAPIResponse
    let planType: String?
}

struct RunningCodexProcess: Hashable, Identifiable, Sendable {
    let id: Int32
    let command: String
    let sessionID: String?
    let workingDirectory: String?
    let host: String
    let terminalTTY: String?
    let hasUsageLimitError: Bool

    var isHostManaged: Bool {
        host == "vscode" || host == "chatgpt"
    }

    var label: String {
        switch host {
        case "vscode": return "VS Code Codex session"
        case "chatgpt": return "ChatGPT Codex session"
        default: return "Codex CLI session"
        }
    }
}

enum CodexServiceError: LocalizedError {
    case binaryNotFound
    case notLoggedIn
    case invalidCredentials
    case subscriptionUnavailable
    /// The provider throttled the request, until `retryAt` when it said.
    case rateLimited(retryAt: Date?)
    case loginFailed(String)
    case unsafeCredentialLocation
    /// The token endpoint refused the refresh token: the account must sign
    /// in again.
    case credentialRejected
    /// A session restart could not prepare the resume of every session it
    /// would stop, so it stopped none.
    case restartUnavailable(String)
    /// The live credential in `~/.codex` needs renewing while Codex runs,
    /// which renews it itself.
    case liveCredentialExpired

    var errorDescription: String? {
        switch self {
        case .liveCredentialExpired:
            return "The Codex sign-in expired; Codex renews it with its next request."
        case let .restartUnavailable(reason):
            return "Codex sessions were not restarted: \(reason)"
        case .binaryNotFound:
            return "Codex CLI not found. Install Codex or choose its path in Settings."
        case .notLoggedIn:
            return "No Codex login was found."
        case .invalidCredentials:
            return "Codex credentials could not be read."
        case .subscriptionUnavailable:
            return "This account does not currently have a Codex-capable subscription."
        case .rateLimited:
            return "Codex usage refresh is temporarily rate limited."
        case let .loginFailed(message):
            return "Codex login failed: \(message)"
        case .unsafeCredentialLocation:
            return "The managed Codex account location is outside AccountDock's storage."
        case .credentialRejected:
            return "Codex rejected this account's saved sign-in. Reauthenticate this account."
        }
    }
}

/// Manages Codex accounts with isolated CODEX_HOME directories, then atomically
/// promotes the selected account's auth.json to ~/.codex/auth.json.
final class CodexService: @unchecked Sendable {
    static let shared = CodexService()

    private let fileManager = FileManager.default
    private let binaryPreferenceKey = "codexBinaryPathPreference"
    private let loginRunner = LoginProcessRunner()
    /// Sends Codex's token renewals (`refreshOAuthTokens`).
    var renewalClient = CredentialRenewalClient()


    var binaryPath: String? {
        if let preferred = UserDefaults.standard.string(forKey: binaryPreferenceKey),
           !preferred.isEmpty,
           fileManager.isExecutableFile(atPath: preferred) {
            return preferred
        }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    func setBinaryPath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: binaryPreferenceKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: binaryPreferenceKey)
        }
    }

    func recoverableRunningProcesses() -> [RunningCodexProcess] {
        let records = AgentSessions.byProcess(.codex)
        return runningCodexProcesses().map { process in
            let record = records[process.id]
            let sessionID = Self.extractResumeSessionID(from: process.command) ?? record?.sessionID
            let rolloutPath = sessionID.flatMap(Self.rolloutPath)
            return RunningCodexProcess(
                id: process.id,
                command: process.command,
                sessionID: sessionID,
                workingDirectory: record?.workingDirectory,
                host: record?.host ?? process.host,
                terminalTTY: process.terminalTTY,
                hasUsageLimitError: rolloutPath.map(Self.rolloutEndsWithUsageLimit) ?? false
            )
        }
    }

    func terminateForSafeRestart(
        _ processes: [RunningCodexProcess],
        shouldCloseTerminalTabs: Bool = false
    ) async -> [RunningCodexProcess] {
        for process in processes {
            if Darwin.kill(process.id, SIGTERM) != 0, errno != ESRCH {
                codexLog.warning("[safeRestart] Could not terminate pid \(process.id): errno \(errno)")
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let remaining = processes.filter { Darwin.kill($0.id, 0) == 0 || errno == EPERM }
            if remaining.isEmpty {
                if shouldCloseTerminalTabs {
                    closeTerminalTabs(for: processes)
                }
                return []
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return processes.filter { Darwin.kill($0.id, 0) == 0 || errno == EPERM }
    }

    /// Requests an in-process credential reload from the AccountDock Codex
    /// fork. Stock Codex does not handle SIGUSR1, so this is intentionally used
    /// only by the explicitly selected Switch Without Restart workflow.
    func requestCredentialReload(_ processes: [RunningCodexProcess]) -> [RunningCodexProcess] {
        processes.filter { process in
            if Darwin.kill(process.id, SIGUSR1) == 0 {
                codexLog.info("[liveSwitch] Requested credential reload for pid \(process.id)")
                return false
            }
            codexLog.warning("[liveSwitch] Could not signal pid \(process.id): errno \(errno)")
            return errno != ESRCH
        }
    }

    /// The shell command that reopens session `sessionID` in `directory`,
    /// against the credential in `codexHome` when one is given.
    static func resumeCommand(binary: String, sessionID: String, directory: String, codexHome: String?) -> String {
        let scope = codexHome.map { "CODEX_HOME=\(shellQuote($0)) " } ?? ""
        return "\(scope)\(shellQuote(binary)) resume \(shellQuote(sessionID)) -C \(shellQuote(directory))"
    }

    /// Sessions `stopForRestart` stopped, each terminal session with the
    /// Terminal launch that reopens it. Host-managed sessions and sessions
    /// without an ID have none: their host reconnects them, or they cannot
    /// be resumed.
    struct StoppedSessions: Sendable {
        /// Processes still running after the grace period.
        let survivors: [RunningCodexProcess]
        let resumes: [(process: RunningCodexProcess, launch: SessionTerminal.PreparedLaunch)]

        /// Reopens every stopped session that has a launch, and discards the
        /// launches of sessions that did not stop. Returns how many reopened.
        @discardableResult
        func resume() -> Int {
            let surviving = Set(survivors.map(\.id))
            var reopened = 0
            for (process, launch) in resumes {
                if surviving.contains(process.id) {
                    launch.discard()
                } else {
                    launch.open()
                    reopened += 1
                    codexLog.info("[safeRestart] Reopened session \(process.sessionID?.prefix(8) ?? "")… in Terminal")
                }
            }
            return reopened
        }
    }

    /// Stops `processes` to restart them, after preparing the Terminal
    /// launch that resumes each terminal session (`resumeCommand`, scoped to
    /// `codexHome`). When any launch cannot be prepared, nothing is stopped
    /// and the error is thrown. The caller resumes the result with
    /// `StoppedSessions.resume()` whether or not what it does while they are
    /// stopped succeeds. `prepare` and `binary` are replaced in tests.
    func stopForRestart(
        _ processes: [RunningCodexProcess],
        codexHome: String?,
        shouldCloseTerminalTabs: Bool = false,
        binary: String? = nil,
        prepare: @Sendable (String) throws -> SessionTerminal.PreparedLaunch = { try SessionTerminal.prepareTerminalLaunch($0) }
    ) async throws -> StoppedSessions {
        var resumes: [(process: RunningCodexProcess, launch: SessionTerminal.PreparedLaunch)] = []
        do {
            for process in processes {
                guard !process.isHostManaged, let sessionID = process.sessionID else {
                    if process.isHostManaged {
                        codexLog.info("[safeRestart] \(process.label) left to its host to reconnect")
                    } else {
                        codexLog.warning("[safeRestart] No session ID available for pid \(process.id)")
                    }
                    continue
                }
                guard let executable = binary ?? binaryPath else { throw CodexServiceError.binaryNotFound }
                let command = Self.resumeCommand(
                    binary: executable, sessionID: sessionID,
                    directory: process.workingDirectory ?? NSHomeDirectory(), codexHome: codexHome
                )
                resumes.append((process, try prepare(command)))
            }
        } catch {
            resumes.forEach { $0.launch.discard() }
            codexLog.warning("[safeRestart] Resume not prepared; no session stopped: \(error.localizedDescription)")
            throw CodexServiceError.restartUnavailable(error.localizedDescription)
        }
        let survivors = await terminateForSafeRestart(processes, shouldCloseTerminalTabs: shouldCloseTerminalTabs)
        return StoppedSessions(survivors: survivors, resumes: resumes)
    }

    private struct CodexProcess {
        let id: Int32
        let command: String
        let host: String
        let terminalTTY: String?
    }

    /// The restartable Codex processes in a fresh `ProcessTable`, the
    /// highest of each tree only.
    private func runningCodexProcesses() -> [CodexProcess] {
        guard let table = ProcessTable.read() else { return [] }
        let parsed: [(Int32, Int32, String, String)] = table.entries.map { ($0.pid, $0.ppid, $0.tty, $0.command) }
        let commandByPID = Dictionary(parsed.map { ($0.0, $0.3) }, uniquingKeysWith: { first, _ in first })
        let parentByPID = Dictionary(parsed.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        let candidates = parsed.filter { _, _, _, command in
            Self.isRestartableCodexCommand(command)
        }
        let candidateIDs = Set(candidates.map(\.0))
        return candidates.compactMap { pid, ppid, tty, command in
            // Restart only the highest Codex process in a tree. Terminating a
            // CLI root also stops its app-server and helper descendants.
            var ancestor = ppid
            var visited = Set<Int32>()
            while ancestor > 1, visited.insert(ancestor).inserted {
                if candidateIDs.contains(ancestor) { return nil }
                guard let next = parentByPID[ancestor] else { break }
                ancestor = next
            }
            var host = "cli"
            ancestor = ppid
            visited.removeAll()
            while ancestor > 1, visited.insert(ancestor).inserted {
                let ancestorCommand = commandByPID[ancestor] ?? ""
                if ancestorCommand.contains("/Visual Studio Code.app/") || ancestorCommand.contains("Code Helper") {
                    host = "vscode"
                    break
                }
                if ancestorCommand.contains("/ChatGPT.app/") {
                    host = "chatgpt"
                    break
                }
                guard let next = parentByPID[ancestor] else { break }
                ancestor = next
            }
            return CodexProcess(
                id: pid,
                command: command,
                host: host,
                terminalTTY: tty == "??" ? nil : tty
            )
        }
    }

    /// A Codex CLI process a switch of `auth.json` reaches. A session in an
    /// AccountDock slot (`CodexSessionIsolation.slotArguments` on its
    /// command line) reads its slot's credential and never `auth.json`, so a
    /// switch leaves it running.
    static func isRestartableCodexCommand(_ command: String) -> Bool {
        let fields = command.split(whereSeparator: \.isWhitespace)
        guard let executable = fields.first.map(String.init) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard name == "codex" else { return false }
        return !command.contains("app-server") && !command.contains(CodexSessionIsolation.providerArgument)
    }

    static func extractResumeSessionID(from command: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|\s)resume(?:\s+|=)([A-Za-z0-9._:-]+)"#
        ) else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let valueRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[valueRange])
    }

    private func closeTerminalTabs(for processes: [RunningCodexProcess]) {
        let ttys = Set(processes.compactMap(\.terminalTTY))
        guard !ttys.isEmpty else { return }
        let ttyList = ttys.map { Self.appleScriptQuote("/dev/\($0)") }.joined(separator: ", ")
        let script = """
        tell application "Terminal"
            repeat with windowIndex from (count of windows) to 1 by -1
                set w to window windowIndex
                repeat with tabIndex from (count of tabs of w) to 1 by -1
                    set t to tab tabIndex of w
                    if tty of t is in {\(ttyList)} then close t
                end repeat
            end repeat
        end tell
        """
        do {
            _ = try CommandRunner.runSynchronously(
                CommandRunner.Command("/usr/bin/osascript", ["-e", script], errorOutput: .discarded), timeout: .infinity
            )
        } catch {
            codexLog.warning("[forceRestart] Could not close Terminal tabs: \(error.localizedDescription)")
        }
    }

    static func rolloutPath(for sessionID: String) -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                  Self.sessionID(fromRolloutPath: url.path) == sessionID else { continue }
            return url.path
        }
        return nil
    }

    /// Returns true only when the latest submitted turn ended with a real
    /// provider usage-limit error. Older errors before a newer user message do
    /// not arm another failover.
    static func rolloutEndsWithUsageLimit(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let tailLength = min(length, 256 * 1024)
        try? handle.seek(toOffset: length - tailLength)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if type == "user_message" { return false }
            guard type == "error" else { continue }
            let message = (payload["message"] as? String ?? "").lowercased()
            let errorInfo = String(describing: payload["codex_error_info"] ?? "").lowercased()
            return message.contains("usage limit")
                || message.contains("quota exceeded")
                || errorInfo.contains("usage_limit")
                || errorInfo.contains("rate_limit_reached")
        }
        return false
    }

    static func sessionID(fromRolloutPath path: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(path.startIndex..., in: path)
        guard let match = regex.firstMatch(in: path, range: range),
              let valueRange = Range(match.range(at: 1), in: path) else { return nil }
        return String(path[valueRange])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func detectedBinaryPaths() -> [String] {
        var paths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ].filter(fileManager.isExecutableFile(atPath:))
        if let selected = binaryPath, !paths.contains(selected) {
            paths.insert(selected, at: 0)
        }
        return paths
    }

    var managedRoot: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AccountDock/managed-codex-homes", isDirectory: true)
    }

    /// The Codex home running sessions use, `~/.codex`, whose `auth.json`
    /// holds the active account's live credential.
    let systemHome: URL
    /// Whether a Codex process is running, which renews the live credential
    /// itself (`getUsageSnapshot`).
    private let cliIsRunning: @Sendable () async -> Bool
    /// Where every write, removal, renewal and read for use of a Codex
    /// credential here is recorded.
    private let audit: CredentialAudit

    /// `systemHome` and `cliIsRunning` default to the user's `~/.codex` and
    /// a process scan; tests pass their own, and may pass an `audit`.
    init(
        systemHome: URL? = nil,
        cliIsRunning: @escaping @Sendable () async -> Bool = { await CLIProcessScan.isRunning(.codex) },
        audit: CredentialAudit = .shared
    ) {
        self.systemHome = systemHome
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
        self.cliIsRunning = cliIsRunning
        self.audit = audit
    }

    /// Whether `home` is `systemHome`, whose credential is the live one.
    private func isSystemHome(_ home: URL) -> Bool {
        home.standardizedFileURL.path == systemHome.standardizedFileURL.path
    }

    /// The access token of an `auth.json` file, for the audit's fingerprint.
    private static func accessToken(inAuthFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any] else { return nil }
        return tokens["access_token"] as? String
    }

    /// Whether this reader may renew the credential in `home`. The live one
    /// in `systemHome` is left to Codex while any Codex process runs: Codex
    /// reloads `auth.json` before it renews, but takes no lock on it, so a
    /// renewal here racing its own leaves one of them with a refresh token
    /// the server has already used, and Codex then asks the user to sign in
    /// again.
    private func mayRenewCredential(in home: URL) async -> Bool {
        guard isSystemHome(home) else { return true }
        return !(await cliIsRunning())
    }

    func isAvailable() async -> Bool {
        guard let binaryPath else { return false }
        return (try? await run(binary: binaryPath, arguments: ["--version"], codexHome: nil)) != nil
    }

    /// Reads this account's isolated Codex OAuth credentials and queries the
    /// same first-party usage endpoint used by the Codex CLI ecosystem.
    /// AccountDock performs the request itself; CodexBar is not invoked.
    func getUsageLimits(codexHome: String?) async throws -> UsageAPIResponse {
        try await getUsageSnapshot(codexHome: codexHome).usage
    }

    /// Starts the account's quota countdown with a deliberately ephemeral
    /// request. Codex is instructed not to persist a rollout/session file.
    func warmQuotaWindow(codexHome: String?) async throws {
        guard let binaryPath else { throw CodexServiceError.binaryNotFound }
        let arguments = [
            "exec", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--ignore-rules",
            "--ignore-user-config",
            "--config", "cli_auth_credentials_store=\"file\"",
            "Reply with exactly: OK"
        ]
        var environment = ProcessInfo.processInfo.environment
        if let codexHome { environment["CODEX_HOME"] = codexHome }
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(
                CommandRunner.Command(binaryPath, arguments, environment: environment, errorOutput: .discarded,
                                      outputLimit: 0),
                timeout: 60
            )
        } catch CommandRunner.Failure.timedOut {
            throw CodexServiceError.loginFailed("Warm-up request timed out.")
        }
        guard result.status == 0 else {
            throw CodexServiceError.loginFailed("Warm-up request exited \(result.status).")
        }
    }

    /// With `resetDetails`, an account whose reply counts reset credits is
    /// asked for each credit's expiry too (`CodexLimitResets.Details`), one
    /// request more; the count stands if that request fails.
    func getUsageSnapshot(codexHome: String?, resetDetails: Bool = false) async throws -> CodexUsageSnapshot {
        let home = codexHome.map(URL.init(fileURLWithPath:)) ?? systemHome
        let authURL = home.appendingPathComponent("auth.json")
        let authData = try Data(contentsOf: authURL)
        guard var auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              var tokens = auth["tokens"] as? [String: Any] else {
            throw CodexServiceError.invalidCredentials
        }
        let live = isSystemHome(home)
        if Self.credentialsNeedRefresh(auth),
           let refreshToken = tokens["refresh_token"] as? String,
           !refreshToken.isEmpty {
            guard await mayRenewCredential(in: home) else { throw CodexServiceError.liveCredentialExpired }
            tokens = try await renewTokens(tokens, refreshToken: refreshToken, home: home, reason: "getUsageSnapshot")
            auth["tokens"] = tokens
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            try Self.writePrivateAuth(auth, to: authURL, live: live, reason: "getUsageSnapshot.renewal", audit: audit)
        }
        audit.record(live ? .liveRead : .savedCopyRead, .codex, location: home.path, live: live,
                     accessToken: tokens["access_token"] as? String, outcome: "ok", reason: "getUsageSnapshot")
        var result = try await fetchUsageResponse(tokens: tokens)
        if result.statusCode == 401,
           let refreshToken = tokens["refresh_token"] as? String,
           !refreshToken.isEmpty {
            // Subscription changes can revoke a server-side access token well
            // before its signed JWT expiry. Refresh and retry once so an
            // upgrade/downgrade immediately publishes its new tier and windows.
            guard await mayRenewCredential(in: home) else { throw CodexServiceError.liveCredentialExpired }
            codexLog.info("[usage] Access token rejected before expiry; refreshing and retrying")
            tokens = try await renewTokens(tokens, refreshToken: refreshToken, home: home, reason: "getUsageSnapshot.rejected")
            auth["tokens"] = tokens
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            try Self.writePrivateAuth(auth, to: authURL, live: live, reason: "getUsageSnapshot.renewal", audit: audit)
            result = try await fetchUsageResponse(tokens: tokens)
        }
        if result.statusCode == 403 {
            throw CodexServiceError.subscriptionUnavailable
        }
        if result.statusCode == 429 {
            throw CodexServiceError.rateLimited(retryAt: result.retryAt)
        }
        guard (200...299).contains(result.statusCode),
              let accessToken = tokens["access_token"] as? String else {
            throw CodexServiceError.invalidCredentials
        }
        LimitResetShapes.note(.codex, reply: result.data)
        var responseSnapshot = try Self.decodeUsageSnapshot(result.data)
        if resetDetails, (responseSnapshot.usage.limitResets?.available.first?.resetsLeft ?? 0) > 0,
           let details = try? await fetchResponse(Self.resetCreditsURL, tokens: tokens), (200...299).contains(details.statusCode) {
            LimitResetShapes.note(.codex, whole: details.data, name: "rate-limit-reset-credits")
            if let decoded = try? JSONDecoder().decode(CodexLimitResets.Details.self, from: details.data),
               let resets = CodexLimitResets.resets(from: decoded) {
                responseSnapshot.usage.limitResets = resets
            }
        }
        let credentialPlan = Self.planType(fromJWT: accessToken)
            ?? (tokens["id_token"] as? String).flatMap(Self.planType(fromJWT:))
        return CodexUsageSnapshot(
            usage: responseSnapshot.usage,
            // A live tier always wins over the login JWT so upgrades and
            // downgrades appear immediately. JWT is only a compatibility
            // fallback when a usable quota response omits plan_type.
            planType: Self.resolvedLivePlan(
                responseSnapshot: responseSnapshot,
                credentialPlan: credentialPlan
            )
        )
    }

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    private func fetchUsageResponse(
        tokens: [String: Any]
    ) async throws -> (data: Data, statusCode: Int, retryAt: Date?) {
        try await fetchResponse(Self.usageURL, tokens: tokens)
    }

    /// A GET of one of the account's endpoints with its access token, with
    /// the time a `Retry-After` header names.
    private func fetchResponse(
        _ url: URL, tokens: [String: Any]
    ) async throws -> (data: Data, statusCode: Int, retryAt: Date?) {
        guard let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexServiceError.invalidCredentials
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AccountDock", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexServiceError.invalidCredentials
        }
        return (data, http.statusCode, RetryAfter.date(in: http))
    }

    static func resolvedLivePlan(
        responseSnapshot: CodexUsageSnapshot,
        credentialPlan: String?
    ) -> String? {
        let livePlan = responseSnapshot.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if livePlan?.isEmpty == false { return livePlan }
        let hasLiveQuota = responseSnapshot.usage.fiveHour != nil
            || responseSnapshot.usage.sevenDay != nil
        return hasLiveQuota ? credentialPlan : "inactive"
    }

    /// Codex's token endpoint, for `CredentialRenewalClient`: a refused
    /// grant is answered with 400 or 401, throttling with 429.
    static let tokenEndpoint = TokenEndpoint(
        url: URL(string: "https://auth.openai.com/oauth/token")!,
        encoding: .json,
        fields: ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "scope": "openid profile email"],
        timeout: 30,
        refusesGrant: TokenEndpoint.badRequestOrUnauthorizedRefuses,
        throttledStatuses: [429]
    )

    private func refreshOAuthTokens(
        _ existing: [String: Any],
        refreshToken: String
    ) async throws -> [String: Any] {
        let data: Data
        do {
            data = try await renewalClient.exchange(Self.tokenEndpoint, refreshToken: refreshToken)
        } catch CredentialRenewalFailure.refused {
            throw CodexServiceError.credentialRejected
        } catch CredentialRenewalFailure.throttled(let retryAt) {
            throw CodexServiceError.rateLimited(retryAt: retryAt)
        } catch CredentialRenewalFailure.status {
            throw CodexServiceError.invalidCredentials
        } catch CredentialRenewalFailure.transport(let error) {
            throw error
        }
        guard let refreshed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexServiceError.invalidCredentials
        }
        var merged = existing
        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = refreshed[key] as? String, !value.isEmpty { merged[key] = value }
        }
        return merged
    }

    /// `refreshOAuthTokens` recorded as a `renewal` of the credential in
    /// `home` by `reason`, whatever its outcome.
    private func renewTokens(_ tokens: [String: Any], refreshToken: String, home: URL,
                             reason: String) async throws -> [String: Any] {
        let subject = CredentialRenewalClient.AuditSubject(provider: .codex, location: home.path, live: isSystemHome(home))
        return try await audit.recordingRenewal(
            subject, presented: (tokens["access_token"] as? String).map { .accessToken($0) }, reason: reason,
            refused: { if case CodexServiceError.credentialRejected = $0 { true } else { false } },
            received: { ($0["access_token"] as? String).map { .accessToken($0) } }
        ) {
            try await refreshOAuthTokens(tokens, refreshToken: refreshToken)
        }
    }

    /// Renews the credential in a managed Codex home and saves it there,
    /// without touching the system `auth.json` running sessions use. Called
    /// by `CodexCredentialModule`.
    func renewCredential(codexHome: String, reason: String) async -> CredentialRenewal {
        let home = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        let authURL = home.appendingPathComponent("auth.json")
        do {
            try validateManagedHome(home)
            guard var auth = try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any],
                  let tokens = auth["tokens"] as? [String: Any],
                  let refreshToken = tokens["refresh_token"] as? String,
                  !refreshToken.isEmpty else {
                audit.record(.renewal, .codex, location: home.path, outcome: "noRefreshToken", reason: reason)
                return .rejected
            }
            auth["tokens"] = try await renewTokens(tokens, refreshToken: refreshToken, home: home, reason: reason)
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            try Self.writePrivateAuth(auth, to: authURL, live: false, reason: reason + ".renewal", audit: audit)
            return .renewed
        } catch CodexServiceError.credentialRejected {
            return .rejected
        } catch {
            return .unavailable
        }
    }

    // MARK: - Session slots

    /// The `auth.json` contents slots serving an account copy their access
    /// token from (`CodexSessionIsolation.slotCredential`): the managed
    /// home's, or for the account whose credential `systemHome` holds
    /// (`isActive`) whichever of the two expires last, since a Codex
    /// session outside a slot renews the live one in place. The live copy
    /// counts only while it names the managed copy's account: a sign-in made
    /// with Codex's own `login` replaces it with another. A live copy that
    /// expires later was renewed by Codex with a newer refresh token, so it
    /// is saved as the managed copy too, which `renewCredential` would
    /// otherwise renew with the spent one. Each read is recorded as a
    /// `savedCopyRead` or `liveRead` by `reason`. Nil when neither holds an
    /// access token.
    func slotSourceCredential(codexHome: String, isActive: Bool, reason: String) -> String? {
        func read(_ url: URL) -> (text: String, expiry: Date)? {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let expiry = Self.accessTokenExpiry(ofAuth: text) else { return nil }
            return (text, expiry)
        }
        let managedURL = URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("auth.json")
        let managed = read(managedURL)
        var chosen = managed?.text
        var live = false
        if isActive, let current = read(systemHome.appendingPathComponent("auth.json")),
           let account = managed.flatMap({ Self.accountID(ofAuth: $0.text) }),
           Self.accountID(ofAuth: current.text) == account, current.expiry > (managed?.expiry ?? .distantPast) {
            chosen = current.text
            live = true
            if let data = current.text.data(using: .utf8),
               let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? Self.writePrivateAuth(auth, to: managedURL, live: false, reason: reason + ".adoptLive", audit: audit)
            }
        }
        guard let chosen else { return nil }
        audit.record(live ? .liveRead : .savedCopyRead, .codex, location: codexHome, live: live,
                     accessToken: Self.accessToken(inAuth: chosen), outcome: "ok", reason: reason)
        return chosen
    }

    /// The access token in an `auth.json`'s text.
    static func accessToken(inAuth text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (auth["tokens"] as? [String: Any])?["access_token"] as? String
    }

    /// The account an `auth.json`'s text belongs to: `tokens.account_id`,
    /// or the account its access token was issued for.
    static func accountID(ofAuth text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any] else { return nil }
        if let id = (tokens["account_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) { return id }
        return (tokens["access_token"] as? String).flatMap(accountID(ofAccessToken:))
    }

    /// When the access token in an `auth.json`'s text expires, by its
    /// signed `exp`; nil without one.
    static func accessTokenExpiry(ofAuth text: String) -> Date? {
        guard let data = text.data(using: .utf8),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let expiry = decodeJWTPayload(accessToken)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }

    /// The ChatGPT account an access token was issued for, from its signed
    /// claims; nil when it names none.
    static func accountID(ofAccessToken token: String) -> String? {
        let auth = decodeJWTPayload(token)?["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Renews the credential of the account whose credential `systemHome`
    /// holds, when slots need its access token to last `lifetime`, and
    /// writes the result to its managed home and to `systemHome`. It starts
    /// from whichever copy expires last and renews only when that one does
    /// not last, so a renewal a Codex session made first is used as it
    /// stands and its refresh token is never presented twice. Codex itself
    /// renews only in an access token's last minutes, and reads
    /// `auth.json` again before it does, adopting a token written there
    /// meanwhile; slots ask for a renewal well before that. Called by
    /// `CodexSessionIsolation.currentSlotCredential` inside
    /// `AppState.credentialGate`.
    func renewLiveCredentialForSlots(codexHome: String, lasting lifetime: TimeInterval,
                                     reason: String) async -> CredentialRenewal {
        let home = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        do {
            try validateManagedHome(home)
            guard let text = slotSourceCredential(codexHome: codexHome, isActive: true, reason: reason),
                  let data = text.data(using: .utf8),
                  var auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = auth["tokens"] as? [String: Any] else { return .rejected }
            if let expiry = Self.accessTokenExpiry(ofAuth: text), expiry > Date().addingTimeInterval(lifetime) {
                return .renewed
            }
            guard let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
                audit.record(.renewal, .codex, location: home.path, live: true, outcome: "noRefreshToken", reason: reason)
                return .rejected
            }
            auth["tokens"] = try await renewTokens(tokens, refreshToken: refreshToken, home: systemHome, reason: reason)
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            let liveURL = systemHome.appendingPathComponent("auth.json")
            let liveAccount = (try? String(contentsOf: liveURL, encoding: .utf8)).flatMap(Self.accountID(ofAuth:))
            try Self.writePrivateAuth(auth, to: home.appendingPathComponent("auth.json"), live: false,
                                      reason: reason + ".renewal", audit: audit)
            if liveAccount != nil, liveAccount == Self.accountID(ofAuth: text) {
                try Self.writePrivateAuth(auth, to: liveURL, live: true, reason: reason + ".renewal", audit: audit)
            }
            return .renewed
        } catch CodexServiceError.credentialRejected {
            return .rejected
        } catch {
            return .unavailable
        }
    }

    /// The access token in a Codex home's `auth.json`, which the CLI sends
    /// with its requests; `AppState.currentAccessToken` fingerprints it.
    static func accessToken(codexHome: String) -> String? {
        let authURL = URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any] else { return nil }
        return tokens["access_token"] as? String
    }

    /// Whether the access token in a Codex home stays valid `interval` from
    /// now, by its signed expiry.
    func credentialLasts(codexHome: String, for interval: TimeInterval, now: Date = Date()) -> Bool {
        let authURL = URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let expiry = Self.decodeJWTPayload(accessToken)?["exp"] as? NSNumber else { return false }
        return Date(timeIntervalSince1970: expiry.doubleValue) > now.addingTimeInterval(interval)
    }

    static func credentialsNeedRefresh(
        _ auth: [String: Any],
        now: Date = Date()
    ) -> Bool {
        // The access token's signed expiry is the authoritative signal. Some
        // Codex auth files write `last_refresh` with fractional seconds, which
        // the default ISO8601 formatter does not accept; treating that parse
        // failure as expiry caused valid inactive accounts to refresh and fail.
        if let tokens = auth["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String,
           let expiry = decodeJWTPayload(accessToken)?["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: expiry.doubleValue)
                <= now.addingTimeInterval(5 * 60)
        }

        guard let value = auth["last_refresh"] as? String,
              let date = iso8601Date(value) else { return true }
        return now.timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// Replaces an `auth.json`, recorded by `reason` as a `liveWrite` when
    /// it is the system home's (`live`) and a `savedCopyWrite` of the
    /// account whose home holds it otherwise, with the token replaced.
    static func writePrivateAuth(_ auth: [String: Any], to url: URL, live: Bool, reason: String,
                                 audit: CredentialAudit = .shared) throws {
        let replaced = accessToken(inAuthFile: url)
        let token = (auth["tokens"] as? [String: Any])?["access_token"] as? String
        let home = url.deletingLastPathComponent().path
        let data = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
        do {
            try PrivateFile.writeAtomically(data, to: url, mode: 0o600)
        } catch {
            audit.record(live ? .liveWrite : .savedCopyWrite, .codex, location: home, live: live, accessToken: token,
                         previousAccessToken: replaced, outcome: "failed", reason: reason)
            throw error
        }
        audit.record(live ? .liveWrite : .savedCopyWrite, .codex, location: home, live: live, accessToken: token,
                     previousAccessToken: replaced, outcome: "ok", reason: reason)
    }

    static func decodeUsage(_ data: Data) throws -> UsageAPIResponse {
        try decodeUsageSnapshot(data).usage
    }

    static func decodeUsageSnapshot(_ data: Data) throws -> CodexUsageSnapshot {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        let quotaWindow = payload.window(matchingSeconds: 7 * 24 * 60 * 60)
            ?? payload.primaryWindow
        let usage = UsageAPIResponse(
            fiveHour: payload.window(matchingSeconds: 5 * 60 * 60)?.usageWindow,
            // `sevenDay` is the shared long-window slot. Free Codex accounts
            // currently expose a 30-day primary quota instead of a 7-day one.
            sevenDay: quotaWindow?.usageWindow,
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil,
            limitResets: payload.resetCredits?.value.map(CodexLimitResets.resets(from:))
        )
        let trimmedPlan = payload.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexUsageSnapshot(
            usage: usage,
            planType: trimmedPlan?.isEmpty == false ? trimmedPlan : nil
        )
    }

    func captureSystemAccount() throws -> (CodexIdentity, String) {
        let source = systemHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else { throw CodexServiceError.notLoggedIn }
        let home = try makeManagedHome()
        try copyAuth(from: source, toHome: home)
        let identity = try readIdentity(home: home)
        audit.record(.capture, .codex, location: home.path, accessToken: Self.accessToken(inAuthFile: source),
                     outcome: "ok", reason: "captureSystemAccount", owner: identity.email)
        return (identity, home.path)
    }

    func loginManagedAccount() async throws -> (CodexIdentity, String) {
        guard let binaryPath else { throw CodexServiceError.binaryNotFound }
        let home = try makeManagedHome()
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            _ = try await loginRunner.run(
                executable: binaryPath,
                arguments: ["login"],
                environment: environment
            )
            let identity = try readIdentity(home: home)
            audit.record(.isolatedLogin, .codex, location: home.path,
                         accessToken: Self.accessToken(inAuthFile: home.appendingPathComponent("auth.json")),
                         outcome: "signedIn", reason: "loginManagedAccount", owner: identity.email)
            return (identity, home.path)
        } catch {
            try? removeManagedHome(home)
            throw error
        }
    }

    func cancelLogin() {
        loginRunner.cancel()
    }

    /// Makes the managed home's credential the system `auth.json`, recorded
    /// as a `liveWrite` of the account whose home it is by `reason`.
    func promoteToSystem(homePath: String, reason: String) throws {
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        try validateManagedHome(home)
        let source = home.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else {
            audit.record(.liveWrite, .codex, location: home.path, outcome: "noCredential", reason: reason)
            throw CodexServiceError.invalidCredentials
        }

        try fileManager.createDirectory(at: systemHome, withIntermediateDirectories: true)
        let destination = systemHome.appendingPathComponent("auth.json")
        let replaced = Self.accessToken(inAuthFile: destination)
        let staged = systemHome.appendingPathComponent(".auth.accountdock-\(UUID().uuidString).json")
        do {
            try fileManager.copyItem(at: source, to: staged)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            audit.record(.liveWrite, .codex, location: home.path, accessToken: Self.accessToken(inAuthFile: source),
                         previousAccessToken: replaced, outcome: "failed", reason: reason)
            throw error
        }
        audit.record(.liveWrite, .codex, location: home.path, accessToken: Self.accessToken(inAuthFile: destination),
                     previousAccessToken: replaced, outcome: "ok", reason: reason)
        codexLog.info("[promote] Promoted managed Codex account to system auth.json")
    }

    /// Saves refreshed system credentials back into the active managed home
    /// before another account is promoted. Recorded as a `capture` by
    /// `reason`, with the identity the live token itself names as its owner.
    func syncSystemCredentials(toManagedHome homePath: String, expectedEmail: String, reason: String) throws {
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        try validateManagedHome(home)
        let source = systemHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else { throw CodexServiceError.notLoggedIn }
        let liveIdentity = try readIdentity(home: systemHome)
        let token = Self.accessToken(inAuthFile: source)
        guard liveIdentity.email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            audit.record(.capture, .codex, location: home.path, accessToken: token, outcome: "refusedOtherAccount",
                         reason: reason, owner: liveIdentity.email)
            throw CodexServiceError.loginFailed(
                "System Codex account is \(liveIdentity.email), expected \(expectedEmail). Credentials were not overwritten."
            )
        }

        let destination = home.appendingPathComponent("auth.json")
        let replaced = Self.accessToken(inAuthFile: destination)
        let staged = home.appendingPathComponent(".auth.accountdock-\(UUID().uuidString).json")
        try fileManager.copyItem(at: source, to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        audit.record(.capture, .codex, location: home.path, accessToken: token, previousAccessToken: replaced,
                     outcome: "ok", reason: reason, owner: liveIdentity.email)
        codexLog.info("[sync] Saved refreshed system credentials into managed Codex home")
    }

    /// Deletes a managed home, recorded as a `savedCopyRemove` by `reason`.
    func removeManagedAccount(homePath: String, reason: String) throws {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let removed = Self.accessToken(inAuthFile: home.appendingPathComponent("auth.json"))
        do {
            try removeManagedHome(home)
        } catch {
            audit.record(.savedCopyRemove, .codex, location: homePath, accessToken: removed, outcome: "failed", reason: reason)
            throw error
        }
        audit.record(.savedCopyRemove, .codex, location: homePath, accessToken: removed,
                     outcome: removed == nil ? "absent" : "ok", reason: reason)
    }

    func systemIdentity() -> CodexIdentity? {
        try? readIdentity(home: systemHome)
    }

    func identity(codexHome: String) throws -> CodexIdentity {
        try readIdentity(home: URL(fileURLWithPath: codexHome, isDirectory: true))
    }

    private func makeManagedHome() throws -> URL {
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let home = managedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        return home
    }

    /// Copies a live `auth.json` into a new managed home; its caller,
    /// `captureSystemAccount`, records the copy once the identity is read.
    private func copyAuth(from source: URL, toHome home: URL) throws {
        let destination = home.appendingPathComponent("auth.json")
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func removeManagedHome(_ home: URL) throws {
        try validateManagedHome(home)
        if fileManager.fileExists(atPath: home.path) {
            try fileManager.removeItem(at: home)
        }
    }

    private func validateManagedHome(_ home: URL) throws {
        let root = managedRoot.standardizedFileURL.path + "/"
        let target = home.standardizedFileURL.path
        guard target.hasPrefix(root), target != managedRoot.path else {
            throw CodexServiceError.unsafeCredentialLocation
        }
    }

    private func readIdentity(home: URL) throws -> CodexIdentity {
        let authURL = home.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL)
        return try Self.identity(fromAuthData: data)
    }

    static func identity(fromAuthData data: Data) throws -> CodexIdentity {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexServiceError.invalidCredentials
        }
        let tokens = json["tokens"] as? [String: Any]
        let idToken = (tokens?["id_token"] as? String) ?? (json["id_token"] as? String)
        let payload = idToken.flatMap(Self.decodeJWTPayload) ?? [:]
        let email = (payload["email"] as? String)
            ?? (payload["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
        let accountID = (tokens?["account_id"] as? String)
            ?? (payload["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        let planType = (payload["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        let resolvedEmail = email ?? accountID.map { "Codex \($0.suffix(8))" }
        guard let resolvedEmail, !resolvedEmail.isEmpty else { throw CodexServiceError.invalidCredentials }
        let name = (payload["name"] as? String) ?? resolvedEmail
        return CodexIdentity(
            email: resolvedEmail,
            displayName: name,
            accountID: accountID,
            planType: planType
        )
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func planType(fromJWT token: String) -> String? {
        let payload = decodeJWTPayload(token)
        let plan = (payload?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func run(binary: String, arguments: [String], codexHome: String?) async throws -> String {
        var environment = ProcessInfo.processInfo.environment
        if let codexHome {
            environment["CODEX_HOME"] = codexHome
        }
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(
                CommandRunner.Command(binary, arguments, environment: environment, errorOutput: .merged), timeout: .infinity
            )
        } catch {
            throw CodexServiceError.loginFailed(error.localizedDescription)
        }
        let output = result.text
        guard result.status == 0 else {
            throw CodexServiceError.loginFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    /// Read leniently: an unknown shape never costs the windows.
    let resetCredits: Lossy<CodexLimitResets.Summary>?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case resetCredits = "rate_limit_reset_credits"
    }

    func window(matchingSeconds target: Int) -> Window? {
        [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .first { $0.limitWindowSeconds == target }
    }

    var primaryWindow: Window? {
        rateLimit?.primaryWindow
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let resetAt: Int
        let resetAfterSeconds: Int?
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }

        var usageWindow: UsageWindow {
            // OpenAI represents an unused Codex window as 0% with
            // reset_after_seconds equal to the entire window. Its reset_at is
            // recomputed as `now + window` on every request, so it is not a
            // real countdown. Expose no reset until a request establishes a
            // fixed window; the warm-up scheduler then knows to start it.
            let isMovingUnusedPlaceholder = usedPercent <= 0
                && resetAfterSeconds.map { $0 >= limitWindowSeconds - 1 } == true
            return UsageWindow(
                utilization: usedPercent,
                resetsAt: isMovingUnusedPlaceholder
                    ? nil
                    : ISO8601DateFormatter().string(
                        from: Date(timeIntervalSince1970: TimeInterval(resetAt))
                    ),
                windowSeconds: limitWindowSeconds
            )
        }
    }
}
