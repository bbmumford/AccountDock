import XCTest
@testable import AccountDock

/// Sessions AccountDock has no fresh lifecycle record of, and slot processes
/// that are no session at all. The fixture is the morning the sessions
/// started at 7:53 pm the evening before had been quiet at their prompts
/// for twelve hours: their records were too old to count, so the plans
/// named them "a run in ~/…" and no pause could list them, while two
/// `claude --resume` processes that never started a session were planned
/// as runs too. The CLI's own registry (`CLISessionRegistry`) names every
/// process that holds a session.
final class QuietSessionRunsTests: XCTestCase {
    private var home: URL!
    private var records: URL { home.appendingPathComponent("Sessions") }
    private var registry: URL { home.appendingPathComponent("registry") }
    /// 8:30 am, twelve hours and 37 minutes after the sessions started.
    let now = ISO8601DateFormatter().date(from: "2026-11-16T21:30:00Z")!
    let started = ISO8601DateFormatter().date(from: "2026-11-16T08:53:29Z")!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("QuietRuns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func record(_ session: String, event: String, pid: Int32, at date: Date, folder: String) throws {
        let text = """
        {"schemaVersion":1,"provider":"claude","sessionID":"\(session)","event":"\(event)",\
        "workingDirectory":"\(folder)","processID":\(pid),"host":"cli",\
        "observedAt":"\(ISO8601DateFormatter().string(from: date))"}
        """
        try Data(text.utf8).write(to: records.appendingPathComponent("claude-\(session).json"))
    }

    private func register(_ session: String, pid: Int32, folder: String, status: String = "idle") throws {
        let text = """
        {"pid":\(pid),"sessionId":"\(session)","cwd":"\(folder)",\
        "startedAt":\(Int(started.timeIntervalSince1970 * 1000)),"kind":"interactive","status":"\(status)"}
        """
        try Data(text.utf8).write(to: registry.appendingPathComponent("\(pid).json"))
    }

