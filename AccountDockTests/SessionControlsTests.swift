import XCTest
@testable import AccountDock

/// The Sessions page's controls: pausing and playing one session through the
/// gate's files, the state each row shows, the move menu, the pin a move by
/// hand leaves, and the one path every move by hand takes.
final class SessionControlsTests: XCTestCase {
    private var home: URL!
    private var pauseDirectory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("SessionControls-\(UUID().uuidString)")
        pauseDirectory = home.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Runs the gate script for one hook event of `session`, with the
    /// scratch home standing in for the user's.
    private func runGate(event: String, session: String) throws -> Process {
        let script = home.appendingPathComponent("gate.sh")
        try Data(AgentPauseGate.script.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "claude", "60"]
        process.environment = ["HOME": home.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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

    /// Whether `condition` holds within `seconds`, checked every tenth of a
    /// second, so a gate script slow to start on a loaded machine is waited
    /// for rather than missed.
    private func waitUntil(within seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        return condition()
    }

    // MARK: - Pausing and playing one session

    func testPausingOneSessionWithNoPauseHoldsOnlyIt() throws {
        XCTAssertTrue(AgentPauseGate.pauseOne(.claudeCode, session: "mine", at: now, directory: pauseDirectory))
        let pause = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertEqual(pause.sessions, ["mine"])
        XCTAssertEqual(pause.holdsNewTurns, false)
        XCTAssertEqual(pause.holdsListedNewTurns, true)
        XCTAssertTrue(pause.holdsOnlyChosenSessions, "only the user ends it")
        XCTAssertTrue(AgentPauseGate.isActive(.claudeCode, directory: pauseDirectory))

        let mineStep = try runGate(event: "PostToolUse", session: "mine")
        let mineTurn = try runGate(event: "UserPromptSubmit", session: "mine")
        let otherStep = try runGate(event: "PostToolUse", session: "other")
        let otherTurn = try runGate(event: "UserPromptSubmit", session: "other")
        XCTAssertTrue(waitForExit(otherStep, within: 30), "another session's tool call passes")
        XCTAssertTrue(waitForExit(otherTurn, within: 30), "another session's new turn passes")
        // The paused session's gate has reached its wait, which it marks,
        // rather than merely not started yet on a loaded machine.
        XCTAssertTrue(waitUntil(within: 30) {
            AgentPauseGate.waitingGates(.claudeCode, directory: pauseDirectory)["mine"] != nil
        }, "the paused session waits at its tool call")
        XCTAssertTrue(mineStep.isRunning, "the paused session waits at its tool call")
        XCTAssertTrue(mineTurn.isRunning, "and at its new turn")

        // Playing it, the last session held, ends the pause.
        XCTAssertTrue(AgentPauseGate.playOne(.claudeCode, session: "mine", running: ["mine", "other"],
                                             continuation: "on account Work", directory: pauseDirectory))
        XCTAssertTrue(waitForExit(mineStep, within: 30))
        XCTAssertTrue(waitForExit(mineTurn, within: 30))
        XCTAssertNil(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertTrue(AgentPauseGate.resumedSessions(.claudeCode, directory: pauseDirectory).isEmpty, "nothing is left behind")
    }

    func testPlayingTheLastHeldSessionEndsThePause() {
        AgentPauseGate.pauseOne(.claudeCode, session: "a", at: now, directory: pauseDirectory)
        XCTAssertFalse(AgentPauseGate.pauseOne(.claudeCode, session: "b", at: now, directory: pauseDirectory),
                       "a second session joins the pause in effect")
        XCTAssertEqual(AgentPauseGate.heldSessions(.claudeCode, running: ["a", "b", "c"], directory: pauseDirectory), ["a", "b"])

        XCTAssertFalse(AgentPauseGate.playOne(.claudeCode, session: "a", running: ["a", "b", "c"], directory: pauseDirectory),
                       "b is still held")
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: pauseDirectory)?.sessions, ["b"])
        XCTAssertTrue(AgentPauseGate.playOne(.claudeCode, session: "b", running: ["a", "b", "c"], directory: pauseDirectory))
        XCTAssertNil(AgentPauseGate.read(.claudeCode, directory: pauseDirectory), "no pause is left holding nothing")

        // A listed session whose process is gone holds nothing.
        AgentPauseGate.write(.init(sessions: ["gone", "x"], reason: "paused by you", pausedAt: now, resumeAt: nil,
                                   holdsNewTurns: false, manual: true, holdsListedNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        XCTAssertTrue(AgentPauseGate.playOne(.claudeCode, session: "x", running: ["x"], directory: pauseDirectory))
    }

    func testPauseAllThenPlayOneLeavesTheRestHeld() throws {
        // As "Pause all" writes it.
        AgentPauseGate.write(.init(sessions: ["a", "b"], reason: "paused by you", pausedAt: now, resumeAt: nil,
                                   holdsNewTurns: true, manual: true),
                             for: .claudeCode, directory: pauseDirectory)
        let running: Set<String> = ["a", "b", "c"]
        XCTAssertFalse(AgentPauseGate.read(.claudeCode, directory: pauseDirectory)!.holdsOnlyChosenSessions)
        XCTAssertEqual(AgentPauseGate.heldSessions(.claudeCode, running: running, directory: pauseDirectory), running,
                       "a pause holding new turns holds every running session")

        XCTAssertFalse(AgentPauseGate.playOne(.claudeCode, session: "a", running: running, directory: pauseDirectory))
        XCTAssertEqual(AgentPauseGate.heldSessions(.claudeCode, running: running, directory: pauseDirectory), ["b", "c"])
        let played = try runGate(event: "PostToolUse", session: "a")
        let held = try runGate(event: "PostToolUse", session: "c")
        XCTAssertTrue(waitForExit(played, within: 3), "the played session goes on")
        XCTAssertFalse(waitForExit(held, within: 1.5), "the others stay held")

        // Pausing the played session again holds it within the same pause.
        XCTAssertFalse(AgentPauseGate.pauseOne(.claudeCode, session: "a", at: now, directory: pauseDirectory))
        XCTAssertEqual(AgentPauseGate.heldSessions(.claudeCode, running: running, directory: pauseDirectory), running)

        for session in ["a", "b"] {
            XCTAssertFalse(AgentPauseGate.playOne(.claudeCode, session: session, running: running, directory: pauseDirectory))
        }
        XCTAssertTrue(AgentPauseGate.playOne(.claudeCode, session: "c", running: running, directory: pauseDirectory),
                      "playing every session ends the pause")
        XCTAssertTrue(waitForExit(held, within: 5))
    }

    func testASessionPausedByHandStaysHeldWhenThePauseAroundItEnds() throws {
        // A pause at a limit holding one account's session.
        AgentPauseGate.write(.init(sessions: ["limited"], reason: "limit", pausedAt: now, resumeAt: nil,
                                   holdsNewTurns: false, holdsListedNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        XCTAssertFalse(AgentPauseGate.pauseOne(.claudeCode, session: "mine", at: now, directory: pauseDirectory),
                       "it joins the pause in effect")
        var pause = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertEqual(Set(pause.sessions), ["limited", "mine"])
        XCTAssertEqual(pause.chosenListed, ["mine"])
        XCTAssertFalse(pause.holdsOnlyChosenSessions)

        // A route narrowing the pause keeps it too.
        AgentPauseGate.narrow(.claudeCode, to: ["large"], reason: "too large", continuation: nil, directory: pauseDirectory)
        pause = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertEqual(Set(pause.sessions), ["large", "mine"])

        // The account's room returns: the pause ends but for the session
        // paused by hand, which waits for the user alone.
        XCTAssertTrue(AgentPauseGate.narrowToChosen(.claudeCode, continuation: "on account Work", directory: pauseDirectory))
        pause = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: pauseDirectory))
        XCTAssertEqual(pause.sessions, ["mine"])
        XCTAssertTrue(pause.holdsOnlyChosenSessions)
        XCTAssertEqual(pause.pausedAt, now)
        XCTAssertEqual(AgentPauseGate.continuation(.claudeCode, directory: pauseDirectory), "on account Work",
                       "the sessions let go are told where they continue")
        XCTAssertTrue(AgentPauseGate.narrowToChosen(.claudeCode, continuation: nil, directory: pauseDirectory),
                      "nothing automatic ends the user's own pause")
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: pauseDirectory), pause)

        // Played, it no longer counts as chosen, and the pause ends.
        XCTAssertTrue(AgentPauseGate.playOne(.claudeCode, session: "mine", running: ["mine"], directory: pauseDirectory))

        // A pause with no session paused by hand is left for the caller to
        // release.
        AgentPauseGate.write(.init(sessions: ["limited"], reason: "limit", pausedAt: now, resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        XCTAssertFalse(AgentPauseGate.narrowToChosen(.claudeCode, continuation: nil, directory: pauseDirectory))
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: pauseDirectory)?.sessions, ["limited"])
    }

    // MARK: - Row states

    private func record(_ session: String, event: String, pid: Int32, in directory: URL) throws {
        let json = """
        {"schemaVersion":1,"provider":"claude","sessionID":"\(session)","event":"\(event)","processID":\(pid),"host":"cli","observedAt":"\(ISO8601DateFormatter().string(from: now))"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("claude-\(session).json"))
    }

    func testRowStatesFollowTheGateFilesAndSessionRecords() throws {
        let records = home.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        for (index, session) in ["waiting", "due", "resumed", "refused", "shared", "plain"].enumerated() {
            try record(session, event: index.isMultiple(of: 2) ? "UserPromptSubmit" : "Stop", pid: Int32(100 + index), in: records)
        }
        try record("ended", event: "SessionEnd", pid: 200, in: records)
        let sessions = AgentSessions.live(.claudeCode, directory: records, now: now, isAlive: { _ in true }, startTime: { _ in nil }).map(\.sessionID)
        XCTAssertEqual(Set(sessions), ["waiting", "due", "resumed", "refused", "shared", "plain"], "an ended session is no row")

        AgentPauseGate.write(.init(sessions: ["waiting", "due", "resumed"], reason: "paused by you", pausedAt: now,
                                   resumeAt: nil, holdsNewTurns: false, manual: true, holdsListedNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        try Data("4242".utf8).write(to: pauseDirectory.appendingPathComponent("claude-waiting.waiting"))
        AgentPauseGate.resume(.claudeCode, session: "resumed", directory: pauseDirectory)

        let states = SessionRowState.derive(.claudeCode, sessions: sessions, refused: ["refused"],
                                            isolated: ["waiting", "due", "resumed", "refused", "plain"],
                                            directory: pauseDirectory)
        XCTAssertEqual(states, [
            "waiting": .waiting, "due": .stopsAtNextStep, "resumed": .resumedWhileOthersPaused,
            "refused": .refusedAtLimit, "shared": .notIsolated, "plain": .running,
        ])
        XCTAssertTrue(states["waiting"]!.isPaused && states["due"]!.isPaused)
        XCTAssertFalse(states["resumed"]!.isPaused)

        // Without slots no session counts as not isolated; a pause that
        // holds new turns holds every running session.
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: now, resumeAt: nil, holdsNewTurns: true),
                             for: .claudeCode, directory: pauseDirectory)
        let all = SessionRowState.derive(.claudeCode, sessions: ["shared", "plain"], refused: [], isolated: nil,
                                         directory: pauseDirectory)
        XCTAssertEqual(all, ["shared": .stopsAtNextStep, "plain": .stopsAtNextStep])
        AgentPauseGate.release(.claudeCode, directory: pauseDirectory)
        let free = SessionRowState.derive(.claudeCode, sessions: ["shared", "plain"], refused: [], isolated: nil,
                                          directory: pauseDirectory)
        XCTAssertEqual(free, ["shared": .running, "plain": .running], "a resume marker means nothing without a pause")
    }

    // MARK: - The move menu

    private let current = UUID(), signIn = UUID(), excluded = UUID(), atLimit = UUID(), roomy = UUID(), other = UUID()

    private var candidates: [SessionMoveCandidate] {
        [
            SessionMoveCandidate(account: current, name: "Home", sessionUsed: 90, weeklyUsed: 50, needsSignIn: false, atLimit: false, excluded: false),
            SessionMoveCandidate(account: signIn, name: "Old", sessionUsed: nil, weeklyUsed: nil, needsSignIn: true, atLimit: false, excluded: false),
            SessionMoveCandidate(account: excluded, name: "Spare", sessionUsed: 10, weeklyUsed: 10, needsSignIn: false, atLimit: false, excluded: true),
            SessionMoveCandidate(account: atLimit, name: "Spent", sessionUsed: 100, weeklyUsed: 70, needsSignIn: false, atLimit: true, excluded: false),
            SessionMoveCandidate(account: roomy, name: "Work", sessionUsed: 20, weeklyUsed: 40, needsSignIn: false, atLimit: false, excluded: false),
            SessionMoveCandidate(account: other, name: "Team", sessionUsed: 60, weeklyUsed: nil, needsSignIn: false, atLimit: false, excluded: false),
        ]
    }

    func testTheMoveMenuShowsEachAccountsRoomAndWhyItCannotTakeTheSession() {
        let menu = SessionMoveMenu.build(candidates: candidates, current: current, pinnedTo: nil, shared: false,
                                         balancingChoice: roomy)
        XCTAssertEqual(menu.kind, .move)
        let byAccount = Dictionary(uniqueKeysWithValues: menu.options.map { ($0.account, $0) })
        XCTAssertEqual(byAccount[current]?.blocker, "it runs here now")
        XCTAssertEqual(byAccount[signIn]?.blocker, "needs signing in")
        // A move by hand may go to an excluded account or one at its limit.
        XCTAssertNil(byAccount[excluded]?.blocker)
        XCTAssertEqual(byAccount[excluded]?.warning, "excluded from failover — the move pins it there")
        XCTAssertNil(byAccount[atLimit]?.blocker)
        XCTAssertEqual(byAccount[atLimit]?.warning, "at its limit — it pauses there until the account has room")
        XCTAssertNil(byAccount[roomy]?.blocker)
        XCTAssertNil(byAccount[other]?.blocker)
        XCTAssertEqual(byAccount[roomy]?.sessionLeft, 80)
        XCTAssertEqual(byAccount[roomy]?.weeklyLeft, 60)

        let work = byAccount[roomy]!, team = byAccount[other]!
        XCTAssertFalse(work.pins, "balancing would place it on Work itself")
        XCTAssertTrue(team.pins)
        XCTAssertEqual(menu.title(work), "Move to Work")
        XCTAssertEqual(menu.detail(work, sessionWindow: "Session", longWindow: "Weekly limit"),
                       "80% of session left · 60% of weekly limit left · balancing agrees; stays unpinned")
        XCTAssertEqual(menu.detail(team, sessionWindow: "Session", longWindow: "Weekly limit"),
                       "40% of session left · pins it here")
        XCTAssertEqual(menu.detail(byAccount[atLimit]!, sessionWindow: "Session", longWindow: "Weekly limit"),
                       "0% of session left · 30% of weekly limit left · at its limit — it pauses there until the account has room · pins it here")
        XCTAssertEqual(menu.detail(byAccount[excluded]!, sessionWindow: "Session", longWindow: "Weekly limit"),
                       "90% of session left · 90% of weekly limit left · excluded from failover — the move pins it there")
    }

    func testAMoveByHandIsRefusedOnlyWhereTheAccountCannotServeTheCLI() {
        let plan = UUID(), near = UUID()
        let more = candidates + [
            SessionMoveCandidate(account: plan, name: "Free", sessionUsed: nil, weeklyUsed: nil, needsSignIn: false,
                                 atLimit: true, excluded: true, cannotServe: "its plan does not include Claude Code"),
            SessionMoveCandidate(account: near, name: "Busy", sessionUsed: 85, weeklyUsed: 20, needsSignIn: false,
                                 atLimit: false, excluded: false, nearLimit: true),
        ]
        // Balancing would place it on the excluded account: it is pinned there all the same.
        let menu = SessionMoveMenu.build(candidates: more, current: current, pinnedTo: nil, shared: false,
                                         balancingChoice: excluded, pausesAtLimit: false)
        let byAccount = Dictionary(uniqueKeysWithValues: menu.options.map { ($0.account, $0) })
        XCTAssertEqual(byAccount[plan]?.blocker, "its plan does not include Claude Code")
        XCTAssertNil(byAccount[plan]?.warning, "a refused account carries its reason, not a warning")
        XCTAssertEqual(byAccount[near]?.warning, "near its limit — it waits there once the account reaches it")
        XCTAssertEqual(byAccount[atLimit]?.warning, "at its limit — it waits there until the account has room")
        XCTAssertTrue(byAccount[excluded]?.pins == true, "balancing never keeps a session on an excluded account")
        XCTAssertTrue(SessionMoveRules.pins(destination: excluded, balancingChoice: excluded, excluded: true))
        XCTAssertFalse(SessionMoveRules.pins(destination: roomy, balancingChoice: roomy))
        XCTAssertEqual(SessionMoveRules.blocker(needsSignIn: true, cannotServe: "x"), "needs signing in")
        XCTAssertNil(SessionMoveRules.blocker(needsSignIn: false, cannotServe: nil))
    }

    func testAnAccountWhosePlanLacksTheCLIGivesItsReason() {
        let free = Account(id: UUID(), email: "f@example.com", displayName: "F", provider: .claudeCode,
                           subscriptionType: "free", isActive: false)
        XCTAssertEqual(free.cliUnavailableReason, "its plan does not include Claude Code")
        var pro = free
        pro.subscriptionType = "pro"
        XCTAssertNil(pro.cliUnavailableReason)
    }

    func testAPinnedSessionsMenuUnpinsAndASharedSignInSessionsRestartsInASlot() {
        let pinned = SessionMoveMenu.build(candidates: candidates, current: current, pinnedTo: (current, "Home"), shared: false,
                                           balancingChoice: nil)
        XCTAssertEqual(pinned.kind, .unpinAndMove)
        XCTAssertEqual(pinned.pinnedTo, "Home")
        XCTAssertEqual(pinned.options.first { $0.account == current }?.blocker, "pinned here")
        let work = pinned.options.first { $0.account == roomy }!
        XCTAssertEqual(pinned.title(work), "Unpin and move to Work")
        XCTAssertTrue(work.pins, "moved by hand, it is pinned again where it lands")

        let shared = SessionMoveMenu.build(candidates: candidates, current: current, pinnedTo: nil, shared: true,
                                           balancingChoice: current)
        XCTAssertEqual(shared.kind, .restartInSlot)
        let home = shared.options.first { $0.account == current }!
        XCTAssertNil(home.blocker, "a session following the active account may take a slot of it")
        XCTAssertFalse(home.pins)
        XCTAssertEqual(shared.title(home), "Restart in a slot on Home")
    }

    // MARK: - The pin a move leaves

    private func pacerAccount(_ id: UUID, left: Double) -> SessionPacer.Account {
        var account = SessionPacer.Account(id: id, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1)
        account.hasSessionWindow = false
        account.weeklyRemaining = left
        account.weeklyResetsAt = now.addingTimeInterval(150 * 3600)
        return account
    }

    func testAMoveBalancingWouldMakeItselfLeavesTheSessionUnpinned() {
        let accounts = [pacerAccount(roomy, left: 300), pacerAccount(other, left: 20)]
        let session = SessionPacer.RebalanceSession(id: "s", account: other, tokensPerHour: 5_000_000,
                                                    contextTokens: 100_000, model: nil, movable: true)
        let choice = SessionMoveRules.balancingChoice(session, pacer: SessionPacer(), accounts: accounts, running: [session],
                                                      destinations: [roomy, other], now: now)
        XCTAssertEqual(choice, roomy, "the account with room carries it longest")
        XCTAssertFalse(SessionMoveRules.pins(destination: roomy, balancingChoice: choice))
    }

    func testAMoveAgainstBalancingPinsTheSession() {
        let accounts = [pacerAccount(roomy, left: 300), pacerAccount(other, left: 20)]
        let session = SessionPacer.RebalanceSession(id: "s", account: roomy, tokensPerHour: 5_000_000,
                                                    contextTokens: 100_000, model: nil, movable: true)
        let neighbour = SessionPacer.RebalanceSession(id: "n", account: other, tokensPerHour: 1_000_000,
                                                      contextTokens: 50_000, model: nil, movable: true)
        let choice = SessionMoveRules.balancingChoice(session, pacer: SessionPacer(), accounts: accounts,
                                                      running: [session, neighbour], destinations: [roomy, other], now: now)
        XCTAssertEqual(choice, roomy)
        XCTAssertTrue(SessionMoveRules.pins(destination: other, balancingChoice: choice),
                      "moved onto the account balancing would not choose, it is pinned there")
        XCTAssertNil(SessionMoveRules.balancingChoice(session, pacer: SessionPacer(), accounts: accounts, running: [],
                                                      destinations: [], now: now))
        XCTAssertTrue(SessionMoveRules.pins(destination: other, balancingChoice: nil), "with no balancing view, a move pins")
    }

    func testEachMoveIsRecordedWithWhatItDidToThePin() {
        XCTAssertEqual(AppState.handMoveEvent(.slotRewritten, session: "session 1234abcd in ~/x", to: "Work", pins: true),
                       "Moved session 1234abcd in ~/x to Work at your request; pinned there, so failover and balancing leave it.")
        XCTAssertEqual(AppState.handMoveEvent(.slotRewritten, session: "s", to: "Work", pins: false),
                       "Moved s to Work at your request; balancing would place it there too, so it stays unpinned.")
        XCTAssertEqual(AppState.handMoveEvent(.slotTaken, session: "s", to: "Work", pins: true),
                       "Moved s to Work at your request: it left the shared sign-in and was resumed in a slot of its own there; it is pinned there once it lands, so failover and balancing leave it.")
        XCTAssertTrue(AppState.handMoveEvent(.restartPending, session: "s", to: "Work", pins: true).hasPrefix("Moving s to Work at your request"))
        XCTAssertFalse(AppState.handMoveEvent(.activeSwitched, session: "s", to: "Work", pins: true).contains("pinned"),
                       "a move of the shared sign-in pins nothing")
    }

    /// The requests interface, the Sessions page and the account cards'
    /// menus all move a session through `AppState.moveSession`, the one
    /// place that decides the pin and records the move.
    func testEveryMoveByHandTakesTheRequestsInterfacesPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountDock", isDirectory: true)
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let requests = try source("AppState+Requests.swift")
        let handler = try XCTUnwrap(requests.range(of: #"case "moveSession":"#))
        let nextCase = try XCTUnwrap(requests.range(of: #"case "pin", "unpin":"#))
        XCTAssertTrue(requests[handler.upperBound..<nextCase.lowerBound].contains("await moveSession("),
                      "the requests interface's moveSession calls AppState.moveSession")
        XCTAssertFalse(requests.contains("requestedSlotMoves["), "and asks for no slot move of its own")

        let controls = try source("AppState+SessionControls.swift")
        let byHand = try XCTUnwrap(controls.range(of: "func moveSessionByHand("))
        let next = try XCTUnwrap(controls.range(of: "func moveSession(_ sessionID"))
        XCTAssertTrue(controls[byHand.upperBound..<next.lowerBound].contains("await moveSession("),
                      "a move chosen from a menu goes the same way")
        XCTAssertTrue(try source("Views/Components/SessionControlButtons.swift").contains("moveSessionByHand("))
        XCTAssertTrue(try source("AppState+SessionPins.swift").contains("await moveSession("),
                      "so does unpin and move")
    }
}
