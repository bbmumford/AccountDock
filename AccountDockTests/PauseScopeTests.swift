import XCTest
@testable import AccountDock

/// Pausing judged per session by the account it runs on
/// (`AppState.pauseScope`), the paused list read from the gate's own files
/// (`AppState.pausedSessions`), and slot sessions the CLI left waiting at a
/// limit (`AppState.leftWaitingCandidates`,
/// `SessionTerminalActions.resumeWaitingAtLimit`).
final class PauseScopeTests: XCTestCase {
    private var home: URL!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = UUID(), second = UUID(), third = UUID()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("PauseScope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Per account

    /// Two slot sessions on each of three Pro accounts, the first active,
    /// and one session on the shared sign-in.
    private var sessions: [String: UUID?] {
        ["a1": first, "a2": first, "b1": second, "b2": second, "c1": third, "c2": third, "shared": nil]
    }

    func testOnlyTheSessionsOnTheAccountNearItsLimitWait() {
        let scope = AppState.pauseScope(sessions: sessions, active: first, atOrNearLimit: { $0 == self.first },
                                        anyRoom: true, destination: { _ in nil })
        XCTAssertEqual(scope.held, ["a1", "a2", "shared"], "the shared sign-in is judged by the active account")
        XCTAssertFalse(scope.holdsNewTurns, "new turns elsewhere go on")
        XCTAssertTrue(scope.moves.isEmpty)
    }

    func testASlotSessionMovesInsteadOfWaitingWhenAnAccountCanTakeIt() {
        let scope = AppState.pauseScope(sessions: sessions, active: first, atOrNearLimit: { $0 == self.first },
                                        anyRoom: true, destination: { $0 == "a1" ? self.second : nil })
        XCTAssertEqual(scope.moves, ["a1": second])
        XCTAssertEqual(scope.held, ["a2", "shared"])

        // Once its slot serves the second account, it no longer waits.
        var moved = sessions
        moved["a2"] = second
        let after = AppState.pauseScope(sessions: moved, active: first, atOrNearLimit: { $0 == self.first },
                                        anyRoom: true, destination: { _ in nil })
        XCTAssertFalse(after.held.contains("a2"))
    }

    func testEveryAccountAtItsLimitHoldsEverythingAndEachResetReleasesItsOwn() {
        var limited: Set<UUID> = [first, second, third]
        let all = AppState.pauseScope(sessions: sessions, active: first, atOrNearLimit: { limited.contains($0) },
                                      anyRoom: false, destination: { _ in nil })
        XCTAssertEqual(all.held, ["a1", "a2", "b1", "b2", "c1", "c2", "shared"])
        XCTAssertTrue(all.holdsNewTurns)

        limited.remove(second)
        let one = AppState.pauseScope(sessions: sessions, active: first, atOrNearLimit: { limited.contains($0) },
                                      anyRoom: true, destination: { _ in nil })
        XCTAssertEqual(one.held, ["a1", "a2", "c1", "c2", "shared"], "the second account's sessions go on after its reset")
        XCTAssertFalse(one.holdsNewTurns)

        limited.remove(first)
        let two = AppState.pauseScope(sessions: sessions, active: first, atOrNearLimit: { limited.contains($0) },
                                      anyRoom: true, destination: { _ in nil })
        XCTAssertEqual(two.held, ["c1", "c2"])
    }

    // MARK: - Pinned sessions

    func testAPinnedSessionWaitsWhenItsOwnAccountReachesItsThresholdAndNeverMoves() {
        // b1 is pinned to the second account, past its failover threshold
        // though not near its limit; a1 is pinned to the first, at its limit,
        // where a destination exists; c1 is pinned to the third, which has room.
        let pinned: [String: UUID] = ["a1": first, "b1": second, "c1": third]
        let threshold: Set<UUID> = [first, second]
        let scope = AppState.pauseScope(
            sessions: sessions, active: first, atOrNearLimit: { $0 == self.first }, anyRoom: true,
            destination: { _ in self.third },
            pinnedHeld: { session in pinned[session].map { threshold.contains($0) } })
        XCTAssertEqual(scope.held, ["a1", "b1", "shared"], "pinned sessions wait for their own account, whatever the active one")
        XCTAssertEqual(scope.moves, ["a2": third], "an unpinned slot session moves; a pinned one never does")
        XCTAssertFalse(scope.held.contains("c1"))
        XCTAssertFalse(scope.held.contains("b2"), "an unpinned session on an account merely past its threshold runs on")

        // Played by the user while its account is at its limit, it runs on.
        let played = AppState.pauseScope(
            sessions: sessions, active: first, atOrNearLimit: { $0 == self.first }, anyRoom: true,
            destination: { _ in nil },
            pinnedHeld: { session in session == "a1" ? false : pinned[session].map { threshold.contains($0) } })
        XCTAssertEqual(played.held, ["a2", "b1", "shared"])

        // Once the second account has room again, b1 goes on.
        let reset = AppState.pauseScope(
            sessions: sessions, active: first, atOrNearLimit: { _ in false }, anyRoom: true,
            destination: { _ in nil }, pinnedHeld: { session in pinned[session].map { _ in false } })
        XCTAssertTrue(reset.held.isEmpty)
    }

    func testAPinnedSessionAtItsLimitJoinsOrStartsAPauseThatOnlyItsAccountEnds() throws {
        let alone = try XCTUnwrap(AppState.pinnedHoldPause(existing: nil, adding: ["p1"], at: now))
        XCTAssertEqual(alone.sessions, ["p1"])
        XCTAssertEqual(alone.holdsNewTurns, false, "every other session runs on")
        XCTAssertEqual(alone.holdsListedNewTurns, true, "its new turns wait too")
        XCTAssertNil(alone.manual)
        XCTAssertNil(alone.account)
        XCTAssertFalse(AppState.capacityEndsPause(alone), "the active account's room does not end it")
        XCTAssertTrue(AppState.capacityEndsPause(alone, routed: true), "ending it brings routed requests back")

        // A pause of sessions the user chose keeps them chosen.
        let chosen = AgentPauseGate.PauseFile(sessions: ["mine"], reason: "paused by you", pausedAt: now, resumeAt: nil,
                                              holdsNewTurns: false, manual: true, holdsListedNewTurns: true, chosen: ["mine"])
        let joined = try XCTUnwrap(AppState.pinnedHoldPause(existing: chosen, adding: ["p1"], at: now))
        XCTAssertEqual(joined.sessions, ["mine", "p1"])
        XCTAssertEqual(joined.chosenListed, ["mine"])
        XCTAssertNil(joined.manual, "the pinned session is judged by its account")
        XCTAssertEqual(joined.pausedAt, now)

        let directory = home.appendingPathComponent("Pause")
        AgentPauseGate.write(joined, for: .claudeCode, directory: directory)
        XCTAssertTrue(AgentPauseGate.narrowToChosen(.claudeCode, continuation: nil, directory: directory),
                      "when the pinned session's account has room, the chosen one stays held")
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory)?.sessions, ["mine"])

