import XCTest
@testable import AccountDock

final class AgentPauseGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPauseGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ session: String, event: String, pid: Int32, at date: String, provider: String = "claude") throws {
        let json = """
        {"schemaVersion":1,"provider":"\(provider)","sessionID":"\(session)","event":"\(event)","processID":\(pid),"host":"cli","observedAt":"\(date)"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(provider)-\(session).json"))
    }

    func testOnlySessionsMidTurnWithALiveProcessArePaused() throws {
        try record("turning", event: "UserPromptSubmit", pid: 10, at: "2026-10-17T09:00:00.120Z")
        try record("finished", event: "Stop", pid: 11, at: "2026-10-17T09:01:00Z")
        try record("crashed", event: "UserPromptSubmit", pid: 12, at: "2026-10-17T09:02:00Z")
        try record("codex-turn", event: "UserPromptSubmit", pid: 13, at: "2026-10-17T09:02:00Z", provider: "codex")
        let now = ISO8601DateFormatter().date(from: "2026-10-17T09:05:00Z")!
        let sessions = AgentPauseGate.turningSessions(.claudeCode, directory: directory, now: now) { $0 != 12 }
        XCTAssertEqual(sessions, ["turning"])
    }

    func testSessionsLeaveThePauseOnlyWhenTheyEnd() throws {
        let pausedAt = ISO8601DateFormatter().date(from: "2026-10-17T09:10:00Z")!
        try record("still", event: "UserPromptSubmit", pid: 10, at: "2026-10-17T09:00:00Z")
        try record("turnended", event: "Stop", pid: 11, at: "2026-10-17T09:12:00Z")
        // A subagent reporting back reaches its session as a new prompt.
        try record("prompted", event: "UserPromptSubmit", pid: 12, at: "2026-10-17T09:15:00Z")
        try record("closed", event: "SessionEnd", pid: 13, at: "2026-10-17T09:16:00Z")
        let pause = AgentPauseGate.PauseFile(sessions: ["still", "turnended", "prompted", "closed"], reason: "limit", pausedAt: pausedAt, resumeAt: nil)
        let held = AgentPauseGate.stillHeld(pause, records: AgentSessions.records(.claudeCode, directory: directory))
        XCTAssertEqual(held, ["still", "turnended", "prompted"])
    }

    func testPauseFileRoundTripsAndReleases() {
        let pause = AgentPauseGate.PauseFile(sessions: ["a"], reason: "limit", pausedAt: Date(timeIntervalSince1970: 1_800_000_000), resumeAt: nil)
        AgentPauseGate.write(pause, for: .codex, directory: directory)
        XCTAssertEqual(AgentPauseGate.read(.codex, directory: directory), pause)
        XCTAssertTrue(AgentPauseGate.isActive(.codex, directory: directory))
        XCTAssertFalse(AgentPauseGate.isActive(.claudeCode, directory: directory))
        AgentPauseGate.release(.codex, directory: directory)
        XCTAssertFalse(AgentPauseGate.isActive(.codex, directory: directory))
    }

    /// Runs the installed gate script against a pause file in a scratch home.
    private func runGate(event: String, session: String, home: URL, output: Pipe? = nil,
                         arguments: [String] = ["claude", "60"], errors: Pipe? = nil) throws -> Process {
        let script = home.appendingPathComponent("gate.sh")
        try Data(AgentPauseGate.script.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        process.environment = ["HOME": home.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = errors ?? FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"\#(session)","hook_event_name":"\#(event)"}"#.utf8))
        try input.fileHandleForWriting.close()
        return process
    }

    private func waitForExit(_ process: Process, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        return !process.isRunning
    }

    func testEverySessionWaitsWhileThePauseHoldsNewTurns() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: ["midturn"], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)

        let toolCall = try runGate(event: "PostToolUse", session: "other", home: directory)
        XCTAssertFalse(waitForExit(toolCall, within: 1.5), "a session the pause does not list also waits after a tool call")

        let newTurn = try runGate(event: "UserPromptSubmit", session: "other", home: directory)
        XCTAssertFalse(waitForExit(newTurn, within: 1.5), "a new turn waits while the pause holds new turns")
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
        XCTAssertTrue(waitForExit(newTurn, within: 5), "the turn continues once the pause ends")
        XCTAssertTrue(waitForExit(toolCall, within: 5), "the tool call continues once the pause ends")

        AgentPauseGate.write(.init(sessions: ["midturn"], reason: "limit", pausedAt: Date(), resumeAt: nil),
                             for: .claudeCode, directory: pauseDirectory)
        let unheld = try runGate(event: "UserPromptSubmit", session: "other", home: directory)
        XCTAssertTrue(waitForExit(unheld, within: 3), "without the flag a new turn is not held")
        let unlisted = try runGate(event: "PostToolUse", session: "other", home: directory)
        XCTAssertTrue(waitForExit(unlisted, within: 3), "without the flag only listed sessions wait")
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
    }

    func testANarrowedPauseHoldsOnlyItsSessionsIncludingTheirNewTurns() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: ["large", "small"], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        let small = try runGate(event: "PostToolUse", session: "small", home: directory, output: Pipe())
        XCTAssertFalse(waitForExit(small, within: 1.5))

        AgentPauseGate.narrow(.claudeCode, to: ["large"], reason: "too large", continuation: "on Kimi k3", directory: pauseDirectory)
        XCTAssertTrue(waitForExit(small, within: 5), "a session left out of the narrowed pause continues")
        let pause = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertEqual(pause.sessions, ["large"])
        XCTAssertEqual(pause.holdsNewTurns, false)
        XCTAssertEqual(AgentPauseGate.continuation(.claudeCode, directory: pauseDirectory), "on Kimi k3")

        let largeTurn = try runGate(event: "UserPromptSubmit", session: "large", home: directory)
        XCTAssertFalse(waitForExit(largeTurn, within: 1.5), "a listed session's new turn waits")
        let otherTurn = try runGate(event: "UserPromptSubmit", session: "other", home: directory)
        XCTAssertTrue(waitForExit(otherTurn, within: 3), "another session's new turn goes on")
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
        XCTAssertTrue(waitForExit(largeTurn, within: 5))
    }

    func testANewLimitHoldsSessionsResumedDuringAnEarlierPause() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: ["s"], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        AgentPauseGate.resume(.claudeCode, session: "s", directory: pauseDirectory)
        let resumed = try runGate(event: "PostToolUse", session: "s", home: directory)
        XCTAssertTrue(waitForExit(resumed, within: 3), "a resumed session goes on")

        AgentPauseGate.clearResumed(.claudeCode, sessions: ["s"], directory: pauseDirectory)
        XCTAssertTrue(AgentPauseGate.resumedSessions(.claudeCode, directory: pauseDirectory).isEmpty)
        let held = try runGate(event: "PostToolUse", session: "s", home: directory)
        XCTAssertFalse(waitForExit(held, within: 1.5), "the new limit's pause holds it")
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
        XCTAssertTrue(waitForExit(held, within: 5))
    }

    func testANarrowedPauseStartedFreshKeepsItsContinuation() {
        AgentPauseGate.narrow(.claudeCode, to: ["large"], reason: "too large", continuation: "on Kimi k3", directory: directory)
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory)?.holdsListedNewTurns, true)
        XCTAssertEqual(AgentPauseGate.continuation(.claudeCode, directory: directory), "on Kimi k3")
    }

    func testAResumedSessionIsToldToCheckItsSubagents() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        for event in ["PostToolUse", "UserPromptSubmit"] {
            let output = Pipe()
            let gate = try runGate(event: event, session: "s", home: directory, output: output)
            Thread.sleep(forTimeInterval: 0.5)
            AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
            XCTAssertTrue(waitForExit(gate, within: 5))
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(specific["hookEventName"] as? String, event)
            XCTAssertTrue((specific["additionalContext"] as? String ?? "").contains("subagents"))
            XCTAssertNotNil(json["systemMessage"])
            AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                                 for: .claudeCode, directory: pauseDirectory)
        }
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
    }

    func testAResumedSessionIsToldWhereItContinues() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        let output = Pipe()
        let gate = try runGate(event: "PostToolUse", session: "s", home: directory, output: output)
        Thread.sleep(forTimeInterval: 0.5)
        AgentPauseGate.release(.claudeCode, continuation: "on Kimi \"K3\"\n", directory: pauseDirectory)
        XCTAssertTrue(waitForExit(gate, within: 5))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(json["systemMessage"] as? String, "AccountDock paused this session for 1 min; it continues on Kimi K3.")
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertTrue((specific["additionalContext"] as? String ?? "").contains("continued on Kimi K3."))
        // The next pause starts without it.
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        XCTAssertNil(AgentPauseGate.continuation(.claudeCode, directory: pauseDirectory))
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
    }

    func testOnlyProvidersThatReadTheReplyAreAnswered() {
        let script = AgentPauseGate.script
        XCTAssertTrue(script.contains(#"claude) printf '{"systemMessage""#))
        XCTAssertTrue(script.contains(#"kimi) printf '{"message""#))
        XCTAssertFalse(script.contains("codex)"))
        XCTAssertFalse(script.contains("@REPLIES@"))
    }

    func testTheGateIsInstalledWithinEachCLIsHookLimit() {
        for provider in AgentPauseGate.providers {
            let limit = provider.capabilities.pauseGate?.maximumHookTimeout
            XCTAssertLessThanOrEqual(AgentPauseGate.hookTimeout(provider), limit ?? .max, "\(provider)")
            XCTAssertLessThan(AgentPauseGate.waitLimit(provider), AgentPauseGate.hookTimeout(provider), "\(provider)")
            XCTAssertEqual(AgentPauseGate.refusesAtWaitLimit(provider, requestsHeld: false), limit != nil, "\(provider)")
            XCTAssertFalse(AgentPauseGate.refusesAtWaitLimit(provider, requestsHeld: true), "\(provider): the router holds the next request")
            if let lifecycle = provider.capabilities.lifecycleHooks, let limit {
                XCTAssertLessThanOrEqual(lifecycle.timeout, limit, "\(provider) lifecycle hook")
            }
        }
        XCTAssertEqual(AgentPauseGate.hookTimeout(.kimi), 600)
        XCTAssertTrue(AgentPauseGate.hookCommand(.kimi, requestsHeld: false)?.contains(" kimi 480 refuse # accountdock-gate") == true)
        XCTAssertTrue(AgentPauseGate.hookCommand(.kimi, requestsHeld: true)?.contains(" kimi 480 # accountdock-gate") == true)
        XCTAssertTrue(AgentPauseGate.hookCommand(.claudeCode)?.hasSuffix(" claude 86400 # accountdock-gate") == true)
    }

    func testAStaleGateEntryIsNotCurrent() throws {
        let url = directory.appendingPathComponent("config.toml")
        try TOMLHookConfig.install(at: url, events: ["PreToolUse", "UserPromptSubmit"], command: "gate old", timeout: 86520,
                                   marker: AgentPauseGate.marker)
        let events = ["PreToolUse", "UserPromptSubmit"]
        XCTAssertTrue(TOMLHookConfig.hasHooks(at: url, events: events, marker: AgentPauseGate.marker))
        XCTAssertFalse(TOMLHookConfig.hasHooks(at: url, events: events, marker: AgentPauseGate.marker, command: "gate old", timeout: 600))
        XCTAssertFalse(TOMLHookConfig.hasHooks(at: url, events: events, marker: AgentPauseGate.marker, command: "gate new", timeout: 86520))
        XCTAssertTrue(TOMLHookConfig.hasHooks(at: url, events: events, marker: AgentPauseGate.marker, command: "gate old", timeout: 86520))
    }

    func testAWaitCutShortByTheHookLimitRefusesTheStep() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .kimi, directory: pauseDirectory)
        for (event, wording) in [("PreToolUse", "tool call did not run"), ("UserPromptSubmit", "message was not sent")] {
            let errors = Pipe()
            let gate = try runGate(event: event, session: "s", home: directory, arguments: ["kimi", "1", "refuse"], errors: errors)
            XCTAssertTrue(waitForExit(gate, within: 6), event)
            XCTAssertEqual(gate.terminationStatus, 2, "\(event): Kimi Code refuses a step on exit status 2")
            let reason = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(reason.contains(wording), reason)
        }
        // Without the refusal the step goes ahead when the wait ends.
        let ahead = try runGate(event: "PreToolUse", session: "s", home: directory, arguments: ["kimi", "1"])
        XCTAssertTrue(waitForExit(ahead, within: 6))
        XCTAssertEqual(ahead.terminationStatus, 0)
        AgentPauseGate.release(.kimi, directory: pauseDirectory)
    }

    func testOneResumedSessionGoesOnWhileTheOthersStayHeld() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: ["mine", "other"], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        let output = Pipe()
        let mine = try runGate(event: "PostToolUse", session: "mine", home: directory, output: output)
        let other = try runGate(event: "PostToolUse", session: "other", home: directory)
        Thread.sleep(forTimeInterval: 0.8)
        let gates = AgentPauseGate.waitingGates(.claudeCode, directory: pauseDirectory)
        XCTAssertEqual(gates["mine"], mine.processIdentifier, "the marker names the gate process")
        XCTAssertEqual(gates["other"], other.processIdentifier)

        AgentPauseGate.resume(.claudeCode, session: "mine", directory: pauseDirectory)
        XCTAssertTrue(waitForExit(mine, within: 5), "the resumed session goes on")
        XCTAssertFalse(waitForExit(other, within: 1), "the other session stays held")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertTrue((json["systemMessage"] as? String ?? "").contains("because you resumed it"))

        let nextStep = try runGate(event: "PostToolUse", session: "mine", home: directory)
        XCTAssertTrue(waitForExit(nextStep, within: 3), "its later tool calls are not held")
        let nextTurn = try runGate(event: "UserPromptSubmit", session: "mine", home: directory)
        XCTAssertTrue(waitForExit(nextTurn, within: 3), "nor its new turns")

        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
        XCTAssertTrue(waitForExit(other, within: 5))
        XCTAssertTrue(AgentPauseGate.resumedSessions(.claudeCode, directory: pauseDirectory).isEmpty, "the pause's end clears it")
    }

    func testANewPauseHoldsAResumedSessionAgain() {
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .kimi, directory: directory)
        AgentPauseGate.resume(.kimi, session: "s", directory: directory)
        AgentPauseGate.write(.init(sessions: ["t"], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .kimi, directory: directory)
        XCTAssertEqual(AgentPauseGate.resumedSessions(.kimi, directory: directory), ["s"], "rewriting the same pause keeps it")
        AgentPauseGate.release(.kimi, directory: directory)
        AgentPauseGate.resume(.kimi, session: "s", directory: directory)
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .kimi, directory: directory)
        XCTAssertTrue(AgentPauseGate.resumedSessions(.kimi, directory: directory).isEmpty, "a new pause starts without it")
    }

    func testThePausedTitleNamesTheResumeShortcut() {
        XCTAssertTrue(AgentPauseGate.script.contains("Paused by AccountDock · \(SessionResumeShortcut.display) resumes"))
        XCTAssertFalse(AgentPauseGate.script.contains("@SHORTCUT@"))
    }

    func testAGateIsFoundUnderTheAppShowingIt() {
        let me = ProcessInfo.processInfo.processIdentifier
        let parent = ProcessAncestry.parent(of: me)
        XCTAssertNotNil(parent)
        XCTAssertTrue(ProcessAncestry.isDescendant(me, of: me))
        XCTAssertTrue(ProcessAncestry.isDescendant(me, of: parent!))
        XCTAssertFalse(ProcessAncestry.isDescendant(1, of: me))
    }

    func testTheGateInstallTimeRoundTrips() {
        XCTAssertNil(AgentPauseGate.installedAt(.kimi, directory: directory))
        let installed = Date(timeIntervalSince1970: 1_800_000_000)
        AgentPauseGate.markInstalled(.kimi, at: installed, directory: directory)
        XCTAssertEqual(AgentPauseGate.installedAt(.kimi, directory: directory), installed)
    }

    func testAProcessStartTimeIsRead() throws {
        let started = try XCTUnwrap(ProcessAncestry.startTime(of: ProcessInfo.processInfo.processIdentifier))
        XCTAssertLessThanOrEqual(started, Date())
        XCTAssertGreaterThan(started, Date().addingTimeInterval(-24 * 3600))
        XCTAssertNil(ProcessAncestry.startTime(of: 999_999))
    }

    func testKimiIsToldThroughItsMessageField() throws {
        let pauseDirectory = directory.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .kimi, directory: pauseDirectory)
        let output = Pipe()
        let gate = try runGate(event: "UserPromptSubmit", session: "s", home: directory, output: output,
                               arguments: ["kimi", "480", "refuse"])
        Thread.sleep(forTimeInterval: 0.5)
        AgentPauseGate.release(.kimi, continuation: "on Kimi account Work", directory: pauseDirectory)
        XCTAssertTrue(waitForExit(gate, within: 5))
        XCTAssertEqual(gate.terminationStatus, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let message = try XCTUnwrap(json["message"] as? String)
        XCTAssertTrue(message.contains("continued on Kimi account Work"))
        XCTAssertTrue(message.contains("subagents"))
    }

    func testLiveSessionsAreReadTheSameWayForEveryProvider() throws {
        try record("claude-live", event: "Stop", pid: 20, at: "2026-10-17T09:00:00Z")
        try record("claude-ended", event: "SessionEnd", pid: 21, at: "2026-10-17T09:00:00Z")
        try record("kimi-working", event: "UserPromptSubmit", pid: 22, at: "2026-10-17T09:00:00Z", provider: "kimi")
        try record("kimi-dead", event: "Stop", pid: 23, at: "2026-10-17T09:00:00Z", provider: "kimi")
        try record("codex-stale", event: "Stop", pid: 24, at: "2026-10-16T09:00:00Z", provider: "codex")
        let now = ISO8601DateFormatter().date(from: "2026-10-17T09:05:00Z")!
        let alive: (Int32) -> Bool = { $0 != 23 }
        XCTAssertEqual(AgentSessions.live(.claudeCode, directory: directory, now: now, isAlive: alive).map(\.sessionID), ["claude-live"])
        let kimi = AgentSessions.live(.kimi, directory: directory, now: now, isAlive: alive)
        XCTAssertEqual(kimi.map(\.sessionID), ["kimi-working"])
        XCTAssertTrue(kimi[0].isWorking)
        XCTAssertTrue(AgentSessions.live(.codex, directory: directory, now: now, isAlive: alive).isEmpty)
        XCTAssertEqual(AgentSessions.byProcess(.kimi, directory: directory)[22]?.sessionID, "kimi-working")
    }

    func testAManualPauseRoundTrips() {
        let pause = AgentPauseGate.PauseFile(sessions: [], reason: "paused by you", pausedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                             resumeAt: nil, holdsNewTurns: true, manual: true)
        AgentPauseGate.write(pause, for: .claudeCode, directory: directory)
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory)?.manual, true)
        XCTAssertTrue(AgentPauseGate.isActive(.claudeCode, directory: directory))
    }

    func testAPauseThatHoldsNewTurnsStaysActiveWithNoSessionListed() {
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: directory)
        XCTAssertTrue(AgentPauseGate.isActive(.claudeCode, directory: directory))
    }

    func testStoppingSkipsJobsOfAnInteractiveShell() {
        XCTAssertTrue(AgentSuspensionService.isInteractiveShellJob(tty: "ttys046", parentCommand: "-/bin/zsh"))
        XCTAssertTrue(AgentSuspensionService.isInteractiveShellJob(tty: "ttys001", parentCommand: "/opt/homebrew/bin/fish -l"))
        XCTAssertFalse(AgentSuspensionService.isInteractiveShellJob(tty: "??", parentCommand: "/bin/zsh"))
        XCTAssertFalse(AgentSuspensionService.isInteractiveShellJob(tty: "ttys047", parentCommand: "claude"))
    }
}

final class AgentHookInstallerTests: XCTestCase {
    func testHooksCountOnlyWhenEveryEventIsPresentAndTheScriptExists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func write(_ command: String, events: [String]) throws {
            let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [["matcher": "", "hooks": [["type": "command", "command": command]]]]) })
            try JSONSerialization.data(withJSONObject: ["model": "x", "hooks": hooks]).write(to: url)
        }
        try write("/bin/sh \"/bin/sh\" # accountdock-hook", events: ["SessionStart", "Stop"])
        XCTAssertTrue(AgentHookInstaller.hasHooks(at: url, events: ["SessionStart", "Stop"], marker: "# accountdock-hook"))
        XCTAssertFalse(AgentHookInstaller.hasHooks(at: url, events: ["SessionStart", "Stop", "SessionEnd"], marker: "# accountdock-hook"))
        try write("/bin/sh \"/Applications/Gone.app/hook.sh\" # accountdock-hook", events: ["SessionStart"])
        XCTAssertFalse(AgentHookInstaller.hasHooks(at: url, events: ["SessionStart"], marker: "# accountdock-hook"))
    }
}
