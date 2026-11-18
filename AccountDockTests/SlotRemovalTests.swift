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

    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// A claimed slot no process read for `idle` seconds.
    private func evidence(scanSucceeded: Bool = true, readers: [AppState.SlotReader] = [],
                          registered: [CLISessionRegistry.Entry] = [], pinned: Bool = false,
                          idle: TimeInterval = 10 * 60) -> AppState.SlotGoneEvidence {
        AppState.SlotGoneEvidence(scanSucceeded: scanSucceeded, readers: readers, registered: registered, pinned: pinned,
                                  idleSince: now.addingTimeInterval(-idle), grace: AppState.slotClaimGrace)
    }

    private func keep(_ evidence: AppState.SlotGoneEvidence, stillRuns: @escaping (AppState.SlotReader) -> Bool = { _ in false },
                      registryRuns: @escaping (CLISessionRegistry.Entry) -> Bool = { _ in false }) -> AppState.SlotKeep? {
        AppState.sessionGoneBlocker(evidence, now: now, stillRuns: stillRuns, registryRuns: registryRuns)
    }

    func testASlotStaysWithinItsGraceSinceItWasLastRead() {
        XCTAssertEqual(keep(evidence(idle: 60)), .withinGrace)
        XCTAssertNil(keep(evidence(idle: AppState.slotClaimGrace + 1)))
    }

    func testAFailedScanKeepsEveryClaimedSlot() {
        guard case .held(let reason) = keep(evidence(scanSucceeded: false)) else { return XCTFail("kept") }
        XCTAssertTrue(reason.contains("could not be read"))
    }

    func testASlotWhoseReaderStillRunsIsKeptAlthoughTheScanMissedIt() {
        let readers = [AppState.SlotReader(pid: 3425, startedAt: nil), AppState.SlotReader(pid: 85569, startedAt: nil)]
        XCTAssertEqual(keep(evidence(readers: readers), stillRuns: { $0.pid == 85569 }),
                       .held("process 85569, seen reading it, still runs"))
    }

    func testASlotIsRemovedOnceTheScanIsWholeAndEveryReaderEnded() {
        XCTAssertNil(keep(evidence(readers: [AppState.SlotReader(pid: 3425, startedAt: nil)])))
        XCTAssertNil(keep(evidence(), stillRuns: { _ in true }),
                     "a slot no process was ever seen reading goes after a whole scan")
    }

    func testTheRegistryListingALiveProcessWithTheSlotsSessionKeepsIt() {
        let entry = CLISessionRegistry.Entry(pid: 3425, sessionID: "341e5695-0000", workingDirectory: nil, startedAt: nil,
                                             busy: nil)
        XCTAssertEqual(keep(evidence(registered: [entry]), registryRuns: { $0.pid == 3425 }),
                       .held("the CLI's registry lists process 3425 with its session 341e5695"))
        XCTAssertNil(keep(evidence(registered: [entry])), "an entry whose process ended is no evidence")
    }

    func testAPinnedSessionsSlotWaitsTheLongerGrace() {
        guard case .held(let reason) = keep(evidence(pinned: true, idle: 30 * 60)) else { return XCTFail("kept") }
        XCTAssertTrue(reason.contains("pinned"))
        XCTAssertNil(keep(evidence(pinned: true, idle: AppState.pinnedClaimGrace + 1)))
        XCTAssertGreaterThan(AppState.pinnedClaimGrace, AppState.requestedClaimGrace)
    }

    func testRegistryEntriesRunWhileTheirProcessStartedWhenTheEntrySays() {
        let listed = Date(timeIntervalSince1970: 1_000)
        let entry = CLISessionRegistry.Entry(pid: 9, sessionID: "s", workingDirectory: nil, startedAt: listed, busy: nil)
        XCTAssertFalse(AppState.registryEntryRuns(entry, isAlive: { _ in false }, startTime: { _ in listed }))
        XCTAssertTrue(AppState.registryEntryRuns(entry, isAlive: { _ in true }, startTime: { _ in listed.addingTimeInterval(3) }))
        XCTAssertFalse(AppState.registryEntryRuns(entry, isAlive: { _ in true },
                                                  startTime: { _ in listed.addingTimeInterval(3_600) }),
                       "a later process given the same ID is not the entry's")
    }

    func testOnlyRegisteredProcessesWhoseEnvironmentWasNotReadSpeakForASlot() {
        let table = ProcessTable(entries: [
            .init(pid: 1, command: "claude", environment: "HOME=/Users/u"),
            .init(pid: 2, command: "claude"),
        ])
        XCTAssertEqual(AppState.unreadProcesses([1, 2, 3], table: table), [2, 3])
    }

    // MARK: - One pass removes only a few

    func testOnePassRemovesUpToTheLimitAndHoldsBackMore() {
        let few = ["/s/a", "/s/b", "/s/c"]
        XCTAssertEqual(AppState.goneRemovals(few, heldSince: nil, now: now).remove, few)
        let many = (0..<10).map { "/s/\($0)" }
        let first = AppState.goneRemovals(many, heldSince: nil, now: now)
        XCTAssertEqual(first.remove, [], "ten slots seeming gone at once are removed by no pass")
        XCTAssertEqual(first.heldSince, now)
        XCTAssertTrue(first.started)
        let later = AppState.goneRemovals(many, heldSince: now, now: now.addingTimeInterval(60))
        XCTAssertEqual(later.remove, [])
        XCTAssertFalse(later.started)
        let after = AppState.goneRemovals(many, heldSince: now, now: now.addingTimeInterval(AppState.massRemovalHold))
        XCTAssertEqual(after.remove.count, AppState.maximumGoneRemovals, "once they stay unread, a few go each pass")
        XCTAssertNil(AppState.goneRemovals(few, heldSince: now, now: now).heldSince, "the hold ends once few stand")
    }

    func testAccountDocksOwnProcessReadsNoSlot() {
        XCTAssertEqual(AppState.processSlotDirectories([3425: "/s/A", 46941: "/s/A", 7: "/s/B"], ownPID: 46941),
                       [3425: "/s/A", 7: "/s/B"])
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
