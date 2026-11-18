import XCTest
@testable import AccountDock

/// A CLI that keeps a slot's credential in a file inside the slot, named by
/// no provider, so `SessionSlots` names the provider by the slot's account.
private struct RemovalFakeIsolation: ProviderSessionIsolation {
    let executable = "removalfakecli"
    let directoryVariable = "REMOVALFAKE_HOME"
    let passThroughVariables: [String] = []
    let passThroughCommands: [String] = []
    let background: BackgroundSessionSupport? = nil
    let installDirectories: [String] = []
    let preferredExecutable: String? = nil
    let resumeArgumentScript = ""
    let keepRunningKey = "n"

    func resumeCommand(sessionID: String) -> String { "removalfakecli \(sessionID)" }
    func screenReportsRunningWork(_ screen: String) -> Bool { false }
    func screenAsksAboutRunningWork(_ screen: String) -> Bool { false }
    func slotCredential(from credential: String) -> SlotCredential? { SlotCredential(contents: credential) }

    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? { nil }

    func prepareSlot(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        (try? Data(credential.contents.utf8).write(to: directory.appendingPathComponent("credential.json"), options: .atomic)) != nil
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        (try? String(contentsOf: directory.appendingPathComponent("credential.json"), encoding: .utf8))
            .map(SlotCredential.init(contents:))
    }

    func removeSlot(_ directory: URL) {}
    func signalReread(_ directory: URL) {}
}

