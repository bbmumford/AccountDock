import AppKit
import Foundation

private let log = FileLog("SessionTerminal")

/// Where a session `AppState.sessionLaunch` prepared is started: a terminal
/// app that can be told to run a command, or the clipboard. Offered by the
/// usage tiles' session button when `isAvailable`.
enum SessionTerminal: String, CaseIterable, Identifiable {
    case agterm
    case terminal
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agterm: "agterm"
        case .terminal: "Terminal"
        case .clipboard: "Copy command"
        }
    }

    var systemImage: String {
        switch self {
        case .agterm, .terminal: "terminal"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// agterm is offered only where it is installed with its control tool,
    /// which starts the session; Terminal ships with macOS.
    var isAvailable: Bool {
        switch self {
        case .agterm: Self.agtermControl != nil
        case .terminal, .clipboard: true
        }
    }

    static var available: [SessionTerminal] { allCases.filter(\.isAvailable) }

    private static var agtermControl: URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.umputun.agterm") else { return nil }
        let control = app.appendingPathComponent("Contents/MacOS/agtermctl")
        return FileManager.default.isExecutableFile(atPath: control.path) ? control : nil
    }

    /// Starts `command`, which begins by changing to `directory`, and keeps a
    /// login shell open there once the CLI exits. `name` titles the agterm
    /// session. Returns a message for the user when it could not start.
    @MainActor
    func start(_ command: String, in directory: URL, name: String) async -> String? {
        switch self {
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return nil
        case .terminal:
            return Self.startInTerminal(command)
        case .agterm:
            guard let control = Self.agtermControl else { return "agterm is not installed." }
            return await Self.startInAgterm(control, command: command, directory: directory, name: name)
        }
    }

    /// Terminal runs a `.command` file it is asked to open, in a new window,
    /// with no automation permission; the file deletes itself when it starts.
    private static func startInTerminal(_ command: String) -> String? {
        do {
            try prepareTerminalLaunch(command).open()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A command written to a `.command` file, with the Terminal app that
    /// opens it. Preparing one before stopping the sessions it resumes
    /// (`CodexService.stopForRestart`) means a session is stopped only when
    /// its resume can be started.
    struct PreparedLaunch: Sendable {
        let script: URL
        let terminal: URL

        func open() {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }

        /// Removes the file of a launch that will not be opened.
        func discard() {
            try? FileManager.default.removeItem(at: script)
        }
    }

    enum LaunchError: LocalizedError, Equatable {
        case scriptNotWritten
        case terminalNotFound

        var errorDescription: String? {
            switch self {
            case .scriptNotWritten: "The session could not be prepared."
            case .terminalNotFound: "Terminal was not found."
            }
        }
    }

    /// The text of the `.command` file that runs `command`: it deletes
    /// itself, runs the command, and leaves a login shell open.
    static func scriptBody(for command: String) -> String {
        "#!/bin/zsh -l\nrm -f -- \"$0\"\n\(command)\nexec /bin/zsh -l\n"
    }

    /// Writes the `.command` file for `command` into `directory` and finds
    /// Terminal; throws when either fails, leaving no file behind.
    static func prepareTerminalLaunch(
        _ command: String,
        directory: URL = FileManager.default.temporaryDirectory,
        terminal: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") }
    ) throws -> PreparedLaunch {
        guard let terminal = terminal() else { throw LaunchError.terminalNotFound }
        let script = directory.appendingPathComponent("accountdock-session-\(UUID().uuidString).command")
        do {
            try PrivateFile.writeAtomically(Data(scriptBody(for: command).utf8), to: script, mode: 0o700)
        } catch {
            log.error("Session script not written: \(error.localizedDescription)")
            throw LaunchError.scriptNotWritten
        }
        return PreparedLaunch(script: script, terminal: terminal)
    }

    /// agterm starts a session through its control socket, which answers
    /// only while the app runs, so the app is opened and asked again once.
    private static func startInAgterm(_ control: URL, command: String, directory: URL, name: String) async -> String? {
        let shell = "/bin/zsh -lic \(AppState.shellQuoted(command + "; exec /bin/zsh -l"))"
        let arguments = ["session", "new", "--cwd", directory.path, "--name", name, "--command", shell]
        if await run(control, arguments) { return nil }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.umputun.agterm") {
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return await run(control, arguments) ? nil : "agterm did not start the session."
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
