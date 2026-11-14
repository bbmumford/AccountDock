import Darwin
import Foundation

/// Types into the terminal a CLI session runs in, as its user would. Used by
/// `AppState.applyModelFallbacks` to switch a session's model and by
/// `AppState.restartInOwnSlot` to restart a session through the launcher.
protocol SessionTerminalInput: Sendable {
    /// The terminal session the process runs in, from its environment;
    /// nil when it runs in no terminal this input can reach.
    func terminalSession(ofProcess pid: Int32) async -> String?
    /// Types `text` into `terminalSession`. Returns whether the terminal
    /// took it.
    func type(_ text: String, into terminalSession: String) async -> Bool
    /// The text `target` shows now, footer included; nil when it cannot be
    /// read.
    func screenText(target: String) async -> String?
}

/// What a session's terminal is told to do, line by line.
enum SessionTerminalCommand {
    /// The key that submits a line.
    static let enter = "\r"

    /// Types each line followed by `enter`, as separate injections so a
    /// CLI that tells pasted text from typed keys reads the Enter as a key.
    /// Stops at the first the terminal refuses.
    static func send(_ lines: [String], into terminalSession: String, through input: SessionTerminalInput) async -> Bool {
        for line in lines {
            guard await input.type(line, into: terminalSession),
                  await input.type(enter, into: terminalSession) else { return false }
        }
        return true
    }
}

/// agterm, through `agtermctl`: a session started in agterm carries
/// `AGTERM_SESSION_ID` in its environment, and `agtermctl session type`
/// injects text into it. Text goes on standard input, never on the command
/// line; each call is limited to `timeout`.
struct AgtermTerminalInput: SessionTerminalInput {
    static let control = URL(fileURLWithPath: "/Applications/agterm.app/Contents/MacOS/agtermctl")
    static let sessionVariable = "AGTERM_SESSION_ID"
    static let timeout: TimeInterval = 15

    /// From the quota cycle's `ProcessTable` while it is at most a few
    /// seconds old, else from a fresh reading of the process.
    func terminalSession(ofProcess pid: Int32) async -> String? {
        if Darwin.kill(pid, 0) == 0,
           let entry = await ProcessTable.currentInBackground(maxAge: Self.processTableAge)?.entry(pid) {

            return Self.sessionID(of: entry)
        }
        let fresh = await Task.detached(priority: .userInitiated) { ProcessTable.read(pid: pid) }.value
        return fresh?.entry(pid).flatMap(Self.sessionID(of:))
    }

    /// How old a `ProcessTable` may be for `terminalSession(ofProcess:)`.
    static let processTableAge: TimeInterval = 5

    func type(_ text: String, into terminalSession: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.control.path),
              let result = try? await CommandRunner.run(
                executable: Self.control,
                arguments: ["session", "type", "--stdin", "--target", terminalSession],
                input: Data(text.utf8),
                timeout: Self.timeout
              ) else { return false }
        return result.status == 0
    }

    func screenText(target: String) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: Self.control.path),
              let result = try? await CommandRunner.run(
                executable: Self.control,
                arguments: ["session", "text", "--target", target],
                timeout: Self.timeout
              ), result.status == 0 else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// The value of `sessionVariable` in a process's environment
    /// (`terminalSession(ofProcess:)`); nil when it is absent or empty.
    static func sessionID(of entry: ProcessTable.Entry) -> String? {
        entry.environmentValue(sessionVariable).flatMap { $0.isEmpty ? nil : $0 }
    }

}

/// What AccountDock types into a session's terminal, and when it may. A
/// session is typed into only between turns, after its last turn's `Stop`
/// (`AgentSession.isIdle`), so nothing lands in a turn the agent is working
/// on.
enum SessionTerminalActions {
    enum Outcome: Equatable {
        case typed
        /// Mid-turn or not yet stopped: tried again after its next `Stop`.
        case notIdle
        /// Between turns, but its transcripts or a shell under it are still
        /// active (`BackgroundSessionState`), or its CLI's screen reports
        /// work still running (`ProviderSessionIsolation.screenReportsRunningWork`).
        case busy
        /// It runs in no terminal `SessionTerminalInput` can type into.
        case notInTerminal
        /// The terminal refused the text.
        case refused
        /// The CLI did not stop the background session.
        case notStopped
        /// Asked to exit, the CLI asked what to do with work still running;
        /// the session was kept running.
        case cancelled
    }

