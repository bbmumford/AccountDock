import Foundation
import Security

private let log = FileLog("Keychain")

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]
    /// The credential this backup replaced, kept so one bad capture cannot
    /// destroy the only working copy.
    var previousToken: String? = nil

    /// Whether a credential is complete: JSON with an access token and a
    /// refresh token. Claude Code can store a credential cut off at the
    /// `security -i` line limit; such a value must never replace a backup.
    static func isCompleteCredential(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { return false }
        return true
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

/// Manages token + identity storage:
/// - Claude CLI's token: read/write via `security` CLI (keychain).
/// - Claude CLI's identity: read/write oauthAccount in ~/.claude.json.
/// - Saved accounts: per-account {token, oauthAccount} in `security` items (see `accountStore`).
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let backupsFilePath: String
    private let legacyBackupsFilePath: String
    private let identityFile: ClaudeIdentityFile

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.accountdock"
        self.backupsFilePath = dir + "/backups.json"
        self.legacyBackupsFilePath = home + "/.ccswitcher/backups.json"
        self.identityFile = ClaudeIdentityFile(url: URL(fileURLWithPath: home + "/.claude.json"))

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Migrate old tokens.json → backups.json if needed
        let oldPath = dir + "/tokens.json"
        if FileManager.default.fileExists(atPath: oldPath) && !FileManager.default.fileExists(atPath: backupsFilePath) {
            log.info("init: Migrating tokens.json → backups.json (old format, token-only entries)")
            // Old format was {accountId: tokenString}. We can't migrate without oauthAccount,
            // so just delete the stale file — user will need to re-capture.
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (keychain via `security` CLI)

    /// The CLI's live credential item, through the same `security` wrapper
    /// as the saved accounts.
    private var claudeSlot: SecurityToolKeychain { SecurityToolKeychain(service: claudeService) }

    func readClaudeToken() -> String? {
        guard let token = claudeSlot.read(account: claudeAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            log.error("[readClaudeToken] No token found!")
            return nil
        }
        log.info("[readClaudeToken] Found via security CLI, length=\(token.count)")
        return token
    }

    /// Replaces the credential in place with `-U`, so Claude Code sessions
    /// never observe a moment without one, and confirms the write by reading
    /// it back. The value travels on the standard input of `security -i`
    /// only: a credential too long for it is refused, never passed as a
    /// process argument, which every process on the Mac can read.
    func writeClaudeToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = claudeSlot.apply(writes: [(account: claudeAccount, value: value)])
        log.info("[writeClaudeToken] Result: \(written)")
        return written
    }

    // MARK: - ~/.claude.json oauthAccount Operations

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let dict = identityFile.readOAuthAccount() else {
            log.error("[readOAuthAccount] Failed to read oauthAccount from \(identityFile.url.path)")
            return nil
        }
        let email = (dict["emailAddress"]?.value as? String) ?? "?"
        log.info("[readOAuthAccount] Found: email=\(email)")
        return dict
    }

    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
        do {
            try identityFile.writeOAuthAccount(oauthAccount)
            let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[writeOAuthAccount] Written: email=\(email)")
            return true
        } catch {
            log.error("[writeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Backup Operations (token + oauthAccount)

    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        guard AccountBackup.isCompleteCredential(token) else {
            log.error("[saveBackup] Refusing to save an incomplete credential for \(accountId) (\(email)), length=\(token.count)")
            return false
        }
        log.info("[saveBackup] Saving for \(accountId) (\(email)), token length=\(token.count)")
        let result = updateBackupStore { store in
            let existing = store[accountId]
            let previous = existing.map { $0.token == token ? $0.previousToken : $0.token } ?? nil
            store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount, previousToken: previous)
        }
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        guard let store = loadBackupStore() else { return nil }
        let backup = store[accountId]
        if let backup {
            let email = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[getBackup] Found for \(accountId) (\(email)), token length=\(backup.token.count)")
        } else {
            log.error("[getBackup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        return updateBackupStore { $0.removeValue(forKey: accountId) }
    }

    // Legacy compatibility — read token string only (for diagnostics)
    func getAccountToken(forAccountId accountId: String) -> String? {
        return getAccountBackup(forAccountId: accountId)?.token
    }

    // MARK: - App Keychain operations (Backups)

    // The earlier single-item stores, read only to move their entries into
    // `accountStore`.
    private let appBackupService = "app.accountdock.backups"
    private let legacyBackupService = "me.xueshi.ccswitcher.backups"
    private let appBackupAccount = "all-accounts"

    // The saved accounts are read from the Keychain once and kept in memory;
    // writes update memory and are written back on `storeQueue`. A Keychain
    // access prompt (shown when the earlier SecItem store is moved) holds a
    // read until the user answers it, and `security` runs as a process, so no Keychain call
    // for the saved accounts runs on the caller's thread: the failover cycle
    // on the main actor keeps running while a prompt waits.
    private let storeLock = NSLock()
    private nonisolated(unsafe) var cachedStore: [String: AccountBackup]?
    private nonisolated(unsafe) var storeLoadStarted = false
    private let storeQueue = DispatchQueue(label: "app.accountdock.keychain.backups")

    /// Whether the saved accounts have been read. Until then they cannot be
    /// used or changed.
    var backupStoreAvailable: Bool { storeLock.withLock { cachedStore != nil } }

    /// Starts reading the saved accounts in the background.
    func preloadBackupStore() {
        let start = storeLock.withLock { () -> Bool in
            guard cachedStore == nil, !storeLoadStarted else { return false }
            storeLoadStarted = true
            return true
        }
        guard start else { return }
        storeQueue.async {
            let store = self.readBackupStoreFromKeychain()
            self.storeLock.withLock { self.cachedStore = store }
        }
    }

    /// The saved accounts, or nil while they have not been read yet.
    private func loadBackupStore() -> [String: AccountBackup]? {
        if let store = storeLock.withLock({ cachedStore }) { return store }
        preloadBackupStore()
        log.warning("[loadBackupStore] Saved accounts not read yet; a Keychain access prompt may be waiting")
        return nil
    }

    /// Changes the saved accounts in memory and writes them back. Refused
    /// while they have not been read, because writing then would replace
    /// every saved account with only this change.
    private func updateBackupStore(_ change: (inout [String: AccountBackup]) -> Void) -> Bool {
        let updated = storeLock.withLock { () -> Bool in
            guard var store = cachedStore else { return false }
            change(&store)
            cachedStore = store
            return true
        }
        guard updated else {
            log.error("[updateBackupStore] Saved accounts not read yet; change refused")
            return false
        }
        storeQueue.async {
            guard let current = self.storeLock.withLock({ self.cachedStore }) else { return }
            _ = self.writeBackupStoreToKeychain(current)
        }
        return true
    }

    private func readBackupStoreFromKeychain() -> [String: AccountBackup] {
        if let store = readAccountStore() {
            log.debug("[loadBackupStore] Loaded \(store.count) entries from the security-tool items")
            writtenStore = store
            return store
        }

        // The saved accounts were kept in one item written through SecItem,
        // tied to the app's signature: reading it asks for the login
        // password this one last time, then they live in `accountStore`.
        let earlier = readBackupStore(service: appBackupService).map { ("AccountDock Keychain item", $0) }
            ?? readBackupStore(service: legacyBackupService).map { ("upstream Keychain item", $0) }
        if let (source, store) = earlier {
            log.info("[loadBackupStore] Moving \(store.count) entries from the \(source) to the security-tool items")
            if writeBackupStoreToKeychain(store) {
                log.info("[loadBackupStore] Move complete")
            } else {
                log.error("[loadBackupStore] Move failed; the entries stay in memory and are written again on the next change")
            }
            return store
        }

        // Migration from local file
        if FileManager.default.fileExists(atPath: backupsFilePath),
           let data = FileManager.default.contents(atPath: backupsFilePath),
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.info("[loadBackupStore] Migrating from local backups.json to Keychain...")
            if writeBackupStoreToKeychain(dict) {
                try? FileManager.default.removeItem(atPath: backupsFilePath)
                log.info("[loadBackupStore] Migration complete, local backups.json removed")
            }
            return dict
        }

        if FileManager.default.fileExists(atPath: legacyBackupsFilePath),
           let data = FileManager.default.contents(atPath: legacyBackupsFilePath),
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.info("[loadBackupStore] Importing upstream file backups into AccountDock Keychain...")
            _ = writeBackupStoreToKeychain(dict)
            return dict
        }

        log.debug("[loadBackupStore] No existing backups, returning empty")
        return [:]
    }

    /// Reads the earlier single-item store written through SecItem. Used only
    /// to move its entries into `accountStore`.
    private func readBackupStore(service: String) -> [String: AccountBackup]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: appBackupAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data,
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            return dict
        }
        return nil
    }

    // MARK: - Saved accounts in security-tool items

    // One item per account, account name = the account ID, holding the
    // credential and identity; a second item, `<id>.previous`, holds the
    // replaced credential; `index` lists the IDs. Split this way because a
    // single account with both credentials comes close to the `security -i`
    // line limit.
    private let accountStore = SecurityToolKeychain(service: "app.accountdock.accounts")
    private static let indexAccount = "index"
    private static let previousSuffix = ".previous"

    /// What is in `accountStore`, as last written or read. Touched only on
    /// `storeQueue`, where every read and write of the saved accounts runs,
    /// so a write sends only the accounts that changed.
    private nonisolated(unsafe) var writtenStore: [String: AccountBackup] = [:]

    private struct StoredEntry: Codable {
        let token: String
        let oauthAccount: [String: AnyCodable]
    }

    private struct StoredPrevious: Codable {
        let previousToken: String
    }

    private func readAccountStore() -> [String: AccountBackup]? {
        guard let indexText = accountStore.read(account: Self.indexAccount),
              let ids = try? JSONDecoder().decode([String].self, from: Data(indexText.utf8)) else { return nil }
        var store: [String: AccountBackup] = [:]
        for id in ids {
            guard let text = accountStore.read(account: id),
                  let entry = try? JSONDecoder().decode(StoredEntry.self, from: Data(text.utf8)) else {
                log.error("[readAccountStore] Listed account \(id) has no readable item")
                continue
            }
            let previous = accountStore.read(account: id + Self.previousSuffix)
                .flatMap { try? JSONDecoder().decode(StoredPrevious.self, from: Data($0.utf8)) }?.previousToken
            store[id] = AccountBackup(token: entry.token, oauthAccount: entry.oauthAccount, previousToken: previous)
        }
        return store
    }

    /// Writes the accounts that differ from `writtenStore` and deletes the
    /// ones no longer saved. On failure `writtenStore` is left unchanged, so
    /// the next write sends them again.
    private func writeBackupStoreToKeychain(_ store: [String: AccountBackup]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) -> String? {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        var writes: [(account: String, value: String)] = []
        var deletes: [String] = []
        for (id, backup) in store {
            let old = writtenStore[id]
            if old?.token != backup.token || old?.oauthAccount != backup.oauthAccount {
                guard let text = json(StoredEntry(token: backup.token, oauthAccount: backup.oauthAccount)) else { return false }
                writes.append((id, text))
            }
            if old?.previousToken != backup.previousToken {
                if let previous = backup.previousToken {
                    guard let text = json(StoredPrevious(previousToken: previous)) else { return false }
                    writes.append((id + Self.previousSuffix, text))
                } else if old?.previousToken != nil {
                    deletes.append(id + Self.previousSuffix)
                }
            }
        }
        for (id, old) in writtenStore where store[id] == nil {
            deletes.append(id)
            if old.previousToken != nil { deletes.append(id + Self.previousSuffix) }
        }
        let ids = store.keys.sorted()
        if ids != writtenStore.keys.sorted() || accountStore.read(account: Self.indexAccount) == nil {
            guard let text = json(ids) else { return false }
            writes.append((Self.indexAccount, text))
        }
        let success = accountStore.apply(writes: writes, deletes: deletes)
        if success {
            writtenStore = store
            log.debug("[saveBackupStore] Saved \(store.count) entries (\(writes.count) items written, \(deletes.count) deleted)")
        } else {
            log.error("[saveBackupStore] Failed to save \(store.count) entries")
        }
        return success
    }
}
