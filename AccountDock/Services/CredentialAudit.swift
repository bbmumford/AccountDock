import CryptoKit
import Darwin
import Foundation

/// The app log for the audit's own failures and mismatches.
private let auditLog = FileLog("CredentialAudit")

/// What happened to a credential, as `CredentialAudit` records it.
enum CredentialAuditAction: String, Codable, CaseIterable, Sendable {
    /// The CLI's live credential read for use.
    case liveRead
    /// The CLI's live credential replaced.
    case liveWrite
    /// An account's saved copy read for use.
    case savedCopyRead
    /// An account's saved copy replaced in AccountDock's store.
    case savedCopyWrite
    /// An account's saved copy deleted.
    case savedCopyRemove
    /// The saved copies written through to the Keychain, one entry per
    /// account the write carried.
    case savedCopyPersist
    /// A session slot's credential written.
    case slotWrite
    /// A session slot deleted with its credential.
    case slotRemove
    /// A one-session slot recorded as serving an account.
    case slotAssign
    /// The live credential read to be saved as an account's copy.
    case capture
    /// A sign-in made outside the live credential, read or cleaned up.
    case isolatedLogin
    /// A credential renewed with its refresh token.
    case renewal
    /// The provider asked whose a credential is.
    case ownershipCheck
    /// The active account changed.
    case `switch`
    /// Running sessions told to read the live credential again.
    case signalSessions
    /// A request that starts an account's quota window.
    case warmup
    /// A usage read made to decide on a warm-up.
    case probe
    /// The account a session or agent was seen served by changed.
    case served
    /// A session's or agent's transcript shows its prompt cache rebuilt
    /// whole right after a warm read, which a change of account causes.
    case servedChange
    /// A running process's own evidence (its status line's or refusal's
    /// reset times) names the account whose token it holds; `accountID` is
    /// the account AccountDock believes it reads, `ownerAccountID` the one
    /// the evidence names.
    case processCredential
}

/// One line of the audit file. Holds no credential text: the access token
/// appears only as `fingerprint`, and nothing of a refresh token at all.
struct CredentialAuditEntry: Codable, Equatable, Sendable {
    /// ISO 8601 with milliseconds.
    var time: String
    var provider: String
    var action: CredentialAuditAction
    /// The account AccountDock attributes the credential or session to.
    var accountID: String?
    var accountLabel: String?
    /// First 12 hexadecimal digits of the SHA-256 of the access token.
    var fingerprint: String?
    /// The same for the credential this action replaced or renewed.
    var previousFingerprint: String?
    var subscriptionType: String?
    var rateLimitTier: String?
    /// Whose the credential is, as the provider or the token itself named
    /// it: the email obfuscated, and the account with that email.
    var ownerEmail: String?
    var ownerAccountID: String?
    var ownerLabel: String?
    /// True when this entry is the provider's answer itself; absent when
    /// the owner was filled in from an earlier answer for the fingerprint.
    var ownerVerified: Bool?
    /// The attributed account and the owner differ.
    var mismatch: Bool?
    var outcome: String
    /// The code path that acted.
    var reason: String
    var slot: String?
    var session: String?
    var process: Int32?
    /// For an agent's entry, the session it runs under; `session` is then
    /// the agent's own transcript name.
    var parentSession: String?
    var model: String?
    /// What decided `accountID` for a `served` entry (`SessionAttribution.Source`).
    var source: String?
    /// When the evidence was seen, when that is not `time`.
    var observedAt: String?
    /// For `servedChange`: the last warm request and the first cold one.
    var before: String?
    var after: String?
    var detail: String?
}

/// The append-only trail of every read for use, write, removal, renewal,
/// ownership answer and slot change of a provider credential, written as
/// JSON Lines to `fileURL` (owner-only, rotated at `maxBytes`, keeping
/// `keepRotated` earlier files). `KeychainService`, the providers'
/// services and credential modules, `SessionSlots` and `AppState` call
/// it; `AppState.handle` answers the `audit` request from `entries`, and
/// Settings opens the file.
///
/// It learns whose each access token is from the provider's answers
/// (ownership checks, isolated sign-ins, a token's own signed identity)
/// and keeps that map in `ownersURL`, so every later entry with a known
/// fingerprint names its real owner; an entry attributed to another
/// account is marked `mismatch`, and `onMismatch` is told once per token
/// and account when the entry reads, writes or spends the token.
final class CredentialAudit: @unchecked Sendable {
    /// One saved account as the audit names it, from `AppState.accounts`.
    struct Account: Equatable, Sendable {
        var id: UUID
        var provider: AIProviderType
        var label: String
        var email: String
        var isActive: Bool
        var location: String?
    }

