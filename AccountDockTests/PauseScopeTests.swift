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
