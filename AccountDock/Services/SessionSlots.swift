import CryptoKit
import Foundation

private let log = FileLog("SessionSlots")

/// Serves a CLI's sessions from several accounts at once without the request
/// router: a launcher in front of the CLI on the user's `PATH` starts each
/// session on an account picked by weight, through a credential slot of its
/// own.
///
/// A slot is a directory under `root`, one per saved account, named in the
/// CLI's `SessionSlotSupport.directoryVariable`; the CLI then reads its
/// credential from the slot's Keychain item instead of its default one.
/// `AppState.maintainSessionSlots` writes each slot and the pool file the
/// launcher reads. A slot holds the access token only: AccountDock renews
/// every account it stores, and a CLI holding the refresh token would
/// replace it under AccountDock. Every session the launcher starts gets a
/// one-session slot of its own, the active account's included, so each can
/// be moved alone; the pool names the active account `activeEntry` only
/// while it has no spare slot, and its session then reads the CLI's default
/// credential.
///
/// Launches from IDEs and apps do not read the shell profile and keep the
/// default credential.
struct SessionSlots: Sendable {
    let support: SessionSlotSupport
    let executable: String
    let home: URL

    /// Pool-file entry for the CLI's default credential.
    static let activeEntry = "-"
    /// The launcher starts the CLI unchanged once the pool file is older
    /// than this, so a stopped AccountDock never leaves sessions on slots
    /// nothing renews.
    static let poolLifetimeMinutes = 30
    /// Marks the profile line `installLauncher` adds, so `removeLauncher`
    /// finds it again.
    static let profileMarker = "# accountdock session slots"
    static let profileFile = ".zshrc"

    init?(_ provider: AIProviderType, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard let support = provider.capabilities.sessionSlots,
              let executable = provider.capabilities.cliExecutableName else { return nil }
        self.support = support
        self.executable = executable
        self.home = home.standardizedFileURL
    }

    var base: URL { home.appendingPathComponent(".accountdock", isDirectory: true) }
    var root: URL { base.appendingPathComponent("\(executable)-slots", isDirectory: true) }
    var binDirectory: URL { base.appendingPathComponent("bin", isDirectory: true) }
    var launcher: URL { binDirectory.appendingPathComponent(executable) }

    /// The CLI itself rather than `launcher`, which would pick an account of
    /// its own: `preferred` when it is the CLI, or else the first on the
    /// usual install paths. Read by `AppState.sessionLaunch`.
    func realExecutable(preferred: String?) -> String? {
        let fm = FileManager.default
        let launcherPath = launcher.resolvingSymlinksInPath().path
        let candidates = [preferred].compactMap { $0 } + [
            "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".claude/local").path,
        ].map { ($0 as NSString).appendingPathComponent(executable) }
        return candidates.first { path in
            fm.isExecutableFile(atPath: path) && URL(fileURLWithPath: path).resolvingSymlinksInPath().path != launcherPath
        }
    }
    var poolFile: URL { root.appendingPathComponent("pool.tsv") }
    /// One line per recent session: its ID, a tab, and the slot directory of
    /// the account its history ran on, or `activeEntry`. The launcher starts
    /// a session resumed by ID there, so its prompt cache and thinking stay
    /// usable; written by `AppState.maintainSessionSlots`.
    var resumeFile: URL { root.appendingPathComponent("resume.tsv") }
    /// Slots of one session each, under `root`: the launcher claims a spare
    /// one filled for the account it picked, and AccountDock can move that
    /// one session by rewriting its slot. Each holds `accountFile`, the
    /// account it serves, and once claimed `claimedMarker`.
    var sessionRoot: URL { root.appendingPathComponent("session", isDirectory: true) }
    static let accountFile = "account"
    static let claimedMarker = "claimed"
    /// Names the file a launcher leaves in `sessionRoot` when it finds no
    /// spare, for `takeSpareRequests`.
    static let requestPrefix = ".wanted."
    /// How long a launcher waits for a spare before it starts its session
    /// on a credential shared with other sessions; `spareWaitVariable` in
    /// the launch's environment gives another number of seconds.
    static let spareWaitSeconds = 4
    static let spareWaitVariable = "ACCOUNTDOCK_SPARE_WAIT"
    /// Marks a slot claimed for a session the user asked AccountDock to
    /// start on one account (`claimRequested`), which may begin later than
    /// a session the launcher claims for.
    static let requestedMarker = "requested"