    func testTheRegistryReadsEachProcessAndSkipsWhatIsNotAnEntry() throws {
        try register("5386173b", pid: 3453, folder: "/Users/u/AreaShare")
        try register("19496bb9", pid: 3901, folder: "/Users/u/ORBTR", status: "busy")
        try Data("not json".utf8).write(to: registry.appendingPathComponent("3880.json"))
        try Data("key".utf8).write(to: registry.appendingPathComponent("3880.0abc.key"))
        let entries = try XCTUnwrap(CLISessionRegistry.read(directory: registry))
        XCTAssertEqual(Set(entries.keys), [3453, 3901])
        XCTAssertEqual(entries[3453]?.sessionID, "5386173b")
        XCTAssertEqual(entries[3453]?.workingDirectory, "/Users/u/AreaShare")
        XCTAssertEqual(entries[3901]?.busy, true)
        XCTAssertEqual(entries[3453]?.startedAt?.timeIntervalSince1970 ?? 0, started.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNil(CLISessionRegistry.read(directory: home.appendingPathComponent("missing")),
                     "a CLI that keeps no registry is told apart from one with no sessions")
        XCTAssertEqual(CLISessionRegistry.directory(.claudeCode, home: home)?.path,
                       home.appendingPathComponent(".claude/sessions").path)
        XCTAssertNil(CLISessionRegistry.directory(.codex, home: home))
    }

    func testASessionQuietForTwelveHoursStaysLiveWhileTheCLINamesItsProcess() throws {
        // Quiet at their prompts since 7:53 pm: the records are 12½ hours old.
        try record("5386173b", event: "SessionStart", pid: 3453, at: started, folder: "/Users/u/AreaShare")
        try record("1603da04", event: "Stop", pid: 3077, at: started.addingTimeInterval(1800), folder: "/Users/u/Mother")
        // A recent one, and an old one whose process the registry gives
        // another session.
        try record("19496bb9", event: "UserPromptSubmit", pid: 3901, at: now.addingTimeInterval(-600), folder: "/Users/u/ORBTR")
        try record("f964a9fc", event: "Stop", pid: 17917, at: started.addingTimeInterval(-3600), folder: "/Users/u")
        try register("5386173b", pid: 3453, folder: "/Users/u/AreaShare")
        try register("1603da04", pid: 3077, folder: "/Users/u/Mother")
        try register("19496bb9", pid: 3901, folder: "/Users/u/ORBTR", status: "busy")
        let entries = try XCTUnwrap(CLISessionRegistry.read(directory: registry))
        let alive: Set<Int32> = [3453, 3077, 3901, 17917]
        let startTime: (Int32) -> Date? = { _ in self.started.addingTimeInterval(-1) }

        let without = AgentSessions.live(.claudeCode, directory: records, now: now, isAlive: alive.contains,
                                         startTime: startTime)
        XCTAssertEqual(without.map(\.sessionID), ["19496bb9"], "without the registry, only the recent record counts")

        let live = AgentSessions.live(.claudeCode, directory: records, now: now, isAlive: alive.contains,
                                      startTime: startTime, registry: entries)
        XCTAssertEqual(live.map(\.sessionID), ["1603da04", "19496bb9", "5386173b"])
        XCTAssertEqual(live.first { $0.sessionID == "5386173b" }?.workingDirectory, "/Users/u/AreaShare")
    }

    func testARegisteredProcessWithNoRecordIsTheSessionTheCLINamesAndAReusedProcessIDIsNot() throws {
        // Resumed in a new process whose hooks have not written yet.
        try record("075198d6", event: "Stop", pid: 1111, at: started.addingTimeInterval(-7200), folder: "/Users/u/ORBTR")
        try register("075198d6", pid: 7088, folder: "/Users/u/ORBTR", status: "busy")
        try register("0dead000", pid: 9999, folder: "/Users/u")
        let entries = try XCTUnwrap(CLISessionRegistry.read(directory: registry))
        let live = AgentSessions.live(.claudeCode, directory: records, now: now, isAlive: { $0 == 7088 || $0 == 9999 },
                                      startTime: { pid in pid == 9999 ? self.now.addingTimeInterval(-60) : self.started },
                                      registry: entries)
        XCTAssertEqual(live.map(\.sessionID), ["075198d6"], "process 9999 started long after the entry: another program")
        let session = try XCTUnwrap(live.first)
        XCTAssertEqual(session.processID, 7088)
        XCTAssertTrue(session.isWorking, "the CLI says a turn is under way")
        XCTAssertEqual(session.workingDirectory, "/Users/u/ORBTR")
    }

    func testOnlyACLIProcessThatHoldsASessionMakesASlotARun() {
        let root = "/slots/session"
        let table = ProcessTable(entries: [
            // The two CLIs waiting before their session starts.
            ProcessTable.Entry(pid: 3880, ppid: 1878, command: "/opt/homebrew/bin/claude --resume f964a9fc",
                               environment: "SLOT=\(root)/07F36B83 PWD=/Users/u"),
            ProcessTable.Entry(pid: 8089, ppid: 1861, command: "/opt/homebrew/bin/claude --resume 3a862465",
                               environment: "SLOT=\(root)/0929ABC6 PWD=/Users/u"),
            // A helper left running after its session, and a session.
            ProcessTable.Entry(pid: 3292, ppid: 1, command: "/usr/bin/python3 server.py",
                               environment: "SLOT=\(root)/0111D2ED PWD=/Users/u/Mother"),
            ProcessTable.Entry(pid: 3453, ppid: 1863, command: "/opt/homebrew/bin/claude",
                               environment: "SLOT=\(root)/114FF8C5 PWD=/Users/u/AreaShare"),
        ])
        let directories = SessionSlots.directoriesByProcess(in: table, variable: "SLOT", root: root)
        XCTAssertEqual(directories.count, 4, "every process with the slot in its environment reads it")
        let entry = CLISessionRegistry.Entry(pid: 3453, sessionID: "5386173b", workingDirectory: "/Users/u/AreaShare",
                                             startedAt: started, busy: false)

        let registered = AppState.slotRunDirectories(directories, table: table, names: ["claude"],
                                                     registry: [3453: entry])
        XCTAssertEqual(registered, ["\(root)/114FF8C5"],
                       "a CLI the registry does not list has no session yet, and a helper is no session")

        let unregistered = AppState.slotRunDirectories(directories, table: table, names: ["claude"], registry: nil)
        XCTAssertEqual(unregistered, ["\(root)/07F36B83", "\(root)/0929ABC6", "\(root)/114FF8C5"],
                       "without a registry every CLI process counts, never a helper")
    }
}
