import XCTest
@testable import AccountDock

/// Kimi Code's slots, in temporary directories with fake credentials: the
/// credential name Kimi Code derives for a slot's pair of values, the
/// spellings that tell slots apart, the launcher the shared slot code
/// generates for them, the credential a slot holds and how it is written
/// next to Kimi Code's own lock, what removing a slot deletes, putting
/// `config.toml` back after a slot's session wrote its own spelling, and
/// the renewal threshold slots are kept above.
final class KimiSessionIsolationTests: XCTestCase {
    private var root: URL!
    /// Stands in for Kimi Code's own home, which holds every slot's
    /// credential.
    private var kimiHome: URL!

    static let oauthHost = "https://auth.kimi.ai"
    static let baseURL = "https://api.kimi.ai/coding/v1"
    /// The credential sessions outside slots read for the pair above.
    static var liveName: String { KimiSessionIsolation.credentialName(oauthHost: oauthHost, baseURL: baseURL) }

    static func config(baseURL: String = baseURL, key: String = "oauth/" + liveName) -> String {
        """
        default_model = "kimi-code/kimi-for-coding"
        # kept as written

        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "\(baseURL)"
        api_key = ""

        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "\(key)"
        oauth_host = "\(oauthHost)"

        [models."kimi-code/kimi-for-coding"]
        provider = "managed:kimi-code"
        model = "kimi-for-coding"
        max_context_size = 262144

        """
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiSessionIsolationTests-\(UUID().uuidString)", isDirectory: true)
        kimiHome = root.appendingPathComponent("kimi-code", isDirectory: true)
        try write(Self.config(), to: kimiHome.appendingPathComponent("config.toml"))
        try write(#"{"access_token":"live","refresh_token":"refresh-live","expires_at":1900000000}"#,
                  to: kimiHome.appendingPathComponent("credentials/\(Self.liveName).json"))
        try write("{}", to: kimiHome.appendingPathComponent("credentials/other.json"))
        try write("{}\n", to: kimiHome.appendingPathComponent("session_index.jsonl"))
        try write("{}\n", to: kimiHome.appendingPathComponent("sessions/s-1/wire.jsonl"))
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
        KimiSessionIsolation(home: kimiHome, lockWait: lockWait)
    }

    /// A stored credential as `KimiService` keeps it, with a refresh token
    /// the slot must never receive.
    private func stored(_ access: String, expiresAt: Double = 1_900_000_000.75, expiresIn: Double = 900) -> String {
        #"{"access_token":"\#(access)","refresh_token":"refresh-\#(access)","expires_at":\#(expiresAt),"expires_in":\#(expiresIn),"scope":"kimi-code","token_type":"Bearer"}"#
    }

