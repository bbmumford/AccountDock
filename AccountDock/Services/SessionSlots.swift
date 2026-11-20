import Foundation

private let log = FileLog("SessionSlots")

/// Serves a CLI's sessions from several accounts at once without the request
/// router, in two layers. Every session the launcher in front of the CLI on
/// the user's `PATH` starts runs in a session slot of its own, a directory
/// under `sessionRoot` the launcher makes for it (or the one it had, taken
/// back when it is resumed); AccountDock assigns that slot to an account by
/// writing the account's credential for it, and moves the session by
/// rewriting it. The slot's directory is named in the provider's
/// `ProviderSessionIsolation.directoryVariable`, so the CLI reads the
/// credential the isolation wrote for that directory instead of its default
/// one. A slot holds the access token only (`SlotCredential`).
///
/// The launcher asks for the account the session last ran on (the resume
/// file), else the one the pool file picks by weight, else the active one,
/// and waits for AccountDock to fill the slot (`AppState.fillRequestedSlots`).
/// Everything here is the same for every provider; where a slot's
/// credential lives and how the CLI is told which slot to read are the
/// isolation's. `AppState.maintainSessionSlots` keeps the slots and writes
/// the pool and resume files.
///
/// Launches from IDEs and apps do not read the shell profile and keep the
/// default credential, and so does every launch while AccountDock is not
/// running, since nothing would fill a slot.
struct SessionSlots: Sendable {
    let isolation: any ProviderSessionIsolation
    let home: URL
    /// Where every slot credential written, slot assigned and slot removed
    /// is recorded, with the slot, the account and the caller's `reason`.
    let audit: CredentialAudit

    var executable: String { isolation.executable }
    /// The CLI's background-session service, whose commands and launches
    /// the launcher runs unchanged: their sessions run in the supervisor's
    /// workers, which never read a slot.
    var background: BackgroundSessionSupport? { isolation.background }

    /// Names the active account in a resume file line or a slot's
    /// `wantedFile`: whichever account is active when AccountDock fills the
    /// slot.
    static let activeEntry = "-"
    /// The launcher reads the pool and resume files only while they are
    /// younger than this, so an AccountDock that stopped writing them leaves
    /// no launch on a choice nothing renews.
    static let poolLifetimeMinutes = 30
    /// Marks the profile line `installLauncher` adds, so `removeLauncher`
    /// finds it again.
    static let profileMarker = "# accountdock session slots"
    /// Read by every zsh, interactive or not, so `zsh -c`, scripts and
    /// tools that start the CLI through a shell find the launcher too.
    static let profileFile = ".zshenv"
    /// Read by interactive zsh after the login files, whose `path_helper`
    /// and Homebrew's `shellenv` put the CLI's own directory ahead of
    /// anything `profileFile` added: the line goes here too, last, so a
    /// terminal's shell finds the launcher first.
    static let interactiveProfileFile = ".zshrc"

    init?(_ provider: AIProviderType, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard let isolation = provider.capabilities.sessionIsolation else { return nil }
        self.init(isolation: isolation, home: home)
    }

    init(isolation: any ProviderSessionIsolation, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         audit: CredentialAudit = .shared) {
        self.isolation = isolation
        self.home = home.standardizedFileURL
        self.audit = audit
    }

    /// The provider an entry names: the one whose isolation this is, else
    /// the provider of the slot's account; nil records nothing, which only
    /// an isolation no provider declares and no saved account uses reaches.
    private func auditProvider(_ account: UUID?) -> AIProviderType? {
        AIProviderType.allCases.first { $0.capabilities.sessionIsolation?.executable == isolation.executable }
            ?? account.flatMap(audit.provider(ofAccount:))
    }

    /// First arguments the launcher runs the CLI unchanged for: the
    /// background service's commands, which start no session of their own,
    /// then the sign-in commands.
    var passThroughCommands: [String] {
        (background?.managementCommands ?? []) + isolation.passThroughCommands
    }

    var base: URL { home.appendingPathComponent(".accountdock", isDirectory: true) }
    var root: URL { base.appendingPathComponent("\(executable)-slots", isDirectory: true) }
    var binDirectory: URL { base.appendingPathComponent("bin", isDirectory: true) }
    var launcher: URL { binDirectory.appendingPathComponent(executable) }

