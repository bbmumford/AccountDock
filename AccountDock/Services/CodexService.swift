import Foundation

private let codexLog = FileLog("Codex")

struct CodexIdentity: Sendable {
    let email: String
    let displayName: String
    let accountID: String?
    let planType: String?
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
        let home = codexHome.map(URL.init(fileURLWithPath:)) ?? systemHome
        let authURL = home.appendingPathComponent("auth.json")
        let authData = try Data(contentsOf: authURL)
        guard let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexServiceError.invalidCredentials
        }

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
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        return UsageAPIResponse(
            fiveHour: payload.window(matchingSeconds: 5 * 60 * 60)?.usageWindow,
            sevenDay: payload.window(matchingSeconds: 7 * 24 * 60 * 60)?.usageWindow,
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
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
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    func window(matchingSeconds target: Int) -> Window? {
        [rateLimit?.primaryWindow, rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .first { $0.limitWindowSeconds == target }
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
                )
            )
        }
    }
}
