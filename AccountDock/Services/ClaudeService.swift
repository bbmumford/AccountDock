import Foundation
import Darwin

private let log = FileLog("Claude")

/// UserDefaults key holding the user's preferred Claude CLI path (empty = auto).
let kClaudeBinaryPathPreferenceKey = "claudeBinaryPathPreference"

/// A claude binary discovered on this Mac.
struct DetectedClaudePath: Hashable, Identifiable {
    let path: String
    let label: String
    var id: String { path }
}

/// A Claude process which was already running when an account switch was requested.
/// Existing Claude processes can retain their startup credential after the system
/// Keychain entry changes, so they must be restarted to guarantee a clean switch.
struct RunningClaudeProcess: Hashable, Identifiable, Sendable {
    let id: Int32
    let command: String
    let sessionID: String?
    let workingDirectory: String?
    let recoveryMethod: RecoveryMethod

    enum RecoveryMethod: String, Hashable, Sendable {
        case hostManaged
        case terminal
        case unavailable
    }

    var label: String {
        if command.localizedCaseInsensitiveContains("vscode") {
            return "VS Code Claude session"
        }
        if command.contains("--claude-in-chrome-mcp") {
            return "Claude in Chrome"
        }
        if command.contains("auth login") {
            return "Claude browser login"
        }
        return "Claude Code session"
    }

    var isWorkload: Bool {
        !command.contains("--claude-in-chrome-mcp") && !command.contains("auth login")
    }
}

struct ClaudeSubscriptionSnapshot: Equatable, Sendable {
    let planType: String?
    let isInactive: Bool
    /// The organisation's rate-limit tier the profile names
    /// (`default_claude_max_5x`), which sizes the plan; nil when it names none.
    var rateLimitTier: String? = nil
    /// The address of the account the profile describes, so a profile read
    /// with a credential found in the shared slot is applied only to the
    /// account it names (`AppState.applyClaudeProfile`); nil when it names none.
    var email: String? = nil
}

/// The account a Claude access token belongs to, from the account profile.
struct ClaudeProfileIdentity: Equatable, Sendable {
    let accountUUID: String?
    let email: String?
}

/// Interacts with the Claude CLI to get auth status and manage accounts.
final class ClaudeService: @unchecked Sendable {
    static let shared = ClaudeService()

    private let lock = NSLock()
    private let loginRunner = LoginProcessRunner()
    /// Sends Claude's token renewals (`refreshStoredToken`).
    var renewalClient = CredentialRenewalClient()

    private var _claudePath: String
    /// Monotonic counter to detect out-of-order setPath completions.
    private var _setPathGeneration: UInt64 = 0
    /// The installed CLI's version for `usageUserAgent`, and when it was read.
    private var _usageCLIVersion: (version: String, readAt: Date)?

    /// Currently active path. Thread-safe.
    var claudePath: String {
        lock.lock(); defer { lock.unlock() }
        return _claudePath
    }

    private init() {
        let preference = UserDefaults.standard.string(forKey: kClaudeBinaryPathPreferenceKey) ?? ""
        if !preference.isEmpty, FileManager.default.isExecutableFile(atPath: preference) {
            self._claudePath = preference
            log.info("Claude binary path: \(preference) (user preference)")
        } else {
            let auto = Self.autoSelectedPath()
            self._claudePath = auto.path
            log.info("Claude binary path: \(auto.path) (\(auto.source))")
            if !preference.isEmpty {
                log.warning("Saved preference \(preference) is no longer valid; falling back to auto")
            }
        }
    }

    /// Update the runtime claude path. Pass nil or empty to revert to auto-detection.
    /// Does NOT validate — caller (Settings UI) is expected to validate before calling.
    /// Auto-resolution happens outside the lock (can take ~3s via shell PATH lookup);
    /// a generation counter ensures a slower call cannot overwrite a faster, later one.
    func setPath(_ override: String?) {
        lock.lock()
        _setPathGeneration &+= 1
        let myGen = _setPathGeneration
        lock.unlock()

        let resolved: (String, String)
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            resolved = (override, "override")
        } else {
            let auto = Self.autoSelectedPath()
            resolved = (auto.path, "auto/\(auto.source)")
        }

