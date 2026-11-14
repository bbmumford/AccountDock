import XCTest
@testable import AccountDock

/// Stops background sessions without running the CLI, recording each.
final class FakeBackgroundControl: BackgroundSessionControl, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: [String] = []
    private let succeeds: Bool

    init(succeeds: Bool = true) { self.succeeds = succeeds }

    var log: [String] { lock.withLock { stopped } }

    func stop(_ sessionID: String, executable: String, support: BackgroundSessionSupport) async -> Bool {
        lock.withLock { stopped.append(sessionID) }
        return succeeds
    }
}

final class BackgroundSessionTests: XCTestCase {
    private let support = AIProviderType.claudeCode.capabilities.backgroundSessions!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, event: String, pid: Int32?) throws -> AgentSession {
        var record: [String: Any] = ["sessionID": id, "event": event]
        if let pid { record["processID"] = pid }
        return try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: record))
    }

    /// The live example: a supervisor, a worker whose spare child runs
    /// session 4822c359, a shell the Bash tool started under it, and the
    /// attach client in a terminal tab, which reads a slot.
    private let processList = """
      9965     1 /opt/homebrew/Caskroom/claude-code/2.1.311/claude daemon run --origin transient HOME=/Users/u
     10740  9965 claude bg-pty-host --bg-pty-host /tmp/cc/spare/ca0cd4dc.pty.sock 200 50 -- /opt/homebrew/claude --bg-spare /tmp/cc/spare/ca0cd4dc.claim.sock HOME=/Users/u
     10878 10740 claude bg-spare --bg-spare /tmp/cc/spare/ca0cd4dc.claim.sock HOME=/Users/u
     11000 10878 /bin/zsh -c -l source /tmp/snapshot.sh && eval 'sleep 60' HOME=/Users/u
     62154 77931 /opt/homebrew/Caskroom/claude-code/2.1.311/claude attach 4822c359 AGTERM_SESSION_ID=agt-7 CLAUDE_SECURESTORAGE_CONFIG_DIR=/h/.accountdock/claude-slots/session/AAA HOME=/Users/u
     62200 77931 /opt/homebrew/bin/claude --bg -p hi CLAUDE_SECURESTORAGE_CONFIG_DIR=/h/.accountdock/claude-slots/session/BBB
     70000 77932 claude --resume 9999 CLAUDE_SECURESTORAGE_CONFIG_DIR=/h/.accountdock/claude-slots/session/CCC
     77931     1 -zsh HOME=/Users/u
    """

    func testOnlyClaudeCodeHasABackgroundService() {
        XCTAssertNotNil(AIProviderType.claudeCode.capabilities.backgroundSessions)
        XCTAssertNil(AIProviderType.codex.capabilities.backgroundSessions)
        XCTAssertNil(AIProviderType.kimi.capabilities.backgroundSessions)
    }

    func testWorkersAttachClientsAndShellsAreRecognised() {
        let processes = BackgroundSessionProcesses(processList: processList, executable: "claude", support: support)
        XCTAssertEqual(processes.workers, [10740, 10878])
        XCTAssertEqual(processes.nonSessions, [9965, 62154, 62200], "the supervisor, the attach client and a --bg launch")
        XCTAssertEqual(processes.attachClient(of: "4822c359-040f-403c-a651-ae45b46cfd8b"), 62154)
        XCTAssertNil(processes.attachClient(of: "9999"))
        XCTAssertTrue(processes.hasShell(under: 10878))
        XCTAssertTrue(processes.hasShell(under: 10740), "a shell anywhere below the worker counts")
        XCTAssertFalse(processes.hasShell(under: 70000))
        XCTAssertTrue(processes.isWorker(10878))
        XCTAssertFalse(processes.isWorker(70000))
    }

    @MainActor func testAnAttachClientHoldsNoSlotAndIsNoSession() throws {
        let processes = BackgroundSessionProcesses(processList: processList, executable: "claude", support: support)
        let directories = SessionSlots.directoriesByProcess(inProcessList: processList,
                                                            variable: "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                                                            root: "/h/.accountdock/claude-slots")
        XCTAssertEqual(Set(directories.keys), [62154, 62200, 70000])
        let kept = AppState.sessionSlotDirectories(directories, background: processes)
        XCTAssertEqual(kept, [70000: "/h/.accountdock/claude-slots/session/CCC"],
                       "the attach client's slot is read by nothing that counts, so serveSessionSlots releases it")

        // The session itself runs in the worker, on the shared sign-in.
        let worker = try session("4822c359-040f-403c-a651-ae45b46cfd8b", event: "Stop", pid: 10878)
        let resumed = try session("9999", event: "Stop", pid: 70000)
        let client = try session("client-record", event: "Stop", pid: 62154)
        let live = AppState.excludingNonSessions([worker, resumed, client], background: processes)
        XCTAssertEqual(live.map(\.sessionID), [worker.sessionID, resumed.sessionID])
        XCTAssertEqual(AppState.unisolated(live, slotDirectoryByProcess: kept).map(\.sessionID), [worker.sessionID])
        var attribution = SessionAttribution(now: now)
        attribution.slotAccounts = kept.mapValues { _ in UUID() }
        attribution.activeAccount = UUID()
        XCTAssertEqual(attribution.decide(session: worker.sessionID, process: worker.processID)?.source, .activeAccount)
        XCTAssertEqual(attribution.decide(session: resumed.sessionID, process: resumed.processID)?.source, .slot)
    }

    func testTheLauncherRunsBackgroundCommandsUnchanged() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        XCTAssertEqual(slots.passThroughCommands, support.managementCommands + slots.support.accountCommands)
        let script = slots.launcherScript()
        XCTAssertTrue(script.contains(slots.passThroughCommands.joined(separator: "|") + ")"))
        XCTAssertTrue(script.contains("= '--bg' ] && exec"))
    }

    func testABackgroundSessionRestartsOnlyOnceIdleAndQuiet() throws {
        let idle = try session("4822c359-040f-403c-a651-ae45b46cfd8b", event: "Stop", pid: 10878)
        let ready = BackgroundSessionState(transcriptChangedAt: now.addingTimeInterval(-3 * 60), shellRunning: false,
                                           attachProcess: 62154)
        XCTAssertNil(AppState.restartBlocker(idle, terminal: "agt-7", background: ready, now: now))
        var recent = ready
        recent.transcriptChangedAt = now.addingTimeInterval(-60)
        XCTAssertNotNil(AppState.restartBlocker(idle, terminal: "agt-7", background: recent, now: now))
        var shell = ready
        shell.shellRunning = true
        XCTAssertNotNil(AppState.restartBlocker(idle, terminal: "agt-7", background: shell, now: now))
        XCTAssertNotNil(AppState.restartBlocker(idle, terminal: nil, background: ready, now: now))
        let working = try session(idle.sessionID, event: "UserPromptSubmit", pid: 10878)
        XCTAssertNotNil(AppState.restartBlocker(working, terminal: "agt-7", background: ready, now: now))
    }

    func testABackgroundSessionIsStoppedThenResumedInItsAttachClientsTab() async throws {
        let terminal = FakeTerminal(sessions: [62154: "agt-7", 10878: "agt-worker"])
        let control = FakeBackgroundControl()
        let idle = try session("4822c359-040f-403c-a651-ae45b46cfd8b", event: "Stop", pid: 10878)
        let ready = BackgroundSessionState(transcriptChangedAt: now.addingTimeInterval(-3 * 60), shellRunning: false,
                                           attachProcess: 62154)
        let outcome = await SessionTerminalActions.restartBackground(
            idle, state: ready, executable: "claude", stopper: "/opt/homebrew/bin/claude", support: support,
            control: control, terminal: terminal, pause: 0, now: now)
        XCTAssertEqual(outcome, .typed)
        XCTAssertEqual(control.log, [idle.sessionID])
        XCTAssertEqual(terminal.log.map(\.text), ["claude --resume '\(idle.sessionID)'", SessionTerminalCommand.enter])
        XCTAssertEqual(Set(terminal.log.map(\.terminal)), ["agt-7"])
    }

    func testABusyOrUnreachableBackgroundSessionIsNeitherStoppedNorTypedInto() async throws {
        let terminal = FakeTerminal(sessions: [62154: "agt-7"])
        let control = FakeBackgroundControl()
        let idle = try session("4822c359-040f-403c-a651-ae45b46cfd8b", event: "Stop", pid: 10878)
        let quiet = now.addingTimeInterval(-3 * 60)
        let cases: [(AgentSession, BackgroundSessionState, SessionTerminalActions.Outcome)] = [
            (try session(idle.sessionID, event: "UserPromptSubmit", pid: 10878),
             BackgroundSessionState(transcriptChangedAt: quiet, attachProcess: 62154), .notIdle),
            (idle, BackgroundSessionState(transcriptChangedAt: now.addingTimeInterval(-30), attachProcess: 62154), .busy),
            (idle, BackgroundSessionState(transcriptChangedAt: quiet, shellRunning: true, attachProcess: 62154), .busy),
            (idle, BackgroundSessionState(transcriptChangedAt: quiet, attachProcess: nil), .notInTerminal),
            (idle, BackgroundSessionState(transcriptChangedAt: quiet, attachProcess: 99), .notInTerminal),
        ]
        for (session, state, expected) in cases {
            let outcome = await SessionTerminalActions.restartBackground(
                session, state: state, executable: "claude", stopper: "claude", support: support,
                control: control, terminal: terminal, pause: 0, now: now)
            XCTAssertEqual(outcome, expected)
        }
        XCTAssertTrue(control.log.isEmpty)
        XCTAssertTrue(terminal.log.isEmpty)

        let failing = FakeBackgroundControl(succeeds: false)
        let outcome = await SessionTerminalActions.restartBackground(
            idle, state: BackgroundSessionState(transcriptChangedAt: quiet, attachProcess: 62154), executable: "claude",
            stopper: "claude", support: support, control: failing, terminal: terminal, pause: 0, now: now)
        XCTAssertEqual(outcome, .notStopped)
        XCTAssertTrue(terminal.log.isEmpty, "nothing is typed when the session was not stopped")
    }

    func testTheNewestTranscriptChangeCountsTheSubagents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-Users-u-project", isDirectory: true)
        let subagents = project.appendingPathComponent("s1/subagents/workflows/run", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let main = project.appendingPathComponent("s1.jsonl")
        let sub = subagents.appendingPathComponent("agent.jsonl")
        try Data("{}".utf8).write(to: main)
        try Data("{}".utf8).write(to: sub)
        let old = now.addingTimeInterval(-600)
        let newer = now.addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: main.path)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: sub.path)
        let changed = try XCTUnwrap(BackgroundSessionState.transcriptChangedAt(session: "s1", root: root))
        XCTAssertEqual(changed.timeIntervalSince1970, newer.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(BackgroundSessionState.transcriptChangedAt(session: "other", root: root))
    }
}