    /// A one-session slot as it stands on disk.
    struct SessionSlot: Equatable {
        let directory: URL
        /// The account it serves; nil until AccountDock has filled it.
        var account: UUID?
        /// When the launcher claimed it for a session; nil while spare.
        var claimedAt: Date?
        /// When its account was last written, by filling or moving it.
        var assignedAt: Date? = nil
        /// Claimed by `claimRequested` rather than the launcher.
        var requested = false
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
            let claimed = (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(Self.claimedMarker).path))?[.creationDate] as? Date
            let assigned = (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(Self.accountFile).path))?[.modificationDate] as? Date
            let requested = fm.fileExists(atPath: directory.appendingPathComponent(Self.requestedMarker).path)
            return SessionSlot(directory: directory, account: account, claimedAt: claimed, assignedAt: assigned,
                               requested: requested)
        }
    }

    /// The slots that hold `account`'s access token: those `serving` names
    /// for it, its own slot unless `serving` names another account for it,
    /// and its spare one-session slots. `AppState.reissueSlotCredential`
    /// writes a renewed token to them.
    func directories(holding account: UUID, serving: [String: UUID]) -> Set<String> {
        var found = Set(serving.filter { $0.value == account }.map(\.key))
        let own = directory(for: account).path
        if slotDirectories().contains(where: { $0.path == own }), serving[own].map({ $0 == account }) ?? true {
            found.insert(own)
        }
        for slot in sessionSlots() where slot.claimedAt == nil && slot.account == account {
            found.insert(slot.directory.path)
        }
        return found
    }

    /// Fills a new spare slot for `account`. The account file is written
    /// last, so the launcher never claims a slot without its credential.
    @discardableResult
    func makeSpare(for account: UUID, credential: String) -> Bool {
        makeSlot(for: account, credential: credential) != nil
    }

    /// Fills a new one-session slot for `account`; nil when it could not be
    /// written.
    func makeSlot(for account: UUID, credential: String) -> URL? {
        let directory = sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard serve(directory, credential: credential), assign(directory, to: account) else { return nil }
        return directory
    }

    /// A new slot for one session started on request, claimed before it is
    /// filled: an unclaimed slot is a spare, which a launcher may take and
    /// `AppState.maintainSessionSlots` may remove at any moment. Nil when it
    /// could not be written.
    func makeRequestedSlot(for account: UUID, credential: String) -> URL? {
        let directory = sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("[makeRequestedSlot] Slot not created: \(error.localizedDescription)")
            return nil
        }
        guard claimRequested(directory), serve(directory, credential: credential), assign(directory, to: account) else {
            remove(directory)
            return nil
        }
        return directory
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

    /// Records the account a one-session slot serves.
    @discardableResult
    func assign(_ directory: URL, to account: UUID) -> Bool {
        do {
            try Data(account.uuidString.utf8).write(to: directory.appendingPathComponent(Self.accountFile), options: .atomic)
            return true
        } catch {
            log.error("[assign] Slot account not written: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Keychain

    /// The Keychain service the CLI reads for a slot directory: the default
    /// service, `-`, and the first eight hexadecimal digits of the SHA-256
    /// of the path in Unicode normalization form C.
    static func keychainService(base: String, directory: String) -> String {
        let digest = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
        return base + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    func store(for directory: URL) -> SecurityToolKeychain {
        SecurityToolKeychain(service: Self.keychainService(base: support.keychainService, directory: directory.path))
    }

    /// The credential JSON without any `refreshToken`, or nil when it is not
    /// a JSON object.
    static func accessOnly(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object.removeValue(forKey: "refreshToken")
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: strip(root), options: [.sortedKeys]) else { return nil }
        return String(data: stripped, encoding: .utf8)
    }

    /// Writes `credential` to the slot when it holds anything else. Returns
    /// whether the slot holds it afterwards.
    func serve(_ directory: URL, credential: String) -> Bool {
        let store = store(for: directory)
        if store.read(account: NSUserName()) == SecurityToolKeychain.asciiOnly(credential) { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("[serve] Slot directory not created: \(error.localizedDescription)")
            return false
        }
        return store.apply(writes: [(NSUserName(), credential)])
    }

    /// Deletes a spare slot, claiming it first: the launcher claims a spare
    /// with the same `mkdir`, so a spare it took in the meantime is left to
    /// its session. Returns whether the slot was removed.
    @discardableResult
    func removeSpare(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(Self.claimedMarker),
                                                    withIntermediateDirectories: false)
        } catch {
            return false
        }
        remove(directory)
        return true
    }

    /// Whether a launcher found no spare slot for its account since the last
    /// call: it leaves a `requestPrefix` file in `sessionRoot` and waits
    /// `spareWaitSeconds` for `AppState.maintainSessionSlots` to fill one.
    /// The files are removed.
    func takeSpareRequests() -> Bool {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: sessionRoot.path)) ?? []).filter { $0.hasPrefix(Self.requestPrefix) }
        for name in names { try? fm.removeItem(at: sessionRoot.appendingPathComponent(name)) }
        return !names.isEmpty
    }

    /// Deletes the slot's Keychain item and directory.
    func remove(_ directory: URL) {
        _ = store(for: directory).apply(writes: [], deletes: [NSUserName()])
        try? FileManager.default.removeItem(at: directory)
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

    // MARK: - Running sessions

    /// Slot directories named in the environment of the user's running
    /// processes, which keep reading their slot until they exit.
    func directoriesInUse() -> Set<String> {
        Set(directoriesByProcess().values)
    }

    /// The slot directory each of the user's running processes reads, by
    /// process ID; `AppState.slotAccount(forSession:)` credits a session's
    /// usage readings to the account serving its slot.
    func directoriesByProcess() -> [Int32: String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Eww", "-o", "pid=,command=", "-U", String(getuid())]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("[directoriesByProcess] ps failed: \(error.localizedDescription)")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self.directoriesByProcess(inProcessList: String(decoding: data, as: UTF8.self),
                                         variable: support.directoryVariable, root: root.path)
    }

    /// Values of `variable` under `root` in `ps -E -o pid=,command=` output,
    /// by the process ID that starts each line.
    static func directoriesByProcess(inProcessList text: String, variable: String, root: String) -> [Int32: String] {
        var found: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let pid = Int32(fields[0]),
                  let directory = directories(inProcessList: String(fields[1]), variable: variable, root: root).first
            else { continue }
            found[pid] = directory
        }
        return found
    }

    /// Values of `variable` under `root` in `ps -E` output.
    static func directories(inProcessList text: String, variable: String, root: String) -> Set<String> {
        let prefix = variable + "=" + root + "/"
        var found = Set<String>()
        for line in text.split(separator: "\n") {
            for word in line.split(separator: " ") where word.hasPrefix(prefix) {
                found.insert(String(word.dropFirst(variable.count + 1)))
            }
        }
        return found
    }

    // MARK: - Launcher

    var launcherInstalled: Bool {
        (try? String(contentsOf: launcher, encoding: .utf8)) == launcherScript()
            && Self.profileHasLine(profileText(), line: profileLine)
    }

    /// Writes the launcher and puts its directory first on the shell's
    /// `PATH`. Shells started afterwards use it.
    func installLauncher() throws {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data(launcherScript().utf8).write(to: launcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let text = profileText()
        if !Self.profileHasLine(text, line: profileLine) {
            try Self.addingLine(profileLine, to: text).write(to: profileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the launcher and its profile line; sessions it started keep
    /// their slots until they exit.
    func removeLauncher() {
        removePool()
        try? FileManager.default.removeItem(at: launcher)
        let text = profileText()
        if Self.profileHasLine(text, line: profileLine) {
            try? Self.removingLine(profileLine, from: text).write(to: profileURL, atomically: true, encoding: .utf8)
        }
    }

    var profileURL: URL { home.appendingPathComponent(Self.profileFile) }

    /// Prepended on every shell start, so the launcher stays ahead of
    /// directories the profile adds earlier.
    var profileLine: String {
        "export PATH=\"$HOME/.accountdock/bin:$PATH\"  \(Self.profileMarker)"
    }

    private func profileText() -> String {
        (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
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

    /// The launcher: starts the first other `executable` on `PATH`, on an
    /// account picked from the pool file at random by weight. It starts the
    /// CLI unchanged when the launch already decides its credential, signs
    /// in or out, or the pool file is missing or stale.
    func launcherScript() -> String {
        let passThrough = support.credentialVariables
            .map { "[ -n \"${\($0):-}\" ] && exec \"$real\" \"$@\"" }
            .joined(separator: "\n")
        return #"""
        #!/bin/sh
        # Installed by AccountDock: starts \#(executable) on one of the accounts in
        # \#(Self.shellQuoted(poolFile.path)), picked at random by weight.
        launcher=\#(Self.shellQuoted(launcher.path))
        pool=\#(Self.shellQuoted(poolFile.path))
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
        sessions=\#(Self.shellQuoted(sessionRoot.path))
        if [ -z "$real" ]; then
          echo "\#(executable): command not found" >&2
          exit 127
        fi
        \#(passThrough)
        case "${1:-}" in
          \#(support.accountCommands.joined(separator: "|"))) exec "$real" "$@" ;;
        esac
        [ -n "$(find "$pool" -mmin -\#(Self.poolLifetimeMinutes) 2>/dev/null)" ] || exec "$real" "$@"
        resumes=\#(Self.shellQuoted(resumeFile.path))
        resumed=
        previous=
        for argument in "$@"; do
          case "$previous" in --resume|-r) resumed=$argument ;; esac
          case "$argument" in --resume=*) resumed=${argument#--resume=} ;; esac
          previous=$argument
        done
        slot=
        if [ -n "$resumed" ] && [ -n "$(find "$resumes" -mmin -\#(Self.poolLifetimeMinutes) 2>/dev/null)" ]; then
          slot=$(awk -F '\t' -v id="$resumed" '$1 == id { print $2; exit }' "$resumes" 2>/dev/null)
        fi
        [ -n "$slot" ] || slot=$(awk -F '\t' -v pid="$$" '
          BEGIN { srand(); seed = srand(); srand(seed + pid * 7919) }
          $1 > 0 { n++; weight[n] = $1; path[n] = $2; total += $1 }
          END {
            if (n == 0) exit
            r = rand() * total
            for (i = 1; i <= n; i++) { r -= weight[i]; if (r < 0) { print path[i]; exit } }
            print path[n]
          }' "$pool" 2>/dev/null)
        # Each session gets a slot of its own, so AccountDock can move it
        # alone. With no spare left, AccountDock is asked for one and given
        # \#(Self.spareWaitSeconds) seconds to fill it.
        if [ -n "$slot" ] && [ "$slot" != "\#(Self.activeEntry)" ]; then
          account=${slot##*/}
          request="$sessions/\#(Self.requestPrefix)$$"
          wait=${\#(Self.spareWaitVariable):-\#(Self.spareWaitSeconds)}
          case "$wait" in ''|*[!0-9]*) wait=\#(Self.spareWaitSeconds) ;; esac
          tries=0
          while :; do
            for spare in "$sessions"/*; do
              [ -f "$spare/\#(Self.accountFile)" ] || continue
              [ "$(cat "$spare/\#(Self.accountFile)" 2>/dev/null)" = "$account" ] || continue
              if mkdir "$spare/\#(Self.claimedMarker)" 2>/dev/null; then
                [ "$tries" -eq 0 ] || rm -f "$request"
                \#(support.directoryVariable)=$spare
                export \#(support.directoryVariable)
                exec "$real" "$@"
              fi
            done
            [ "$tries" -lt $((wait * 5)) ] || break
            : > "$request" 2>/dev/null || break
            tries=$((tries + 1))
            sleep 0.2
          done
          [ "$tries" -eq 0 ] || rm -f "$request"
        fi
        if [ -z "$slot" ] || [ "$slot" = "\#(Self.activeEntry)" ] || [ ! -d "$slot" ]; then
          exec "$real" "$@"
        fi
        \#(support.directoryVariable)=$slot
        export \#(support.directoryVariable)
        exec "$real" "$@"

        """#
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
