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
    let usage: UsageAPIResponse
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

private struct CodexHookSession: Decodable {
    let provider: String?
    let sessionID: String
    let workingDirectory: String?
    let processID: Int32?
    let host: String?
    let observedAt: Date?
}

enum CodexServiceError: LocalizedError {
    case binaryNotFound
    case notLoggedIn
    case invalidCredentials
    case loginFailed(String)
    case unsafeCredentialLocation

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Codex CLI not found. Install Codex or choose its path in Settings."
        case .notLoggedIn:
            return "No Codex login was found."
        case .invalidCredentials:
            return "Codex credentials could not be read."
        case let .loginFailed(message):
            return "Codex login failed: \(message)"
        case .unsafeCredentialLocation:
            return "The managed Codex account location is outside AccountDock's storage."
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
        let records = hookSessionRecords()
        return runningCodexProcesses().map { process in
            let record = records[process.id]
            let openSession = openSessionMetadata(processID: process.id)
            return RunningCodexProcess(
                id: process.id,
                command: process.command,
                sessionID: Self.extractResumeSessionID(from: process.command)
                    ?? openSession.sessionID
                    ?? record?.sessionID,
                workingDirectory: openSession.workingDirectory ?? record?.workingDirectory,
                host: record?.host ?? process.host,
                terminalTTY: process.terminalTTY,
                hasUsageLimitError: openSession.rolloutPath.map(Self.rolloutEndsWithUsageLimit) ?? false
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

    func resumeAfterSafeRestart(_ processes: [RunningCodexProcess], codexHome: String? = nil) {
        guard let binaryPath else { return }
        for process in processes {
            guard !process.isHostManaged,
                  let sessionID = process.sessionID else {
                if process.isHostManaged {
                    codexLog.info("[safeRestart] \(process.label) left to its host to reconnect")
                } else {
                    codexLog.warning("[safeRestart] No session ID available for pid \(process.id)")
                }
                continue
            }
            let directory = process.workingDirectory ?? NSHomeDirectory()
            let scope = codexHome.map { "CODEX_HOME=\(Self.shellQuote($0)) " } ?? ""
            let command = "\(scope)\(Self.shellQuote(binaryPath)) resume \(Self.shellQuote(sessionID)) -C \(Self.shellQuote(directory))"
            let script = "tell application \"Terminal\" to do script \(Self.appleScriptQuote(command))"
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            launcher.arguments = ["-e", script]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            do {
                try launcher.run()
                codexLog.info("[safeRestart] Requested CLI resume for session \(sessionID.prefix(8))…")
            } catch {
                codexLog.warning("[safeRestart] Could not resume CLI session: \(error.localizedDescription)")
            }
        }
    }

    private struct CodexProcess {
        let id: Int32
        let command: String
        let host: String
        let terminalTTY: String?
    }

    private func runningCodexProcesses() -> [CodexProcess] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        let parsed: [(Int32, Int32, String, String)] = lines.compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid, String(fields[2]), String(fields[3]))
        }
        let commandByPID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.0, $0.3) })
        let parentByPID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.0, $0.1) })
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

    static func isRestartableCodexCommand(_ command: String) -> Bool {
        let fields = command.split(whereSeparator: \.isWhitespace)
        guard let executable = fields.first.map(String.init) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard name == "codex" else { return false }
        return !command.contains("app-server")
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
        let closer = Process()
        closer.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        closer.arguments = ["-e", script]
        closer.standardOutput = FileHandle.nullDevice
        closer.standardError = FileHandle.nullDevice
        do {
            try closer.run()
            closer.waitUntilExit()
        } catch {
            codexLog.warning("[forceRestart] Could not close Terminal tabs: \(error.localizedDescription)")
        }
    }

    private func hookSessionRecords() -> [Int32: CodexHookSession] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.reduce(into: [:]) { result, file in
            guard file.lastPathComponent.hasPrefix("codex-"),
                  let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(CodexHookSession.self, from: data),
                  let pid = record.processID else { return }
            if let existing = result[pid],
               let old = existing.observedAt,
               let new = record.observedAt,
               old > new { return }
            result[pid] = record
        }
    }

    private func openSessionMetadata(
        processID: Int32
    ) -> (sessionID: String?, workingDirectory: String?, rolloutPath: String?) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(processID), "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil, nil) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return (nil, nil, nil) }

        var sessionID: String?
        var workingDirectory: String?
        var rolloutPath: String?
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard rawLine.first == "n" else { continue }
            let path = String(rawLine.dropFirst())
            if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl"),
               let id = Self.sessionID(fromRolloutPath: path) {
                sessionID = id
                rolloutPath = path
            } else if workingDirectory == nil,
                      path.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: path) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    workingDirectory = path
                }
            }
        }
        return (sessionID, workingDirectory, rolloutPath)
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

    var systemHome: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
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
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "exec", "--ephemeral", "--skip-git-repo-check",
                "--sandbox", "read-only", "--ignore-rules",
                "Reply with exactly: OK"
            ]
            var environment = ProcessInfo.processInfo.environment
            if let codexHome { environment["CODEX_HOME"] = codexHome }
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline {
                Darwin.usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                throw CodexServiceError.loginFailed("Warm-up request timed out.")
            }
            guard process.terminationStatus == 0 else {
                throw CodexServiceError.loginFailed("Warm-up request exited \(process.terminationStatus).")
            }
        }.value
    }

    func getUsageSnapshot(codexHome: String?) async throws -> CodexUsageSnapshot {
        let home = codexHome.map(URL.init(fileURLWithPath:)) ?? systemHome
        let authURL = home.appendingPathComponent("auth.json")
        let authData = try Data(contentsOf: authURL)
        guard var auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              var tokens = auth["tokens"] as? [String: Any] else {
            throw CodexServiceError.invalidCredentials
        }
        if Self.credentialsNeedRefresh(auth),
           let refreshToken = tokens["refresh_token"] as? String,
           !refreshToken.isEmpty {
            tokens = try await refreshOAuthTokens(tokens, refreshToken: refreshToken)
            auth["tokens"] = tokens
            auth["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            try Self.writePrivateAuth(auth, to: authURL)
        }
        guard
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexServiceError.invalidCredentials
        }
        // The usage endpoint has been observed returning the same plan_type for
        // different, correctly scoped accounts. Prefer the plan claim carried by
        // this account's signed access token; use the response only for older
        // credentials that do not contain the claim.
        let credentialPlan = Self.planType(fromJWT: accessToken)
            ?? (tokens["id_token"] as? String).flatMap(Self.planType(fromJWT:))

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AccountDock", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CodexServiceError.invalidCredentials
        }
        let responseSnapshot = try Self.decodeUsageSnapshot(data)
        return CodexUsageSnapshot(
            usage: responseSnapshot.usage,
            planType: credentialPlan ?? responseSnapshot.planType
        )
    }

    private func refreshOAuthTokens(
        _ existing: [String: Any],
        refreshToken: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let refreshed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexServiceError.invalidCredentials
        }
        var merged = existing
        for key in ["access_token", "refresh_token", "id_token"] {
            if let value = refreshed[key] as? String, !value.isEmpty { merged[key] = value }
        }
        return merged
    }

    private static func credentialsNeedRefresh(_ auth: [String: Any]) -> Bool {
        guard let value = auth["last_refresh"] as? String,
              let date = ISO8601DateFormatter().date(from: value) else { return true }
        return Date().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    private static func writePrivateAuth(_ auth: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            extraUsage: nil
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
            return (identity, home.path)
        } catch {
            try? removeManagedHome(home)
            throw error
        }
    }

    func cancelLogin() {
        loginRunner.cancel()
    }

    func promoteToSystem(homePath: String) throws {
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        try validateManagedHome(home)
        let source = home.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else { throw CodexServiceError.invalidCredentials }

        try fileManager.createDirectory(at: systemHome, withIntermediateDirectories: true)
        let destination = systemHome.appendingPathComponent("auth.json")
        let staged = systemHome.appendingPathComponent(".auth.accountdock-\(UUID().uuidString).json")
        try fileManager.copyItem(at: source, to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        codexLog.info("[promote] Promoted managed Codex account to system auth.json")
    }

    /// Saves refreshed system credentials back into the active managed home
    /// before another account is promoted.
    func syncSystemCredentials(toManagedHome homePath: String, expectedEmail: String) throws {
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        try validateManagedHome(home)
        let source = systemHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else { throw CodexServiceError.notLoggedIn }
        let liveIdentity = try readIdentity(home: systemHome)
        guard liveIdentity.email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw CodexServiceError.loginFailed(
                "System Codex account is \(liveIdentity.email), expected \(expectedEmail). Credentials were not overwritten."
            )
        }

        let destination = home.appendingPathComponent("auth.json")
        let staged = home.appendingPathComponent(".auth.accountdock-\(UUID().uuidString).json")
        try fileManager.copyItem(at: source, to: staged)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        codexLog.info("[sync] Saved refreshed system credentials into managed Codex home")
    }

    func removeManagedAccount(homePath: String) throws {
        try removeManagedHome(URL(fileURLWithPath: homePath, isDirectory: true))
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
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            var environment = ProcessInfo.processInfo.environment
            if let codexHome {
                environment["CODEX_HOME"] = codexHome
            }
            process.environment = environment
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                guard process.terminationStatus == 0 else {
                    throw CodexServiceError.loginFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return output
            } catch let error as CodexServiceError {
                throw error
            } catch {
                throw CodexServiceError.loginFailed(error.localizedDescription)
            }
        }.value
    }
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
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
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        var usageWindow: UsageWindow {
            UsageWindow(
                utilization: usedPercent,
                resetsAt: ISO8601DateFormatter().string(
                    from: Date(timeIntervalSince1970: TimeInterval(resetAt))
                ),
                windowSeconds: limitWindowSeconds
            )
        }
    }
}