        // Nothing changes for a session already listed, or under a pause holding every turn.
        XCTAssertNil(AppState.pinnedHoldPause(existing: alone, adding: [], at: now))
        var all = alone
        all.holdsNewTurns = true
        XCTAssertNil(AppState.pinnedHoldPause(existing: all, adding: ["p2"], at: now))
        let accountHold = AgentPauseGate.PauseFile(sessions: ["h"], reason: "reset", pausedAt: now, resumeAt: nil, account: first)
        XCTAssertEqual(AppState.pinnedHoldPause(existing: accountHold, adding: ["p1"], at: now)?.sessions, ["h", "p1"])
        XCTAssertFalse(AppState.capacityEndsPause(accountHold))
    }

    func testThePinnedHoldIsRecordedWithItsAccountAndReason() {
        XCTAssertEqual(AppState.pinnedHoldEvent(session: "api (4f2a)", account: "Work", hold: .threshold),
                       "Paused api (4f2a), pinned to Work, which reached its threshold; it continues when Work has room.")
        XCTAssertEqual(AppState.pinnedHoldEvent(session: "api (4f2a)", account: "Work", hold: .limit),
                       "Paused api (4f2a), pinned to Work, which reached its limit; it continues when Work has room.")
    }

    // MARK: - A pause the user took

    private var pauseAll: AgentPauseGate.PauseFile {
        AgentPauseGate.PauseFile(sessions: ["a", "b"], reason: "paused by you", pausedAt: now, resumeAt: nil,
                                 holdsNewTurns: true, manual: true)
    }

    func testTheUsersPauseAllOutlastsEveryAutomaticRelease() throws {
        let directory = home.appendingPathComponent("Pause")
        let pause = pauseAll
        XCTAssertTrue(pause.heldByUser)
        XCTAssertTrue(pause.holdsAllForUser)
        AgentPauseGate.write(pause, for: .claudeCode, directory: directory)

        // Capacity returning or a reset (`resumeAgentsIfCapacityReturned`), with or without a route.
        XCTAssertFalse(AppState.capacityEndsPause(pause))
        XCTAssertFalse(AppState.capacityEndsPause(pause, routed: true))
        // Every automatic end goes through `endPause`, which keeps it whole.
        XCTAssertTrue(AgentPauseGate.narrowToChosen(.claudeCode, continuation: "on Work", directory: directory))
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory), pause)
        // A route narrowing it to the sessions too large for the target.
        XCTAssertFalse(AgentPauseGate.narrow(.claudeCode, to: ["big"], reason: "too large", continuation: "on Kimi",
                                             directory: directory))
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory), pause)
        // A pause at a limit written over it (`suspendAgents`).
        XCTAssertTrue(AppState.limitPauseYields(to: pause))
        // Paced resume, steps within headroom and sessions left waiting at a limit.
        XCTAssertTrue(AppState.automaticallyReleasable(["a", "b", "c"], pause: pause, running: ["c", "d"]).isEmpty)
        let refusals = ["c": AppState.SessionRefusal(at: now.addingTimeInterval(-600), account: first, words: "limit")]
        XCTAssertTrue(AppState.leftWaitingCandidates(
            sessions: ["c"], refusals: refusals, slotAccount: { _ in self.second }, canServe: { _ in true },
            handled: [:], userHeld: pause.userHeld(running: ["c"]), now: now).isEmpty,
            "a session the user paused is not told to go on")
        XCTAssertEqual(AppState.leftWaitingCandidates(
            sessions: ["c"], refusals: refusals, slotAccount: { _ in self.second }, canServe: { _ in true },
            handled: [:], now: now), ["c": second])
    }

    func testASessionBothTheUserAndALimitHoldWaitsForTheUser() throws {
        let directory = home.appendingPathComponent("Pause")
        let limit = AgentPauseGate.PauseFile(sessions: ["a", "b"], reason: "limit", pausedAt: now, resumeAt: nil,
                                             holdsNewTurns: true, chosen: ["b"])
        XCTAssertFalse(limit.heldByUser)
        XCTAssertTrue(AppState.capacityEndsPause(limit), "an automatic pause ends when capacity returns")
        XCTAssertFalse(AppState.limitPauseYields(to: limit))
        XCTAssertEqual(AppState.automaticallyReleasable(["a", "b"], pause: limit), ["a"],
                       "paced resume may let a go, never b")

        AgentPauseGate.write(limit, for: .claudeCode, directory: directory)
        XCTAssertTrue(AgentPauseGate.narrowToChosen(.claudeCode, continuation: nil, directory: directory))
        let mine = try XCTUnwrap(AgentPauseGate.read(.claudeCode, directory: directory))
        XCTAssertEqual(mine.sessions, ["b"])
        XCTAssertTrue(mine.heldByUser)
        XCTAssertFalse(mine.holdsAllForUser)
        XCTAssertFalse(AppState.capacityEndsPause(mine), "what is left is the user's, which capacity never ends")
        XCTAssertTrue(AppState.automaticallyReleasable(["b"], pause: mine).isEmpty)
        XCTAssertFalse(AppState.limitPauseYields(to: mine), "a later limit pauses others and keeps b chosen")

        // An automatic pause that is not the user's narrows to a route as before.
        AgentPauseGate.write(limit, for: .claudeCode, directory: directory)
        XCTAssertTrue(AgentPauseGate.narrow(.claudeCode, to: ["big"], reason: "too large", continuation: nil,
                                            directory: directory))
        XCTAssertEqual(AgentPauseGate.read(.claudeCode, directory: directory)?.sessions, ["big", "b"])
    }

    // MARK: - The paused list from the gate's files

    private func runGate(_ provider: AIProviderType, session: String) throws -> Process {
        let script = home.appendingPathComponent("gate.sh")
        try Data(AgentPauseGate.script.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, AgentPauseGate.key(provider) ?? "", "60"]
        process.environment = ["HOME": home.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let event = AgentPauseGate.gateEvent(provider)
        input.fileHandleForWriting.write(Data(#"{"session_id":"\#(session)","hook_event_name":"\#(event)"}"#.utf8))
        try input.fileHandleForWriting.close()
        return process
    }

    private func waitUntil(within seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        return condition()
    }

    func testThePausedListReadsWhatEachProvidersGateWrites() throws {
        let pauseDirectory = home.appendingPathComponent("Library/Application Support/AccountDock/Pause")
        let resetAt = now.addingTimeInterval(2 * 3600)
        for provider in AgentPauseGate.providers {
            let session = "held-\(AgentPauseGate.key(provider) ?? "")"
            AgentPauseGate.write(.init(sessions: [session], reason: "limit", pausedAt: now, resumeAt: nil,
                                       holdsNewTurns: false, holdsListedNewTurns: true),
                                 for: provider, directory: pauseDirectory)
            let gate = try runGate(provider, session: session)
            XCTAssertTrue(waitUntil(within: 5) { AgentPauseGate.waitingSessions(provider, directory: pauseDirectory) == [session] },
                          "\(provider.rawValue)'s gate marks the session waiting where the app reads it")
            // Read with nothing in memory, as after a relaunch.
            func listed() -> [WaitingSession] {
                AppState.pausedSessions(
                    provider, pause: AgentPauseGate.read(provider, directory: pauseDirectory),
                    gates: AgentPauseGate.waitingGates(provider, directory: pauseDirectory),
                    resumed: AgentPauseGate.resumedSessions(provider, directory: pauseDirectory),
                    records: [:], running: [session, "free"], names: [:],
                    account: { _ in self.second }, resumeAt: { $0 == self.second ? resetAt : nil })
            }
            let shown = listed()
            XCTAssertEqual(shown.map(\.sessionID), [session], "only the held session, not every running one")
            XCTAssertEqual(shown.first?.isWaiting, true)
            XCTAssertEqual(shown.first?.gateProcess, gate.processIdentifier)
            XCTAssertEqual(shown.first?.account, second)
            XCTAssertEqual(shown.first?.resumeAt, resetAt, "the resume time is its own account's")

            AgentPauseGate.release(provider, directory: pauseDirectory)
            XCTAssertTrue(waitUntil(within: 5) { !gate.isRunning }, "\(provider.rawValue)'s session goes on once released")
            XCTAssertTrue(listed().isEmpty)
            XCTAssertTrue(AgentPauseGate.waitingSessions(provider, directory: pauseDirectory).isEmpty)
        }
    }

    // MARK: - Sessions the CLI left waiting at a limit

    private func refusal(on account: UUID, minutesAgo: Double) -> AppState.SessionRefusal {
        AppState.SessionRefusal(at: now.addingTimeInterval(-minutesAgo * 60), account: account, words: "limit")
    }

    func testOnlyASessionWhoseSlotMovedToAnAccountWithRoomIsLookedAt() {
        let refusals = ["moved": refusal(on: first, minutesAgo: 10), "unmoved": refusal(on: first, minutesAgo: 10),
                        "noRoom": refusal(on: first, minutesAgo: 10), "old": refusal(on: first, minutesAgo: 7 * 60),
                        "done": refusal(on: first, minutesAgo: 10)]
        let slots = ["moved": second, "unmoved": first, "noRoom": third, "old": second, "done": second]
        let candidates = AppState.leftWaitingCandidates(
            sessions: Array(refusals.keys) + ["neverRefused"], refusals: refusals, slotAccount: { slots[$0] },
            canServe: { $0 != self.third }, handled: ["done": refusals["done"]!.at], now: now)
        XCTAssertEqual(candidates, ["moved": second])
    }

    private func agentSession(_ id: String, event: String, pid: Int32) throws -> AgentSession {
        let record: [String: Any] = ["sessionID": id, "event": event, "processID": pid]
        return try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: record))
    }

    func testAWaitingSessionIsResumedWithEscapeThenAPrompt() async throws {
        let isolation = ClaudeSessionIsolation()
        let footer = "  ⎿  You've hit your session limit · resets 12:20pm\n\n> \n  Continuing automatically at Nov 20 at 12pm · esc to cancel\n"
        let terminal = FakeTerminal(sessions: [42: "agt-1"], screens: [footer])
        // A refused turn records no `Stop`: the session's last event is still its prompt.
        let session = try agentSession("s1", event: "UserPromptSubmit", pid: 42)
        let outcome = await SessionTerminalActions.resumeWaitingAtLimit(session, isolation: isolation, terminal: terminal,
                                                                       prompt: "go on", pause: 0)
        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(terminal.log.map(\.text), ["\u{1B}", "go on", SessionTerminalCommand.enter])

        let dialog = "Usage limit reached\n❯ 1. Stop and wait for limit to reset\n  2. Wait here, then continue automatically at 12:20pm\n  3. Add funds to continue with usage credits\n"
        let asked = FakeTerminal(sessions: [42: "agt-1"], screens: [dialog])
        let fromDialog = await SessionTerminalActions.resumeWaitingAtLimit(session, isolation: isolation, terminal: asked,
                                                                          prompt: "go on", pause: 0)
        XCTAssertEqual(fromDialog, .resumed)
        XCTAssertEqual(asked.log.first?.text, "\u{1B}")
    }

    func testASessionMidTurnOrOutsideAgtermIsLeftAlone() async throws {
        let isolation = ClaudeSessionIsolation()
        let working = "● Reading files…\n\n  ✻ Thinking… (esc to interrupt)\n"
        let terminal = FakeTerminal(sessions: [42: "agt-1"], screens: [working])
        let session = try agentSession("s1", event: "UserPromptSubmit", pid: 42)
        let busy = await SessionTerminalActions.resumeWaitingAtLimit(session, isolation: isolation, terminal: terminal,
                                                                    prompt: "go on", pause: 0)
        XCTAssertEqual(busy, .notWaiting)
        XCTAssertTrue(terminal.log.isEmpty, "nothing is typed into a session mid-turn")

        let elsewhere = FakeTerminal(sessions: [:], screens: ["Continuing automatically at 12pm · esc to cancel"])
        let outside = await SessionTerminalActions.resumeWaitingAtLimit(session, isolation: isolation, terminal: elsewhere,
                                                                       prompt: "go on", pause: 0)
        XCTAssertEqual(outside, .notInTerminal)
        XCTAssertTrue(elsewhere.log.isEmpty)

        // A transcript quoting the footer above the bottom lines is no wait.
        let quoted = "Continuing automatically at 12pm · esc to cancel\n" + (1...12).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertFalse(isolation.screenWaitsAtLimit(quoted))
    }

    func testTheFooterIsFoundAboveALongAgentsPanel() {
        let isolation = ClaudeSessionIsolation()
        let rule = String(repeating: "─", count: 60)
        let panel = (1...9).map { "  ◯ general-purpose  Waiting on step \($0)    2h 14m" }.joined(separator: "\n")
        // The transcript above the box quotes the wait; only the footer below it counts.
        let screen = "⏺ Usage limit reached · continuing automatically at 1:30am · esc to cancel\n" + rule + "\n❯ \n" + rule
            + "\n    Continuing automatically at 1:30am · esc to cancel · /usage-credits to continue now"
            + "\n  execution-platform | md 03f30f18 | wf 0\n  ⏵⏵ bypass permissions on · 1 shell, 3 monitors\n  ⏺ main\n" + panel
        XCTAssertTrue(isolation.screenWaitsAtLimit(screen))
        XCTAssertTrue(isolation.screenReportsRunningWork(screen))

        let continued = "⏺ Usage limit reached · continuing automatically at 1:30am · esc to cancel\n" + rule + "\n❯ \n" + rule
            + "\n  execution-platform | md 03f30f18 | wf 0\n  ⏵⏵ bypass permissions on\n  ⏺ main\n" + panel
        XCTAssertFalse(isolation.screenWaitsAtLimit(continued), "the transcript's line above the box is no wait")
        XCTAssertFalse(isolation.screenReportsRunningWork(continued))
    }

    func testThePolicyResumesLeftWaitingSessionsByDefault() throws {
        XCTAssertTrue(ProviderFailoverPolicy().resumeSessionsLeftWaiting)
        let decoded = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.resumeSessionsLeftWaiting, "a policy stored before the option has it on")
        var off = ProviderFailoverPolicy()
        off.resumeSessionsLeftWaiting = false
        let again = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(again.resumeSessionsLeftWaiting)
    }
}
