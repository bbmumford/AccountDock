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
    case unsafeCredentialLocation
    /// The active account's credential needs renewing while Kimi Code runs,
    /// which renews it itself.
    case liveCredentialExpired

    var errorDescription: String? {
        switch self {
        case .liveCredentialExpired: "The Kimi Code sign-in expired; Kimi Code renews it with its next request."
        case .unsafeCredentialLocation: "The managed Kimi account location is outside AccountDock's storage."
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

    private struct Credential: Codable, Sendable {
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

    /// Kimi Code's own directory, holding `config.toml` and the credential
    /// slot its sessions use.
    private let home: URL
    /// Where each account's credential copy lives, one directory per account.
    private let managedRoot: URL
    /// Whether a Kimi Code process is running, which renews the credential
    /// in its slot itself (`renewed`).
    private let cliIsRunning: @Sendable () async -> Bool
    /// Runs the renewals of one managed credential one after another: Kimi
    /// rotates the refresh token on every renewal, so a second renewal that
    /// presented the same token would be refused and mark the account as
    /// needing sign-in. `renewCredential`, `renewed` and
    /// `renewLiveCredentialForSlots` all go through it.
    private let renewals = KimiRenewalQueue()
    /// Where every write, removal, renewal, read for use and ownership
    /// answer of a Kimi credential here is recorded.
    private let audit: CredentialAudit

    /// `home`, `managedRoot` and `cliIsRunning` default to the user's
    /// directories and a process scan; tests pass their own, and may pass
    /// an `audit` of their own.
    init(
        home: URL? = nil,
        managedRoot: URL? = nil,
        cliIsRunning: @escaping @Sendable () async -> Bool = { await CLIProcessScan.isRunning(.kimi) },
        audit: CredentialAudit = .shared
    ) {
        self.audit = audit
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
        self.managedRoot = managedRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDock/KimiAccounts", isDirectory: true)
        self.cliIsRunning = cliIsRunning
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
            try atomicCopy(source, to: destination, reason: "loginManagedAccount")
            let signedIn = try await identity(location: destination.path, reason: "loginManagedAccount")
            audit.record(.isolatedLogin, .kimi, location: destination.path,
                         accessToken: (try? readCredential(at: destination))?.accessToken,
                         outcome: "signedIn", reason: "loginManagedAccount", owner: signedIn.identifier)
            return (signedIn, destination.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func captureCurrentAccount() async throws -> (KimiIdentity, String) {
        let id = UUID()
        let location = try captureSystemAccount(accountID: id)
        return (try await identity(location: location, reason: "captureCurrentAccount"), location)
    }

    /// The account the credential at `location` signs in as, from Kimi's
    /// profile endpoint; recorded as an `ownershipCheck` by `reason`.
    func identity(location: String, reason: String) async throws -> KimiIdentity {
        let credential = try readCredential(at: URL(fileURLWithPath: location))
        var request = URLRequest(url: apiRoot.appendingPathComponent("me"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, accessToken: credential.accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            audit.record(.ownershipCheck, .kimi, location: location, accessToken: credential.accessToken,
                         outcome: "status \((response as? HTTPURLResponse)?.statusCode ?? 0)", reason: reason)
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
        audit.record(.ownershipCheck, .kimi, location: location, accessToken: credential.accessToken,
                     outcome: "answered", reason: reason, owner: identifier)
        return KimiIdentity(
            identifier: identifier,
            displayName: displayName,
            planType: tier?.isEmpty == false ? tier : nil
        )
    }

    /// Makes the account's copy at `location` Kimi Code's live credential,
    /// recorded as a `liveWrite` of that account by `reason`.
    func promoteToSystem(location: String, reason: String) throws {
        let source = URL(fileURLWithPath: location)
        _ = try readCredential(at: source)
        let target = try activeCredentialURL(in: home)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicCopy(source, to: target, attributedTo: location, reason: reason)
    }

    func syncSystemCredentials(toManagedLocation location: String, reason: String) throws {
        try atomicCopy(try activeCredentialURL(in: home), to: URL(fileURLWithPath: location), reason: reason)
    }

    /// Deletes the account directory holding `location`, which must be one
    /// `makeManagedDirectory` created: a directory inside `managedRoot`, not
    /// the root itself or anything outside it. Recorded as a
    /// `savedCopyRemove` by `reason`.
    func removeManagedAccount(location: String, reason: String) throws {
        let directory = URL(fileURLWithPath: location).standardizedFileURL.deletingLastPathComponent()
        let root = managedRoot.standardizedFileURL.path
        guard directory.path.hasPrefix(root + "/"), directory.path != root else {
            audit.record(.savedCopyRemove, .kimi, location: location, outcome: "refusedUnsafeLocation", reason: reason)
            throw KimiServiceError.unsafeCredentialLocation
        }
        let removed = (try? readCredential(at: URL(fileURLWithPath: location)))?.accessToken
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        audit.record(.savedCopyRemove, .kimi, location: location, accessToken: removed,
                     outcome: removed == nil ? "absent" : "ok", reason: reason)
    }

    /// An access token valid for at least `minimumLifetime`, for the request
    /// router. The active account's CLI copy is used when it is newer, since
    /// the Kimi CLI renews it itself; the token is renewed here only when
    /// neither copy lasts long enough.
    func freshAccessToken(location: String, isActive: Bool, minimumLifetime: TimeInterval,
                          reason: String) async throws -> (String, Date) {
        let managedURL = URL(fileURLWithPath: location)
        var credential = try newestCredential(at: managedURL, isActive: isActive, reason: reason)
        if credential.expiresAt.map({ Date(timeIntervalSince1970: $0) <= Date().addingTimeInterval(minimumLifetime) }) != false {
            credential = try await renewed(credential, managedURL: managedURL, isActive: isActive, reason: reason)
        }
        audit.record(.savedCopyRead, .kimi, location: location, accessToken: credential.accessToken, outcome: "ok",
                     reason: reason)
        return (credential.accessToken, Date(timeIntervalSince1970: credential.expiresAt ?? Date().timeIntervalSince1970))
    }

    /// `credential` renewed and saved to the managed copy, and for the active
    /// account to Kimi Code's slot as well. The active account's credential
    /// is left to Kimi Code while one of its processes runs: it renews the
    /// slot under a lock of its own and, when the refresh token it renews
    /// with was already used, overwrites the slot with an empty, revoked
    /// credential, so a renewal here racing its own can sign the account out.
    /// A renewal that finished while this one waited in `renewals` has
    /// already replaced `credential`'s refresh token; its result is used
    /// instead of presenting the spent token.
    private func renewed(_ credential: Credential, managedURL: URL, isActive: Bool, reason: String) async throws -> Credential {
        if isActive, await cliIsRunning() { throw KimiServiceError.liveCredentialExpired }
        return try await renewals.run(Self.renewalKey(managedURL)) { [self] in
            let current = (try? newestCredential(at: managedURL, isActive: isActive, reason: reason)) ?? credential
            if current.refreshToken != credential.refreshToken { return current }
            let fresh: Credential
            do {
                fresh = try await refresh(current)
            } catch {
                audit.record(.renewal, .kimi, location: managedURL.path, accessToken: current.accessToken,
                             outcome: Self.renewalOutcome(error), reason: reason)
                throw error
            }
            audit.record(.renewal, .kimi, location: managedURL.path, accessToken: fresh.accessToken,
                         previousAccessToken: current.accessToken, outcome: "renewed", reason: reason)
            try writeCredential(fresh, to: managedURL, reason: reason + ".renewal")
            if isActive {
                try writeCredential(fresh, to: activeCredentialURL(in: home), attributedTo: managedURL.path,
                                    reason: reason + ".renewal")
            }
            return fresh
        }
    }

    /// How a failed renewal is recorded.
    private static func renewalOutcome(_ error: Error) -> String {
        switch error {
        case KimiServiceError.credentialRejected, KimiServiceError.invalidCredentials: "rejected"
        default: "unavailable"
        }
    }

    /// The key `renewals` orders a managed credential's renewals by.
    private static func renewalKey(_ managedURL: URL) -> String {
        managedURL.standardizedFileURL.path
    }

    /// Starts the account's 5-hour window with a one-token request to the
    /// coding endpoint, which is what Kimi Code itself calls.
    func warmQuotaWindow(location: String, isActive: Bool) async throws {
        let (accessToken, _) = try await freshAccessToken(location: location, isActive: isActive, minimumLifetime: 60,
                                                          reason: "warmQuotaWindow")
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
    /// A renewal of the same copy that finished while this one waited in
    /// `renewals` counts as this one.
    func renewCredential(location: String, reason: String) async -> CredentialRenewal {
        let managedURL = URL(fileURLWithPath: location)
        let presented: Credential
        do {
            presented = try readCredential(at: managedURL)
        } catch {
            audit.record(.renewal, .kimi, location: location, outcome: "rejected", reason: reason)
            return .rejected
        }
        do {
            try await renewals.run(Self.renewalKey(managedURL)) { [self] in
                let current = try readCredential(at: managedURL)
                guard current.refreshToken == presented.refreshToken else { return }
                let renewed = try await refresh(current)
                audit.record(.renewal, .kimi, location: location, accessToken: renewed.accessToken,
                             previousAccessToken: current.accessToken, outcome: "renewed", reason: reason)
                try writeCredential(renewed, to: managedURL, reason: reason + ".renewal")
            }
            return .renewed
        } catch {
            let outcome: CredentialRenewal = Self.renewalOutcome(error) == "rejected" ? .rejected : .unavailable
            audit.record(.renewal, .kimi, location: location, accessToken: presented.accessToken,
                         outcome: outcome == .rejected ? "rejected" : "unavailable", reason: reason)
            return outcome
        }
    }

    /// Whether the managed credential's access token stays valid `interval`
    /// from now; one without an expiry counts as expiring.
    func credentialLasts(location: String, for interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let credential = try? readCredential(at: URL(fileURLWithPath: location)),
              let expiresAt = credential.expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt) > now.addingTimeInterval(interval)
    }

    // MARK: - Session slots

    /// The credential, as Kimi Code's credential JSON, that slots serving
    /// the account copy their access token from: the managed copy, or for
    /// the account whose credential Kimi Code's home holds (`isActive`)
    /// whichever of the two is newer (`newestCredential`). Nil when neither
    /// is complete. Read by `KimiSessionIsolation.currentSlotCredential`.
    func slotSourceCredential(location: String, isActive: Bool) -> String? {
        guard let credential = try? newestCredential(at: URL(fileURLWithPath: location), isActive: isActive,
                                                     reason: "slotSourceCredential"),
              let data = try? JSONEncoder().encode(credential) else { return nil }
        audit.record(.savedCopyRead, .kimi, location: location, accessToken: credential.accessToken, outcome: "ok",
                     reason: "slotSourceCredential")
        return String(decoding: data, as: UTF8.self)
    }

    /// Renews the credential of the account whose credential Kimi Code's
    /// home holds, when slots need its access token to last `lifetime`,
    /// even while Kimi Code runs: under Kimi Code's own lock on that
    /// credential (`KimiCredentialLock`), so a renewal of its own and this
    /// one never overlap, and after reading both copies again under the
    /// lock, so a renewal Kimi Code finished first is used as it stands and
    /// its new refresh token is never presented twice. The renewed
    /// credential goes to the managed copy and to Kimi Code's home, where
    /// unslotted sessions read it at their next request. `renewed` instead
    /// leaves this credential to a running Kimi Code, since the router and
    /// usage readings take no lock. Called by
    /// `KimiSessionIsolation.currentSlotCredential`; `lockWait` is how long
    /// a lock Kimi Code keeps fresh is waited for.
    func renewLiveCredentialForSlots(location: String, lasting lifetime: TimeInterval,
                                     lockWait: TimeInterval = 15, reason: String) async -> CredentialRenewal {
        let managedURL = URL(fileURLWithPath: location)
        guard let liveURL = try? activeCredentialURL(in: home) else { return .unavailable }
        let lock = KimiCredentialLock(home: home, name: liveURL.deletingPathExtension().lastPathComponent)
        do {
            return try await renewals.run(Self.renewalKey(managedURL)) { [self] in
                guard await Task.detached(operation: { lock.acquire(waitingUpTo: lockWait) }).value else {
                    return .unavailable
                }
                // The renewal request can outlast the lock's stale period.
                let keepAlive = Task.detached {
                    while true {
                        do { try await Task.sleep(nanoseconds: UInt64(KimiCredentialLock.touchInterval * 1_000_000_000)) }
                        catch { return }
                        lock.touch()
                    }
                }
                defer {
                    keepAlive.cancel()
                    lock.release()
                }
                let current = try newestCredential(at: managedURL, isActive: true, reason: reason)
                if let expiresAt = current.expiresAt,
                   Date(timeIntervalSince1970: expiresAt) > Date().addingTimeInterval(lifetime) {
                    return .renewed
                }
                let fresh: Credential
                do {
                    fresh = try await refresh(current)
                } catch {
                    audit.record(.renewal, .kimi, location: location, live: true, accessToken: current.accessToken,
                                 outcome: Self.renewalOutcome(error), reason: reason)
                    throw error
                }
                audit.record(.renewal, .kimi, location: location, live: true, accessToken: fresh.accessToken,
                             previousAccessToken: current.accessToken, outcome: "renewed", reason: reason)
                try writeCredential(fresh, to: managedURL, reason: reason + ".renewal")
                try writeCredential(fresh, to: liveURL, attributedTo: location, reason: reason + ".renewal")
                return .renewed
            }
        } catch KimiServiceError.credentialRejected {
            return .rejected
        } catch KimiServiceError.invalidCredentials {
            return .rejected
        } catch {
            return .unavailable
        }
    }

    /// The managed credential, replaced by the CLI's copy for the active
    /// account when that is newer: the Kimi CLI renews its own copy, which
    /// revokes the managed copy's refresh token, so `refresh` on the older
    /// one is refused though the account is still signed in. The copy
    /// taken from the CLI is recorded as a `savedCopyWrite` by `reason`.
    private func newestCredential(at managedURL: URL, isActive: Bool, reason: String) throws -> Credential {
        let credential = try readCredential(at: managedURL)
        guard isActive, let activeURL = try? activeCredentialURL(in: home),
              let active = try? readCredential(at: activeURL),
              (active.expiresAt ?? 0) > (credential.expiresAt ?? 0) else { return credential }
        try writeCredential(active, to: managedURL, reason: reason + ".adoptLive")
        return active
    }

    func getUsageLimits(location: String, isActive: Bool) async throws -> UsageAPIResponse {
        let managedURL = URL(fileURLWithPath: location)
        var credential = try newestCredential(at: managedURL, isActive: isActive, reason: "getUsageLimits")
        var renewedHere = false
        if credential.expiresAt.map({ Date(timeIntervalSince1970: $0) <= Date().addingTimeInterval(60) }) != false {
            credential = try await renewed(credential, managedURL: managedURL, isActive: isActive, reason: "getUsageLimits")
            renewedHere = true
        }
        var (data, status) = try await usageResponse(accessToken: credential.accessToken)
        if status == 401, !renewedHere {
            // The access token was refused before its recorded expiry: renew
            // it once and read again.
            credential = try await renewed(credential, managedURL: managedURL, isActive: isActive, reason: "getUsageLimits")
            (data, status) = try await usageResponse(accessToken: credential.accessToken)
        }
        audit.record(.savedCopyRead, .kimi, location: location, accessToken: credential.accessToken,
                     outcome: "status \(status)", reason: "getUsageLimits")
        if status == 401 {
            // A renewed token refused again shows the sign-in is no longer
            // accepted; for the active account Kimi Code may still renew its
            // own copy.
            throw isActive ? KimiServiceError.liveCredentialExpired : KimiServiceError.credentialRejected
        }
        guard status == 200 else {
            if status == 429 { throw KimiServiceError.rateLimited }
            throw KimiServiceError.requestFailed("usage endpoint returned \(status)")
        }
        LimitResetShapes.note(.kimi, reply: data)
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

    private func usageResponse(accessToken: String) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: apiRoot.appendingPathComponent("usages"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func captureSystemAccount(accountID: UUID) throws -> String {
        let source = try activeCredentialURL(in: home)
        _ = try readCredential(at: source)
        let directory = try makeManagedDirectory(accountID: accountID)
        let destination = directory.appendingPathComponent("credentials.json")
        try atomicCopy(source, to: destination, reason: "captureCurrentAccount")
        return destination.path
    }

    private func makeManagedDirectory(accountID: UUID) throws -> URL {
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let directory = managedRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// The table of `config.toml` naming the OAuth credential Kimi Code's
    /// managed provider signs in with. Other tables carry a `key` too: other
    /// providers' and services' OAuth references.
    static let credentialTable = #"providers."managed:kimi-code".oauth"#

    /// The credential file Kimi Code's sessions use: the `key` of
    /// `credentialTable` in `kimiHome`'s `config.toml`, as a file under
    /// `credentials/`.
    func activeCredentialURL(in kimiHome: URL) throws -> URL {
        let config = kimiHome.appendingPathComponent("config.toml")
        guard let key = TOMLHookConfig.value(at: config, table: Self.credentialTable, key: "key"), !key.isEmpty else {
            throw KimiServiceError.credentialsNotFound
        }
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

    /// Replaces the credential file at `url`, recorded by `reason` as a
    /// `liveWrite` when `url` is Kimi Code's own credential and a
    /// `savedCopyWrite` otherwise, attributed to the account whose copy is
    /// at `attributedTo` (by default `url` itself), with the token replaced.
    private func writeCredential(_ credential: Credential, to url: URL, attributedTo location: String? = nil,
                                 reason: String) throws {
        let live = (try? activeCredentialURL(in: home))?.standardizedFileURL.path == url.standardizedFileURL.path
        let replaced = (try? readCredential(at: url))?.accessToken
        let data = try JSONEncoder().encode(credential)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFile.writeAtomically(data, to: url, mode: 0o600)
        } catch {
            audit.record(live ? .liveWrite : .savedCopyWrite, .kimi, location: location ?? url.path, live: live,
                         accessToken: credential.accessToken, previousAccessToken: replaced, outcome: "failed", reason: reason)
            throw error
        }
        audit.record(live ? .liveWrite : .savedCopyWrite, .kimi, location: location ?? url.path, live: live,
                     accessToken: credential.accessToken, previousAccessToken: replaced, outcome: "ok", reason: reason)
    }

    private func atomicCopy(_ source: URL, to destination: URL, attributedTo location: String? = nil,
                            reason: String) throws {
        let data = try Data(contentsOf: source)
        let credential = try JSONDecoder().decode(Credential.self, from: data)
        try writeCredential(credential, to: destination, attributedTo: location, reason: reason)
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

/// Runs the operations given for one key one after another, in the order
/// they arrive; operations for different keys run at the same time.
/// `KimiService` keys its renewals by managed credential.
actor KimiRenewalQueue {
    private var last: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ key: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last[key]
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        last[key] = Task { _ = try? await task.value }
        return try await task.value
    }
}