/// A claimed slot is removed as gone only on evidence that its session
/// ended, and a slot a running process still names is made again: a
/// process list cut short names no process, which would read as every
/// running session having ended and delete each one's slot under it.
final class SlotRemovalTests: XCTestCase {
    private var root: URL!
    private var audit: CredentialAudit!
    private let alpha = UUID()
    private let beta = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlotRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audit = CredentialAudit(directory: root.appendingPathComponent("Logs", isDirectory: true))
        audit.updateAccounts([
            .init(id: alpha, provider: .claudeCode, label: "Alpha", email: "alpha@example.com", isActive: true),
            .init(id: beta, provider: .claudeCode, label: "Beta", email: "beta@example.com", isActive: false),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var slots: SessionSlots {
        SessionSlots(isolation: RemovalFakeIsolation(), home: root.appendingPathComponent("home"), audit: audit)
    }

    // MARK: - The scan

    func testAScanIsWholeOnlyWhenItListsProcessesAndAccountDocksOwn() {
        XCTAssertFalse(AppState.processScanSucceeded(ProcessTable(entries: []), ownPID: 50))
        let others = ProcessTable(entries: [.init(pid: 1, command: "/sbin/launchd"), .init(pid: 7, command: "claude")])
        XCTAssertFalse(AppState.processScanSucceeded(others, ownPID: 50), "a list without AccountDock's own process is cut short")
        let whole = ProcessTable(entries: others.entries + [.init(pid: 50, command: "AccountDock")])
        XCTAssertTrue(AppState.processScanSucceeded(whole, ownPID: 50))
    }

    // MARK: - Removal needs evidence

    func testAFailedScanKeepsEveryClaimedSlot() {
        let blocker = AppState.sessionGoneBlocker(scanSucceeded: false, readers: [], stillRuns: { _ in false })
        XCTAssertNotNil(blocker)
        XCTAssertTrue(blocker?.contains("could not be read") == true)
    }

    func testASlotWhoseReaderStillRunsIsKeptAlthoughTheScanMissedIt() {
        let readers = [AppState.SlotReader(pid: 3425, startedAt: nil), AppState.SlotReader(pid: 46941, startedAt: nil)]
        let blocker = AppState.sessionGoneBlocker(scanSucceeded: true, readers: readers, stillRuns: { $0.pid == 46941 })
        XCTAssertEqual(blocker, "process 46941, seen reading it, still runs")
    }

    func testASlotIsRemovedOnceTheScanIsWholeAndEveryReaderEnded() {
        let readers = [AppState.SlotReader(pid: 3425, startedAt: nil)]
        XCTAssertNil(AppState.sessionGoneBlocker(scanSucceeded: true, readers: readers, stillRuns: { _ in false }))
        XCTAssertNil(AppState.sessionGoneBlocker(scanSucceeded: true, readers: [], stillRuns: { _ in true }),
                     "a slot no process was ever seen reading goes after a whole scan, as before")
    }

    func testAReaderRunsWhileItsProcessIDIsAliveWithTheSameStart() {
        let started = Date(timeIntervalSince1970: 1_000)
        let reader = AppState.SlotReader(pid: 77, startedAt: started)
        XCTAssertFalse(AppState.readerRuns(reader, isAlive: { _ in false }, startTime: { _ in started }))
        XCTAssertTrue(AppState.readerRuns(reader, isAlive: { _ in true }, startTime: { _ in started }))
        XCTAssertFalse(AppState.readerRuns(reader, isAlive: { _ in true }, startTime: { _ in started.addingTimeInterval(600) }),
                       "a later process given the same ID is not the reader")
        XCTAssertTrue(AppState.readerRuns(AppState.SlotReader(pid: 77, startedAt: nil), isAlive: { _ in true },
                                          startTime: { _ in nil }))
    }

    func testReadersFollowTheScanAndKeepThoseStillRunningForASlotTheScanMissed() {
        let previous: [String: [AppState.SlotReader]] = [
            "/s/A": [.init(pid: 1, startedAt: nil)],
            "/s/B": [.init(pid: 2, startedAt: nil), .init(pid: 3, startedAt: nil)],
            "/s/C": [.init(pid: 4, startedAt: nil)],
        ]
        let started = Date(timeIntervalSince1970: 5)
        let readers = AppState.slotReaders(previous: previous, byProcess: [9: "/s/A", 8: "/s/D"], startedAt: [9: started],
                                           stillRuns: { $0.pid == 3 })
        XCTAssertEqual(readers["/s/A"], [.init(pid: 9, startedAt: started)], "a slot read now has the readers seen now")
        XCTAssertEqual(readers["/s/B"], [.init(pid: 3, startedAt: nil)], "a missed slot keeps the readers still running")
        XCTAssertNil(readers["/s/C"], "a slot whose readers all ended has none")
        XCTAssertEqual(readers["/s/D"], [.init(pid: 8, startedAt: nil)])
    }

    // MARK: - Restoring a slot a running process names

    func testOnlyMissingOneSessionSlotsAreRestored() throws {
        let slots = slots
        let present = slots.sessionRoot.appendingPathComponent(UUID().uuidString).path
        let missing = slots.sessionRoot.appendingPathComponent(UUID().uuidString).path
        let byProcess: [Int32: String] = [
            1: present, 2: missing, 3: missing, 4: slots.directory(for: alpha).path, 5: slots.sessionRoot.path + "/x",
        ]
        XCTAssertEqual(AppState.missingSlots(byProcess: byProcess, present: [present], isSessionSlot: { slots.isSessionSlot($0) }),
                       [missing])
    }

    func testARestoredSlotServesTheAccountItWasOnBeforeItsPinAndThePool() {
        XCTAssertEqual(AppState.restoredSlotAccounts(history: alpha, serving: alpha, audit: beta, pinned: beta, fallback: nil),
                       [alpha, beta])
        XCTAssertEqual(AppState.restoredSlotAccounts(history: nil, serving: nil, audit: nil, pinned: beta, fallback: alpha),
                       [beta, alpha])
        XCTAssertEqual(AppState.restoredSlotAccounts(history: nil, serving: nil, audit: nil, pinned: nil, fallback: nil), [])
    }

    func testRestoringRecreatesTheClaimedSlotAtItsPathWithItsCredentialAndRecordsIt() throws {
        let slots = slots
        let directory = slots.sessionRoot.appendingPathComponent("07314A9F-EA79-4DA9-9B1C-FCF5103E425A", isDirectory: true)
        let credential = SlotCredential(contents: #"{"claudeAiOauth":{"accessToken":"restored-token"}}"#)
        XCTAssertTrue(slots.restoreClaimedSlot(directory, account: alpha, credential: credential,
                                               reason: "serveSessionSlots.restore", session: "341e5695", process: 3425))
        XCTAssertEqual(slots.isolation.readCredential(in: directory), credential)
        let listed = try XCTUnwrap(slots.sessionSlots().first { $0.directory.path == directory.path })
        XCTAssertNotNil(listed.claimedAt, "claimed, so no launcher hands it to a new session")
        XCTAssertEqual(listed.account, alpha)
        let entries = audit.entries().filter { $0.slot == directory.path && $0.reason == "serveSessionSlots.restore" }
        XCTAssertEqual(Set(entries.map(\.action)), [.slotWrite, .slotAssign])
        XCTAssertTrue(entries.allSatisfy { $0.session == "341e5695" && $0.process == 3425 })

        XCTAssertFalse(slots.restoreClaimedSlot(directory, account: beta, credential: credential, reason: "test.again"),
                       "a slot on disk is not made again")
        XCTAssertFalse(slots.restoreClaimedSlot(slots.directory(for: alpha), account: alpha, credential: credential,
                                                reason: "test.notSessionSlot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: slots.directory(for: alpha).path))
    }

    func testTheAuditNamesTheAccountEachSlotWasLastOn() {
        let first = "/home/.accountdock/claude-slots/session/07314A9F-EA79-4DA9-9B1C-FCF5103E425A"
        let second = "/home/.accountdock/claude-slots/session/24EAD119-92EA-4E26-94AA-CA32BEDAEB86"
        audit.record(.slotAssign, .claudeCode, account: beta, outcome: "ok", reason: "test.assign", slot: first)
        audit.record(.slotAssign, .claudeCode, account: alpha, outcome: "ok", reason: "test.move", slot: first)
        audit.record(.slotRemove, .claudeCode, account: alpha, outcome: "ok", reason: "serveSessionSlots.sessionGone", slot: first)
        audit.record(.slotWrite, .claudeCode, account: beta, outcome: "ok", reason: "test.write", slot: second)
        audit.record(.served, .claudeCode, account: alpha, outcome: "ok", reason: "test.served", slot: second)
        let found = audit.lastSlotAccounts([first, second, "/home/.accountdock/claude-slots/session/none"])
        XCTAssertEqual(found, [first: alpha, second: beta])
    }

    func testOnlyAnIsolationThatReadsItsCredentialByPathRestoresInPlace() throws {
        XCTAssertTrue(try XCTUnwrap(AIProviderType.claudeCode.capabilities.sessionIsolation).restoresRemovedSlot)
        XCTAssertTrue(try XCTUnwrap(AIProviderType.codex.capabilities.sessionIsolation).restoresRemovedSlot)
        XCTAssertFalse(try XCTUnwrap(AIProviderType.kimi.capabilities.sessionIsolation).restoresRemovedSlot)
    }
}