        lock.lock()
        guard myGen == _setPathGeneration else {
            lock.unlock()
            log.info("[setPath] superseded by newer call, discarding \(resolved.0)")
            return
        }
        _claudePath = resolved.0
        lock.unlock()
        log.info("[setPath] \(resolved.1): \(resolved.0)")
    }

    // MARK: - Detection

    /// Today's 3-tier fallback: curated → shell PATH → bare "claude".
    static func autoSelectedPath() -> (path: String, source: String) {
        for candidate in curatedPathCandidates() where FileManager.default.fileExists(atPath: candidate) {
            return (candidate, "curated")
        }
        if let shellPath = shellPathLookup() {
            return (shellPath, "shell PATH")
        }
        return ("claude", "fallback")
    }

    /// All claude binaries that actually exist on this Mac, deduplicated by
    /// resolved symlink target, ordered by discovery source.
    static func detectedPaths() -> [DetectedClaudePath] {
        var result: [DetectedClaudePath] = []
        var seenResolved = Set<String>()

        func add(_ path: String, _ label: String) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seenResolved.contains(resolved) else { return }
            seenResolved.insert(resolved)
            result.append(DetectedClaudePath(path: path, label: label))
        }

        for (path, label) in curatedLabeledCandidates() {
            add(path, label)
        }
        for (path, label) in nvmLabeledCandidates() {
            add(path, label)
        }
        if let shellPath = shellPathLookup() {
            add(shellPath, "From shell PATH")
        }

        return result
    }

    private static func curatedPathCandidates() -> [String] {
        curatedLabeledCandidates().map { $0.0 } + nvmLabeledCandidates().map { $0.0 }
    }

    private static func curatedLabeledCandidates() -> [(String, String)] {
        let home = NSHomeDirectory()
        return [
            ("/usr/local/bin/claude", "/usr/local/bin"),
            ("/opt/homebrew/bin/claude", "Homebrew"),
            ("/opt/local/bin/claude", "MacPorts"),
            ("\(home)/.local/bin/claude", "Anthropic native installer"),
            ("\(home)/.claude/local/claude", "Anthropic migrate installer"),
            ("\(home)/.npm-global/bin/claude", "npm global"),
            ("\(home)/.volta/bin/claude", "Volta"),
            ("\(home)/Library/pnpm/claude", "pnpm"),
            ("\(home)/.bun/bin/claude", "Bun"),
            ("\(home)/.yarn/bin/claude", "Yarn"),
        ]
    }

    /// Discover Claude binaries installed via NVM (Node Version Manager).
    /// NVM stores node versions at ~/.nvm/versions/node/<version>/bin/.
    private static func nvmLabeledCandidates() -> [(String, String)] {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: nvmDir) else { return [] }
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            log.warning("[nvmLabeledCandidates] NVM directory exists but could not be read: \(nvmDir)")
            return []
        }
        return versions
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { ("\(nvmDir)/\($0)/bin/claude", "NVM \($0)") }
    }

    /// Last-resort lookup: ask the user's interactive login shell where `claude` lives.
    /// Catches install layouts the curated list doesn't enumerate (asdf shims, fnm, n,
    /// pnpm/yarn/bun/Volta with non-default prefixes, custom npm prefixes, etc.).
    /// Bounded by a short timeout so a slow .zshrc can't block app launch.
    private static func shellPathLookup() -> String? {
        // Hard timeout — don't let a heavy shell rc file block forever.
        let result: CommandRunner.Result
        do {
            result = try CommandRunner.runSynchronously(
                CommandRunner.Command("/bin/zsh", ["-ilc", "command -v claude"],
                                      environment: ProcessInfo.processInfo.environment),
                timeout: 3
            )
        } catch CommandRunner.Failure.timedOut {
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        guard result.status == 0 else { return nil }
        let raw = String(data: result.output, encoding: .utf8) ?? ""
        // `command -v` may emit multiple lines if claude is shadowed; take the first.
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    // MARK: - Auth Status

    func getAuthStatus() async throws -> AuthStatus {
        log.info("[getAuthStatus] Fetching auth status...")
        let output = try await runClaude(args: ["auth", "status"])
        guard let data = output.data(using: .utf8) else {
            log.error("[getAuthStatus] Invalid output (not UTF-8)")
            throw ClaudeServiceError.invalidOutput
        }
        let status = try JSONDecoder().decode(AuthStatus.self, from: data)
        log.info("[getAuthStatus] loggedIn=\(status.loggedIn), provider=\(status.apiProvider ?? "nil"), sub=\(status.subscriptionType ?? "nil")")
        return status
    }

    /// Reads the current subscription from Claude's account profile. Unlike
    /// `claude auth status`, this is a live response and therefore reflects a
    /// subscription which has ended since the credentials were issued.
    func getLiveSubscription(accessToken: String) async throws -> ClaudeSubscriptionSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UsageError.network("profile HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        return Self.liveSubscription(fromProfileJSON: json)
    }

    /// Reads which account an access token belongs to: the token names no
    /// account, so a credential found in Claude's shared Keychain slot is
    /// attributed by asking. A rejected token throws `UsageError.expired`.
    func getProfileIdentity(accessToken: String) async throws -> ClaudeProfileIdentity {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299: break
        case 401: throw UsageError.expired
        case 429: throw UsageError.rateLimited(nil)
        default: throw UsageError.network("profile HTTP \(status)")
        }
        return Self.profileIdentity(fromProfileJSON: try JSONSerialization.jsonObject(with: data))
    }

    static func profileIdentity(fromProfileJSON json: Any) -> ClaudeProfileIdentity {
        let account = (json as? [String: Any])?["account"] as? [String: Any]
        return ClaudeProfileIdentity(
            accountUUID: account?["uuid"] as? String,
            email: (account?["email"] as? String) ?? (account?["email_address"] as? String)
        )
    }

    /// The plan the profile reports now. A credential carries the plan and
    /// tier it was issued under, which an upgrade does not change, so the
    /// profile's `organization.organization_type` (`claude_max`,
    /// `claude_pro`, `claude_team`, `claude_enterprise`) and
    /// `organization.rate_limit_tier` decide; an explicit `subscriptionType`
    /// field is used when the profile has one.
    static func liveSubscription(fromProfileJSON json: Any) -> ClaudeSubscriptionSnapshot {
        let expired = containsExpiredSubscription(json)
        let organization = (json as? [String: Any])?["organization"] as? [String: Any]
        let explicit = firstString(named: ["subscriptionType", "subscription_type"], in: json)
        let organizationPlan = (organization?["organization_type"] as? String).flatMap { type -> String? in
            let plan = type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
            return plan.isEmpty ? nil : plan
        }
        return ClaudeSubscriptionSnapshot(
            planType: expired ? nil : (explicit ?? organizationPlan),
            isInactive: expired,
            rateLimitTier: expired ? nil : organization?["rate_limit_tier"] as? String,
            email: profileIdentity(fromProfileJSON: json).email
        )
    }

    private static func containsExpiredSubscription(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let status = dictionary["status"] as? String,
               status.caseInsensitiveCompare("expired") == .orderedSame {
                return true
            }
            return dictionary.values.contains(where: containsExpiredSubscription)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsExpiredSubscription)
        }
        return false
    }

    private static func firstString(named keys: Set<String>, in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let result = dictionary[key] as? String,
                   !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
            }
            for child in dictionary.values {
                if let result = firstString(named: keys, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstString(named: keys, in: child) { return result }
            }
        }
        return nil
    }

    func isClaudeAvailable() async -> Bool {
        do {
            let version = try await runClaude(args: ["--version"])
            log.info("[isClaudeAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            log.error("[isClaudeAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Usage API

    enum UsageError: LocalizedError {
        case expired
        case subscriptionUnavailable
        /// The account's organisation has turned off subscription access
        /// for Claude Code (`refusesCLIAccess`).
        case organizationDisabled
        case rateLimited(Date?)
        case network(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .expired: "Claude credentials have expired."
            case .subscriptionUnavailable: "This account does not currently include Claude Code."
            case .organizationDisabled: "Your organization has disabled Claude subscription access for Claude Code."
            case .rateLimited: "Anthropic temporarily rate-limited usage refresh."
            case let .network(message): "Usage request failed: \(message)"
            case let .decode(message): "Usage response could not be read: \(message)"
            }
        }
    }

    /// Whether `text`, a reply, a CLI's output or a transcript's error, is
    /// Anthropic refusing an account because its organisation has turned
    /// off subscription access for Claude Code: HTTP 403 with the error type
    /// `oauth_org_not_allowed`, which Claude Code shows as "API Error: Your
    /// organization has disabled Claude subscription access for Claude Code
    /// · Use an Anthropic API key instead, or ask your admin to enable
    /// access". A team admin removing the account's seat or licence causes
    /// it. Read by `getUsageLimits`, the warm-up and re-check probes and
    /// `ClaudeTranscriptSource.accessRefusal`.
    static func refusesCLIAccess(_ text: String) -> Bool {
        text.contains("oauth_org_not_allowed")
            || text.range(of: "disabled Claude subscription access", options: .caseInsensitive) != nil
    }

    /// Fetch usage for a specific access token
    ///
    /// `cedar_ember=1` adds the limit resets the account holds
    /// (`UsageAPIResponse.limitResets`) to the same reading. The provider
    /// lists them only to the Claude Code client, which it recognises by
    /// `usageUserAgent`; any other client is answered as ineligible.
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1") else { throw UsageError.network("invalid url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(await usageUserAgent(), forHTTPHeaderField: "User-Agent")

        log.debug("[getUsageLimits] REQUEST URL: \(url.absoluteString)")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let responseString = String(data: responseData, encoding: .utf8) ?? ""
            log.error("[getUsageLimits] HTTP \(httpResponse?.statusCode ?? 0)")

            if httpResponse?.statusCode == 401 || responseString.contains("token_expired") {
                throw UsageError.expired
            }
            if httpResponse?.statusCode == 403 {
                throw Self.refusesCLIAccess(responseString) ? UsageError.organizationDisabled : UsageError.subscriptionUnavailable
            }
            if httpResponse?.statusCode == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Self.retryAfterDate($0) }
                throw UsageError.rateLimited(retryAfter)
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        
        LimitResetShapes.note(.claudeCode, reply: responseData)
        do {
            let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: responseData)
            log.info("[getUsageLimits] session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            return usage
        } catch {
            log.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    static func retryAfterDate(_ value: String, now: Date = Date()) -> Date? {
        RetryAfter.date(value, now: now)
    }

    /// Extract access token string from a token JSON (keychain format)
    static func extractAccessToken(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    /// The rate-limit tier in a token JSON (keychain format).
    static func rateLimitTier(from tokenJSON: String) -> String? {
        guard let data = tokenJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["rateLimitTier"] as? String
    }

    /// Refreshes a stored Claude OAuth record without installing it as the
    /// machine-wide Claude credential. This keeps inactive accounts observable
    /// and rotates their refresh token independently of the active CLI account.
    func refreshStoredToken(_ tokenJSON: String) async throws -> String {
        guard let data = tokenJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            throw UsageError.expired
        }

        let responseData: Data
        do {
            responseData = try await renewalClient.exchange(Self.tokenEndpoint, refreshToken: refreshToken)
        } catch CredentialRenewalFailure.refused {
            throw UsageError.expired
        } catch CredentialRenewalFailure.status(let status) {
            throw UsageError.network("token endpoint returned \(status)")
        } catch CredentialRenewalFailure.transport(let error) {
            throw UsageError.network(error.localizedDescription)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let refreshed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = refreshed["access_token"] as? String,
              !accessToken.isEmpty else {
            throw UsageError.network("token endpoint reply could not be read")
        }
        oauth["accessToken"] = accessToken
        if let rotated = refreshed["refresh_token"] as? String, !rotated.isEmpty {
            oauth["refreshToken"] = rotated
        }
        if let expiresIn = refreshed["expires_in"] as? Double {
            oauth["expiresAt"] = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1_000)
        } else if let expiresIn = refreshed["expires_in"] as? Int {
            oauth["expiresAt"] = Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1_000)
        }
        root["claudeAiOauth"] = oauth
        let encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let result = String(data: encoded, encoding: .utf8) else { throw UsageError.decode("token encoding") }
        return result
    }

    /// Claude's token endpoint, for `CredentialRenewalClient`.
    static let tokenEndpoint = TokenEndpoint(
        url: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        encoding: .form,
        fields: ["client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"],
        headers: ["Accept": "application/json"],
        timeout: 30,
        refusesGrant: { refreshRejectsGrant(status: $0, body: $1) }
    )

    /// Whether a failed token-endpoint reply means the refresh token itself

    /// is dead: a 401, or a 400 whose error is `invalid_grant`. Throttling,
    /// server errors, other refusals and unreadable replies leave the stored
    /// credential usable later, so `ClaudeCredentialModule` reports them as
    /// unavailable rather than rejected and the account keeps its sign-in.
    static func refreshRejectsGrant(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        guard status == 400, let reply = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return reply["error"] as? String == "invalid_grant"
    }

    /// Starts a fresh quota countdown without creating resumable history.
    /// The OAuth token is carried only in the child environment, never argv.
    func warmQuotaWindow(accessToken: String) async throws {
        let executable = claudePath
        let probeID = UUID().uuidString.lowercased()
        try await Task.detached(priority: .utility) {
            defer { Self.removeWarmupProbeResidue(sessionID: probeID) }
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = accessToken
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            // The reply's last lines say why a probe failed, such as a usage
            // limit the account has already reached.
            let result: CommandRunner.Result
            do {
                result = try CommandRunner.runSynchronously(
                    CommandRunner.Command(executable, Self.warmupArguments(sessionID: probeID),
                                          environment: environment, errorOutput: .merged),
                    timeout: 90
                )
            } catch CommandRunner.Failure.timedOut {
                throw UsageError.network("warm-up request timed out")
            }
            guard result.status == 0 else {
                let text = String(decoding: result.output.suffix(300), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                throw UsageError.network("warm-up request exited \(result.status)\(text.isEmpty ? "" : ": \(text)")")
            }
        }.value
    }

    /// `--bare` cannot be used here: current Claude CLI releases deliberately
    /// disable OAuth and Keychain reads in bare mode, causing an injected
    /// CLAUDE_CODE_OAUTH_TOKEN to be reported as "Not logged in". Safe mode
    /// still suppresses hooks and other user customisations, while retaining
    /// OAuth support for the isolated account probe.
    static func warmupArguments(sessionID: String) -> [String] {
        [
            "--safe-mode",
            "--print",
            "--no-session-persistence",
            "--session-id", sessionID,
            "--max-turns", "1",
            "--model", "haiku",
            "Reply with exactly: OK"
        ]
    }

    private static func removeWarmupProbeResidue(sessionID: String) {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AccountDock/Sessions", isDirectory: true)
        ]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent.localizedCaseInsensitiveContains(sessionID) else { continue }
                try? FileManager.default.removeItem(at: url)
                log.info("[warmup] Removed probe residue \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - Account Switching

    /// Returns only executable processes whose binary is named `claude`.
    /// Matching the executable column avoids false positives from editors,
    /// AccountDock itself, or shell commands that merely mention Claude.
    func runningProcesses() -> [RunningClaudeProcess] {
        guard let table = ProcessTable.read() else {
            log.warning("[runningProcesses] The process list could not be read")
            return []
        }
        return Self.parseRunningProcesses(table, excludingPID: Int32(ProcessInfo.processInfo.processIdentifier))
    }

    /// The processes in `table` whose executable, the command's first word,
    /// is named `claude`.
    static func parseRunningProcesses(
        _ table: ProcessTable,
        excludingPID: Int32
    ) -> [RunningClaudeProcess] {
        return table.entries.compactMap { entry in
            guard entry.pid != excludingPID, entry.executableName == "claude" else { return nil }
            let pid = entry.pid
            let command = entry.command
            let sessionID = extractResumeSessionID(from: command)
            return RunningClaudeProcess(
                id: pid,
                command: command,
                sessionID: sessionID,
                workingDirectory: nil,
                recoveryMethod: command.localizedCaseInsensitiveContains("vscode")
                    ? .hostManaged
                    : (sessionID == nil ? .unavailable : .terminal)
            )
        }
    }

    /// Enrich process inspection with AccountDock's own hook registry. Hook
    /// records map the Claude parent PID to its session without depending on a
    /// particular IDE, terminal, or orchestration harness.
    func recoverableRunningProcesses() -> [RunningClaudeProcess] {
        let records = AgentSessions.byProcess(.claudeCode)
        return runningProcesses().filter(\.isWorkload).map { process in
            guard let record = records[process.id] else { return process }
            let hostManaged = process.command.localizedCaseInsensitiveContains("vscode")
                || record.host?.localizedCaseInsensitiveContains("vscode") == true
            return RunningClaudeProcess(
                id: process.id,
                command: process.command,
                sessionID: process.sessionID ?? record.sessionID,
                workingDirectory: record.workingDirectory,
                recoveryMethod: hostManaged ? .hostManaged : .terminal
            )
        }
    }

    static func extractResumeSessionID(from command: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"--resume(?:=|\s+)([A-Za-z0-9._:-]+)"#
        ) else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        guard let match = expression.firstMatch(in: command, range: range),
              let idRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[idRange])
    }

    /// Why `claude auth status` after writing `target`'s credential does not
    /// confirm the switch, or nil when it does; `switchAccount` rolls back on
    /// any failure.
    static func verificationFailure(of status: AuthStatus, switchingTo target: Account) -> ClaudeServiceError? {
        guard status.loggedIn else { return .switchVerificationFailed }
        guard target.matches(email: status.email) else {
            return .switchWrongAccount(expected: target.email, actual: status.email ?? "unknown")
        }
        return nil
    }

    func switchAccount(from currentAccount: Account, to targetAccount: Account) async throws -> AuthStatus {
        let keychain = KeychainService.shared
        // Keep an exact snapshot of the live state. A target credential can
        // exist in AccountDock yet have expired or been revoked since capture;
        // verification must therefore be transactional.
        let audit = CredentialAudit.shared
        let originalToken = keychain.readClaudeToken(reason: "switchAccount.snapshot", account: currentAccount.id)
        let originalOAuth = keychain.readOAuthAccount()

        func restoreOriginalCredentials() {
            guard let originalToken, let originalOAuth else {
                log.error("[switchAccount] Rollback unavailable: original credentials could not be read")
                return
            }
            let tokenRestored = keychain.writeClaudeToken(originalToken, account: currentAccount.id,
                                                          reason: "switchAccount.rollBack")
            let identityRestored = keychain.writeOAuthAccount(originalOAuth)
            log.info("[switchAccount] Rolled back rejected target credentials: token=\(tokenRestored), identity=\(identityRestored)")
        }

        log.info("[switchAccount] Switching from \(currentAccount.id) to \(targetAccount.id)")

        // 1. The outgoing account's live credential is backed up by the
        // caller (`AppState.captureOwnCredential`), which asks the provider
        // whose it is; nothing here saves the live credential under an
        // account, since the identity file beside it can be a running
        // session's.

        // 2. Retrieve target account's backup
        log.info("[switchAccount] Step 2: Reading backup for target account...")
        guard var targetBackup = keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString,
                                                           reason: "switchAccount.target") else {
            log.error("[switchAccount] Step 2: No backup found for target account!")
            throw ClaudeServiceError.noTokenForAccount(targetAccount.id.uuidString)
        }
        if !AccountBackup.isCompleteCredential(targetBackup.token) {
            guard let previous = targetBackup.previousToken, AccountBackup.isCompleteCredential(previous) else {
                log.error("[switchAccount] Step 2: Target backup is incomplete and no earlier copy exists")
                throw ClaudeServiceError.noTokenForAccount(targetAccount.id.uuidString)
            }
            log.warning("[switchAccount] Step 2: Target backup is incomplete; using the earlier copy")
            targetBackup = AccountBackup(token: previous, oauthAccount: targetBackup.oauthAccount)
        }
        let targetEmail = (targetBackup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[switchAccount] Step 2: Target backup found (email=\(targetEmail))")

        // 3. Write target token to keychain + target oauthAccount to ~/.claude.json
        log.info("[switchAccount] Step 3: Writing target credentials...")
        guard keychain.writeClaudeToken(targetBackup.token, account: targetAccount.id, reason: "switchAccount.install") else {
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            log.error("[switchAccount] Step 3: Failed to write oauthAccount to ~/.claude.json!")
            restoreOriginalCredentials()
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        // 4. Verify by the credential written
        let identity = targetBackup.oauthAccount
        return try await Self.verifySwitch(to: targetAccount, writtenToken: targetBackup.token, identity: identity,
                                           now: Date(), io: SwitchVerificationIO(
            authStatus: { try await self.getAuthStatus() },
            profileEmail: { access in
                do {
                    let email = try await self.getProfileIdentity(accessToken: access).email
                    audit.record(.ownershipCheck, .claudeCode, account: targetAccount.id, accessToken: access,
                                 outcome: email.map { targetAccount.matches(email: $0) ? "own" : "notOwn" } ?? "noOwner",
                                 reason: "switchAccount.verify", owner: email)
                    return email
                } catch {
                    let outcome: String
                    if case UsageError.expired = error { outcome = "rejected" } else { outcome = "unavailable" }
                    audit.record(.ownershipCheck, .claudeCode, account: targetAccount.id, accessToken: access,
                                 outcome: outcome, reason: "switchAccount.verify")
                    throw error
                }
            },
            liveToken: { keychain.readClaudeToken(reason: "switchAccount.verify", account: targetAccount.id) },
            identityEmail: { keychain.readOAuthAccount()?["emailAddress"]?.value as? String },
            restoreIdentity: { keychain.writeOAuthAccount(identity) },
            rollBack: restoreOriginalCredentials
        ))
    }

    /// What `verifySwitch` reads and writes: the live CLI, Keychain slot,
    /// identity file and profile endpoint in `switchAccount`, fakes in tests.
    struct SwitchVerificationIO {
        /// `claude auth status`, which may refresh an expired access token.
        var authStatus: () async throws -> AuthStatus
        /// The email the provider's profile endpoint names for an access
        /// token (`getProfileIdentity`); throws `UsageError.expired` when
        /// the provider rejects the token.
        var profileEmail: (String) async throws -> String?
        /// The credential in the CLI's Keychain slot now.
        var liveToken: () -> String?
        /// The email `~/.claude.json` names now.
        var identityEmail: () -> String?
        /// Writes the target's identity to `~/.claude.json` again.
        var restoreIdentity: () -> Bool
        /// Puts back the credential and identity the switch replaced.
        var rollBack: () -> Void
    }

    /// Confirms a switch whose credential (`writtenToken`) and identity
    /// were just written for `target`, by asking the provider whose that
    /// credential is. Every running Claude session rewrites
    /// `~/.claude.json` with its own account, so the identity
    /// `claude auth status` reports can be a session's rather than the one
    /// just written, within a second of the write: the identity file
    /// cannot confirm or refute a switch while sessions run.
    ///
    /// The profile naming `target` confirms it; the identity file is then
    /// written again if a session replaced it. The profile naming another
    /// account throws `switchWrongAccount` (`switchUnconfirmed` when the
    /// token asked about was read back from the Keychain slot), the
    /// provider rejecting the token throws `switchVerificationFailed`; each
    /// rolls back, and
    /// `AppState.switchTo` quarantines the target for them. When the
    /// profile cannot be asked, `claude auth status` naming `target`
    /// confirms the switch, and anything else rolls it back with
    /// `switchUnconfirmed`, which quarantines nothing. An access token past
    /// its expiry is asked about as the CLI refreshed it into the Keychain
    /// slot during `claude auth status`.
    static func verifySwitch(to target: Account, writtenToken: String, identity: [String: AnyCodable], now: Date,
                             io: SwitchVerificationIO) async throws -> AuthStatus {
        log.info("[switchAccount] Step 4: Verifying the written credential with the provider...")
        let status = try? await io.authStatus()
        let written = AppState.claudeAccessToken(writtenToken).flatMap { $0.1 > now ? $0.0 : nil }
        let token = written ?? io.liveToken().flatMap { extractAccessToken(from: $0) }
        var profileEmail: String?
        if let token {
            do {
                profileEmail = try await io.profileEmail(token)
            } catch UsageError.expired {
                log.error("[switchAccount] Step 4: The provider rejected the target credential")
                io.rollBack()
                throw ClaudeServiceError.switchVerificationFailed
            } catch {
                log.warning("[switchAccount] Step 4: Profile check unavailable: \(error.localizedDescription)")
            }
        }
        if let profileEmail {
            guard target.matches(email: profileEmail) else {
                log.error("[switchAccount] Step 4: The credential asked about is \(profileEmail)'s, expected \(target.email)")
                io.rollBack()
                // The Keychain slot, read when the written token had
                // expired, can hold a running session's own credential.
                throw written != nil
                    ? ClaudeServiceError.switchWrongAccount(expected: target.email, actual: profileEmail)
                    : ClaudeServiceError.switchUnconfirmed
            }
            if !target.matches(email: io.identityEmail()) {
                let restored = io.restoreIdentity()
                log.info("[switchAccount] Step 4: A running session rewrote the identity file; written again: \(restored)")
            }
            log.info("[switchAccount] Step 4: Switch verified by the provider's profile — \(profileEmail)")
            if let status, status.loggedIn, target.matches(email: status.email) { return status }
            return authStatus(of: target, identity: identity)
        }
        guard let status, verificationFailure(of: status, switchingTo: target) == nil else {
            log.error("[switchAccount] Step 4: Not confirmed (loggedIn=\(status?.loggedIn ?? false), email=\(status?.email ?? "nil"), expected \(target.email))")
            io.rollBack()
            throw ClaudeServiceError.switchUnconfirmed
        }
        log.info("[switchAccount] Step 4: Switch verified by `claude auth status` — \(status.email ?? "")")
        return status
    }

    /// The signed-in state `verifySwitch` reports when the provider
    /// confirmed the credential but `claude auth status` named a running
    /// session's account: `target`'s, from the identity saved with its
    /// credential and the plan last known for it, which `AppState.switchTo`
    /// replaces with the live one when the profile answers.
    static func authStatus(of target: Account, identity: [String: AnyCodable]) -> AuthStatus {
        AuthStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", email: target.email,
                   orgId: identity["organizationUuid"]?.value as? String,
                   orgName: (identity["organizationName"]?.value as? String) ?? target.orgName,
                   subscriptionType: target.subscriptionType)
    }

    /// Runs `claude auth login`, which opens the browser for OAuth, with its
    /// credential and identity kept in `directory` (`ClaudeIsolatedLogin`),
    /// never in the live sign-in.
    func login(isolatedIn directory: URL) async throws {
        log.info("[login] Starting isolated `claude auth login`... (will open browser)")
        let claudePath = self.claudePath
        _ = try await loginRunner.run(
            executable: claudePath,
            arguments: ["auth", "login"],
            environment: ClaudeIsolatedLogin.environment(environment(for: claudePath), directory: directory)
        )
        log.info("[login] `claude auth login` process exited")
    }

    func cancelLogin() {
        loginRunner.cancel()
    }

    /// Run `claude auth logout`
    func logout() async throws {
        log.info("[logout] Running `claude auth logout`...")
        _ = try await runClaude(args: ["auth", "logout"])
        log.info("[logout] Logout complete")
    }

    // MARK: - Version

    /// The User-Agent the installed Claude Code CLI sends, for
    /// `getUsageLimits`. The version is read again at most hourly, so an
    /// update is picked up without running the CLI on every reading.
    func usageUserAgent(now: Date = Date()) async -> String {
        let cached = lock.withLock { _usageCLIVersion }
        if let cached, now.timeIntervalSince(cached.readAt) < 3600 { return Self.usageUserAgent(version: cached.version) }
        let version = await Self.readVersion(at: claudePath) ?? cached?.version ?? "2.1.0"
        lock.withLock { _usageCLIVersion = (version, now) }
        return Self.usageUserAgent(version: version)
    }

    static func usageUserAgent(version: String) -> String {
        "claude-cli/\(version) (external, cli)"
    }

    /// Run `<path> --version` and return the first semver-looking token.
    /// Returns nil on launch failure, non-zero exit, or no version found.
    static func readVersion(at path: String) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        // Inject same PATH augmentation as runClaude so NVM-installed
        // claude can find `node` when invoked here.
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.local/bin",
            "\(homeDir)/.npm-global/bin"
        ]
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        extraPaths.insert(resolvedBinDir, at: 0)
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        env["HOME"] = homeDir

        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(CommandRunner.Command(path, ["--version"], environment: env), timeout: 5)
        } catch CommandRunner.Failure.timedOut {
            log.warning("[readVersion] timed out for \(path)")
            return nil
        } catch {
            log.warning("[readVersion] launch failed for \(path): \(error.localizedDescription)")
            return nil
        }
        guard result.status == 0 else { return nil }
        let raw = String(data: result.output, encoding: .utf8) ?? ""
        return Self.extractSemver(from: raw)

    }

    /// Fetch the latest published claude-code version. Returns nil on any failure.
    static func fetchLatestVersion() async -> String? {
        guard let url = URL(string: "https://downloads.claude.ai/claude-code-releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.warning("[fetchLatestVersion] non-200 response")
                return nil
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strict: the entire body must BE a semver. Protects against the CDN
            // returning an HTML error page with 200 status that happens to contain
            // dotted numbers (CSS dimensions, version strings in copy, etc.).
            return Self.isPureSemver(trimmed) ? trimmed : nil
        } catch {
            log.warning("[fetchLatestVersion] error: \(error.localizedDescription)")
            return nil
        }
    }

    /// True if the whole string is ASCII digits separated by dots (e.g. "1.0.42", "2.1.139").
    private static func isPureSemver(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 32 else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for p in parts {
            guard !p.isEmpty else { return false }
            for ch in p {
                guard ch.isASCII, ch.isNumber else { return false }
            }
        }
        return true
    }

    /// Extract the first dotted-ASCII-numeric token from a string (e.g. "1.0.42" out of "1.0.42 (Claude Code)").
    private static func extractSemver(from text: String) -> String? {
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isNumber || $0 == ".") }
        for token in text.split(whereSeparator: { !allowed($0) }) {
            let s = String(token)
            guard isPureSemver(s) else { continue }
            return s
        }
        return nil
    }

    // MARK: - CLI Runner

    /// How long one `claude` command may run. `switchAccount` waits for
    /// `claude auth status` with the target credential already written;
    /// without an answer within this, only the provider's profile can
    /// confirm the switch (`verifySwitch`).
    static let cliTimeout: TimeInterval = 30

    private func runClaude(args: [String]) async throws -> String {
        let claudePath = self.claudePath
        log.debug("[runClaude] Running: \(claudePath) \(args.joined(separator: " "))")
        return try await Self.runClaude(
            executable: claudePath, args: args, environment: environment(for: claudePath), timeout: Self.cliTimeout
        )
    }

    /// Runs `claude` and returns its standard output. Throws `cliTimedOut`
    /// when it runs past `timeout`; it is stopped then.
    static func runClaude(
        executable: String, args: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> String {
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(
                executable: URL(fileURLWithPath: executable), arguments: args,
                environment: environment, timeout: timeout
            )
        } catch CommandRunner.Failure.timedOut(let seconds) {
            log.error("[runClaude] `\(args.joined(separator: " "))` did not finish within \(Int(seconds)) s; stopped")
            throw ClaudeServiceError.cliTimedOut(seconds: seconds)
        } catch {
            log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
            throw ClaudeServiceError.processLaunchFailed(error)
        }
        let output = String(data: result.output, encoding: .utf8) ?? ""
        if result.status == 0 {
            log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
            return output
        }
        if args == ["auth", "status"], (try? JSONDecoder().decode(AuthStatus.self, from: result.output)) != nil {
            // Claude uses exit 1 for the valid logged-out status
            // document. Let getAuthStatus decode it so callers can
            // distinguish rejected credentials from a CLI failure.
            log.info("[runClaude] auth status returned logged-out state (exit \(result.status))")
            return output
        }
        log.error("[runClaude] Failed (exit \(result.status))")
        throw ClaudeServiceError.cliError("exit \(result.status)")
    }

    private func environment(for executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.local/bin",
            "\(homeDir)/.npm-global/bin"
        ]
        if executable.contains("/") {
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            extraPaths.insert(URL(fileURLWithPath: resolved).deletingLastPathComponent().path, at: 0)
        }
        environment["PATH"] = (extraPaths + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment["HOME"] = homeDir
        return environment
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidOutput
    case cliError(String)
    case processLaunchFailed(Error)
    case noTokenForAccount(String)
    case keychainWriteFailed
    case oauthAccountWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)
    /// Neither the provider's profile nor `claude auth status` confirmed
    /// the switch; nothing says the target's credential is wrong.
    case switchUnconfirmed
    case cliTimedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .cliTimedOut(let seconds):
            return "Claude CLI did not answer within \(Int(seconds)) seconds"
        case .invalidOutput:
            return "Invalid output from Claude CLI"
        case .cliError(let msg):
            return "Claude CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Claude: \(error.localizedDescription)"
        case .noTokenForAccount:
            return "No stored backup for target account"
        case .keychainWriteFailed:
            return "Failed to write token to keychain"
        case .oauthAccountWriteFailed:
            return "Failed to write oauthAccount to ~/.claude.json"
        case .switchVerificationFailed:
            return "The target Claude credentials are no longer valid. Re-authenticate that account before switching. The previous profile was restored."
        case .switchUnconfirmed:
            return "The switch could not be confirmed, so the previous profile was restored. It is tried again at the next decision."
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        }
    }
}