    /// The CLI itself rather than `launcher`, which would pick an account of
    /// its own: `preferred` when it is the CLI, or else the first on the
    /// usual install paths and the isolation's `installDirectories`. Read
    /// by `AppState.sessionLaunch`.
    func realExecutable(preferred: String?) -> String? {
        let fm = FileManager.default
        let launcherPath = launcher.resolvingSymlinksInPath().path
        let directories = [
            "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
        ] + isolation.installDirectories.map { home.appendingPathComponent($0).path }
        let candidates = [preferred].compactMap { $0 }
            + directories.map { ($0 as NSString).appendingPathComponent(executable) }
        return candidates.first { path in
            fm.isExecutableFile(atPath: path) && URL(fileURLWithPath: path).resolvingSymlinksInPath().path != launcherPath
        }
    }
    var poolFile: URL { root.appendingPathComponent("pool.tsv") }
    /// One line per recent session: its ID, a tab, and either the session
    /// slot it last ran in, which the launcher takes back for it while that
    /// slot is `reclaimableMarker`ed, or the account its history ran on,
    /// named by that account's `directory(for:)` path. A line whose first
    /// field is a folder (it starts with `/`) names the slot a `--continue`
    /// started there takes back. The launcher resumes a session there, so
    /// its prompt cache and thinking stay usable; written by
    /// `AppState.maintainSessionSlots`.
    var resumeFile: URL { root.appendingPathComponent("resume.tsv") }
    /// Session slots, one per session, under `root`: the launcher makes one
    /// for each launch and AccountDock fills it for an account and can move
    /// that one session by rewriting it. Each holds `claimedMarker`, in
    /// which the launcher leaves the ID of the process it started
    /// (`claimerFile`), the launcher's `wantedFile` until AccountDock has
    /// filled it, and `accountFile`, the account it serves, written last.
    var sessionRoot: URL { root.appendingPathComponent("session", isDirectory: true) }
    /// Holds AccountDock's process ID and name while it runs
    /// (`markStarted`); a launch finding no running AccountDock there starts
    /// the CLI unchanged, since nothing would fill its slot.
    var startedFile: URL { root.appendingPathComponent("started") }
    /// Holds AccountDock's process ID once its first pass over the slots
    /// since it started has written the pool and resume files
    /// (`markReady`); until then a launch waits for it.
    var readyFile: URL { root.appendingPathComponent("ready") }
    static let accountFile = "account"
    static let claimedMarker = "claimed"
    /// Inside `claimedMarker`: the process ID the launcher started the CLI
    /// as, written when it claims the slot, so a launcher taking the slot
    /// back for a resumed session can tell whether that process still runs.
    static let claimerFile = "pid"
    /// The session AccountDock last saw reading a claimed slot, and the
    /// folder it ran in, one per line (`recordSession`); kept with the slot,
    /// so the resume table can name the slot for that session after
    /// AccountDock or the machine restarts.
    static let sessionFile = "session"
    /// Left by AccountDock in a claimed slot whose session has ended and
    /// whose ID the resume file maps to it (`markReclaimable`): a launcher
    /// resuming that session renames it away and so takes the slot, and
    /// AccountDock renames it away before it removes the slot
    /// (`removeReclaimable`); one rename succeeds, so the two never both
    /// have it.
    static let reclaimableMarker = "reclaimable"
    /// Written by the launcher in the slot it made, before the slot appears
    /// under `sessionRoot`: the account it asks for (an account ID, or
    /// `activeEntry`) and, on the next line, the session it resumes, if any.
    /// `AppState.fillRequestedSlots` fills the slot and removes it.
    static let wantedFile = "wanted"
    /// Names the file a launcher leaves in `sessionRoot` once its slot waits
    /// to be filled, for `takeSlotRequests`; it wakes AccountDock's watch.
    static let requestPrefix = ".wanted."
    /// The prefix of the name a launcher makes its slot under, outside the
    /// names `sessionSlots` reads, before renaming it into place whole.
    static let makingPrefix = ".making."
    /// How long a launcher waits for AccountDock to fill its slot, and how
    /// long for AccountDock's first pass after it started
    /// (`readyFile`); the variables in the launch's environment give other
    /// numbers of seconds. Filling one slot takes well under a second, so
    /// either wait ends long before its limit unless AccountDock is stuck.
    static let fillWaitSeconds = 30
    static let fillWaitVariable = "ACCOUNTDOCK_SLOT_WAIT"
    static let startWaitSeconds = 60
    static let startWaitVariable = "ACCOUNTDOCK_START_WAIT"
    /// Marks a slot claimed for a session the user asked AccountDock to
    /// start on one account (`claimRequested`), which may begin later than
    /// a session the launcher claims for.
    static let requestedMarker = "requested"

    /// A session slot as it stands on disk.
    struct SessionSlot: Equatable {
        let directory: URL
        /// The account it serves; nil until AccountDock has filled it.
        var account: UUID?
        /// When the launcher made it for a session, or last took it back for
        /// one (`claimerFile`'s time); nil for a slot no launch has claimed,
        /// which only an earlier AccountDock made ahead of a launch.
        var claimedAt: Date?
        /// When its account was last written, by filling or moving it.
        var assignedAt: Date? = nil
        /// Claimed by `claimRequested` rather than the launcher.
        var requested = false
        /// The session and folder `sessionFile` records.
        var session: String? = nil
        var folder: String? = nil
        /// Since when it has been offered back to its session
        /// (`reclaimableMarker`); nil while not.
        var reclaimableSince: Date? = nil
    }

    func directory(for account: UUID) -> URL {
        root.appendingPathComponent(account.uuidString, isDirectory: true)
    }

