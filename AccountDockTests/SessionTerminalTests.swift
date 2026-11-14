import XCTest
@testable import AccountDock

/// A terminal that records what is typed, for sessions whose processes it
/// knows.
final class FakeTerminal: SessionTerminalInput, @unchecked Sendable {
    private let lock = NSLock()
    private let sessions: [Int32: String]
    private let accepts: Bool
    private var typed: [(String, String)] = []

    init(sessions: [Int32: String], accepts: Bool = true) {
        self.sessions = sessions
        self.accepts = accepts
    }

    var log: [(terminal: String, text: String)] { lock.withLock { typed.map { ($0.0, $0.1) } } }

    func terminalSession(ofProcess pid: Int32) async -> String? { sessions[pid] }

    func type(_ text: String, into terminalSession: String) async -> Bool {
        lock.withLock { typed.append((terminalSession, text)) }
        return accepts
    }
}

final class SessionTerminalTests: XCTestCase {
    private func session(_ id: String, event: String, pid: Int32?) throws -> AgentSession {
        var record: [String: Any] = ["sessionID": id, "event": event]
        if let pid { record["processID"] = pid }
        return try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: record))
    }

    func testAnIdleSessionInAgtermIsSwitchedToTheFallbackModel() async throws {
        let terminal = FakeTerminal(sessions: [42: "agt-1"])
        let idle = try session("s1", event: "Stop", pid: 42)
        let outcome = await SessionTerminalActions.switchModel(idle, to: "claude-sonnet-5-5", terminal: terminal)
        XCTAssertEqual(outcome, .typed)
        XCTAssertEqual(terminal.log.map(\.text), ["/model claude-sonnet-5-5", SessionTerminalCommand.enter])
        XCTAssertEqual(Set(terminal.log.map(\.terminal)), ["agt-1"])
    }

    func testAModelSwitchWaitsForTheTurnToEndAndNeedsAgterm() async throws {
        let terminal = FakeTerminal(sessions: [42: "agt-1"])
        let working = try session("s1", event: "UserPromptSubmit", pid: 42)
        let outcomeWorking = await SessionTerminalActions.switchModel(working, to: "claude-sonnet-5-5", terminal: terminal)
        XCTAssertEqual(outcomeWorking, .notIdle)
        XCTAssertTrue(terminal.log.isEmpty, "nothing is typed mid-turn")

        let elsewhere = try session("s2", event: "Stop", pid: 7)
        let outcomeElsewhere = await SessionTerminalActions.switchModel(elsewhere, to: "claude-sonnet-5-5", terminal: terminal)
        XCTAssertEqual(outcomeElsewhere, .notInTerminal)
        XCTAssertTrue(terminal.log.isEmpty)

        let refusing = FakeTerminal(sessions: [42: "agt-1"], accepts: false)
        let outcomeRefused = await SessionTerminalActions.switchModel(try session("s1", event: "Stop", pid: 42),
                                                                      to: "claude-sonnet-5-5", terminal: refusing)
        XCTAssertEqual(outcomeRefused, .refused)
    }

    func testTheFallbackIsOneTheCLICanSwitchToAndOnlyWhenOn() {
        var policy = ProviderFailoverPolicy()
        XCTAssertNil(AppState.modelFallback(for: "claude-fable-5", policy: policy, provider: .claudeCode), "off by default")
        policy.noRoomModelFallback = "claude-sonnet-5-5"
        XCTAssertEqual(AppState.modelFallback(for: "claude-fable-5", policy: policy, provider: .claudeCode), "claude-sonnet-5-5")
        XCTAssertNil(AppState.modelFallback(for: "claude-sonnet-5-5[1m]", policy: policy, provider: .claudeCode),
                     "a session already on it is left alone")
        XCTAssertNil(AppState.modelFallback(for: "gpt-6", policy: policy, provider: .codex), "a CLI with no model choices")
        XCTAssertTrue(AIProviderType.codex.capabilities.sessionModelChoices.isEmpty)

        XCTAssertNil(AppState.modelFallbackEvent(.notIdle, session: "s", model: "Sonnet 5.5"), "waiting records nothing")
        XCTAssertNotNil(AppState.modelFallbackEvent(.typed, session: "s", model: "Sonnet 5.5"))
        XCTAssertNotNil(AppState.modelFallbackEvent(.notInTerminal, session: "s", model: "Sonnet 5.5"))
    }

    func testTheAgtermSessionIsReadFromTheProcessEnvironment() {
        XCTAssertEqual(AgtermTerminalInput.sessionID(inProcessList: "claude --resume x PATH=/bin AGTERM_SESSION_ID=ab12 TERM=xterm"), "ab12")
        XCTAssertNil(AgtermTerminalInput.sessionID(inProcessList: "claude PATH=/bin AGTERM_SESSION_ID= TERM=xterm"))
        XCTAssertNil(AgtermTerminalInput.sessionID(inProcessList: "claude PATH=/bin"))
    }

    func testABoundedProcessReadsItsInputFromStandardInput() async throws {
        let result = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                                  input: Data("typed text".utf8), timeout: 5)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "typed text")
    }
}
