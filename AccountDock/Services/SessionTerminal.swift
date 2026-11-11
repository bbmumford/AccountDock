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
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("accountdock-session-\(UUID().uuidString).command")
        let body = "#!/bin/zsh -l\nrm -f -- \"$0\"\n\(command)\nexec /bin/zsh -l\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            log.error("Session script not written: \(error.localizedDescription)")
            return "The session could not be prepared."
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return "Terminal was not found."
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return nil
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
