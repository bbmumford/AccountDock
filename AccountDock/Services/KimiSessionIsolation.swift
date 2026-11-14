import Foundation

private let log = FileLog("KimiSessionIsolation")

/// Kimi Code's slots. `KIMI_CODE_HOME` names the directory Kimi Code uses as
/// its whole home: its configuration, its credential under `credentials/`,
/// its sessions, logs and caches all live there. A slot is such a home with
/// the configuration copied from Kimi Code's own home (`prepareSlot`) and a
/// credential holding one account's access token with its real expiry and
/// an empty refresh token (`slotCredential`). With an empty refresh token
/// Kimi Code never renews in the slot: when the token reaches its renewal
/// threshold it refuses that request before any network call and leaves
/// the file as it is, so it never presents a refresh token AccountDock owns
/// and never writes its revoked placeholder into the slot. AccountDock
/// therefore writes a renewed access token into every slot serving the
/// account before the threshold (`minimumLifetime(expiresIn:)`). Kimi Code
/// reads the credential file again before every model request, so a slot
/// rewritten for another account moves its session at the next request and
/// `signalReread` has nothing to do.
struct KimiSessionIsolation: ProviderSessionIsolation {
    let executable = "kimi"
    let directoryVariable = "KIMI_CODE_HOME"
    /// `KIMI_CODE_HOME` already names a home; `KIMI_MODEL_NAME` defines a
    /// model with its own API key; the base URL and OAuth host overrides
    /// make Kimi Code read a credential stored under another name.
    let passThroughVariables = ["KIMI_CODE_HOME", "KIMI_MODEL_NAME", "KIMI_CODE_BASE_URL",
                                "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]
    /// Sign-in and sign-out, the commands that manage providers, the
    /// installation and its configuration, and those that read or write the
    /// session history in Kimi Code's own home; none starts a session that
    /// sends model requests.
    let passThroughCommands = ["login", "logout", "provider", "doctor", "migrate", "upgrade", "update",
                               "install-desktop", "app", "session", "import-sessions", "export", "fork", "vis"]
    let background: BackgroundSessionSupport? = nil
    /// Kimi Code's own installer puts it here.
    let installDirectories = [".kimi-code/bin"]
    var preferredExecutable: String? { nil }

    /// Kimi Code's own home, which slots copy their configuration from and
    /// which is never written here.
    let sourceHome: URL
    /// How long `writeCredential` waits for a lock Kimi Code keeps fresh.
    let lockWait: TimeInterval

    init(sourceHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true),
         lockWait: TimeInterval = 10) {
        self.sourceHome = sourceHome
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
                    switch await service.renewLiveCredentialForSlots(location: location, lasting: required) {
                    case .renewed: state.clearNeedsSignIn(account)
                    case .rejected: state.noteCredentialRejected(account)
                    case .unavailable: break
                    }
                } else {
                    _ = await state.renewSavedCredential(account)
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

    /// Files of Kimi Code's own home a slot needs before Kimi Code starts in
    /// it: `config.toml` (providers, models, the hooks AccountDock installs,
    /// and the OAuth table naming the credential), `tui.toml`, `mcp.json`,
    /// `device_id`, which Kimi Code and AccountDock's own renewals send with
    /// their requests, and the `region` marker.
    static let copiedFiles = ["config.toml", "tui.toml", "mcp.json", "device_id", "region"]

    /// Creates the slot and copies `copiedFiles` from `sourceHome` where the
    /// slot has none or an older one, so a change in Kimi Code's own home,
    /// such as reinstalled hooks, reaches spare slots, and a change Kimi
    /// Code made in the slot since stays. Each copy keeps its source's
    /// permissions.
    func prepareSlot(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Self.copiedFiles {
            let source = sourceHome.appendingPathComponent(name)
            guard let sourceAttributes = try? fm.attributesOfItem(atPath: source.path),
                  sourceAttributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let destination = directory.appendingPathComponent(name)
            if let copied = (try? fm.attributesOfItem(atPath: destination.path))?[.modificationDate] as? Date,
               let changed = sourceAttributes[.modificationDate] as? Date, copied >= changed {
                continue
            }
            let mode = (sourceAttributes[.posixPermissions] as? NSNumber).map { mode_t($0.uint16Value) } ?? 0o600
            try PrivateFile.writeAtomically(try Data(contentsOf: source), to: destination, mode: mode)
        }
    }

    /// The credential file Kimi Code reads in `directory`: named by the
    /// `key` of `KimiService.credentialTable` in the slot's `config.toml`,
    /// or Kimi Code's default `oauth/kimi-code` when it names none. Nil for
    /// a key that names no file.
    func credentialFile(in directory: URL) -> URL? {
        let key = TOMLHookConfig.value(at: directory.appendingPathComponent("config.toml"),
                                       table: KimiService.credentialTable, key: "key")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "oauth/kimi-code"
        return KimiService.credentialStorageName(for: key)
            .map { directory.appendingPathComponent("credentials/\($0).json") }
    }

    /// Writes the credential as Kimi Code writes it, to a new file set to
    /// 0600 before anything is written to it, synced, then renamed over the
    /// old one, while holding Kimi Code's lock on it (`KimiCredentialLock`),
    /// waited for up to `lockWait` while Kimi Code keeps it fresh.
    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        guard let file = credentialFile(in: directory) else {
            log.error("The slot's config.toml names no credential file Kimi Code reads")
            return false
        }
        let lock = KimiCredentialLock(home: directory, name: file.deletingPathExtension().lastPathComponent)
        guard lock.acquire(waitingUpTo: lockWait) else {
            log.warning("Kimi Code's credential lock in a slot is held; the slot is written at the next pass")
            return false
        }
        defer { lock.release() }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
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

    /// Kimi Code keeps nothing for a slot outside its home.
    func removeSlot(_ directory: URL) {}

    /// Kimi Code reads the credential file before every model request.
    func signalReread(_ directory: URL) {}
}