    private struct Owner: Codable {
        var provider: String
        var email: String
        var accountID: String?
        var learnedAt: Date
    }

    /// One request of a session or agent, for `noteRequest`.
    struct CacheSample: Equatable, Sendable {
        var at: Date
        var contextTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var model: String?
    }

    static let shared = CredentialAudit(directory: defaultDirectory)

    /// True while XCTest hosts the app; read by `AppState` to leave the
    /// mismatch events uninstalled under tests.
    static var isTesting: Bool { AppLogs.isTesting }

    /// `AppLogs.directory`: `~/Library/Logs`, or the test run's own
    /// directory, so no test reaches the real trail.
    static var defaultDirectory: URL { AppLogs.directory }


    static let fileName = "AccountDock-credentials.jsonl"
    static let ownersFileName = "AccountDock-credentials-owners.json"
    static let defaultMaxBytes: UInt64 = 20 * 1024 * 1024
    /// A repeated read of the same token for the same caller and account is
    /// written again only after this long; every change of token is written.
    static let readRepeatInterval: TimeInterval = 15 * 60
    /// The fingerprints `ownersURL` keeps, newest first.
    static let maximumOwners = 5_000

    let fileURL: URL
    let ownersURL: URL
    let maxBytes: UInt64
    let keepRotated: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private var accounts: [Account] = []
    private var owners: [String: Owner] = [:]
    private var ownersLoaded = false
    private var lastReads: [String: (fingerprint: String?, at: Date)] = [:]
    private var lastServed: [String: UUID] = [:]
    private var lastSamples: [String: (sample: CacheSample, lifetime: TimeInterval)] = [:]
    private var lastSessionRequest: [String: Date] = [:]
    private var reportedMismatches: Set<String> = []
    private var mismatchHandler: (@Sendable (AIProviderType, String) -> Void)?
    private let formatter: ISO8601DateFormatter

    init(directory: URL, maxBytes: UInt64 = CredentialAudit.defaultMaxBytes, keepRotated: Int = 3) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.ownersURL = directory.appendingPathComponent(Self.ownersFileName)
        self.maxBytes = maxBytes
        self.keepRotated = keepRotated
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // MARK: - What the audit knows

    /// Replaces the accounts entries are attributed to and owners matched
    /// against. Called by `AppState` whenever its accounts change.
    func updateAccounts(_ accounts: [Account]) {
        lock.withLock { self.accounts = accounts }
    }

    /// The provider of a saved account, for a caller that knows only the
    /// account, such as `SessionSlots` serving a provider it does not name.
    func provider(ofAccount id: UUID) -> AIProviderType? {
        lock.withLock { accounts.first { $0.id == id }?.provider }
    }

    /// Called once for every new mismatch with the provider and a sentence
    /// for the user; `AppState` records it as an event.
    func onMismatch(_ handler: @escaping @Sendable (AIProviderType, String) -> Void) {
        lock.withLock { mismatchHandler = handler }
    }

    // MARK: - Fingerprints and token facts

