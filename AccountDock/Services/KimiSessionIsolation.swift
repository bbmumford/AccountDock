import CryptoKit
import Foundation

private let log = FileLog("KimiSessionIsolation")

/// Kimi Code's slots. Every slot runs in Kimi Code's own home, so all its
/// sessions share their history, settings and hooks; only the credential
/// file differs. With `KIMI_CODE_BASE_URL` or `KIMI_CODE_OAUTH_HOST` set,
/// Kimi Code reads the credential named after a hash of the two values,
/// `credentials/kimi-code-env-<16 hex>.json`, instead of the one
/// `config.toml` names (`credentialName(oauthHost:baseURL:)`). A slot is
/// therefore a pair of values: the real OAuth host, and the real API base
/// URL spelt with some host letters in upper case (`spelling(of:number:)`),
/// which names a credential of its own while every request still reaches
/// the same server; Kimi Code sends its model requests to `config.toml`'s
/// `base_url` whatever the variable says. The slot directory holds only
/// that pair (`baseURLFile`, `oauthHostFile`) and the shared slot
/// bookkeeping; the credential lives in Kimi Code's home.
///
/// A slot's credential holds one account's access token with its real
/// expiry and an empty refresh token (`slotCredential`). With an empty
/// refresh token Kimi Code never renews it: at its renewal threshold it
/// refuses that request before any network call and leaves the file as it
/// is, so it never presents a refresh token AccountDock owns and never
/// writes its revoked placeholder. AccountDock therefore writes a renewed
/// access token into every slot serving the account before the threshold
/// (`minimumLifetime(expiresIn:)`). Kimi Code reads the credential file
/// again before every model request, so a slot rewritten for another
/// account moves its session at the next request and `signalReread` has
/// nothing to do.
///
/// A Kimi Code session that finds the server's model list changed writes
/// its provider entry back into `config.toml` with the base URL and
/// credential name it runs on; `restoreSharedState` puts Kimi Code's own
/// spelling back, so sessions outside slots keep their own credential.
struct KimiSessionIsolation: ProviderSessionIsolation {
    let executable = "kimi"
    /// Names the slot directory in a session's environment. Kimi Code does
    /// not read it; `SessionSlots.directoriesByProcess` finds the slot by it.
    let directoryVariable = "ACCOUNTDOCK_KIMI_SLOT"
    /// The variables `launcherExportLines` sets from the slot's files, which
    /// make Kimi Code read the slot's credential.
    static let baseURLVariable = "KIMI_CODE_BASE_URL"
    static let oauthHostVariable = "KIMI_CODE_OAUTH_HOST"
    /// The credential a running session reads is named by the spelling
    /// its launch exported, which only the removed directory recorded;
    /// `prepareSlot` would give a new directory another spelling.
    let restoresRemovedSlot = false
    /// `KIMI_CODE_HOME` names another home; `KIMI_MODEL_NAME` defines a
    /// model with its own API key; the base URL and OAuth host overrides
    /// already choose a credential, as they do in a slot's own session, so
    /// a launch from inside one stays on that slot.
    let passThroughVariables = ["KIMI_CODE_HOME", "KIMI_MODEL_NAME", "KIMI_CODE_BASE_URL",
                                "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
    /// Sign-in and sign-out, the commands that manage providers, the
    /// installation and its configuration, and those that read or write the
    /// session history; none starts a session that sends model requests.
    let passThroughCommands = ["login", "logout", "provider", "doctor", "migrate", "upgrade", "update",
                               "install-desktop", "app", "session", "import-sessions", "export", "fork", "vis"]
    let background: BackgroundSessionSupport? = nil
    /// Kimi Code's own installer puts it here.
    let installDirectories = [".kimi-code/bin"]
    var preferredExecutable: String? { nil }

    /// Kimi Code's home: its `config.toml`, and every slot's credential.
    let home: URL
    /// How long `writeCredential` waits for a lock Kimi Code keeps fresh.
    let lockWait: TimeInterval

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true),
         lockWait: TimeInterval = 10) {
        self.home = home
        self.lockWait = lockWait
    }

    var resumeArgumentScript: String {
        SessionSlots.resumeArgumentScript(options: ["-S", "--session"], inlineOptions: ["--session"])
    }

    func resumeCommand(sessionID: String) -> String {
        "\(executable) -S \(SessionSlots.shellQuoted(sessionID))"
    }

    // MARK: - Screen

    /// Lines at the bottom of the screen read for Kimi Code's footer; the
    /// transcript above it may quote the badge.
    static let footerLines = 8

    /// Kimi Code's footer shows a badge for each kind of background work
    /// still running, `[1 task running]` for commands and `[2 agents running]`
    /// for subagents, and none when the count is zero.
    func screenReportsRunningWork(_ screen: String) -> Bool {
        let lines = screen.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.suffix(Self.footerLines)
        return lines.contains { line in
            line.range(of: #"\[[1-9][0-9]* (task|tasks|agent|agents) running\]"#, options: .regularExpression) != nil
        }
    }

    /// Kimi Code exits without asking about running work.
    func screenAsksAboutRunningWork(_ screen: String) -> Bool { false }

    /// Escape cancels Kimi Code's choice pickers; `screenAsksAboutRunningWork`
    /// never asks for it.
    let keepRunningKey = "\u{1B}"

    // MARK: - Renewal threshold

    /// Kimi Code renews its access token once less than
    /// `max(300, expires_in × 0.5)` seconds of it remain; in a slot that
    /// renewal fails the request instead.
    static let minimumRenewalThreshold: TimeInterval = 300
    static let renewalThresholdRatio = 0.5
    /// Time a slot's token must still last beyond Kimi Code's threshold when
    /// AccountDock serves it: the next maintenance pass, which runs every
    /// quota cycle (at most a minute apart while slots are in use) and may
    /// be skipped while credential work or a sign-in is under way, must find
    /// it still above the threshold and replace it.
    static let rewriteMargin: TimeInterval = 3 * 60

    static func renewalThreshold(expiresIn: TimeInterval?) -> TimeInterval {
        max(minimumRenewalThreshold, (expiresIn ?? 0) * renewalThresholdRatio)
    }

    /// How long a token served to a slot must still last.
    static func minimumLifetime(expiresIn: TimeInterval?) -> TimeInterval {
        renewalThreshold(expiresIn: expiresIn) + rewriteMargin
    }

    // MARK: - Credential

    /// `credential`, Kimi Code's credential JSON as AccountDock stores it,
    /// with its access token, expiry, scope and type and an empty refresh
    /// token, keys sorted and times in whole seconds as Kimi Code writes
    /// them, so `readCredential` returns it unchanged. Nil without an access
    /// token or a real expiry: an expiry of 0 would tell Kimi Code the token
    /// never needs renewing.
    func slotCredential(from credential: String) -> SlotCredential? {
        guard let data = credential.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let expiresAt = (object["expires_at"] as? NSNumber)?.doubleValue, expiresAt > 0 else { return nil }
        var slot: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": "",
            "expires_at": Int(expiresAt.rounded(.down)),
        ]
        if let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue { slot["expires_in"] = Int(expiresIn.rounded(.down)) }
        if let scope = object["scope"] as? String { slot["scope"] = scope }
        if let tokenType = object["token_type"] as? String { slot["token_type"] = tokenType }
        guard let encoded = try? JSONSerialization.data(withJSONObject: slot, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return SlotCredential(contents: String(decoding: encoded, as: UTF8.self))
    }

    /// The account's access token as `KimiService.slotSourceCredential`
    /// reads it, renewed first when it lasts less than
    /// `minimumLifetime(expiresIn:)`. `minimumLifetime`, which the slot code
    /// sizes for credentials that last hours, is not used: a Kimi access
    /// token may last less than that in all, and a slot needs it only to
    /// outlast Kimi Code's threshold until the next pass rewrites it.
    ///
    /// An inactive account's managed copy is renewed by
    /// `AppState.renewSavedCredential`, as for every other renewal. The
    /// account whose credential Kimi Code's home holds is renewed by
    /// `KimiService.renewLiveCredentialForSlots` under Kimi Code's lock,
    /// since unslotted sessions renew that credential themselves. Both run
    /// in `AppState.credentialGate` and in `KimiService`'s renewal queue, so
    /// one refresh token is presented once. The pass that called this
    /// writes the renewed token to every slot it serves. A token at or
    /// within Kimi Code's threshold is not served: Kimi Code would refuse
    /// every request on it.
    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? {
        guard let location = account.credentialLocation else { return nil }
        let service = state.kimiService
        let isActive = state.readsLiveCredential(account)
        guard let stored = service.slotSourceCredential(location: location, isActive: isActive) else { return nil }
        let required = Self.minimumLifetime(expiresIn: Self.expiresIn(of: stored))
        var current = stored
        if !Self.lasts(stored, for: required) {
            await state.credentialGate.run {
                if isActive {
                    switch await service.renewLiveCredentialForSlots(location: location, lasting: required,
                                                                       reason: "currentSlotCredential.live") {
                    case .renewed: state.clearNeedsSignIn(account)
                    case .rejected: state.noteCredentialRejected(account)
                    case .unavailable: break
                    }
                } else {
                    _ = await state.renewSavedCredential(account, reason: "currentSlotCredential.saved")
                }
            }
            guard let renewed = service.slotSourceCredential(location: location, isActive: isActive) else { return nil }
            current = renewed
        }
        guard Self.lasts(current, for: Self.renewalThreshold(expiresIn: Self.expiresIn(of: current))) else {
            log.warning("No access token of \(state.messageName(account)) outlasts Kimi Code's renewal threshold")
            return nil
        }
        return slotCredential(from: current)
    }

    /// Whether the credential JSON's access token is valid `interval` from
    /// now.
    static func lasts(_ credential: String, for interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt = number("expires_at", in: credential) else { return false }
        return Date(timeIntervalSince1970: expiresAt) > now.addingTimeInterval(interval)
    }

    static func expiresIn(of credential: String) -> TimeInterval? {
        number("expires_in", in: credential)
    }

    private static func number(_ key: String, in credential: String) -> Double? {
        guard let data = credential.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object[key] as? NSNumber)?.doubleValue
    }

    // MARK: - Slot

    /// Files in a slot directory holding the values its sessions run with:
    /// `KIMI_CODE_BASE_URL` and `KIMI_CODE_OAUTH_HOST`.
    static let baseURLFile = "base-url"
    static let oauthHostFile = "oauth-host"

    /// The table of `config.toml` holding the managed provider's `base_url`.
    static let providerTable = #"providers."managed:kimi-code""#
    /// Kimi Code's OAuth host when `config.toml` names none.
    static let defaultOAuthHost = "https://auth.kimi.com"
    /// The OAuth host and API base URL pair that keeps Kimi Code's
    /// unscoped credential name `kimi-code`.
    static let sharedDefaultBaseURL = "https://api.kimi.com/coding/v1"
    /// Prefix of every credential name Kimi Code derives from the two
    /// values; the only names a slot's removal deletes.
    static let scopedNamePrefix = "kimi-code-env-"
    /// API base URL of each region's OAuth host, for a `config.toml` whose
    /// `base_url` names no Kimi host, as while AccountDock's request hold
    /// points it at the local router.
    static let regionBaseURLs = ["https://auth.kimi.ai": "https://api.kimi.ai/coding/v1",
                                 "https://auth.kimi.com": "https://api.kimi.com/coding/v1"]

    var configFile: URL { home.appendingPathComponent("config.toml") }

    /// The credential name Kimi Code reads for `oauthHost` and `baseURL`,
    /// as it derives it: both trimmed of trailing slashes (the host of
    /// surrounding white space too), then the first 16 hex digits of the
    /// SHA-256 of `JSON.stringify({ oauthHost, baseUrl })`; the default
    /// host with the shared default base URL keeps `kimi-code`.
    static func credentialName(oauthHost: String, baseURL: String) -> String {
        let host = trimmingTrailingSlashes(oauthHost.trimmingCharacters(in: .whitespacesAndNewlines))
        let base = trimmingTrailingSlashes(baseURL)
        if host == defaultOAuthHost, base == sharedDefaultBaseURL { return "kimi-code" }
        let json = #"{"oauthHost":"# + jsonString(host) + #","baseUrl":"# + jsonString(base) + "}"
        let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        return scopedNamePrefix + digest.prefix(16)
    }

    private static func trimmingTrailingSlashes(_ value: String) -> String {
        var value = Substring(value)
        while value.hasSuffix("/") { value = value.dropLast() }
        return String(value)
    }

    /// A string as JavaScript's `JSON.stringify` writes it.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The range of the host in an `http(s)://host[:port]/path` URL.
    private static func hostRange(in url: String) -> Range<String.Index>? {
        guard let scheme = url.range(of: "://") else { return nil }
        let rest = url[scheme.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" }) ?? url.endIndex
        return scheme.upperBound..<end
    }

    /// `url` with its host in lower case, as Kimi Code and its login write
    /// it; nil when it has no host.
    static func canonicalBaseURL(_ url: String) -> String? {
        guard let range = hostRange(in: url), !range.isEmpty else { return nil }
        return url.replacingCharacters(in: range, with: url[range].lowercased())
    }

    /// The `number`th slot spelling of `base`: the host letters whose bit is
    /// set in `number`, counted from the left, in upper case. Every number
    /// from 1 below `2^letters` gives a different spelling and none gives
    /// the canonical one, so a slot never reads the credential of sessions
    /// outside slots. Nil past the last one. URL parsing lower-cases the
    /// host, so every spelling reaches the same server.
    static func spelling(of base: String, number: Int) -> String? {
        guard number > 0, let canonical = canonicalBaseURL(base), let range = hostRange(in: canonical) else { return nil }
        let host = canonical[range]
        let letters = host.filter(\.isLetter).count
        guard letters > 0, number < 1 << min(letters, 16) else { return nil }
        var index = 0
        let spelt = String(host.map { character -> Character in
            guard character.isLetter else { return character }
            defer { index += 1 }
            return number & (1 << index) != 0 ? Character(character.uppercased()) : character
        })
        return canonical.replacingCharacters(in: range, with: spelt)
    }

    /// Whether `url`'s host has a letter in upper case, which only a slot
    /// spelling has.
    static func isSlotSpelling(_ url: String) -> Bool {
        guard let range = hostRange(in: url) else { return false }
        return url[range].contains(where: \.isUppercase)
    }

    /// The managed provider's OAuth host and canonical API base URL in
    /// `config.toml`, which slots are spelt from. The base URL falls back
    /// to the OAuth host's region when `base_url` names no host with
    /// letters. Nil without a managed provider.
    func sharedEndpoints() -> (oauthHost: String, baseURL: String)? {
        guard let configured = TOMLHookConfig.value(at: configFile, table: Self.providerTable, key: "base_url") else { return nil }
        let oauthHost = TOMLHookConfig.value(at: configFile, table: KimiService.credentialTable, key: "oauth_host")
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOAuthHost
        if let canonical = Self.canonicalBaseURL(configured), Self.spelling(of: canonical, number: 1) != nil {
            return (oauthHost, canonical)
        }
        guard let regional = Self.regionBaseURLs[Self.trimmingTrailingSlashes(oauthHost)] else { return nil }
        return (oauthHost, regional)
    }

    /// The pair of values a slot runs with, from its files; nil when either
    /// is missing or the base URL is not a slot spelling.
    func selector(in directory: URL) -> (oauthHost: String, baseURL: String)? {
        func read(_ name: String) -> String? {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let oauthHost = read(Self.oauthHostFile), let baseURL = read(Self.baseURLFile),
              Self.isSlotSpelling(baseURL) else { return nil }
        return (oauthHost, baseURL)
    }

    /// Creates the slot directory and, the first time, gives it a spelling
    /// no other slot holds: it takes the first spelling whose credential
    /// file it can create in Kimi Code's home with `O_EXCL`, so two slots
    /// prepared at once never share one; the empty file reads as no
    /// credential until `writeCredential` replaces it. The slot's files are
    /// written after, the base URL last. Throws without a managed provider
    /// in `config.toml` or when every spelling is taken.
    func prepareSlot(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard selector(in: directory) == nil else { return }
        guard let endpoints = sharedEndpoints() else {
            throw NSError(domain: "KimiSessionIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kimi Code's config.toml names no managed provider"])
        }
        let credentials = home.appendingPathComponent("credentials", isDirectory: true)
        try fm.createDirectory(at: credentials, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var number = 1
        while let baseURL = Self.spelling(of: endpoints.baseURL, number: number) {
            number += 1
            let name = Self.credentialName(oauthHost: endpoints.oauthHost, baseURL: baseURL)
            let file = credentials.appendingPathComponent("\(name).json")
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "Slot credential not created"])
            }
            close(descriptor)
            do {
                try PrivateFile.writeAtomically(Data(endpoints.oauthHost.utf8), to: directory.appendingPathComponent(Self.oauthHostFile), mode: 0o600)
                try PrivateFile.writeAtomically(Data(baseURL.utf8), to: directory.appendingPathComponent(Self.baseURLFile), mode: 0o600)
            } catch {
                unlink(file.path)
                throw error
            }
            return
        }
        throw NSError(domain: "KimiSessionIsolation", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Every slot spelling of Kimi Code's base URL is taken"])
    }

    /// The credential file Kimi Code reads in a session of the slot
    /// `directory`: the name its pair derives, in Kimi Code's home. Nil for
    /// a slot without a pair, or one whose name is not a derived one.
    func credentialFile(in directory: URL) -> URL? {
        guard let selector = selector(in: directory) else { return nil }
        let name = Self.credentialName(oauthHost: selector.oauthHost, baseURL: selector.baseURL)
        guard name.hasPrefix(Self.scopedNamePrefix) else { return nil }
        return home.appendingPathComponent("credentials/\(name).json")
    }

    /// Writes the credential as Kimi Code writes it, to a new file set to
    /// 0600 before anything is written to it, synced, then renamed over the
    /// old one, while holding Kimi Code's lock on it (`KimiCredentialLock`),
    /// waited for up to `lockWait` while Kimi Code keeps it fresh.
    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        guard let file = credentialFile(in: directory) else {
            log.error("A Kimi slot names no credential")
            return false
        }
        let lock = KimiCredentialLock(home: home, name: file.deletingPathExtension().lastPathComponent)
        guard lock.acquire(waitingUpTo: lockWait) else {
            log.warning("Kimi Code's lock on a slot credential is held; the slot is written at the next pass")
            return false
        }
        defer { lock.release() }
        do {
            try PrivateFile.writeAtomically(Data(credential.contents.utf8), to: file, mode: 0o600)
        } catch {
            log.error("Slot credential not written: \(error.localizedDescription)")
            return false
        }
        return readCredential(in: directory) == credential
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        credentialFile(in: directory)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(SlotCredential.init(contents:))
    }

    /// Deletes the slot's own credential file from Kimi Code's home, and
    /// nothing else there: only a regular file whose name its pair derives
    /// with the `kimi-code-env-` prefix, and only while `config.toml`, once
    /// `restoreSharedState` has run, neither selects it nor names it as its
    /// `key`, so sessions outside slots never lose the file they read.
    /// `SessionSlots.remove` deletes the slot directory after.
    func removeSlot(_ directory: URL) {
        restoreSharedState()
        guard let file = credentialFile(in: directory) else { return }
        let name = file.deletingPathExtension().lastPathComponent
        guard !configuredCredentialNames().contains(name) else {
            log.warning("A removed Kimi slot's credential is still the one config.toml names; it is kept")
            return
        }
        var status = stat()
        guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return }
        unlink(file.path)
    }

    /// The credential names `config.toml` points sessions outside slots
    /// at: the one Kimi Code derives from its `oauth_host` and `base_url`,
    /// and the one its `key` names.
    func configuredCredentialNames() -> Set<String> {
        var names = Set<String>()
        if let configured = TOMLHookConfig.value(at: configFile, table: Self.providerTable, key: "base_url") {
            let oauthHost = TOMLHookConfig.value(at: configFile, table: KimiService.credentialTable, key: "oauth_host")
                .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOAuthHost
            names.insert(Self.credentialName(oauthHost: oauthHost, baseURL: configured))
        }
        if let key = TOMLHookConfig.value(at: configFile, table: KimiService.credentialTable, key: "key"),
           let name = KimiService.credentialStorageName(for: key) {
            names.insert(name)
        }
        return names
    }

    /// Puts `config.toml`'s managed provider back on Kimi Code's own
    /// spelling after a slot's session wrote its own there: a `base_url`
    /// with an upper-case host letter goes back to lower case, and `key` to
    /// the name Kimi Code derives for it. Kimi Code reads the credential
    /// that pair names, so until this runs, sessions outside slots and
    /// `KimiService.activeCredentialURL` read the slot's. Left alone when
    /// the credential that spelling names holds a refresh token: then it is
    /// a sign-in of Kimi Code's own, made with that spelling, not a slot.
    func restoreSharedState() {
        guard let configured = TOMLHookConfig.value(at: configFile, table: Self.providerTable, key: "base_url"),
              Self.isSlotSpelling(configured), let canonical = Self.canonicalBaseURL(configured) else { return }
        let oauthHost = TOMLHookConfig.value(at: configFile, table: KimiService.credentialTable, key: "oauth_host")
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOAuthHost
        let selected = home.appendingPathComponent("credentials/\(Self.credentialName(oauthHost: oauthHost, baseURL: configured)).json")
        if let data = try? Data(contentsOf: selected),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refresh = object["refresh_token"] as? String, !refresh.isEmpty {
            return
        }
        do {
            try TOMLHookConfig.setValue(at: configFile, table: Self.providerTable, key: "base_url", value: canonical, comment: nil)
            try TOMLHookConfig.setValue(at: configFile, table: KimiService.credentialTable, key: "key",
                                        value: "oauth/" + Self.credentialName(oauthHost: oauthHost, baseURL: canonical), comment: nil)
            log.info("Kimi Code's config.toml put back on its own base URL after a slot's session wrote its own")
        } catch {
            log.warning("Kimi Code's config.toml not put back yet: \(error.localizedDescription)")
        }
    }

    /// Exports the slot directory, then the pair from its files; a slot
    /// whose files cannot be read runs the CLI unchanged.
    func launcherExportLines(slot: String) -> [String] {
        let base = Self.baseURLVariable, host = Self.oauthHostVariable
        return [
            "\(directoryVariable)=\(slot)",
            "\(base)=$(cat \"\(slot)/\(Self.baseURLFile)\" 2>/dev/null) || exec \"$real\" \"$@\"",
            "\(host)=$(cat \"\(slot)/\(Self.oauthHostFile)\" 2>/dev/null) || exec \"$real\" \"$@\"",
            "[ -n \"$\(base)\" ] && [ -n \"$\(host)\" ] || exec \"$real\" \"$@\"",
            "export \(directoryVariable) \(base) \(host)",
        ]
    }

    func launchAssignments(forSlot directory: URL) -> [(name: String, value: String)] {
        var assignments = [(name: directoryVariable, value: directory.path)]
        if let selector = selector(in: directory) {
            assignments += [(Self.baseURLVariable, selector.baseURL), (Self.oauthHostVariable, selector.oauthHost)]
        }
        return assignments
    }

    /// Kimi Code reads the credential file before every model request.
    func signalReread(_ directory: URL) {}
}
