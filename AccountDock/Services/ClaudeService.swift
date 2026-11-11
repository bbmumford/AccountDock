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
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            log.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        // Hard timeout — don't let a heavy shell rc file block forever.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            log.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
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

    static func liveSubscription(fromProfileJSON json: Any) -> ClaudeSubscriptionSnapshot {
        let expired = containsExpiredSubscription(json)
        return ClaudeSubscriptionSnapshot(
            planType: expired ? nil : firstString(
                named: ["subscriptionType", "subscription_type"],
                in: json
            ),
            isInactive: expired
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
        case rateLimited(Date?)
        case network(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .expired: "Claude credentials have expired."
            case .subscriptionUnavailable: "This account does not currently include Claude Code."
            case .rateLimited: "Anthropic temporarily rate-limited usage refresh."
            case let .network(message): "Usage request failed: \(message)"
            case let .decode(message): "Usage response could not be read: \(message)"
            }
        }
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
                throw UsageError.subscriptionUnavailable
            }
            if httpResponse?.statusCode == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Self.retryAfterDate($0) }
                throw UsageError.rateLimited(retryAfter)
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }
        
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
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
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

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        // Only a rejection of the grant means the stored credential is dead;
        // throttling and server errors leave it usable later.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode),
           http.statusCode == 429 || http.statusCode >= 500 {
            throw UsageError.network("token endpoint returned \(http.statusCode)")
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let refreshed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let accessToken = refreshed["access_token"] as? String,
              !accessToken.isEmpty else {
            throw UsageError.expired
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

    /// Starts a fresh quota countdown without creating resumable history.
    /// The OAuth token is carried only in the child environment, never argv.
    func warmQuotaWindow(accessToken: String) async throws {
        let executable = claudePath
        let probeID = UUID().uuidString.lowercased()
        try await Task.detached(priority: .utility) {
            defer { Self.removeWarmupProbeResidue(sessionID: probeID) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Self.warmupArguments(sessionID: probeID)
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = accessToken
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            process.environment = environment
            // The reply's last lines say why a probe failed, such as a usage
            // limit the account has already reached.
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(90)
            while process.isRunning && Date() < deadline {
                Darwin.usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                throw UsageError.network("warm-up request timed out")
            }
            guard process.terminationStatus == 0 else {
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile().suffix(300), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                throw UsageError.network("warm-up request exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")")
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
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm=,args="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.warning("[runningProcesses] ps failed: \(error.localizedDescription)")
            return []
        }

        // Drain before waiting. `ps -axo ... args` can exceed a pipe's buffer
        // on machines with many long-lived agent processes. Waiting first
        // deadlocks: ps blocks trying to write while AccountDock blocks waiting
        // for ps to exit, freezing the main actor during failover.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parseRunningProcesses(
            text,
            excludingPID: Int32(ProcessInfo.processInfo.processIdentifier)
        )
    }

    static func parseRunningProcesses(
        _ text: String,
        excludingPID: Int32
    ) -> [RunningClaudeProcess] {
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  pid != excludingPID else { return nil }
            let executable = URL(fileURLWithPath: String(fields[1])).lastPathComponent
            guard executable == "claude" else { return nil }
            let command = String(fields[2])
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


    /// Gracefully stops the exact processes captured before a credential switch.
    /// It intentionally never escalates to SIGKILL; unsaved interactive sessions
    /// remain under the user's control if they do not respond to termination.
    func terminateForSafeRestart(_ processes: [RunningClaudeProcess]) async -> [RunningClaudeProcess] {
        guard !processes.isEmpty else { return [] }
        for process in processes {
            if Darwin.kill(process.id, SIGTERM) != 0, errno != ESRCH {
                log.warning("[safeRestart] Could not terminate pid \(process.id): errno \(errno)")
            }
        }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let remaining = processes.filter { Darwin.kill($0.id, 0) == 0 || errno == EPERM }
            if remaining.isEmpty { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return processes.filter { Darwin.kill($0.id, 0) == 0 || errno == EPERM }
    }

    /// Resumes workloads using a method appropriate to their host. IDE-managed
    /// sessions are left to their host's respawn mechanism. Standalone CLI
    /// sessions open in Terminal at their original working directory.
    func resumeAfterSafeRestart(_ processes: [RunningClaudeProcess]) {
        let activeSessionIDs = Set(runningProcesses().compactMap(\.sessionID))
        for process in processes {
            guard process.recoveryMethod == .terminal,
                  let sessionID = process.sessionID,
                  !activeSessionIDs.contains(sessionID) else { continue }
            let directory = process.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            let shellCommand = "cd \(Self.shellQuote(directory)) && \(Self.shellQuote(claudePath)) --resume \(Self.shellQuote(sessionID))"
            let script = "tell application \"Terminal\" to do script \(Self.appleScriptQuote(shellCommand))"
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            launcher.arguments = ["-e", script]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            do {
                try launcher.run()
                log.info("[safeRestart] Requested CLI resume for session \(sessionID.prefix(8))…")
            } catch {
                log.warning("[safeRestart] Could not resume CLI session: \(error.localizedDescription)")
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func switchAccount(from currentAccount: Account, to targetAccount: Account) async throws -> AuthStatus {
        let keychain = KeychainService.shared
        // Keep an exact snapshot of the live state. A target credential can
        // exist in AccountDock yet have expired or been revoked since capture;
        // verification must therefore be transactional.
        let originalToken = keychain.readClaudeToken()
        let originalOAuth = keychain.readOAuthAccount()

        func restoreOriginalCredentials() {
            guard let originalToken, let originalOAuth else {
                log.error("[switchAccount] Rollback unavailable: original credentials could not be read")
                return
            }
            let tokenRestored = keychain.writeClaudeToken(originalToken)
            let identityRestored = keychain.writeOAuthAccount(originalOAuth)
            log.info("[switchAccount] Rolled back rejected target credentials: token=\(tokenRestored), identity=\(identityRestored)")
        }

        log.info("[switchAccount] Switching from \(currentAccount.id) to \(targetAccount.id)")

        // 1. Back up current account (token + oauthAccount)
        log.info("[switchAccount] Step 1: Backing up current account...")
        if currentAccount.id == targetAccount.id {
            // Restoring the active account: the live credential is the one
            // being replaced, so it must not overwrite the backup restored.
            log.info("[switchAccount] Step 1: Restoring the same account; live credential not backed up")
        } else if let currentToken = keychain.readClaudeToken(),
           let currentOAuth = keychain.readOAuthAccount() {
            let email = (currentOAuth["emailAddress"]?.value as? String) ?? "?"
            if email == currentAccount.email {
                let saved = keychain.saveAccountBackup(token: currentToken, oauthAccount: currentOAuth, forAccountId: currentAccount.id.uuidString)
                log.info("[switchAccount] Step 1: Backup saved: \(saved)")
            } else {
                log.warning("[switchAccount] Step 1: oauthAccount email (\(email)) != source (\(currentAccount.email)), skipping backup")
            }
        } else {
            log.warning("[switchAccount] Step 1: Could not read current token or oauthAccount")
        }

        // 2. Retrieve target account's backup
        log.info("[switchAccount] Step 2: Reading backup for target account...")
        guard var targetBackup = keychain.getAccountBackup(forAccountId: targetAccount.id.uuidString) else {
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
        guard keychain.writeClaudeToken(targetBackup.token) else {
            log.error("[switchAccount] Step 3: Failed to write token to keychain!")
            throw ClaudeServiceError.keychainWriteFailed
        }
        guard keychain.writeOAuthAccount(targetBackup.oauthAccount) else {
            log.error("[switchAccount] Step 3: Failed to write oauthAccount to ~/.claude.json!")
            restoreOriginalCredentials()
            throw ClaudeServiceError.oauthAccountWriteFailed
        }
        log.info("[switchAccount] Step 3: Both token and oauthAccount written")

        // 4. Verify
        log.info("[switchAccount] Step 4: Verifying with `claude auth status`...")
        do {
            let status = try await getAuthStatus()
            guard status.loggedIn else {
                log.error("[switchAccount] Step 4: Target credentials are not logged in")
                throw ClaudeServiceError.switchVerificationFailed
            }
            if status.email != targetAccount.email {
                log.error("[switchAccount] Step 4: Logged in as \(status.email ?? "nil") instead of \(targetAccount.email)")
                throw ClaudeServiceError.switchWrongAccount(expected: targetAccount.email, actual: status.email ?? "unknown")
            }
            log.info("[switchAccount] Step 4: Switch verified — logged in as \(status.email ?? "")")
            return status
        } catch {
            restoreOriginalCredentials()
            throw error
        }
    }

    /// Capture the current Claude auth token + oauthAccount and associate with an account
    func captureCurrentCredentials(forAccountId accountId: String, expectedEmail: String) -> Bool {
        log.info("[capture] Capturing credentials for account \(accountId)...")
        let keychain = KeychainService.shared
        guard let token = keychain.readClaudeToken() else {
            log.error("[capture] Failed: no token found in keychain")
            return false
        }
        guard let oauthAccount = keychain.readOAuthAccount() else {
            log.error("[capture] Failed: no oauthAccount found in ~/.claude.json")
            return false
        }
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        guard email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            log.error("[capture] Refusing credential write: live identity \(email) does not match destination \(expectedEmail)")
            return false
        }
        log.info("[capture] Token + oauthAccount found (email=\(email)), saving backup...")
        let result = keychain.saveAccountBackup(token: token, oauthAccount: oauthAccount, forAccountId: accountId)
        log.info("[capture] Save result: \(result)")
        return result
    }

    /// Run `claude auth login` which opens browser for OAuth.
    func login() async throws {
        log.info("[login] Starting `claude auth login`... (will open browser)")
        let claudePath = self.claudePath
        _ = try await loginRunner.run(
            executable: claudePath,
            arguments: ["auth", "login"],
            environment: environment(for: claudePath)
        )
        log.info("[login] `claude auth login` process exited")

        // Give keychain a moment to sync after CLI writes
        try await Task.sleep(for: .seconds(1))
        log.info("[login] Post-login delay complete, ready for token capture")
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
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]
                process.standardOutput = stdout
                process.standardError = Pipe()

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
                process.environment = env

                do {
                    try process.run()
                } catch {
                    log.warning("[readVersion] launch failed for \(path): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date().addingTimeInterval(5.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    log.warning("[readVersion] timed out for \(path)")
                    continuation.resume(returning: nil)
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: Self.extractSemver(from: raw))
            }
        }
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

    private func runClaude(args: [String]) async throws -> String {
        let claudePath = self.claudePath
        log.debug("[runClaude] Running: \(claudePath) \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudePath] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                process.environment = self.environment(for: claudePath)

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        log.debug("[runClaude] Success (exit 0), output length: \(output.count)")
                        continuation.resume(returning: output)
                    } else if args == ["auth", "status"],
                              let data = output.data(using: .utf8),
                              (try? JSONDecoder().decode(AuthStatus.self, from: data)) != nil {
                        // Claude uses exit 1 for the valid logged-out status
                        // document. Let getAuthStatus decode it so callers can
                        // distinguish rejected credentials from a CLI failure.
                        log.info("[runClaude] auth status returned logged-out state (exit \(process.terminationStatus))")
                        continuation.resume(returning: output)
                    } else {
                        log.error("[runClaude] Failed (exit \(process.terminationStatus))")
                        continuation.resume(throwing: ClaudeServiceError.cliError("exit \(process.terminationStatus)"))
                    }
                } catch {
                    log.error("[runClaude] Process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClaudeServiceError.processLaunchFailed(error))
                }
            }
        }
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

    var errorDescription: String? {
        switch self {
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
        case .switchWrongAccount(let expected, let actual):
            return "Switch failed: expected \(expected) but got \(actual). Try removing and re-adding the account."
        }
    }
}
