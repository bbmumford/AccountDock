import Foundation
import Darwin

struct KimiIdentity: Sendable {
    let identifier: String
    let displayName: String
    let planType: String?
}

enum KimiServiceError: LocalizedError {
    case binaryNotFound
    case credentialsNotFound
    case invalidCredentials
    case requestFailed(String)
    case rateLimited
    /// The token endpoint refused the refresh token: the account must sign
    /// in again.
    case credentialRejected

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: "Kimi Code CLI was not found."
        case .credentialsNotFound: "Kimi Code credentials were not found. Run `kimi login` first."
        case .invalidCredentials: "The Kimi credential is incomplete or unreadable."
        case .requestFailed(let detail): "Kimi request failed: \(detail)"
        case .rateLimited: "Kimi temporarily rate-limited usage refresh."
        case .credentialRejected: "Kimi rejected this account's saved sign-in. Reauthenticate this account."
        }
    }
}

/// Native Kimi Code adapter. AccountDock owns a copy of each CLI credential and
/// atomically promotes it into Kimi's configured credential slot when switching.
/// Refresh tokens rotate, so every successful refresh is persisted before use.
final class KimiService: @unchecked Sendable {
    static let shared = KimiService()

    private struct Credential: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double?
        var expiresIn: Double?
        var scope: String?
        var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct UsageEnvelope: Decodable {
        struct Window: Decodable {
            let usedRatio: Double
            let resetTime: String?
            enum CodingKeys: String, CodingKey {
                case usedRatio = "used_ratio"
                case resetTime = "reset_time"
            }
        }
        struct Usages: Decodable {
            let session: Window
            let monthTotal: Window
            let monthCode: Window
            enum CodingKeys: String, CodingKey {
                case session = "limit_5h"
                case monthTotal = "limit_month_total"
                case monthCode = "limit_month_code"
            }
        }
        let usages: Usages
    }