    private func object(_ credential: SlotCredential) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credential.contents.utf8)) as? [String: Any])
    }

    /// Every file under Kimi Code's home with its contents, for comparing
    /// what a removal left.
    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: kimiHome, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[String(url.resolvingSymlinksInPath().path.dropFirst(kimiHome.resolvingSymlinksInPath().path.count))] = try Data(contentsOf: url)
        }
        return files
    }

    // MARK: Credential name and spellings

    /// Names Kimi Code 2.6.1 read in a scratch home for these pairs.
    func testTheCredentialNameIsTheOneKimiCodeDerives() {
        typealias K = KimiSessionIsolation
        XCTAssertEqual(K.credentialName(oauthHost: "https://auth.kimi.com", baseURL: "http://127.0.0.1:18765/coding/v1"),
                       "kimi-code-env-cd7f2a44eee9aa1a")
        XCTAssertEqual(K.credentialName(oauthHost: "https://auth.kimi.com/", baseURL: "http://127.0.0.1:18765/coding/v1/"),
                       "kimi-code-env-cd7f2a44eee9aa1a", "trailing slashes are removed")
        XCTAssertEqual(K.credentialName(oauthHost: "https://auth.kimi.com", baseURL: "http://LocalHost:18765/coding/v1"),
                       "kimi-code-env-4c985a707aed11eb")
        XCTAssertEqual(K.credentialName(oauthHost: "https://auth.kimi.ai", baseURL: "http://LOCALHOST:18765/coding/v1"),
                       "kimi-code-env-da9ed4f6e0787ac0")
        XCTAssertEqual(K.credentialName(oauthHost: "https://auth.kimi.com", baseURL: "https://api.kimi.com/coding/v1"), "kimi-code")
    }

    func testEverySpellingIsDistinctAndNoneIsKimisOwn() {
        typealias K = KimiSessionIsolation
        XCTAssertEqual(K.spelling(of: Self.baseURL, number: 1), "https://Api.kimi.ai/coding/v1")
        XCTAssertEqual(K.spelling(of: Self.baseURL, number: 511), "https://API.KIMI.AI/coding/v1")
        XCTAssertNil(K.spelling(of: Self.baseURL, number: 512), "api.kimi.ai has 9 letters")
        XCTAssertNil(K.spelling(of: Self.baseURL, number: 0))
        XCTAssertNil(K.spelling(of: "http://127.0.0.1:1/coding/v1", number: 1), "a host without letters has no spelling")
        let spellings = (1...511).compactMap { K.spelling(of: Self.baseURL, number: $0) }
        XCTAssertEqual(Set(spellings).count, 511)
        XCTAssertTrue(spellings.allSatisfy { K.isSlotSpelling($0) && K.canonicalBaseURL($0) == Self.baseURL })
        let names = Set(spellings.map { K.credentialName(oauthHost: Self.oauthHost, baseURL: $0) })
        XCTAssertEqual(names.count, 511)
        XCTAssertFalse(names.contains(Self.liveName))
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("kimi-code-env-") })
        XCTAssertEqual(K.spelling(of: "https://api.kimi.ai:443/coding/v1", number: 3), "https://APi.kimi.ai:443/coding/v1")
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
        try write("#!/bin/sh\nprintf '%s|%s|%s|%s' \"${ACCOUNTDOCK_KIMI_SLOT:-}\" \"${KIMI_CODE_BASE_URL:-}\" \"${KIMI_CODE_OAUTH_HOST:-}\" \"$*\"\n",
                  to: real)
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
        func expected(_ slot: URL, _ arguments: String) throws -> String {
            let selector = try XCTUnwrap(isolation.selector(in: slot))
            return "\(slot.path)|\(selector.baseURL)|\(selector.oauthHost)|\(arguments)"
        }

        // Sign-in, account and configuration commands run the real CLI
        // unchanged, on Kimi Code's own credential.
        for command in [["login"], ["logout"], ["provider", "list"], ["doctor"], ["session", "list"], ["export", "s-9"]] {
            XCTAssertEqual(try launch(command), "|||" + command.joined(separator: " "), command.joined(separator: " "))
        }
        XCTAssertEqual(try launch(["-p", "hi"], environment: ["KIMI_CODE_HOME": "/elsewhere"]), "|||-p hi")
        XCTAssertEqual(try launch(["-p", "hi"], environment: ["KIMI_MODEL_NAME": "m"]), "|||-p hi")
        XCTAssertEqual(try launch(["-p", "hi"], environment: ["KIMI_CODE_BASE_URL": "https://API.kimi.ai/coding/v1"]),
                       "|https://API.kimi.ai/coding/v1||-p hi", "a launch inside a slot's session stays on that slot")

        // A session resumed by ID goes back to the account its history ran
        // on, by either spelling of the option.
        slots.writeResumes([(session: "s-1", path: slots.directory(for: other).path)])
        XCTAssertEqual(try launch(["-S", "s-1"]), try expected(otherSpare, "-S s-1"))
        let again = try XCTUnwrap(slots.makeSlot(for: other, credential: otherCredential))
        XCTAssertEqual(try launch(["--session=s-1"]), try expected(again, "--session=s-1"))

        // A new session claims a spare of the pool's account.
        XCTAssertEqual(try launch(["-y"]), try expected(spare, "-y"))

        // A spare whose pair cannot be read runs the CLI unchanged.
        let broken = try XCTUnwrap(slots.makeSlot(for: account, credential: credential))
        try FileManager.default.removeItem(at: broken.appendingPathComponent(KimiSessionIsolation.baseURLFile))
        XCTAssertEqual(try launch(["-y"]), "|||-y")

        // Each kimi process is mapped to the slot its environment names; a
        // process on Kimi Code's own credential reads no slot.
        let list = """
          321     1 /Users/me/.kimi-code/bin/kimi -S s-1 ACCOUNTDOCK_KIMI_SLOT=\(otherSpare.path) KIMI_CODE_BASE_URL=https://API.kimi.ai/coding/v1 HOME=/x
          322     1 /Users/me/.kimi-code/bin/kimi -y HOME=/x
          323     1 /Users/me/.kimi-code/bin/kimi KIMI_CODE_BASE_URL=https://api.kimi.ai/coding/v1 HOME=/x
          324     1 /Users/me/.kimi-code/bin/kimi -y ACCOUNTDOCK_KIMI_SLOT=\(spare.path)
        """
        XCTAssertEqual(slots.directoriesByProcess(inProcessList: list), [321: otherSpare.path, 324: spare.path])
    }

    func testASessionStartedOnASlotSetsItsPair() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let assignments = isolation.launchAssignments(forSlot: slot)
        XCTAssertEqual(assignments.map { $0.name }, ["ACCOUNTDOCK_KIMI_SLOT", "KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST"])
        XCTAssertEqual(assignments.map { $0.value }, [slot.path, "https://Api.kimi.ai/coding/v1", Self.oauthHost])
    }

    // MARK: Slot

    func testASlotHoldsOnlyItsPairAndItsCredentialLivesInKimisHome() throws {
        let isolation = isolation()
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try isolation.prepareSlot(first)
        try isolation.prepareSlot(second)
        try isolation.prepareSlot(first)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: first.path)), ["base-url", "oauth-host"])
        let slotMode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions]
        XCTAssertEqual((slotMode as? NSNumber)?.intValue, 0o700)
        let firstSelector = try XCTUnwrap(isolation.selector(in: first))
        let secondSelector = try XCTUnwrap(isolation.selector(in: second))
        XCTAssertEqual(firstSelector.baseURL, "https://Api.kimi.ai/coding/v1", "preparing again keeps the slot's spelling")
        XCTAssertEqual(secondSelector.baseURL, "https://aPi.kimi.ai/coding/v1", "a second slot takes the next free spelling")
        XCTAssertEqual(firstSelector.oauthHost, Self.oauthHost)

        let file = try XCTUnwrap(isolation.credentialFile(in: first))
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path,
                       kimiHome.appendingPathComponent("credentials").standardizedFileURL.path)
        XCTAssertEqual(file.deletingPathExtension().lastPathComponent,
                       KimiSessionIsolation.credentialName(oauthHost: Self.oauthHost, baseURL: firstSelector.baseURL))
        XCTAssertNotEqual(isolation.credentialFile(in: first), isolation.credentialFile(in: second))
        XCTAssertEqual(isolation.readCredential(in: first), SlotCredential(contents: ""), "claimed empty until written")
        XCTAssertEqual(try String(contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8), Self.config(),
                       "preparing a slot leaves config.toml alone")
    }

    func testASpellingWhoseCredentialExistsIsSkipped() throws {
        let isolation = isolation()
        let taken = KimiSessionIsolation.credentialName(oauthHost: Self.oauthHost, baseURL: "https://Api.kimi.ai/coding/v1")
        try write("{}", to: kimiHome.appendingPathComponent("credentials/\(taken).json"))
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        XCTAssertEqual(isolation.selector(in: slot)?.baseURL, "https://aPi.kimi.ai/coding/v1")
        XCTAssertEqual(try String(contentsOf: kimiHome.appendingPathComponent("credentials/\(taken).json"), encoding: .utf8), "{}")
    }

    func testASlotNeedsAManagedProviderAndFollowsTheRegionWhileTheBaseURLIsLocal() throws {
        let isolation = isolation()
        try write(Self.config(baseURL: "http://127.0.0.1:43521/__provider/kimi"), to: kimiHome.appendingPathComponent("config.toml"))
        XCTAssertEqual(isolation.sharedEndpoints()?.baseURL, Self.baseURL)
        try write("default_model = \"x\"\n", to: kimiHome.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try isolation.prepareSlot(root.appendingPathComponent("slot", isDirectory: true)))
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
        let file = try XCTUnwrap(isolation.credentialFile(in: slot))
        let name = file.deletingPathExtension().lastPathComponent

        let first = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        XCTAssertTrue(isolation.writeCredential(first, to: slot))
        let firstInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        let second = try XCTUnwrap(isolation.slotCredential(from: stored("b2")))
        XCTAssertTrue(isolation.writeCredential(second, to: slot))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(attributes[.systemFileNumber] as? Int, firstInode, "replaced by a rename, not rewritten in place")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)),
                       ["\(Self.liveName).json", "other.json", "\(name).json"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), second.contents)
        XCTAssertEqual(isolation.readCredential(in: slot), second)

        // Kimi Code's lock target for that name exists, as Kimi Code
        // creates it, and the lock is released.
        let lock = KimiCredentialLock(home: kimiHome, name: name)
        XCTAssertEqual(lock.directory.path, kimiHome.appendingPathComponent("oauth/\(name).lock").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kimiHome.appendingPathComponent("oauth/\(name)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.directory.path))
    }

    func testTheWriteWaitsForAFreshLockHeldByKimi() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let name = try XCTUnwrap(isolation.credentialFile(in: slot)).deletingPathExtension().lastPathComponent
        let lock = KimiCredentialLock(home: kimiHome, name: name)
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
        XCTAssertEqual(isolation.readCredential(in: slot), SlotCredential(contents: ""),
                       "nothing is written while Kimi Code holds the lock")
        lock.release()
        wait(for: [written], timeout: 5)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(isolation.readCredential(in: slot), credential)
    }

    func testALockKeptFreshPastTheWaitLeavesTheSlotAsItIs() throws {
        let isolation = isolation(lockWait: 0.3)
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let name = try XCTUnwrap(isolation.credentialFile(in: slot)).deletingPathExtension().lastPathComponent
        let lock = KimiCredentialLock(home: kimiHome, name: name)
        XCTAssertTrue(lock.acquire(waitingUpTo: 0))
        defer { lock.release() }
        XCTAssertFalse(isolation.writeCredential(try XCTUnwrap(isolation.slotCredential(from: stored("a1"))), to: slot))
        XCTAssertEqual(isolation.readCredential(in: slot), SlotCredential(contents: ""))
    }

    func testAStaleLockIsTakenOver() throws {
        let isolation = isolation(lockWait: 0)
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(slot)
        let name = try XCTUnwrap(isolation.credentialFile(in: slot)).deletingPathExtension().lastPathComponent
        let lock = KimiCredentialLock(home: kimiHome, name: name)
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

    // MARK: Removal

    func testRemovingASlotDeletesOnlyItsOwnCredentialFromKimisHome() throws {
        let isolation = isolation()
        let slots = SessionSlots(isolation: isolation, home: root.appendingPathComponent("home", isDirectory: true))
        let credential = try XCTUnwrap(isolation.slotCredential(from: stored("a1")))
        let removed = try XCTUnwrap(slots.makeSlot(for: UUID(), credential: credential))
        let kept = try XCTUnwrap(slots.makeSlot(for: UUID(), credential: credential))
        let removedFile = try XCTUnwrap(isolation.credentialFile(in: removed))
        let before = try snapshot()

        slots.remove(removed)

        var expected = before
        expected["/credentials/\(removedFile.lastPathComponent)"] = nil
        XCTAssertEqual(try snapshot(), expected, "nothing else in Kimi Code's home changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertEqual(isolation.readCredential(in: kept), credential)

        // A removed slot leaves its spelling free for the next one.
        let next = try XCTUnwrap(slots.makeSlot(for: UUID(), credential: credential))
        XCTAssertEqual(isolation.credentialFile(in: next), removedFile)
    }

    func testRemovingASlotKeepsACredentialConfigTomlStillNames() throws {
        let isolation = isolation()
        let slots = SessionSlots(isolation: isolation, home: root.appendingPathComponent("home", isDirectory: true))
        let slot = try XCTUnwrap(slots.makeSlot(for: UUID(), credential: try XCTUnwrap(isolation.slotCredential(from: stored("a1")))))
        let file = try XCTUnwrap(isolation.credentialFile(in: slot))
        let selector = try XCTUnwrap(isolation.selector(in: slot))
        // config.toml names the slot's spelling, and the file under that
        // name holds a refresh token, so it is not put back.
        try write(Self.config(baseURL: selector.baseURL, key: "oauth/" + file.deletingPathExtension().lastPathComponent),
                  to: kimiHome.appendingPathComponent("config.toml"))
        try write(stored("signed-in"), to: file)

        slots.remove(slot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRemovalLeavesAnythingButADerivedCredentialAlone() throws {
        let isolation = isolation()
        let slot = root.appendingPathComponent("slot", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let before = try snapshot()
        // A slot naming Kimi Code's own spelling has no credential of its own.
        try write(Self.baseURL, to: slot.appendingPathComponent("base-url"))
        try write(Self.oauthHost, to: slot.appendingPathComponent("oauth-host"))
        isolation.removeSlot(slot)
        XCTAssertNil(isolation.credentialFile(in: slot))
        XCTAssertEqual(try snapshot(), before)
    }

    // MARK: config.toml written by a slot's session

    func testConfigTomlIsPutBackAfterASlotsSessionWroteItsSpelling() throws {
        let isolation = isolation()
        let spelling = "https://API.kimi.ai/coding/v1"
        let slotName = KimiSessionIsolation.credentialName(oauthHost: Self.oauthHost, baseURL: spelling)
        try write(#"{"access_token":"a1","refresh_token":"","expires_at":1900000000}"#,
                  to: kimiHome.appendingPathComponent("credentials/\(slotName).json"))
        try write(Self.config(baseURL: spelling, key: "oauth/" + slotName), to: kimiHome.appendingPathComponent("config.toml"))
        XCTAssertEqual(isolation.configuredCredentialNames(), [slotName])

        isolation.restoreSharedState()
        XCTAssertEqual(try String(contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8), Self.config(),
                       "base_url and key go back, and everything else stays as written")
        XCTAssertEqual(isolation.configuredCredentialNames(), [Self.liveName])

        // Kimi Code's own spelling is left alone.
        let backup = kimiHome.appendingPathComponent("config.toml.accountdock-hooks-backup")
        try? FileManager.default.removeItem(at: backup)
        isolation.restoreSharedState()
        XCTAssertEqual(try String(contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8), Self.config())
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testASignInMadeWithAnUpperCaseSpellingIsLeftAlone() throws {
        let isolation = isolation()
        let spelling = "https://API.kimi.ai/coding/v1"
        let name = KimiSessionIsolation.credentialName(oauthHost: Self.oauthHost, baseURL: spelling)
        try write(stored("signed-in"), to: kimiHome.appendingPathComponent("credentials/\(name).json"))
        let config = Self.config(baseURL: spelling, key: "oauth/" + name)
        try write(config, to: kimiHome.appendingPathComponent("config.toml"))
        isolation.restoreSharedState()
        XCTAssertEqual(try String(contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8), config)
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
            ACCOUNTDOCK_KIMI_SLOT=$spare
            KIMI_CODE_BASE_URL=$(cat "$spare/base-url" 2>/dev/null) || exec "$real" "$@"
            KIMI_CODE_OAUTH_HOST=$(cat "$spare/oauth-host" 2>/dev/null) || exec "$real" "$@"
            [ -n "$KIMI_CODE_BASE_URL" ] && [ -n "$KIMI_CODE_OAUTH_HOST" ] || exec "$real" "$@"
            export ACCOUNTDOCK_KIMI_SLOT KIMI_CODE_BASE_URL KIMI_CODE_OAUTH_HOST
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
    ACCOUNTDOCK_KIMI_SLOT=$slot
    KIMI_CODE_BASE_URL=$(cat "$slot/base-url" 2>/dev/null) || exec "$real" "$@"
    KIMI_CODE_OAUTH_HOST=$(cat "$slot/oauth-host" 2>/dev/null) || exec "$real" "$@"
    [ -n "$KIMI_CODE_BASE_URL" ] && [ -n "$KIMI_CODE_OAUTH_HOST" ] || exec "$real" "$@"
    export ACCOUNTDOCK_KIMI_SLOT KIMI_CODE_BASE_URL KIMI_CODE_OAUTH_HOST
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
