import XCTest
@testable import AccountDock

/// Kimi Code's slots, in temporary directories with fake credentials: the
/// launcher the shared slot code generates for them, the credential a slot
/// holds and how it is written next to Kimi Code's own lock, moving a slot
/// to another account, and the renewal threshold slots are kept above.
final class KimiSessionIsolationTests: XCTestCase {
    private var root: URL!
    /// Stands in for Kimi Code's own home, which slots copy from.
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiSessionIsolationTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("kimi-code", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("default_model = \"kimi\"\n\n[providers.\"managed:kimi-code\".oauth]\nstorage = \"file\"\nkey = \"oauth/kimi-code\"\n",
                  to: source.appendingPathComponent("config.toml"))
        try write("00000000-0000-0000-0000-000000000000\n", to: source.appendingPathComponent("device_id"))
        try write("global\n", to: source.appendingPathComponent("region"))
        StubURLProtocol.reply = { _ in (599, [:], Data()) }
        StubURLProtocol.requested = []
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func isolation(lockWait: TimeInterval = 10) -> KimiSessionIsolation {
        KimiSessionIsolation(sourceHome: source, lockWait: lockWait)
    }

    /// A stored credential as `KimiService` keeps it, with a refresh token
    /// the slot must never receive.
    private func stored(_ access: String, expiresAt: Double = 1_900_000_000.75, expiresIn: Double = 900) -> String {
        #"{"access_token":"\#(access)","refresh_token":"refresh-\#(access)","expires_at":\#(expiresAt),"expires_in":\#(expiresIn),"scope":"kimi-code","token_type":"Bearer"}"#
    }

    private func object(_ credential: SlotCredential) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credential.contents.utf8)) as? [String: Any])
    }

    // MARK: Launcher

    func testKimiLauncherScriptIsUnchanged() {
        let slots = SessionSlots(isolation: KimiSessionIsolation(), home: URL(fileURLWithPath: "/Users/golden"))
        XCTAssertEqual(slots.launcherScript(), Self.golden)
        XCTAssertEqual(slots.root.path, "/Users/golden/.accountdock/kimi-slots")
        XCTAssertEqual(slots.launcher.path, "/Users/golden/.accountdock/bin/kimi")
        XCTAssertEqual(KimiSessionIsolation().resumeCommand(sessionID: "s 1"), "kimi -S 's 1'")
    }

    func testTheLauncherPassesThroughResumesAndClaimsKimiSlots() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let realBin = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let real = realBin.appendingPathComponent("kimi")
        try write("#!/bin/sh\nprintf '%s|%s' \"${KIMI_CODE_HOME:-}\" \"$*\"\n", to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let isolation = isolation()
        let slots = SessionSlots(isolation: isolation, home: home)
        try slots.installLauncher()
        let account = UUID(), other = UUID()
        let credential = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        let otherCredential = try XCTUnwrap(isolation.slotCredential(from: stored("b2")))
        let spare = try XCTUnwrap(slots.makeSlot(for: account, credential: credential))
        let otherSpare = try XCTUnwrap(slots.makeSlot(for: other, credential: otherCredential))
        slots.writePool([(slots.directory(for: account).path, 1)])

        func launch(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec kimi \"$@\"", "sh"] + arguments
            process.environment = ["PATH": slots.binDirectory.path + ":" + realBin.path + ":/usr/bin:/bin",
                                   SessionSlots.spareWaitVariable: "0"]
                .merging(environment) { $1 }
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        // Sign-in, account and configuration commands run the real CLI
        // unchanged, on Kimi Code's own home.
        for command in [["login"], ["logout"], ["provider", "list"], ["doctor"], ["session", "list"], ["export", "s-9"]] {
            XCTAssertEqual(try launch(command), "|" + command.joined(separator: " "), command.joined(separator: " "))
        }
        XCTAssertEqual(try launch(["-p", "hi"], environment: ["KIMI_CODE_HOME": "/elsewhere"]), "/elsewhere|-p hi")
        XCTAssertEqual(try launch(["-p", "hi"], environment: ["KIMI_MODEL_NAME": "m"]), "|-p hi")

        // A session resumed by ID goes back to the account its history ran
        // on, by either spelling of the option.
        slots.writeResumes([(session: "s-1", path: slots.directory(for: other).path)])
        XCTAssertEqual(try launch(["-S", "s-1"]), otherSpare.path + "|-S s-1")
        let again = try XCTUnwrap(slots.makeSlot(for: other, credential: otherCredential))
        XCTAssertEqual(try launch(["--session=s-1"]), again.path + "|--session=s-1")

        // A new session claims a spare of the pool's account.
        XCTAssertEqual(try launch(["-y"]), spare.path + "|-y")

        // Each kimi process is mapped to the slot its environment names;
        // a process on Kimi Code's own home reads no slot.
        let list = """
          321     1 /Users/me/.kimi-code/bin/kimi -S s-1 KIMI_CODE_HOME=\(otherSpare.path) HOME=/x
          322     1 /Users/me/.kimi-code/bin/kimi -y HOME=/x
          323     1 /Users/me/.kimi-code/bin/kimi KIMI_CODE_HOME=/Users/me/.kimi-code HOME=/x
          324     1 /Users/me/.kimi-code/bin/kimi -y KIMI_CODE_HOME=\(spare.path)
        """
        XCTAssertEqual(slots.directoriesByProcess(inProcessList: list), [321: otherSpare.path, 324: spare.path])
    }

    // MARK: Credential

    func testASlotCredentialHoldsTheAccessTokenAndExpiryWithAnEmptyRefreshToken() throws {
        let credential = try XCTUnwrap(isolation().slotCredential(from: stored("a1")))
        let fields = try object(credential)
        XCTAssertEqual(fields["access_token"] as? String, "a1")
        XCTAssertEqual(fields["refresh_token"] as? String, "")
        XCTAssertEqual((fields["expires_at"] as? NSNumber)?.intValue, 1_900_000_000)
        XCTAssertEqual((fields["expires_in"] as? NSNumber)?.intValue, 900)
        XCTAssertEqual(fields["scope"] as? String, "kimi-code")
        XCTAssertEqual(fields["token_type"] as? String, "Bearer")
        XCTAssertFalse(credential.contents.contains("refresh-a1"))
        XCTAssertNil(isolation().slotCredential(from: #"{"access_token":"","refresh_token":"r","expires_at":1}"#))
        XCTAssertNil(isolation().slotCredential(from: #"{"access_token":"a","refresh_token":"r","expires_at":0}"#),
                     "an expiry of 0 would tell Kimi Code never to renew")
    }

    func testTheCredentialIsWrittenAtomicallyWithMode0600UnderKimisLock() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let file = slot.appendingPathComponent("credentials/kimi-code.json")
        XCTAssertEqual(isolation.credentialFile(in: slot), file)

        let first = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        XCTAssertTrue(isolation.writeCredential(first, to: slot))
        let firstInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        let second = try XCTUnwrap(isolation.slotCredential(from: stored("b2")))
        XCTAssertTrue(isolation.writeCredential(second, to: slot))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(attributes[.systemFileNumber] as? Int, firstInode, "replaced by a rename, not rewritten in place")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]
        XCTAssertEqual((directoryMode as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["kimi-code.json"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), second.contents)
        XCTAssertEqual(isolation.readCredential(in: slot), second)

        // Kimi Code's lock target exists, as Kimi Code creates it, and the
        // lock is released.
        let lock = KimiCredentialLock(home: slot, name: "kimi-code")
        XCTAssertEqual(lock.directory.path, slot.appendingPathComponent("oauth/kimi-code.lock").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("oauth/kimi-code").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.directory.path))
    }

    func testTheWriteWaitsForAFreshLockHeldByKimi() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let lock = KimiCredentialLock(home: slot, name: "kimi-code")
        XCTAssertTrue(lock.acquire(waitingUpTo: 0), "Kimi Code holds its lock")
        let credential = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))

        let written = expectation(description: "written once the lock is released")
        let result = LockedFlag()
        DispatchQueue.global().async {
            result.set(isolation.writeCredential(credential, to: slot))
            written.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.6)
        lock.touch()
        XCTAssertNil(isolation.readCredential(in: slot), "nothing is written while Kimi Code holds the lock")
        lock.release()
        wait(for: [written], timeout: 5)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(isolation.readCredential(in: slot), credential)
    }

    func testALockKeptFreshPastTheWaitLeavesTheSlotAsItIs() throws {
        let isolation = isolation(lockWait: 0.3)
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let lock = KimiCredentialLock(home: slot, name: "kimi-code")
        XCTAssertTrue(lock.acquire(waitingUpTo: 0))
        defer { lock.release() }
        XCTAssertFalse(isolation.writeCredential(try XCTUnwrap(isolation.slotCredential(from: stored("a1"))), to: slot))
        XCTAssertNil(isolation.readCredential(in: slot))
    }

    func testAStaleLockIsTakenOver() throws {
        let isolation = isolation(lockWait: 0)
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let lock = KimiCredentialLock(home: slot, name: "kimi-code")
        XCTAssertTrue(lock.acquire(waitingUpTo: 0))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: lock.directory.path)
        let credential = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        XCTAssertTrue(isolation.writeCredential(credential, to: slot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.directory.path))
    }

    func testASlotIsRewrittenForAnotherAccount() throws {
        let isolation = isolation()
        let slots = SessionSlots(isolation: isolation, home: root.appendingPathComponent("home", isDirectory: true))
        let first = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        let second = try XCTUnwrap(isolation.slotCredential(from: stored("b2", expiresAt: 1_900_000_500)))
        let slot = try XCTUnwrap(slots.makeSlot(for: UUID(), credential: first))
        XCTAssertEqual(isolation.readCredential(in: slot), first)

        XCTAssertTrue(slots.serve(slot, credential: second))
        let fields = try object(try XCTUnwrap(isolation.readCredential(in: slot)))
        XCTAssertEqual(fields["access_token"] as? String, "b2")
        XCTAssertEqual(fields["refresh_token"] as? String, "")
        XCTAssertEqual((fields["expires_at"] as? NSNumber)?.intValue, 1_900_000_500)
    }

    // MARK: Slot contents

    func testASlotCopiesKimisConfigurationAndKeepsItsOwnNewerCopy() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        let sourceConfig = try String(contentsOf: source.appendingPathComponent("config.toml"), encoding: .utf8)
        try isolation.prepareSlot(slot)
        XCTAssertEqual(try String(contentsOf: slot.appendingPathComponent("config.toml"), encoding: .utf8), sourceConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("device_id").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("region").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.appendingPathComponent("mcp.json").path))
        let slotMode = try FileManager.default.attributesOfItem(atPath: slot.path)[.posixPermissions]
        XCTAssertEqual((slotMode as? NSNumber)?.intValue, 0o700)

        // A change Kimi Code made in the slot stays until Kimi Code's own
        // home changes after it.
        try write("default_model = \"slot\"\n", to: slot.appendingPathComponent("config.toml"))
        try isolation.prepareSlot(slot)
        XCTAssertEqual(try String(contentsOf: slot.appendingPathComponent("config.toml"), encoding: .utf8), "default_model = \"slot\"\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: source.appendingPathComponent("config.toml").path)
        try isolation.prepareSlot(slot)
        XCTAssertEqual(try String(contentsOf: slot.appendingPathComponent("config.toml"), encoding: .utf8), sourceConfig)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("config.toml"), encoding: .utf8), sourceConfig,
                       "Kimi Code's own home is never written")
    }

    func testTheFooterBadgeReportsRunningWork() {
        let isolation = isolation()
        XCTAssertTrue(isolation.screenReportsRunningWork("> done\n\n  [1 task running]  ctrl+t tasks\n"))
        XCTAssertTrue(isolation.screenReportsRunningWork("> done\n  [2 agents running]\n"))
        XCTAssertFalse(isolation.screenReportsRunningWork("> done\n  context 12%\n"))
        XCTAssertFalse(isolation.screenAsksAboutRunningWork("[1 task running]"))
    }

    // MARK: Renewal

    func testASlotsMinimumLifetimeExceedsKimisRenewalThreshold() {
        for expiresIn in [nil, 60, 300, 600, 900, 3600, 86_400] as [TimeInterval?] {
            let threshold = KimiSessionIsolation.renewalThreshold(expiresIn: expiresIn)
            XCTAssertEqual(threshold, max(300, (expiresIn ?? 0) * 0.5))
            XCTAssertGreaterThan(KimiSessionIsolation.minimumLifetime(expiresIn: expiresIn), threshold)
            XCTAssertGreaterThanOrEqual(KimiSessionIsolation.minimumLifetime(expiresIn: expiresIn) - threshold, 2 * 60,
                                        "the margin outlasts a quota cycle")
        }
        let now = Date()
        // 550 s left: above Kimi Code's 450 s threshold, within its margin.
        let token = stored("a1", expiresAt: now.addingTimeInterval(550).timeIntervalSince1970, expiresIn: 900)
        XCTAssertTrue(KimiSessionIsolation.lasts(token, for: KimiSessionIsolation.renewalThreshold(expiresIn: 900), now: now))
        XCTAssertFalse(KimiSessionIsolation.lasts(token, for: KimiSessionIsolation.minimumLifetime(expiresIn: 900), now: now),
                       "a token within the margin of Kimi Code's threshold is renewed before it is served")
    }

    /// Kimi Code's own home and an account's managed copy holding the same
    /// credential, as after the account was made active.
    private func liveAccount(expiring expiry: Date) throws -> (service: KimiService, managed: URL, live: URL) {
        let home = root.appendingPathComponent("live-home", isDirectory: true)
        try write("[providers.\"managed:kimi-code\".oauth]\nstorage = \"file\"\nkey = \"oauth/kimi-code\"\n",
                  to: home.appendingPathComponent("config.toml"))
        let credential = #"{"access_token":"old","refresh_token":"refresh-old","expires_at":\#(expiry.timeIntervalSince1970),"expires_in":900}"#
        let live = home.appendingPathComponent("credentials/kimi-code.json")
        let managed = root.appendingPathComponent("managed/account/credentials.json")
        try write(credential, to: live)
        try write(credential, to: managed)
        let service = KimiService(home: home, managedRoot: root.appendingPathComponent("managed"), cliIsRunning: { true })
        return (service, managed, live)
    }

    func testTheActiveCredentialIsRenewedForSlotsUnderKimisLockWhileKimiRuns() async throws {
        let files = try liveAccount(expiring: Date().addingTimeInterval(200))
        StubURLProtocol.reply = { url in
            url.path.hasSuffix("/api/oauth/token")
                ? (200, [:], Data(#"{"access_token":"new","refresh_token":"refresh-new","expires_in":900,"token_type":"Bearer"}"#.utf8))
                : (599, [:], Data())
        }
        let outcome = await files.service.renewLiveCredentialForSlots(location: files.managed.path, lasting: 630)
        XCTAssertEqual(outcome, .renewed)
        for url in [files.live, files.managed] {
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(fields["access_token"] as? String, "new")
            XCTAssertEqual(fields["refresh_token"] as? String, "refresh-new")
        }
        XCTAssertEqual(StubURLProtocol.requested.count, 1)
        let lock = KimiCredentialLock(home: files.live.deletingLastPathComponent().deletingLastPathComponent(), name: "kimi-code")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.directory.path))
    }

    func testARenewalKimiFinishedFirstIsUsedWithoutPresentingItsTokenAgain() async throws {
        let files = try liveAccount(expiring: Date().addingTimeInterval(200))
        // Kimi Code renewed its own copy while AccountDock waited.
        try write(#"{"access_token":"kimis","refresh_token":"refresh-kimis","expires_at":\#(Date().addingTimeInterval(900).timeIntervalSince1970),"expires_in":900}"#,
                  to: files.live)
        let outcome = await files.service.renewLiveCredentialForSlots(location: files.managed.path, lasting: 630)
        XCTAssertEqual(outcome, .renewed)
        XCTAssertEqual(StubURLProtocol.requested, [])
        let source = try XCTUnwrap(files.service.slotSourceCredential(location: files.managed.path, isActive: true))
        XCTAssertTrue(source.contains("kimis"))
    }

    func testTheActiveRenewalWaitsForKimisLock() async throws {
        let files = try liveAccount(expiring: Date().addingTimeInterval(200))
        let lock = KimiCredentialLock(home: files.live.deletingLastPathComponent().deletingLastPathComponent(), name: "kimi-code")
        XCTAssertTrue(lock.acquire(waitingUpTo: 0), "Kimi Code is renewing")
        defer { lock.release() }
        let outcome = await files.service.renewLiveCredentialForSlots(location: files.managed.path, lasting: 630, lockWait: 0.3)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(StubURLProtocol.requested, [])
    }

    static let golden = #"""
    #!/bin/sh
    # Installed by AccountDock: starts kimi on one of the accounts in
    # '/Users/golden/.accountdock/kimi-slots/pool.tsv', picked at random by weight.
    launcher='/Users/golden/.accountdock/bin/kimi'
    pool='/Users/golden/.accountdock/kimi-slots/pool.tsv'
    real=
    saved_ifs=$IFS
    IFS=:
    for dir in $PATH; do
      [ -n "$dir" ] || continue
      candidate="$dir/kimi"
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      [ "$candidate" -ef "$launcher" ] && continue
      real=$candidate
      break
    done
    IFS=$saved_ifs
    sessions='/Users/golden/.accountdock/kimi-slots/session'
    if [ -z "$real" ]; then
      echo "kimi: command not found" >&2
      exit 127
    fi
    [ -n "${KIMI_CODE_HOME:-}" ] && exec "$real" "$@"
    [ -n "${KIMI_MODEL_NAME:-}" ] && exec "$real" "$@"
    [ -n "${KIMI_CODE_BASE_URL:-}" ] && exec "$real" "$@"
    [ -n "${KIMI_CODE_OAUTH_HOST:-}" ] && exec "$real" "$@"
    [ -n "${KIMI_OAUTH_HOST:-}" ] && exec "$real" "$@"
    case "${1:-}" in
      login|logout|provider|doctor|migrate|upgrade|update|install-desktop|app|session|import-sessions|export|fork|vis) exec "$real" "$@" ;;
    esac

    # A stale pool, as after a restart before AccountDock has written a
    # new one, is asked for again the way a spare is, and given
    # 4 seconds; without AccountDock running the CLI starts unchanged.
    fresh_pool() { [ -n "$(find "$pool" -mmin -30 2>/dev/null)" ]; }
    if ! fresh_pool; then
      [ -d "$sessions" ] || exec "$real" "$@"
      request="$sessions/.wanted.pool.$$"
      wait=${ACCOUNTDOCK_SPARE_WAIT:-4}
      case "$wait" in ''|*[!0-9]*) wait=4 ;; esac
      tries=0
      while ! fresh_pool && [ "$tries" -lt $((wait * 5)) ]; do
        : > "$request" 2>/dev/null || break
        tries=$((tries + 1))
        sleep 0.2
      done
      rm -f "$request"
      fresh_pool || exec "$real" "$@"
    fi
    resumes='/Users/golden/.accountdock/kimi-slots/resume.tsv'
    resumed=
    previous=
    for argument in "$@"; do
      case "$previous" in -S|--session) resumed=$argument ;; esac
      case "$argument" in --session=*) resumed=${argument#--session=} ;; esac
      previous=$argument
    done
    slot=
    if [ -n "$resumed" ] && [ -n "$(find "$resumes" -mmin -30 2>/dev/null)" ]; then
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
    # 4 seconds to fill it.
    if [ -n "$slot" ] && [ "$slot" != "-" ]; then
      account=${slot##*/}
      request="$sessions/.wanted.$$"
      wait=${ACCOUNTDOCK_SPARE_WAIT:-4}
      case "$wait" in ''|*[!0-9]*) wait=4 ;; esac
      tries=0
      while :; do
        for spare in "$sessions"/*; do
          [ -f "$spare/account" ] || continue
          [ "$(cat "$spare/account" 2>/dev/null)" = "$account" ] || continue
          if mkdir "$spare/claimed" 2>/dev/null; then
            [ "$tries" -eq 0 ] || rm -f "$request"
            KIMI_CODE_HOME=$spare
            export KIMI_CODE_HOME
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
    if [ -z "$slot" ] || [ "$slot" = "-" ] || [ ! -d "$slot" ]; then
      exec "$real" "$@"
    fi
    KIMI_CODE_HOME=$slot
    export KIMI_CODE_HOME
    exec "$real" "$@"

    """#
}

/// A result set on one thread and read on another.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
