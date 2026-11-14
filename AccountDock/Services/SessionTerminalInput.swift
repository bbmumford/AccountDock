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

    func terminalSession(ofProcess pid: Int32) async -> String? {
        guard let result = try? await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-Eww", "-o", "command=", "-p", String(pid)],
            timeout: Self.timeout
        ), result.status == 0 else { return nil }
        return Self.sessionID(inProcessList: String(decoding: result.output, as: UTF8.self))
    }

    func type(_ text: String, into terminalSession: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.control.path),
              let result = try? await BoundedProcess.run(
                executable: Self.control,
                arguments: ["session", "type", "--stdin", "--target", terminalSession],
                input: Data(text.utf8),
                timeout: Self.timeout
              ) else { return false }
        return result.status == 0
    }

    /// The value of `sessionVariable` in `ps -E` output for one process
    /// (`terminalSession(ofProcess:)`).
    static func sessionID(inProcessList text: String) -> String? {
        let prefix = sessionVariable + "="
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) where word.hasPrefix(prefix) {
            let value = word.dropFirst(prefix.count)
            if !value.isEmpty { return String(value) }
        }
        return nil
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
        /// active (`BackgroundSessionState`).
        case busy
        /// It runs in no terminal `SessionTerminalInput` can type into.
        case notInTerminal
        /// The terminal refused the text.
        case refused
        /// The CLI did not stop the background session.
        case notStopped
    }

    /// Switches the session's model with the CLI's `/model` command.
    static func switchModel(_ session: AgentSession, to model: String,
                            terminal: SessionTerminalInput) async -> Outcome {
        guard let target = await reachable(session, terminal: terminal) else {
            return session.isIdle ? .notInTerminal : .notIdle
        }
        return await SessionTerminalCommand.send(["/model \(model)"], into: target, through: terminal) ? .typed : .refused
    }

    /// Ends the session and resumes it by ID from the same shell, so the
    /// resumed run starts through the launcher and reads a slot of its own.
    /// `pause` lets the shell take the terminal back between the two lines.
    static func restartInOwnSlot(_ session: AgentSession, executable: String, terminal: SessionTerminalInput,
                                 pause: TimeInterval = 2) async -> Outcome {
        guard let target = await reachable(session, terminal: terminal) else {
            return session.isIdle ? .notInTerminal : .notIdle
        }
        guard await SessionTerminalCommand.send(["/exit"], into: target, through: terminal) else { return .refused }
        if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        let resume = "\(executable) --resume \(AppState.shellQuoted(session.sessionID))"
        return await SessionTerminalCommand.send([resume], into: target, through: terminal) ? .typed : .refused
    }

    /// Stops a session that runs in a background worker and resumes it by
    /// ID in its attach client's terminal, so the resumed run starts
    /// through the launcher and reads a slot of its own. Only once it is
    /// idle by every sign `state` carries (`AppState.restartBlocker`): its
    /// last turn stopped, its transcripts quiet, no shell under its worker,
    /// and an attach client in a terminal `terminal` reaches. `stopper` is
    /// the CLI's own executable, which `control` runs with the stop
    /// command; `executable` is typed, so the launcher on the shell's
    /// `PATH` starts the resumed run. `pause` lets the attach client exit
    /// and the shell take the terminal back.
    static func restartBackground(_ session: AgentSession, state: BackgroundSessionState, executable: String,
                                  stopper: String, support: BackgroundSessionSupport,
                                  control: BackgroundSessionControl, terminal: SessionTerminalInput,
                                  pause: TimeInterval = 2, now: Date = Date()) async -> Outcome {
        guard session.isIdle else { return .notIdle }
        guard state.transcriptsQuiet(now: now), !state.shellRunning else { return .busy }
        guard let client = state.attachProcess, let target = await terminal.terminalSession(ofProcess: client) else {
            return .notInTerminal
        }
        guard await control.stop(session.sessionID, executable: stopper, support: support) else { return .notStopped }
        if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        let resume = "\(executable) --resume \(AppState.shellQuoted(session.sessionID))"
        return await SessionTerminalCommand.send([resume], into: target, through: terminal) ? .typed : .refused
    }

    /// The terminal session to type into: nil while the session is not
    /// idle, or when it runs in no terminal the input reaches.
    private static func reachable(_ session: AgentSession, terminal: SessionTerminalInput) async -> String? {
        guard session.isIdle, let pid = session.processID else { return nil }
        return await terminal.terminalSession(ofProcess: pid)
    }
}