    private struct UserProfile: Decodable {
        let userID: String
        let nickname: String?
        let userLevelName: String?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case nickname
            case userLevelName = "user_level_name"
            case email
        }
    }

    private let fileManager = FileManager.default
    private let loginRunner = LoginProcessRunner()
    private let authHost = URL(string: "https://auth.kimi.ai")!
    private let apiRoot = URL(string: "https://api.kimi.ai/coding/v1")!
    private let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    private var home: URL { fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true) }
    private var managedRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDock/KimiAccounts", isDirectory: true)
    }

    func isAvailable() -> Bool { executablePath() != nil }
    func cancelLogin() { loginRunner.cancel() }

    func loginManagedAccount() async throws -> (KimiIdentity, String) {
        guard let executable = executablePath() else { throw KimiServiceError.binaryNotFound }
        let directory = try makeManagedDirectory(accountID: UUID())
        do {
            var environment = ProcessInfo.processInfo.environment
            // A new account must not inherit the already-authenticated system
            // profile: `kimi login` otherwise exits successfully without ever
            // starting its device-code browser flow.
            environment["KIMI_CODE_HOME"] = directory.path
            environment["KIMI_CODE_NO_AUTO_UPDATE"] = "1"
            _ = try await loginRunner.run(
                executable: executable,
                arguments: ["login", "--region", "global"],
                environment: environment,
                openFirstBrowserURL: true,
                preferredBrowserHosts: ["kimi.ai", "kimi.com"]
            )
            let source = try activeCredentialURL(in: directory)
            let destination = directory.appendingPathComponent("credentials.json")
            try atomicCopy(source, to: destination)
            return (try await identity(location: destination.path), destination.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func captureCurrentAccount() async throws -> (KimiIdentity, String) {
        let id = UUID()
        let location = try captureSystemAccount(accountID: id)
        return (try await identity(location: location), location)
    }

    func identity(location: String) async throws -> KimiIdentity {
        let credential = try readCredential(at: URL(fileURLWithPath: location))
        var request = URLRequest(url: apiRoot.appendingPathComponent("me"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, accessToken: credential.accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw KimiServiceError.requestFailed(
                "profile endpoint returned \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        let email = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = email?.isEmpty == false ? email! : profile.userID
        let nickname = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = nickname?.isEmpty == false ? nickname! : identifier
        let tier = profile.userLevelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return KimiIdentity(
            identifier: identifier,
            displayName: displayName,
            planType: tier?.isEmpty == false ? tier : nil
        )
    }

    func promoteToSystem(location: String) throws {
        let source = URL(fileURLWithPath: location)
        _ = try readCredential(at: source)
        let target = try activeCredentialURL(in: home)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicCopy(source, to: target)
    }

    func syncSystemCredentials(toManagedLocation location: String) throws {
        try atomicCopy(try activeCredentialURL(in: home), to: URL(fileURLWithPath: location))
    }

    func removeManagedAccount(location: String) throws {
        try fileManager.removeItem(at: URL(fileURLWithPath: location).deletingLastPathComponent())
    }

    /// An access token valid for at least `minimumLifetime`, for the request
    /// router. The active account's CLI copy is used when it is newer, since
    /// the Kimi CLI renews it itself; the token is renewed here only when
    /// neither copy lasts long enough.
    func freshAccessToken(location: String, isActive: Bool, minimumLifetime: TimeInterval) async throws -> (String, Date) {
        let managedURL = URL(fileURLWithPath: location)
        var credential = try newestCredential(at: managedURL, isActive: isActive)
        if credential.expiresAt.map({ Date(timeIntervalSince1970: $0) <= Date().addingTimeInterval(minimumLifetime) }) != false {
            credential = try await refresh(credential)
            try writeCredential(credential, to: managedURL)
            if isActive { try writeCredential(credential, to: activeCredentialURL(in: home)) }
        }
        return (credential.accessToken, Date(timeIntervalSince1970: credential.expiresAt ?? Date().timeIntervalSince1970))
    }

    /// Starts the account's 5-hour window with a one-token request to the
    /// coding endpoint, which is what Kimi Code itself calls.
    func warmQuotaWindow(location: String, isActive: Bool) async throws {
        let (accessToken, _) = try await freshAccessToken(location: location, isActive: isActive, minimumLifetime: 60)
        var request = URLRequest(url: apiRoot.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, accessToken: accessToken)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "kimi-for-coding",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "Reply with exactly: OK"]],
        ])
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = String(decoding: data.prefix(200), as: UTF8.self)
            throw KimiServiceError.requestFailed("warm-up request returned \(status): \(reply)")
        }
    }

    /// Renews an inactive account's managed credential and saves it there,
    /// without touching the credential slot Kimi's running sessions use.
    /// Called by `KimiCredentialModule`.
    func renewCredential(location: String) async -> CredentialRenewal {
        let managedURL = URL(fileURLWithPath: location)
        do {
            let renewed = try await refresh(try readCredential(at: managedURL))
            try writeCredential(renewed, to: managedURL)
            return .renewed
        } catch KimiServiceError.credentialRejected {
            return .rejected
        } catch KimiServiceError.invalidCredentials {
            return .rejected
        } catch {
            return .unavailable
        }
    }

    /// Whether the managed credential's access token stays valid `interval`
    /// from now; one without an expiry counts as expiring.
    func credentialLasts(location: String, for interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let credential = try? readCredential(at: URL(fileURLWithPath: location)),
              let expiresAt = credential.expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt) > now.addingTimeInterval(interval)
    }

    /// The managed credential, replaced by the CLI's copy for the active
    /// account when that is newer: the Kimi CLI renews its own copy, which
    /// revokes the managed copy's refresh token, so `refresh` on the older
    /// one is refused though the account is still signed in.
    private func newestCredential(at managedURL: URL, isActive: Bool) throws -> Credential {
        let credential = try readCredential(at: managedURL)
        guard isActive, let activeURL = try? activeCredentialURL(in: home),
              let active = try? readCredential(at: activeURL),
              (active.expiresAt ?? 0) > (credential.expiresAt ?? 0) else { return credential }
        try writeCredential(active, to: managedURL)
        return active
    }

    func getUsageLimits(location: String, isActive: Bool) async throws -> UsageAPIResponse {
        let managedURL = URL(fileURLWithPath: location)
        var credential = try newestCredential(at: managedURL, isActive: isActive)
        if credential.expiresAt.map({ Date(timeIntervalSince1970: $0) <= Date().addingTimeInterval(60) }) != false {
            credential = try await refresh(credential)
            try writeCredential(credential, to: managedURL)
            if isActive { try writeCredential(credential, to: activeCredentialURL(in: home)) }
        }
        var request = URLRequest(url: apiRoot.appendingPathComponent("usages"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, accessToken: credential.accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 429 { throw KimiServiceError.rateLimited }
            throw KimiServiceError.requestFailed("usage endpoint returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let body = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        let month = body.usages.monthCode.usedRatio > body.usages.monthTotal.usedRatio
            ? body.usages.monthCode : body.usages.monthTotal
        return UsageAPIResponse(
            fiveHour: UsageWindow(utilization: body.usages.session.usedRatio * 100, resetsAt: body.usages.session.resetTime, windowSeconds: 18_000),
            sevenDay: UsageWindow(utilization: month.usedRatio * 100, resetsAt: month.resetTime),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )
    }

    private func captureSystemAccount(accountID: UUID) throws -> String {
        let source = try activeCredentialURL(in: home)
        _ = try readCredential(at: source)
        let directory = try makeManagedDirectory(accountID: accountID)
        let destination = directory.appendingPathComponent("credentials.json")
        try atomicCopy(source, to: destination)
        return destination.path
    }

    private func makeManagedDirectory(accountID: UUID) throws -> URL {
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let directory = managedRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func activeCredentialURL(in kimiHome: URL) throws -> URL {
        let config = kimiHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let match = text.range(of: #"(?m)^key\s*=\s*\"([^\"]+)\""#, options: .regularExpression) else {
            throw KimiServiceError.credentialsNotFound
        }
        let line = String(text[match])
        guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else {
            throw KimiServiceError.credentialsNotFound
        }
        let key = String(line[line.index(after: first)..<last])
        guard let storageName = Self.credentialStorageName(for: key) else {
            throw KimiServiceError.invalidCredentials
        }
        return kimiHome.appendingPathComponent("credentials/\(storageName).json")
    }

    /// Kimi config stores a logical OAuth key (`oauth/<name>`), while its file
    /// storage deliberately removes that namespace and writes `<name>.json`.
    static func credentialStorageName(for logicalKey: String) -> String? {
        let name = logicalKey.hasPrefix("oauth/")
            ? String(logicalKey.dropFirst("oauth/".count))
            : logicalKey
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return name
    }

    private func refresh(_ current: Credential) async throws -> Credential {
        var request = URLRequest(url: authHost.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyIdentityHeaders(to: &request)
        let values = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
        ]
        request.httpBody = values.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A refused grant is answered with 400 or 401; anything else says
        // nothing about the refresh token.
        if status == 400 || status == 401 { throw KimiServiceError.credentialRejected }
        guard status == 200 else {
            throw KimiServiceError.requestFailed("token endpoint returned \(status)")
        }
        var fresh = try JSONDecoder().decode(Credential.self, from: data)
        if let seconds = fresh.expiresIn { fresh.expiresAt = Date().timeIntervalSince1970 + seconds }
        return fresh
    }

    private func readCredential(at url: URL) throws -> Credential {
        guard let data = try? Data(contentsOf: url),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              !credential.accessToken.isEmpty, !credential.refreshToken.isEmpty else {
            throw KimiServiceError.invalidCredentials
        }
        return credential
    }

    private func writeCredential(_ credential: Credential, to url: URL) throws {
        let data = try JSONEncoder().encode(credential)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: url) }
    }

    private func atomicCopy(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        let credential = try JSONDecoder().decode(Credential.self, from: data)
        try writeCredential(credential, to: destination)
    }

    private func applyHeaders(to request: inout URLRequest, accessToken: String) {
        applyIdentityHeaders(to: &request)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func applyIdentityHeaders(to request: inout URLRequest) {
        request.setValue("kimi-code-cli/2.1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue("2.1.1", forHTTPHeaderField: "X-Msh-Version")
        request.setValue(Host.current().localizedName ?? "Mac", forHTTPHeaderField: "X-Msh-Device-Name")
        request.setValue("macOS", forHTTPHeaderField: "X-Msh-Device-Model")
        if let id = try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8) {
            request.setValue(id.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Msh-Device-Id")
        }
    }

    private func executablePath() -> String? {
        [home.appendingPathComponent("bin/kimi").path, "/opt/homebrew/bin/kimi", "/usr/local/bin/kimi"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