    /// The account a slot directory belongs to, or nil for any other path.
    func account(forDirectory path: String) -> UUID? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// The account a slot directory serves as far as the slot itself
    /// records: an account's own slot by its name, a one-session slot by
    /// its account file.
    func recordedAccount(forSlotAt path: String) -> UUID? {
        if let id = account(forDirectory: path) { return id }
        let file = URL(fileURLWithPath: path).appendingPathComponent(Self.accountFile)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Session slots

    /// Every one-session slot on disk.
    func sessionSlots() -> [SessionSlot] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sessionRoot.path)) ?? []
        return names.compactMap { name -> SessionSlot? in
            guard UUID(uuidString: name) != nil else { return nil }
            let directory = sessionRoot.appendingPathComponent(name, isDirectory: true)
            let account = (try? String(contentsOf: directory.appendingPathComponent(Self.accountFile), encoding: .utf8))
                .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            func date(_ name: String, _ key: FileAttributeKey) -> Date? {
                (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[key] as? Date
            }
            let claimed = date(Self.claimedMarker, .creationDate)
            // A slot taken back for a resumed session is claimed anew then.
            let taken = claimed == nil ? nil : date(Self.claimedMarker + "/" + Self.claimerFile, .modificationDate)
            let recorded = Self.recordedSession(
                (try? String(contentsOf: directory.appendingPathComponent(Self.sessionFile), encoding: .utf8)) ?? ""
            )
            let requested = fm.fileExists(atPath: directory.appendingPathComponent(Self.requestedMarker).path)
            return SessionSlot(directory: directory, account: account,
                               claimedAt: [claimed, taken].compactMap { $0 }.max(),
                               assignedAt: date(Self.accountFile, .modificationDate), requested: requested,
                               session: recorded?.session, folder: recorded?.folder,
                               reclaimableSince: claimed == nil ? nil : date(Self.reclaimableMarker, .creationDate))
        }
    }

    /// `sessionFile`'s text: the session ID on its first line, its folder,
    /// when known, on the second.
    static func sessionText(session: String, folder: String?) -> String {
        session + "\n" + (folder.map { $0 + "\n" } ?? "")
    }

    /// The session and folder `sessionText` wrote; nil for anything else.
    static func recordedSession(_ text: String) -> (session: String, folder: String?)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let session = lines.first, !session.isEmpty, !session.contains("\t") else { return nil }
        let folder = lines.dropFirst().first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        return (session, folder)
    }

    /// Records in `directory` (a claimed one-session slot) the session
    /// reading it and its folder, unless it already says so; read back by
    /// `sessionSlots`. Returns whether the slot says so afterwards.
    @discardableResult
    func recordSession(_ session: String, folder: String?, in directory: URL) -> Bool {
        guard isSessionSlot(directory.path), !session.isEmpty, !session.contains("\n"), !session.contains("\t") else {
            return false
        }
        let file = directory.appendingPathComponent(Self.sessionFile)
        let text = Self.sessionText(session: session, folder: folder.flatMap { $0.contains("\n") ? nil : $0 })
        if (try? String(contentsOf: file, encoding: .utf8)) == text { return true }
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            return true
        } catch {
            log.error("[recordSession] Slot session not recorded: \(error.localizedDescription)")
            return false
        }
    }

    /// Offers a claimed one-session slot whose session has ended back to
    /// that session (`reclaimableMarker`); a slot no launch claimed is never
    /// marked. Returns whether it is marked afterwards.
    @discardableResult
    func markReclaimable(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard isSessionSlot(directory.path),
              fm.fileExists(atPath: directory.appendingPathComponent(Self.claimedMarker).path) else { return false }
        let marker = directory.appendingPathComponent(Self.reclaimableMarker).path
        return fm.fileExists(atPath: marker) || fm.createFile(atPath: marker, contents: nil)
    }

    /// Takes the offer `markReclaimable` made back with one rename, the
    /// rename a launcher taking the slot makes too, so only one of them
    /// has it. Returns whether this call took it: false when a launcher
    /// already took the slot for its session, or it was never offered.
    @discardableResult
    func retractReclaimable(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let held = directory.appendingPathComponent(".retracted-" + UUID().uuidString)
        do {
            try fm.moveItem(at: directory.appendingPathComponent(Self.reclaimableMarker), to: held)
        } catch {
            return false
        }
        try? fm.removeItem(at: held)
        return true
    }

    /// Removes a slot offered back to its session once the offer is taken
    /// back (`retractReclaimable`), recorded as a `slotRemove` by
    /// `reason`; a slot a launcher took in the meantime is left to its
    /// session. Returns whether the slot was removed.
    @discardableResult
    func removeReclaimable(_ directory: URL, reason: String) -> Bool {
        guard retractReclaimable(directory) else { return false }
        remove(directory, reason: reason)
        return true
    }

    /// The slots that hold `account`'s access token: those `serving` names
    /// for it, its own slot unless `serving` names another account for it,
    /// and the session slots offered back to their sessions that it serves.
    /// `AppState.reissueSlotCredential` writes a renewed token to them.
    func directories(holding account: UUID, serving: [String: UUID]) -> Set<String> {
        var found = Set(serving.filter { $0.value == account }.map(\.key))
        let own = directory(for: account).path
        if slotDirectories().contains(where: { $0.path == own }), serving[own].map({ $0 == account }) ?? true {
            found.insert(own)
        }
        for slot in sessionSlots() where slot.reclaimableSince != nil && slot.account == account {
            found.insert(slot.directory.path)
        }
        return found
    }

    /// A session slot a launcher made and waits on: what its `wantedFile`
    /// asks for, and the process the launcher is (`claimerFile`).
    struct WantedSlot: Equatable {
        let directory: URL
        /// The account asked for; nil for `activeEntry` or anything else.
        var account: UUID?
        /// The session the launch resumes, when it resumes one.
        var session: String?
        var claimer: Int32?
    }

    /// The session slots waiting to be filled: claimed, with a `wantedFile`
    /// and no `accountFile` yet.
    func wantedSlots() -> [WantedSlot] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sessionRoot.path)) ?? []
        return names.sorted().compactMap { name -> WantedSlot? in
            guard UUID(uuidString: name) != nil else { return nil }
            let directory = sessionRoot.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: directory.appendingPathComponent(Self.accountFile).path),
                  fm.fileExists(atPath: directory.appendingPathComponent(Self.claimedMarker).path),
                  let text = try? String(contentsOf: directory.appendingPathComponent(Self.wantedFile), encoding: .utf8)
            else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let claimer = (try? String(contentsOf: directory.appendingPathComponent(Self.claimedMarker + "/" + Self.claimerFile),
                                       encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return WantedSlot(directory: directory, account: lines.first.flatMap(UUID.init(uuidString:)),
                              session: lines.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }, claimer: claimer)
        }
    }

    /// Fills a session slot a launcher waits on for `account`: the
    /// credential, then the account file, which tells the launcher to start
    /// the CLI, recorded as a `slotWrite` and a `slotAssign` by `reason`;
    /// then its `wantedFile` goes. With no `credential`, as for a pinned
    /// session whose pin cannot be written now, the account file alone
    /// names the account the session waits on. Returns whether the slot
    /// holds the credential, when given, and names the account.
    func fill(_ directory: URL, account: UUID, credential: SlotCredential?, reason: String,
              session: String? = nil, process: Int32? = nil) -> Bool {
        guard isSessionSlot(directory.path) else { return false }
        if let credential {
            guard serve(directory, credential: credential, account: account, reason: reason, session: session,
                        process: process) else { return false }
        } else {
            try? isolation.prepareSlot(directory)
        }
        guard assign(directory, to: account, reason: reason, session: session, process: process) else { return false }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.wantedFile))
        return true
    }

    /// A new slot for one session started on request, claimed before it is
    /// filled, so no pass takes it for a slot no launch claimed. Nil when it
    /// could not be written.
    func makeRequestedSlot(for account: UUID, credential: SlotCredential, reason: String) -> URL? {
        let directory = sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try isolation.prepareSlot(directory)
        } catch {
            log.error("[makeRequestedSlot] Slot not created: \(error.localizedDescription)")
            return nil
        }
        guard claimRequested(directory), serve(directory, credential: credential, account: account, reason: reason),
              assign(directory, to: account, reason: reason) else {
            remove(directory, reason: reason + ".unfilled")
            return nil
        }
        return directory
    }

    /// Whether `path` names a one-session slot: a directory named by a UUID
    /// right under `sessionRoot`.
    func isSessionSlot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().path == sessionRoot.standardizedFileURL.path
            && UUID(uuidString: url.lastPathComponent) != nil
    }

    /// Recreates a one-session slot whose directory is gone while a running
    /// process still names it (`AppState.restoreMissingSlots`): the
    /// directory at that same path, claimed before anything else, so no
    /// launcher takes it for a new session, then `credential` and
    /// `account`, recorded as a `slotWrite` and a `slotAssign` by `reason`.
    /// Refuses a path that is not a one-session slot or that exists.
    /// Returns whether the slot holds the credential afterwards.
    func restoreClaimedSlot(_ directory: URL, account: UUID, credential: SlotCredential, reason: String,
                            session: String? = nil, process: Int32? = nil) -> Bool {
        let fm = FileManager.default
        guard isSessionSlot(directory.path), !fm.fileExists(atPath: directory.path) else { return false }
        do {
            try isolation.prepareSlot(directory)
            try fm.createDirectory(at: directory.appendingPathComponent(Self.claimedMarker), withIntermediateDirectories: false)
        } catch {
            log.error("[restoreClaimedSlot] Slot not created: \(error.localizedDescription)")
            return false
        }
        guard serve(directory, credential: credential, account: account, reason: reason, session: session, process: process)
        else { return false }
        return assign(directory, to: account, reason: reason, session: session, process: process)
    }

    /// Claims a slot for one session started on request, so the launcher
    /// never hands it to another session; the session names the slot itself
    /// through the CLI's slot variable.
    func claimRequested(_ directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory.appendingPathComponent(Self.claimedMarker), withIntermediateDirectories: false)
            return fm.createFile(atPath: directory.appendingPathComponent(Self.requestedMarker).path, contents: nil)
        } catch {
            log.error("[claimRequested] Slot not claimed: \(error.localizedDescription)")
            return false
        }
    }

    /// Records the account a one-session slot serves, as a `slotAssign`
    /// from the account it served before, by `reason`, for the session and
    /// process using it when known.
    @discardableResult
    func assign(_ directory: URL, to account: UUID, reason: String, session: String? = nil,
                process: Int32? = nil) -> Bool {
        let previous = recordedAccount(forSlotAt: directory.path)
        let written: Bool
        do {
            try Data(account.uuidString.utf8).write(to: directory.appendingPathComponent(Self.accountFile), options: .atomic)
            written = true
        } catch {
            log.error("[assign] Slot account not written: \(error.localizedDescription)")
            written = false
        }
        if let provider = auditProvider(account) {
            audit.record(.slotAssign, provider, account: account, outcome: written ? "ok" : "failed", reason: reason,
                         slot: directory.path, session: session, process: process,
                         detail: previous.map { $0 == account ? "unchanged" : "from \($0.uuidString)" })
        }
        return written
    }

    // MARK: - Credential

    /// Writes `credential` to the slot through the isolation when the slot
    /// holds anything else, then tells a CLI reading it. Returns whether
    /// the slot holds it afterwards. A write is recorded as a `slotWrite`
    /// for `account` by `reason`, with the token it replaced and the
    /// session and process using the slot when known.
    func serve(_ directory: URL, credential: SlotCredential, account: UUID?, reason: String,
               session: String? = nil, process: Int32? = nil) -> Bool {
        let held = isolation.readCredential(in: directory)
        if held == credential { return true }
        let provider = auditProvider(account)
        func note(_ outcome: String) {
            guard let provider else { return }
            audit.record(.slotWrite, provider, account: account, credential: credential.contents,
                         previousCredential: held?.contents, outcome: outcome, reason: reason,
                         slot: directory.path, session: session, process: process)
        }
        do {
            try isolation.prepareSlot(directory)
        } catch {
            log.error("[serve] Slot directory not created: \(error.localizedDescription)")
            note("noDirectory")
            return false
        }
        guard isolation.writeCredential(credential, to: directory) else {
            note("failed")
            return false
        }
        isolation.signalReread(directory)
        note("ok")
        return true
    }

    /// Deletes a slot no launch has claimed, as an earlier AccountDock made
    /// ahead of launches, claiming it first with the `mkdir` an earlier
    /// launcher claimed one with, so one taken in the meantime is left to
    /// its session. Returns whether the slot was removed.
    @discardableResult
    func removeUnclaimed(_ directory: URL, reason: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(Self.claimedMarker),
                                                    withIntermediateDirectories: false)
        } catch {
            return false
        }
        remove(directory, reason: reason)
        return true
    }

    /// Whether a launcher has asked for its slot to be filled since the
    /// last call: it leaves a `requestPrefix` file in `sessionRoot` while it
    /// waits for `AppState.fillRequestedSlots`. The files are removed.
    func takeSlotRequests() -> Bool {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: sessionRoot.path)) ?? []).filter { $0.hasPrefix(Self.requestPrefix) }
        for name in names { try? fm.removeItem(at: sessionRoot.appendingPathComponent(name)) }
        return !names.isEmpty
    }

    /// Deletes what the isolation keeps for the slot, then its directory,
    /// recorded as a `slotRemove` of the account the slot served and the
    /// token it held, by `reason`.
    func remove(_ directory: URL, reason: String) {
        let account = recordedAccount(forSlotAt: directory.path)
        let held = isolation.readCredential(in: directory)
        isolation.removeSlot(directory)
        try? FileManager.default.removeItem(at: directory)
        if let provider = auditProvider(account) {
            audit.record(.slotRemove, provider, account: account, credential: held?.contents,
                         outcome: held == nil ? "empty" : "ok", reason: reason, slot: directory.path)
        }
    }

    /// Every slot directory on disk.
    func slotDirectories() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }.map { directory(for: $0) }
    }

    // MARK: - Pool

    /// One line per entry with a positive weight: the weight, a tab, and the
    /// slot directory or `activeEntry`.
    static func poolText(_ entries: [(path: String, weight: Double)]) -> String {
        entries.filter { $0.weight > 0 }
            .map { String(format: "%g", $0.weight) + "\t" + $0.path + "\n" }
            .joined()
    }

    func writePool(_ entries: [(path: String, weight: Double)]) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(Self.poolText(entries).utf8).write(to: poolFile, options: .atomic)
        } catch {
            log.error("[writePool] Pool file not written: \(error.localizedDescription)")
        }
    }

    func removePool() {
        try? FileManager.default.removeItem(at: poolFile)
        try? FileManager.default.removeItem(at: resumeFile)
    }

    // MARK: - AccountDock running

    /// Records that AccountDock runs as process `pid` named `name` (the
    /// last path component of its executable, as `ps -o comm=` ends), in
    /// `startedFile`, which every launch reads first. Written as AccountDock
    /// starts, before its first pass over the slots. The ready file an
    /// earlier run left goes first: a process ID comes round again after a
    /// restart, and one left naming this run's would end the launches' wait
    /// before the pass.
    func markStarted(pid: Int32, name: String) {
        try? FileManager.default.removeItem(at: readyFile)
        write("\(pid)\t\(name)\n", to: startedFile)
    }

    /// Records that AccountDock's first pass since `markStarted(pid:)` has
    /// written the pool and resume files, in `readyFile`; launches waiting
    /// for it go on.
    func markReady(pid: Int32) {
        write("\(pid)\n", to: readyFile)
    }

    /// The process ID `readyFile` holds; nil when none.
    func readyPID() -> Int32? {
        (try? String(contentsOf: readyFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func write(_ text: String, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            log.error("[write] \(file.lastPathComponent) not written: \(error.localizedDescription)")
        }
    }

    static func resumeText(_ entries: [(session: String, path: String)]) -> String {
        entries.filter { !$0.session.contains("\t") && !$0.session.contains("\n") && !$0.session.isEmpty }
            .map { $0.session + "\t" + $0.path + "\n" }
            .joined()
    }

    func writeResumes(_ entries: [(session: String, path: String)]) {
        do {
            try Data(Self.resumeText(entries).utf8).write(to: resumeFile, options: .atomic)
        } catch {
            log.error("[writeResumes] Resume file not written: \(error.localizedDescription)")
        }
    }

    /// Names `path` in the resume file for `session` at once, replacing any
    /// line it had, so a session resumed before the next maintenance pass
    /// starts there; `AppState.applySlotRestarts` calls it for a session it
    /// is about to restart on another account.
    func addResume(session: String, path: String) {
        let text = (try? String(contentsOf: resumeFile, encoding: .utf8)) ?? ""
        let kept = text.split(separator: "\n").filter { !$0.hasPrefix(session + "\t") }.map { $0 + "\n" }.joined()
        do {
            try Data((kept + Self.resumeText([(session, path)])).utf8).write(to: resumeFile, options: .atomic)
        } catch {
            log.error("[addResume] Resume file not written: \(error.localizedDescription)")
        }
    }

    // MARK: - Running sessions

    /// Slot directories named in the environment of the user's running
    /// processes, which keep reading their slot until they exit.
    func directoriesInUse() -> Set<String> {
        Set(directoriesByProcess().values)
    }

    /// The slot directory each of the user's running processes reads, by
    /// process ID, from a fresh `ProcessTable`; empty when it cannot be
    /// read. `AppState.slotAccount(forSession:)` credits a session's usage
    /// readings to the account serving its slot.
    func directoriesByProcess() -> [Int32: String] {
        guard let table = ProcessTable.read() else {
            log.error("[directoriesByProcess] The process list could not be read")
            return [:]
        }
        return directoriesByProcess(in: table)
    }

    func directoriesByProcess(in table: ProcessTable) -> [Int32: String] {
        Self.directoriesByProcess(in: table, variable: isolation.directoryVariable, root: root.path)
    }

    /// The value of `variable` in each process's environment that names a
    /// directory under `root`, by process ID.
    static func directoriesByProcess(in table: ProcessTable, variable: String, root: String) -> [Int32: String] {
        table.entries.reduce(into: [:]) { found, entry in
            if let directory = entry.environmentValue(variable), directory.hasPrefix(root + "/") {
                found[entry.pid] = directory
            }
        }
    }


    // MARK: - Launcher

    var launcherInstalled: Bool {
        (try? String(contentsOf: launcher, encoding: .utf8)) == launcherScript()
            && Self.profileHasLine(profileText(), line: profileLine)
            && Self.profileHasLine(profileText(interactiveProfileURL), line: profileLine)
    }

    /// Writes the launcher and puts its directory first on the shell's
    /// `PATH`. Shells started afterwards use it.
    func installLauncher() throws {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data(launcherScript().utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        for url in [profileURL, interactiveProfileURL] {
            let text = profileText(url)
            if !Self.profileHasLine(text, line: profileLine) {
                try Self.addingLine(profileLine, to: text).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Removes the launcher and its profile line; sessions it started keep
    /// their slots until they exit.
    func removeLauncher() {
        removePool()
        try? FileManager.default.removeItem(at: launcher)
        for url in [profileURL, interactiveProfileURL] {
            let text = profileText(url)
            if Self.profileHasLine(text, line: profileLine) {
                try? Self.removingLine(profileLine, from: text).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    var profileURL: URL { home.appendingPathComponent(Self.profileFile) }
    var interactiveProfileURL: URL { home.appendingPathComponent(Self.interactiveProfileFile) }

    /// Prepended on every shell start, so the launcher stays ahead of
    /// directories the profile adds earlier.
    var profileLine: String {
        "export PATH=\"$HOME/.accountdock/bin:$PATH\"  \(Self.profileMarker)"
    }

    private func profileText(_ url: URL? = nil) -> String {
        (try? String(contentsOf: url ?? profileURL, encoding: .utf8)) ?? ""
    }

    static func profileHasLine(_ text: String, line: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == line }
    }

    /// The profile with `line` appended last, so the directory it adds comes
    /// before every directory added above it.
    static func addingLine(_ line: String, to text: String) -> String {
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return text + separator + line + "\n"
    }

    static func removingLine(_ line: String, from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 != line }
            .joined(separator: "\n")
    }

    /// The launcher: starts the first other `executable` on `PATH` in a
    /// session slot of its own. It starts the CLI unchanged when the launch
    /// already decides its credential, signs in or out, manages or starts a
    /// background session (`passThroughCommands`,
    /// `BackgroundSessionSupport.backgroundFlag`), or no AccountDock runs
    /// (`startedFile`), since nothing would fill a slot; while AccountDock
    /// is starting it waits for its first pass (`readyFile`). A session
    /// resumed by ID, or continued in a folder the resume file names, takes
    /// back the session slot the resume file names for it while that slot is
    /// offered (`reclaimableMarker`) and the process that claimed it
    /// (`claimerFile`) no longer runs with it. Every other launch makes a
    /// slot, asks in its `wantedFile` for the account the resume file names,
    /// or the one the pool file picks by weight, or the active one, and waits
    /// for AccountDock to fill it; one not filled within `fillWaitSeconds`
    /// starts the CLI unchanged.
    func launcherScript() -> String {
        let passThrough = isolation.passThroughVariables
            .map { "[ -n \"${\($0):-}\" ] && exec \"$real\" \"$@\"" }
            .joined(separator: "\n")
        let backgroundFlag = background.map { flag in
            "for argument in \"$@\"; do [ \"$argument\" = \(Self.shellQuoted(flag.backgroundFlag)) ] && exec \"$real\" \"$@\"; done"
        } ?? ""
        let claimer = "\(Self.claimedMarker)/\(Self.claimerFile)"
        return #"""
        #!/bin/sh
        # Installed by AccountDock: starts \#(executable) in a session slot of its own,
        # which AccountDock fills for the account the session last ran on, or
        # the one \#(Self.shellQuoted(poolFile.path)) picks at random by weight, or the active one.
        launcher=\#(Self.shellQuoted(launcher.path))
        root=\#(Self.shellQuoted(root.path))
        pool=\#(Self.shellQuoted(poolFile.path))
        sessions=\#(Self.shellQuoted(sessionRoot.path))
        real=
        saved_ifs=$IFS
        IFS=:
        for dir in $PATH; do
          [ -n "$dir" ] || continue
          candidate="$dir/\#(executable)"
          [ -f "$candidate" ] && [ -x "$candidate" ] || continue
          [ "$candidate" -ef "$launcher" ] && continue
          real=$candidate
          break
        done
        IFS=$saved_ifs
        if [ -z "$real" ]; then
          echo "\#(executable): command not found" >&2
          exit 127
        fi
        \#(passThrough)
        case "${1:-}" in
          \#(passThroughCommands.joined(separator: "|"))) exec "$real" "$@" ;;
        esac
        \#(backgroundFlag)
        # AccountDock fills every session slot, and runs while the process its
        # started file names, by ID and name, runs. Without it the CLI starts
        # unchanged, and AccountDock restarts the session in a slot of its own
        # once it runs.
        dock=
        dock_name=
        [ -f "$root/\#(startedFile.lastPathComponent)" ] && read -r dock dock_name < "$root/\#(startedFile.lastPathComponent)"
        case "$dock" in *[!0-9]*) dock= ;; esac
        [ -n "$dock" ] && [ -n "$dock_name" ] || exec "$real" "$@"
        case "$(ps -o comm= -p "$dock" 2>/dev/null)" in
          "$dock_name"|*/"$dock_name") ;;
          *) exec "$real" "$@" ;;
        esac
        # While AccountDock is starting, its first pass over the slots, which
        # writes the pool and resume files, is waited for: its ID in the ready file.
        wait=${\#(Self.startWaitVariable):-\#(Self.startWaitSeconds)}
        case "$wait" in ''|*[!0-9]*) wait=\#(Self.startWaitSeconds) ;; esac
        tries=0
        ready=
        [ -f "$root/\#(readyFile.lastPathComponent)" ] && read -r ready < "$root/\#(readyFile.lastPathComponent)"
        while [ "$ready" != "$dock" ] && [ "$tries" -lt $((wait * 5)) ]; do
          kill -0 "$dock" 2>/dev/null || exec "$real" "$@"
          sleep 0.2
          tries=$((tries + 1))
          ready=
          [ -f "$root/\#(readyFile.lastPathComponent)" ] && read -r ready < "$root/\#(readyFile.lastPathComponent)"
        done
        resumes=\#(Self.shellQuoted(resumeFile.path))
        resumed=
        previous=
        \#(isolation.resumeArgumentScript)
        continued=
        \#(isolation.continueArgumentScript)
        slot=
        if { [ -n "$resumed" ] || [ -n "$continued" ]; } && [ -n "$(find "$resumes" -mmin -\#(Self.poolLifetimeMinutes) 2>/dev/null)" ]; then
          if [ -n "$resumed" ]; then
            slot=$(awk -F '\t' -v id="$resumed" '$1 == id { print $2; exit }' "$resumes" 2>/dev/null)
          else
            here=$(pwd -P 2>/dev/null)
            slot=$(awk -F '\t' -v a="$PWD" -v b="$here" '$1 == a || $1 == b { print $2; exit }' "$resumes" 2>/dev/null)
          fi
        fi
        # A session resumed into the session slot it last ran in takes it back:
        # AccountDock offers that slot once its session has ended, and the
        # rename of its \#(Self.reclaimableMarker) marker, which one launcher alone can make,
        # takes it, unless the process that claimed it still runs: a process
        # with its ID that started no later than the claim was written (one
        # that started later was given the ID since, as after a restart).
        # Otherwise the session asks for the account that slot serves.
        account=
        case "$slot" in
          "$sessions"/*)
            claimer=
            [ -f "$slot/\#(claimer)" ] && read -r claimer < "$slot/\#(claimer)"
            case "$claimer" in *[!0-9]*) claimer= ;; esac
            running=
            if [ -n "$claimer" ] && kill -0 "$claimer" 2>/dev/null; then
              running=1
              written=$(stat -f %m "$slot/\#(claimer)" 2>/dev/null)
              started=$(LC_ALL=C ps -o lstart= -p "$claimer" 2>/dev/null)
              started=$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null)
              case "$written" in *[!0-9]*) written= ;; esac
              case "$started" in *[!0-9]*) started= ;; esac
              [ -n "$written" ] && [ -n "$started" ] && [ "$started" -gt $((written + 5)) ] && running=
            fi
            if [ -z "$running" ] && mv "$slot/\#(Self.reclaimableMarker)" "$slot/\#(Self.claimedMarker)/reclaimed.$$" 2>/dev/null; then
              rm -f "$slot/\#(Self.claimedMarker)/reclaimed.$$"
              { echo "$$" > "$slot/\#(claimer)"; } 2>/dev/null
              \#(isolation.launcherExportLines(slot: "$slot").joined(separator: "\n      "))
              exec "$real" "$@"
            fi
            [ -f "$slot/\#(Self.accountFile)" ] && read -r account < "$slot/\#(Self.accountFile)"
            ;;
          */*) account=${slot##*/} ;;
          ?*) account=$slot ;;
        esac
        if [ -z "$account" ] && [ -n "$(find "$pool" -mmin -\#(Self.poolLifetimeMinutes) 2>/dev/null)" ]; then
          account=$(awk -F '\t' -v pid="$$" '
            BEGIN { srand(); seed = srand(); srand(seed + pid * 7919) }
            $1 > 0 { n++; weight[n] = $1; path[n] = $2; total += $1 }
            END {
              if (n == 0) exit
              r = rand() * total
              for (i = 1; i <= n; i++) { r -= weight[i]; if (r < 0) { print path[i]; exit } }
              print path[n]
            }' "$pool" 2>/dev/null)
          account=${account##*/}
        fi
        [ -n "$account" ] || account=\#(Self.activeEntry)
        # The session's own slot: made under a name AccountDock does not read,
        # claimed, told the account it asks for, then renamed into place whole.
        # AccountDock fills it for that account, its account file last, and is
        # given \#(Self.fillWaitSeconds) seconds to; the CLI starts unchanged if it does not.
        name=$(uuidgen 2>/dev/null)
        making="$sessions/\#(Self.makingPrefix)$$"
        mine="$sessions/$name"
        [ -n "$name" ] && mkdir -m 700 "$making" 2>/dev/null && mkdir "$making/\#(Self.claimedMarker)" 2>/dev/null \
          && { echo "$$" > "$making/\#(claimer)"; } 2>/dev/null \
          && { printf '%s\n%s\n' "$account" "$resumed" > "$making/\#(Self.wantedFile)"; } 2>/dev/null \
          && mv "$making" "$mine" 2>/dev/null || exec "$real" "$@"
        request="$sessions/\#(Self.requestPrefix)$$"
        wait=${\#(Self.fillWaitVariable):-\#(Self.fillWaitSeconds)}
        case "$wait" in ''|*[!0-9]*) wait=\#(Self.fillWaitSeconds) ;; esac
        tries=0
        while [ ! -f "$mine/\#(Self.accountFile)" ] && [ "$tries" -lt $((wait * 5)) ]; do
          [ $((tries % 25)) -eq 0 ] && : > "$request" 2>/dev/null
          kill -0 "$dock" 2>/dev/null || break
          sleep 0.2
          tries=$((tries + 1))
        done
        rm -f "$request"
        if [ ! -f "$mine/\#(Self.accountFile)" ]; then
          rm -f "$mine/\#(Self.wantedFile)"
          exec "$real" "$@"
        fi
        \#(isolation.launcherExportLines(slot: "$mine").joined(separator: "\n"))
        exec "$real" "$@"

        """#
    }

    /// Launcher lines that set `resumed` from `"$@"` for a CLI whose
    /// `options` take the session ID as the next argument and whose
    /// `inlineOptions` also take it after `=`; used for
    /// `ProviderSessionIsolation.resumeArgumentScript`.
    static func resumeArgumentScript(options: [String], inlineOptions: [String]) -> String {
        var lines = [#"for argument in "$@"; do"#]
        if !options.isEmpty {
            lines.append(#"  case "$previous" in "# + options.joined(separator: "|") + #") resumed=$argument ;; esac"#)
        }
        for option in inlineOptions {
            lines.append(#"  case "$argument" in "# + option + #"=*) resumed=${argument#"# + option + #"=} ;; esac"#)
        }
        lines += ["  previous=$argument", "done"]
        return lines.joined(separator: "\n")
    }

    /// Launcher lines that set `continued` when one of `options` is among
    /// `"$@"`; used for `ProviderSessionIsolation.continueArgumentScript`.
    static func continueArgumentScript(options: [String]) -> String {
        guard !options.isEmpty else { return "" }
        return [#"for argument in "$@"; do"#,
                #"  case "$argument" in "# + options.joined(separator: "|") + ") continued=1 ;; esac",
                "done"].joined(separator: "\n")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