    /// First 12 hexadecimal digits of the SHA-256 of an access token.
    static func fingerprint(ofAccessToken token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The access token in a credential as any provider stores it: Claude's
    /// `claudeAiOauth.accessToken`, Codex's `tokens.access_token`, Kimi's
    /// `access_token`; text that is not JSON is taken as the token itself.
    static func accessToken(in credential: String) -> String? {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let root = jsonObject(trimmed) else {
            return trimmed.first == "{" || trimmed.first == "[" ? nil : trimmed
        }
        if let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        if let tokens = root["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty {
            return token
        }
        for key in ["access_token", "accessToken"] {
            if let token = root[key] as? String, !token.isEmpty { return token }
        }
        return nil
    }

    /// The plan fields a credential names, which are not secret: Claude's
    /// `subscriptionType` and `rateLimitTier`, Codex's plan in its signed
    /// tokens.
    static func tierFields(in credential: String) -> (subscriptionType: String?, rateLimitTier: String?) {
        guard let root = jsonObject(credential) else { return (nil, nil) }
        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            return (oauth["subscriptionType"] as? String, oauth["rateLimitTier"] as? String)
        }
        if let tokens = root["tokens"] as? [String: Any] {
            let plan = [tokens["id_token"], tokens["access_token"]].compactMap { $0 as? String }.lazy
                .compactMap { jwtPayload($0)?["https://api.openai.com/auth"] as? [String: Any] }
                .compactMap { $0["chatgpt_plan_type"] as? String }.first
            return (plan, nil)
        }
        return (nil, nil)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Recording

    /// Appends one entry. The account is `account`, else the one whose
    /// saved copy is at `location`, else with `live` the provider's active
    /// account. `credential` or `accessToken` gives the fingerprint and
    /// plan fields; `owner` is an email the provider (or the token's own
    /// signed identity) named for that token, which is learned for the
    /// fingerprint. Repeated reads (`liveRead`, `savedCopyRead`) of the same
    /// token by the same caller are written once per `readRepeatInterval`.
    /// Returns the entry written, nil when none was.
    @discardableResult
    func record(_ action: CredentialAuditAction, _ provider: AIProviderType,
                account: UUID? = nil, location: String? = nil, live: Bool = false,
                credential: String? = nil, accessToken: String? = nil, previousCredential: String? = nil,
                previousAccessToken: String? = nil, outcome: String, reason: String, owner: String? = nil,
                slot: String? = nil, session: String? = nil, process: Int32? = nil,
                parentSession: String? = nil, model: String? = nil, source: String? = nil,
                observedAt: Date? = nil, before: Date? = nil, after: Date? = nil,
                detail: String? = nil, now: Date = Date()) -> CredentialAuditEntry? {
        let token = accessToken ?? credential.flatMap(Self.accessToken(in:))
        let fingerprint = token.map(Self.fingerprint(ofAccessToken:))
        let tiers = credential.map(Self.tierFields(in:)) ?? (nil, nil)
        let previous = (previousAccessToken ?? previousCredential.flatMap(Self.accessToken(in:)))
            .map(Self.fingerprint(ofAccessToken:))
        var notice: (AIProviderType, String)?
        let entry: CredentialAuditEntry? = lock.withLock {
            loadOwnersIfNeeded()
            let attributed = account.flatMap { id in accounts.first { $0.id == id } }
                ?? location.flatMap { self.account(atLocation: $0, provider: provider) }
                ?? (live ? accounts.first { $0.provider == provider && $0.isActive } : nil)
            let attributedID = account?.uuidString ?? attributed?.id.uuidString
            if action == .liveRead || action == .savedCopyRead {
                let key = "\(action.rawValue)|\(provider.rawValue)|\(reason)|\(attributedID ?? "")|\(outcome)"
                if let last = lastReads[key], last.fingerprint == fingerprint,
                   now.timeIntervalSince(last.at) < Self.readRepeatInterval { return nil }
                lastReads[key] = (fingerprint, now)
            }
            var entry = CredentialAuditEntry(
                time: formatter.string(from: now), provider: provider.rawValue, action: action,
                accountID: attributedID, accountLabel: attributed?.label,
                fingerprint: fingerprint, previousFingerprint: previous == fingerprint ? nil : previous,
                subscriptionType: tiers.0, rateLimitTier: tiers.1,
                outcome: outcome, reason: reason, slot: slot, session: session, process: process,
                parentSession: parentSession, model: model, source: source,
                observedAt: observedAt.map(formatter.string(from:)),
                before: before.map(formatter.string(from:)), after: after.map(formatter.string(from:)),
                detail: detail
            )
            if let owner, let fingerprint {
                learnOwner(owner, provider: provider, fingerprint: fingerprint, now: now)
                entry.ownerVerified = true
            }
            if let fingerprint, let known = owners[fingerprint] {
                entry.ownerEmail = known.email
                entry.ownerAccountID = known.accountID
                entry.ownerLabel = known.accountID.flatMap { id in accounts.first { $0.id.uuidString == id }?.label }
                if let attributedID, known.accountID != attributedID {
                    entry.mismatch = true
                    // An answer that discovers the owner is acted on by its
                    // caller, which refuses to save the token as the wrong
                    // account's; a token then read, written or spent as the
                    // wrong account's is what the event reports.
                    let discovers = action == .ownershipCheck || action == .capture || action == .isolatedLogin
                    if !discovers, reportedMismatches.insert("\(fingerprint)|\(attributedID)").inserted {
                        notice = (provider, Self.mismatchSentence(entry))
                    }
                }
            }
            append(entry)
            return entry
        }
        if let notice {
            auditLog.error(notice.1)
            let handler = lock.withLock { mismatchHandler }
            handler?(notice.0, notice.1)
        }
        return entry
    }

    /// The event a mismatch records, naming the action and the code path.
    static func mismatchSentence(_ entry: CredentialAuditEntry) -> String {
        let held: String = switch entry.action {
        case .liveWrite: "written to the live sign-in"
        case .liveRead: "read from the live sign-in"
        case .savedCopyWrite, .savedCopyPersist: "saved"
        case .savedCopyRead: "read as the saved copy"
        case .slotWrite: "written to a session slot"
        case .capture: "captured"
        case .renewal: "renewed"
        case .warmup, .probe: "used for a warm-up"
        default: "attributed"
        }
        let attributed = entry.accountLabel ?? entry.accountID ?? "an account"
        let owner = entry.ownerLabel ?? entry.ownerEmail ?? "another account"
        return "The credential \(held) as \(attributed)'s is \(owner)'s (\(entry.reason), token \(entry.fingerprint ?? "?"))."
    }

    /// Records a session's or agent's serving account when it differs from
    /// the last one recorded for it, so each change appears once. `agent`
    /// is a subagent's transcript name under `session`.
    @discardableResult
    func recordServed(_ provider: AIProviderType, session: String, agent: String? = nil, account: UUID,
                      source: String, model: String? = nil, process: Int32? = nil, observedAt: Date? = nil,
                      now: Date = Date()) -> CredentialAuditEntry? {
        let key = "\(provider.rawValue)|\(session)|\(agent ?? "")"
        let changed = lock.withLock { () -> Bool in
            guard lastServed[key] != account else { return false }
            lastServed[key] = account
            return true
        }
        guard changed else { return nil }
        return record(.served, provider, account: account, outcome: "ok", reason: "sessionAttribution",
                      session: agent ?? session, process: process, parentSession: agent == nil ? nil : session,
                      model: model, source: source, observedAt: observedAt, now: now)
    }

    /// Records what a running process's own evidence (`source`, such as its
    /// status line's reset times) says about the token it holds: the
    /// account `observed`, against `believed`, the account AccountDock
    /// believes it reads (`believedSource`: its slot or the live
    /// credential). Written when the observed account for the session
    /// changes; a difference is marked `mismatch` and reported through
    /// `onMismatch` once per session and account. Returns the entry when
    /// it is a new mismatch, which the caller offers to signal.
    @discardableResult
    func recordProcessCredential(_ provider: AIProviderType, session: String, process: Int32?, observed: UUID,
                                 believed: UUID?, source: String, believedSource: String, observedAt: Date?,
                                 detail: String? = nil, now: Date = Date()) -> CredentialAuditEntry? {
        let key = "process|\(provider.rawValue)|\(session)"
        var notice: String?
        let entry: CredentialAuditEntry? = lock.withLock {
            guard lastServed[key] != observed else { return nil }
            lastServed[key] = observed
            loadOwnersIfNeeded()
            let believedAccount = believed.flatMap { id in accounts.first { $0.id == id } }
            let observedAccount = accounts.first { $0.id == observed }
            let newest = owners.filter { $0.value.accountID == observed.uuidString }
                .max { $0.value.learnedAt < $1.value.learnedAt }?.key
            var parts = ["AccountDock believes it reads \(believedAccount?.label ?? believed?.uuidString ?? "no account")'s (\(believedSource))."]
            if let newest { parts.append("The newest token known for \(observedAccount?.label ?? observed.uuidString) is \(newest).") }
            if let detail { parts.append(detail) }
            var entry = CredentialAuditEntry(
                time: formatter.string(from: now), provider: provider.rawValue, action: .processCredential,
                accountID: believed?.uuidString, accountLabel: believedAccount?.label,
                ownerEmail: observedAccount?.email.obfuscatedEmail(), ownerAccountID: observed.uuidString,
                ownerLabel: observedAccount?.label,
                outcome: believed == observed ? "asBelieved" : "differs", reason: "processEvidence",
                session: session, process: process, source: source,
                observedAt: observedAt.map(formatter.string(from:)), detail: parts.joined(separator: " ")
            )
            if believed != observed {
                entry.mismatch = true
                if reportedMismatches.insert("process|\(session)|\(observed.uuidString)").inserted {
                    let who = process.map { "Session \(session.prefix(8)) (process \($0))" } ?? "Session \(session.prefix(8))"
                    notice = "\(who) is using \(observedAccount?.label ?? "another account")'s sign-in by its \(source), "
                        + "while AccountDock believes it reads \(believedAccount?.label ?? "no account")'s (\(believedSource)). "
                        + "Tell it to read its sign-in again under Settings → Audit, or with the request {\"action\":\"signalSessions\"}."
                }
            }
            append(entry)
            return entry
        }
        guard let notice else { return nil }
        auditLog.error(notice)
        let handler = lock.withLock { mismatchHandler }
        handler?(provider, notice)
        return entry
    }

    /// Whether `current` shows a session's prompt cache rebuilt by a change
    /// of account rather than by its expiry: `previous` read a warm cache
    /// (at least half its context), `current` reads almost none (5% or
    /// less) while writing at least 80% of its context, within the cache
    /// lifetime `previous` left, on the same model, and without the
    /// context shrinking by half as a compaction does. Small contexts say
    /// nothing either way.
    static func isAccountChange(previous: CacheSample, current: CacheSample, cacheLifetime: TimeInterval) -> Bool {
        let minimum = 2_000
        guard previous.contextTokens >= minimum, current.contextTokens >= minimum,
              current.at > previous.at, current.at.timeIntervalSince(previous.at) < cacheLifetime,
              current.contextTokens * 2 >= previous.contextTokens else { return false }
        if let before = previous.model, let after = current.model, before != after { return false }
        let warm = Double(previous.cacheReadTokens) >= 0.5 * Double(previous.contextTokens)
        let cold = Double(current.cacheReadTokens) <= 0.05 * Double(current.contextTokens)
        let rebuilt = Double(current.cacheWriteTokens) >= 0.8 * Double(current.contextTokens)
        return warm && cold && rebuilt
    }

    /// One request a session or agent made, from its transcript: records
    /// `served` when its attributed account changed, and `servedChange`
    /// when the request's cache shows a change of account
    /// (`isAccountChange`) whatever the attribution says. `cacheLifetime`
    /// is the lifetime the request's own cache write set, nil when it wrote
    /// none. Requests must arrive in time order per session.
    @discardableResult
    func noteRequest(_ provider: AIProviderType, session: String, agent: String?, account: UUID?, source: String?,
                     sample: CacheSample, cacheLifetime: TimeInterval?, now: Date = Date()) -> Bool {
        if let account {
            recordServed(provider, session: session, agent: agent, account: account, source: source ?? "unknown",
                         model: sample.model, observedAt: sample.at, now: now)
        }
        let key = "\(provider.rawValue)|\(session)|\(agent ?? "")"
        let parentKey = "\(provider.rawValue)|\(session)"
        let found = lock.withLock { () -> (previous: CacheSample, parentLast: Date?)? in
            let last = lastSamples[key]
            let lifetime = cacheLifetime ?? last?.lifetime ?? 300
            lastSamples[key] = (sample, lifetime)
            if agent == nil { lastSessionRequest[parentKey] = sample.at }
            guard let last, Self.isAccountChange(previous: last.sample, current: sample, cacheLifetime: last.lifetime) else {
                return nil
            }
            return (last.sample, agent == nil ? nil : lastSessionRequest[parentKey])
        }
        guard let found else { return false }
        let gap = Int(sample.at.timeIntervalSince(found.previous.at).rounded())
        var detail = "Cache read fell from \(found.previous.cacheReadTokens) to \(sample.cacheReadTokens) tokens"
            + " with \(sample.cacheWriteTokens) of \(sample.contextTokens) written, \(gap)s after a warm read."
        if agent != nil {
            if let parent = found.parentLast, parent > found.previous.at {
                detail += " Its parent session made a request at \(formatter.string(from: parent))."
            } else {
                detail += " Its parent session made no request between them."
            }
        }
        record(.servedChange, provider, account: account, outcome: "detected", reason: "transcriptCache",
               session: agent ?? session, parentSession: agent == nil ? nil : session, model: sample.model,
               source: source, observedAt: sample.at, before: found.previous.at, after: sample.at,
               detail: detail, now: now)
        return true
    }

    // MARK: - Owners

    private func account(atLocation location: String, provider: AIProviderType) -> Account? {
        let path = URL(fileURLWithPath: location).standardizedFileURL.path
        return accounts.first { account in
            guard account.provider == provider, let held = account.location else { return false }
            let own = URL(fileURLWithPath: held).standardizedFileURL.path
            return own == path || own + "/auth.json" == path
        }
    }

    /// Called with `lock` held.
    private func learnOwner(_ email: String, provider: AIProviderType, fingerprint: String, now: Date) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = accounts.first { $0.provider == provider && $0.email.caseInsensitiveCompare(trimmed) == .orderedSame }
        let owner = Owner(provider: provider.rawValue, email: trimmed.obfuscatedEmail(),
                          accountID: match?.id.uuidString, learnedAt: now)
        let previous = owners[fingerprint]
        owners[fingerprint] = owner
        guard previous?.accountID != owner.accountID || previous?.email != owner.email else { return }
        if owners.count > Self.maximumOwners {
            let kept = owners.sorted { $0.value.learnedAt > $1.value.learnedAt }.prefix(Self.maximumOwners)
            owners = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        saveOwners()
    }

    /// The owner learned for a fingerprint: the account's ID when it is a
    /// saved account, and the obfuscated email.
    func owner(ofFingerprint fingerprint: String) -> (accountID: String?, email: String)? {
        lock.withLock {
            loadOwnersIfNeeded()
            return owners[fingerprint].map { ($0.accountID, $0.email) }
        }
    }

    private func loadOwnersIfNeeded() {
        guard !ownersLoaded else { return }
        ownersLoaded = true
        guard let data = FileManager.default.contents(atPath: ownersURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        owners = (try? decoder.decode([String: Owner].self, from: data)) ?? [:]
    }

    private func saveOwners() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(owners) else { return }
        do {
            try FileManager.default.createDirectory(at: ownersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFile.writeAtomically(data, to: ownersURL, mode: 0o600)
        } catch {
            auditLog.error("Owner map not written: \(error.localizedDescription)")
        }
    }

    // MARK: - File

    /// Called with `lock` held.
    private func append(_ entry: CredentialAuditEntry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        if handle == nil { openFile() }
        if size > 0, size + UInt64(line.count) > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            size += UInt64(line.count)
        } catch {
            auditLog.error("Entry not written: \(error.localizedDescription)")
        }
    }

    /// Opens the file for appending, created owner-only; an existing file is
    /// narrowed to owner-only too.
    private func openFile() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            auditLog.error("Audit file not opened: errno \(errno)")
            return
        }
        fchmod(descriptor, 0o600)
        var info = stat()
        size = fstat(descriptor, &info) == 0 ? UInt64(info.st_size) : 0
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// `.N-1` → `.N` down to the file itself → `.1`, dropping the oldest.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL(keepRotated))
        if keepRotated > 1 {
            for index in stride(from: keepRotated - 1, through: 1, by: -1) where fm.fileExists(atPath: rotatedURL(index).path) {
                try? fm.moveItem(at: rotatedURL(index), to: rotatedURL(index + 1))
            }
        }
        if keepRotated > 0 { try? fm.moveItem(at: fileURL, to: rotatedURL(1)) } else { try? fm.removeItem(at: fileURL) }
        openFile()
    }

    func rotatedURL(_ index: Int) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).\(index)")
    }

    // MARK: - Query

    /// Entries from the oldest rotated file to the newest line, observed or
    /// written at or after `since`, about `account` (an account's ID,
    /// label or email, matched as the attributed account or the owner),
    /// the newest `limit`.
    func entries(since: Date? = nil, account query: String? = nil, limit: Int? = nil) -> [CredentialAuditEntry] {
        let (files, ids): ([URL], Set<String>) = lock.withLock {
            let files = (stride(from: keepRotated, through: 1, by: -1).map(rotatedURL) + [fileURL])
            guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return (files, []) }
            let matching = accounts.filter {
                $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame
                    || $0.label.caseInsensitiveCompare(query) == .orderedSame
                    || $0.email.caseInsensitiveCompare(query) == .orderedSame
            }
            return (files, Set(matching.map(\.id.uuidString)))
        }
        let decoder = JSONDecoder()
        var found: [CredentialAuditEntry] = []
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(CredentialAuditEntry.self, from: Data(line)) else { continue }
                if let since {
                    let stamp = entry.observedAt ?? entry.time
                    guard let at = formatter.date(from: stamp), at >= since else { continue }
                }
                if let query, !query.isEmpty {
                    let named = [entry.accountID, entry.ownerAccountID].compactMap { $0 }
                    let labels = [entry.accountLabel, entry.ownerLabel].compactMap { $0?.lowercased() }
                    guard named.contains(where: { ids.contains($0) || $0.lowercased() == query })
                            || labels.contains(where: { $0.contains(query) }) else { continue }
                }
                found.append(entry)
            }
        }
        if let limit, found.count > limit { found = Array(found.suffix(limit)) }
        return found
    }

    /// Parses an ISO 8601 time with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