    /// Switches the session's model with the CLI's `/model` command.
    static func switchModel(_ session: AgentSession, to model: String,
                            terminal: SessionTerminalInput) async -> Outcome {
        guard let target = await reachable(session, terminal: terminal) else {
            return session.isIdle ? .notInTerminal : .notIdle
        }
        return await SessionTerminalCommand.send(["/model \(model)"], into: target, through: terminal) ? .typed : .refused
    }

    /// Ends the session and resumes it by ID from the same shell with the
    /// isolation's `resumeCommand`, so the resumed run starts through the
    /// launcher and reads a slot of its own. A session whose screen reports
    /// work still running is left alone, and so is one whose CLI asks at
    /// exit what to do with such work: it is answered with the isolation's
    /// `keepRunningKey`, never Enter, whose first choice would stop it.
    /// `pause` lets the CLI answer `/exit` and the shell take the terminal
    /// back before the screen is read again.
    static func restartInOwnSlot(_ session: AgentSession, isolation: any ProviderSessionIsolation,
                                 terminal: SessionTerminalInput, pause: TimeInterval = 2) async -> Outcome {
        guard let target = await reachable(session, terminal: terminal) else {
            return session.isIdle ? .notInTerminal : .notIdle
        }
        if let screen = await terminal.screenText(target: target), isolation.screenReportsRunningWork(screen) {
            return .busy
        }
        guard await SessionTerminalCommand.send([isolation.exitCommand], into: target, through: terminal) else { return .refused }
        if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        if let screen = await terminal.screenText(target: target), isolation.screenAsksAboutRunningWork(screen) {
            _ = await terminal.type(isolation.keepRunningKey, into: target)
            return .cancelled
        }
        let resume = isolation.resumeCommand(sessionID: session.sessionID)
        return await SessionTerminalCommand.send([resume], into: target, through: terminal) ? .typed : .refused
    }

    /// Stops a session that runs in a background worker and resumes it by
    /// ID in its attach client's terminal, so the resumed run starts
    /// through the launcher and reads a slot of its own. Only once it is
    /// idle by every sign `state` carries (`AppState.restartBlocker`): its
    /// last turn stopped, its transcripts quiet, no shell under its worker,
    /// and an attach client in a terminal `terminal` reaches, whose screen
    /// reports no work still running. `stopper` is
    /// the CLI's own executable, which `control` runs with the stop
    /// command; the isolation's `resumeCommand` is typed, so the launcher
    /// on the shell's `PATH` starts the resumed run. `pause` lets the
    /// attach client exit and the shell take the terminal back. A session
    /// `refused` at a usage limit since its last served request counts as
    /// idle with quiet transcripts, as `AppState.restartBlocker` counts it:
    /// its turns all fail.
    static func restartBackground(_ session: AgentSession, state: BackgroundSessionState,
                                  isolation: any ProviderSessionIsolation,
                                  stopper: String, support: BackgroundSessionSupport,
                                  control: BackgroundSessionControl, terminal: SessionTerminalInput,
                                  refused: Bool = false, pause: TimeInterval = 2, now: Date = Date()) async -> Outcome {
        guard refused || session.isIdle else { return .notIdle }
        guard refused || state.transcriptsQuiet(now: now), !state.shellRunning else { return .busy }

        guard let client = state.attachProcess, let target = await terminal.terminalSession(ofProcess: client) else {
            return .notInTerminal
        }
        if let screen = await terminal.screenText(target: target), isolation.screenReportsRunningWork(screen) {
            return .busy
        }
        guard await control.stop(session.sessionID, executable: stopper, support: support) else { return .notStopped }
        if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        let resume = isolation.resumeCommand(sessionID: session.sessionID)
        return await SessionTerminalCommand.send([resume], into: target, through: terminal) ? .typed : .refused
    }

    /// The terminal session to type into: nil while the session is not
    /// idle, or when it runs in no terminal the input reaches.
    private static func reachable(_ session: AgentSession, terminal: SessionTerminalInput) async -> String? {
        guard session.isIdle, let pid = session.processID else { return nil }
        return await terminal.terminalSession(ofProcess: pid)
    }
}
