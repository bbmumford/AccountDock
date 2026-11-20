import XCTest
@testable import AccountDock

/// A CLI keeping a slot's credential in a file inside the slot, so removing
/// a slot touches nothing outside the test's directory.
private struct ReclaimFakeIsolation: ProviderSessionIsolation {
    let executable = "reclaimfakecli"
    let directoryVariable = "RECLAIMFAKE_HOME"
    let passThroughVariables: [String] = []
    let passThroughCommands: [String] = []
    let background: BackgroundSessionSupport? = nil
    let installDirectories: [String] = []
    let preferredExecutable: String? = nil
    let resumeArgumentScript = ""
    let keepRunningKey = "n"

    func resumeCommand(sessionID: String) -> String { "reclaimfakecli \(sessionID)" }
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

/// A session slot whose session has ended is offered back to that session
/// for an hour: its slot records the session, the resume file names the
/// slot for it, and one rename decides whether a launcher or AccountDock
/// has it.
final class SlotReclaimTests: XCTestCase {
    private var root: URL!
    private var audit: CredentialAudit!
    private let alpha = UUID()
    private let beta = UUID()
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SlotReclaimTests-\(UUID().uuidString)",
                                                                             isDirectory: true)
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
        SessionSlots(isolation: ReclaimFakeIsolation(), home: root.appendingPathComponent("home"), audit: audit)
    }

    private func claimedSlot() throws -> URL {
        let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(SessionSlots.claimedMarker),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(slots.assign(directory, to: alpha, reason: "test"))
        return directory
    }

    func testASlotRecordsTheSessionReadingItAndItsFolder() throws {
        let directory = try claimedSlot()
        XCTAssertTrue(slots.recordSession("341e5695-45ad", folder: "/Users/a/ORBTR", in: directory))
        let slot = try XCTUnwrap(slots.sessionSlots().first)
        XCTAssertEqual(slot.session, "341e5695-45ad")
        XCTAssertEqual(slot.folder, "/Users/a/ORBTR")
        XCTAssertTrue(slots.recordSession("8c64c5f8", folder: nil, in: directory), "a later session replaces it")
        XCTAssertEqual(slots.sessionSlots().first?.session, "8c64c5f8")
        XCTAssertNil(slots.sessionSlots().first?.folder)
        XCTAssertFalse(slots.recordSession("x", folder: nil, in: slots.directory(for: alpha)), "only a session slot")
        XCTAssertFalse(slots.recordSession("a\tb", folder: nil, in: directory))
        XCTAssertNil(SessionSlots.recordedSession(""))
        XCTAssertEqual(SessionSlots.recordedSession("id\nrelative/folder\n")?.folder, nil, "a folder is a full path")
    }

    func testOneRenameDecidesWhetherTheLauncherOrAccountDockHasAnOfferedSlot() throws {
        let unclaimed = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unclaimed, withIntermediateDirectories: true)
        XCTAssertFalse(slots.markReclaimable(unclaimed), "a slot no launch claimed is never offered")

        let offered = try claimedSlot()
        XCTAssertTrue(slots.markReclaimable(offered))
        XCTAssertNotNil(slots.sessionSlots().first { $0.directory == offered }?.reclaimableSince)
        XCTAssertEqual(slots.directories(holding: alpha, serving: [:]), [offered.path], "an offered slot's token is kept current")
        // A launcher takes it with the same rename AccountDock would make.
        try FileManager.default.moveItem(at: offered.appendingPathComponent(SessionSlots.reclaimableMarker),
                                         to: offered.appendingPathComponent(SessionSlots.claimedMarker + "/reclaimed.1"))
        XCTAssertFalse(slots.removeReclaimable(offered, reason: "test"), "a slot a launcher took stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: offered.path))

        let retired = try claimedSlot()
        XCTAssertTrue(slots.markReclaimable(retired))
        XCTAssertTrue(slots.removeReclaimable(retired, reason: "test.retire"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertEqual(audit.entries().filter { $0.slot == retired.path && $0.reason == "test.retire" }.map(\.action), [.slotRemove])
    }

    func testATakenSlotCountsAsClaimedWhenItWasTaken() throws {
        let directory = try claimedSlot()
        let claimed = try XCTUnwrap(slots.sessionSlots().first?.claimedAt)
        let later = claimed.addingTimeInterval(3600)
        let pid = directory.appendingPathComponent(SessionSlots.claimedMarker + "/" + SessionSlots.claimerFile)
        try "123\n".write(to: pid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: pid.path)
        let taken = try XCTUnwrap(slots.sessionSlots().first?.claimedAt)
        XCTAssertEqual(taken.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 1,
                       "its grace runs from when it was taken back, not from its first claim")
    }

    func testOnlyASlotWhoseSessionEndedIsOfferedAndOnlyForAnHour() {
        func choice(knows: Bool = true, chosen: Bool = true, ended: Bool = true, account: Bool = true, inSlot: Bool = false,
                    restarting: Bool = false, since: Date? = nil) -> AppState.ReclaimChoice {
            AppState.reclaimChoice(knowsSession: knows, chosen: chosen, ended: ended, hasAccount: account, runsInSlot: inSlot,
                                   restarting: restarting, reclaimableSince: since, now: now)
        }
        XCTAssertEqual(choice(), .offer)
        XCTAssertEqual(choice(ended: false), .none, "its session may still run")
        XCTAssertEqual(choice(knows: false), .none)
        XCTAssertEqual(choice(chosen: false), .none, "another slot of the same session is offered")
        XCTAssertEqual(choice(account: false), .none)
        XCTAssertEqual(choice(inSlot: true), .none, "its session runs in another slot")
        XCTAssertEqual(choice(restarting: true), .none, "it moves to another account by its restart")
        let offered = now.addingTimeInterval(-10 * 60)
        XCTAssertEqual(choice(ended: false, since: offered), .offer, "an offer stands while it lasts")
        XCTAssertEqual(choice(since: now.addingTimeInterval(-AppState.reclaimGrace - 1)), .retire)
        XCTAssertEqual(choice(inSlot: true, since: offered), .retire)
        XCTAssertEqual(choice(knows: false, since: offered), .retire, "as when slots are no longer offered back")
    }

    func testASessionIsOfferedTheSlotItWasLastClaimedIn() {
        let older = now.addingTimeInterval(-3600)
        XCTAssertEqual(AppState.reclaimSlots([(path: "/s/A", session: "one", claimedAt: older),
                                              (path: "/s/B", session: "one", claimedAt: now),
                                              (path: "/s/C", session: "two", claimedAt: older)]),
                       ["one": "/s/B", "two": "/s/C"])
        XCTAssertEqual(AppState.reclaimSlots([(path: "/s/B", session: "one", claimedAt: now),
                                              (path: "/s/A", session: "one", claimedAt: now)]),
                       ["one": "/s/A"], "a tie goes by path")
    }

    func testASlotsSessionIsWhatItRecordsElseWhatThisRunSawElseTheAudit() {
        XCTAssertEqual(AppState.knownSlotSession(recorded: "r", statusLine: "s", seen: ["x"], audit: "a"), "r")
        XCTAssertEqual(AppState.knownSlotSession(recorded: nil, statusLine: "s", seen: ["x"], audit: "a"), "s")
        XCTAssertEqual(AppState.knownSlotSession(recorded: nil, statusLine: nil, seen: ["x"], audit: "a"), "x")
        XCTAssertEqual(AppState.knownSlotSession(recorded: nil, statusLine: nil, seen: ["x", "y"], audit: "a"), "a",
                       "several sessions seen name none of them")
        XCTAssertNil(AppState.knownSlotSession(recorded: nil, statusLine: nil, seen: [], audit: nil))
    }

    func testTheResumeFileNamesEachOfferedSlotBeforeAnyAccount() {
        let reclaim = AppState.SlotReclaim(session: "one", path: "/s/A", account: alpha, folder: "/w")
        let table = AppState.resumeTable(reclaims: [reclaim], continues: [(session: "/w", path: "/s/A")],
                                         accounts: [(session: "one", path: "/r/alpha"), (session: "two", path: "/r/beta")])
        XCTAssertEqual(table.map(\.session), ["one", "/w", "two"])
        XCTAssertEqual(table.map(\.path), ["/s/A", "/s/A", "/r/beta"])
        XCTAssertEqual(SessionSlots.resumeText(table), "one\t/s/A\n/w\t/s/A\ntwo\t/r/beta\n")
    }

    func testAContinueIsNamedOnlyWhereItsFolderIsUnambiguous() {
        func record(_ id: String, _ folder: String, _ age: TimeInterval) -> AgentSession {
            AgentSession(sessionID: id, provider: "claude", event: "Stop", workingDirectory: folder, processID: nil,
                         host: nil, observedAt: now.addingTimeInterval(-age))
        }
        let one = AppState.SlotReclaim(session: "one", path: "/s/A", account: alpha, folder: "/w/one")
        let two = AppState.SlotReclaim(session: "two", path: "/s/B", account: alpha, folder: "/w/shared")
        let three = AppState.SlotReclaim(session: "three", path: "/s/C", account: beta, folder: "/w/shared")
        let four = AppState.SlotReclaim(session: "four", path: "/s/D", account: beta, folder: "/w/newer")
        let five = AppState.SlotReclaim(session: "five", path: "/s/E", account: beta, folder: "/w/busy")
        let entries = AppState.continueEntries(
            [one, two, three, four, five],
            records: [record("one", "/w/one", 60), record("four", "/w/newer", 600), record("later", "/w/newer", 60),
                      record("five", "/w/busy", 600), record("running", "/w/busy", 6000)],
            running: ["running"]
        )
        XCTAssertEqual(entries.map(\.session), ["/w/one"])
        XCTAssertEqual(entries.map(\.path), ["/s/A"])
    }

    func testTheAuditNamesTheSessionLastWrittenToASlot() throws {
        let first = slots.sessionRoot.appendingPathComponent(UUID().uuidString).path
        let second = slots.sessionRoot.appendingPathComponent(UUID().uuidString).path
        audit.record(.slotAssign, .claudeCode, account: alpha, outcome: "ok", reason: "test", slot: first, session: "older")
        audit.record(.slotWrite, .claudeCode, account: alpha, outcome: "ok", reason: "test", slot: first, session: "newer")
        audit.record(.slotRemove, .claudeCode, account: alpha, outcome: "ok", reason: "test", slot: second)
        XCTAssertEqual(audit.lastSlotSessions([first, second]), [first: "newer"])
        XCTAssertEqual(audit.lastSlotSessions([]), [:])
    }
}
