import XCTest
@testable import AccountDock

final class SessionRestartTests: XCTestCase {
    private var directory: URL!
    private var sleepers: [Process] = []
    /// Any app bundle URL serves as the Terminal a prepared launch names;
    /// no test opens one.
    private let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRestartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sleepers.filter(\.isRunning).forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        sleepers.append(process)
        return process
    }

    private func session(_ process: Process, id: String) -> RunningCodexProcess {
        RunningCodexProcess(id: process.processIdentifier, command: "codex resume \(id)", sessionID: id,
                            workingDirectory: "/tmp", host: "cli", terminalTTY: nil, hasUsageLimitError: false)
    }

    private func run(_ command: String) throws -> String {
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", command]
        shell.standardOutput = output
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testTheCodexResumeCommandQuotesEveryPartAndScopesTheCredentialHome() throws {
        let stub = directory.appendingPathComponent("co dex")
        try PrivateFile.writeAtomically(Data("#!/bin/sh\nprintf '%s|' \"$CODEX_HOME\" \"$@\"\n".utf8), to: stub, mode: 0o755)
        let home = "/Users/me/Library/Application Support/AccountDock/managed-codex-homes/A"

        let scoped = CodexService.resumeCommand(binary: stub.path, sessionID: "0199-ab.c", directory: "/tmp/it's \"here\" $HOME", codexHome: home)
        XCTAssertTrue(scoped.hasPrefix("CODEX_HOME='\(home)' "))
        XCTAssertEqual(try run(scoped), "\(home)|resume|0199-ab.c|-C|/tmp/it's \"here\" $HOME|")

        let unscoped = CodexService.resumeCommand(binary: stub.path, sessionID: "s", directory: "/tmp", codexHome: nil)
        XCTAssertFalse(unscoped.contains("CODEX_HOME"))
        XCTAssertEqual(try run("unset CODEX_HOME; " + unscoped), "|resume|s|-C|/tmp|")
    }

    func testTheTerminalScriptDeletesItselfRunsTheCommandAndKeepsAShell() throws {
        let launch = try SessionTerminal.prepareTerminalLaunch("echo hi", directory: directory, terminal: { self.terminal })
        XCTAssertEqual(try String(contentsOf: launch.script, encoding: .utf8), "#!/bin/zsh -l\nrm -f -- \"$0\"\necho hi\nexec /bin/zsh -l\n")
        let mode = try FileManager.default.attributesOfItem(atPath: launch.script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        launch.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.script.path))
    }

    func testWithoutTerminalNoLaunchIsPreparedAndNoFileIsLeft() throws {
        XCTAssertThrowsError(try SessionTerminal.prepareTerminalLaunch("echo hi", directory: directory, terminal: { nil })) { error in
            XCTAssertEqual(error as? SessionTerminal.LaunchError, .terminalNotFound)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testNoSessionIsStoppedWhenAnyResumeCannotBePrepared() async throws {
        let first = try sleeper(), second = try sleeper()
        let directory: URL = self.directory, terminal = self.terminal
        do {
            _ = try await CodexService.shared.stopForRestart(
                [session(first, id: "one"), session(second, id: "two")],
                codexHome: nil,
                binary: "/usr/local/bin/codex",
                prepare: { command in
                    // The second session's launch cannot be prepared.
                    guard !command.contains("'two'") else { throw SessionTerminal.LaunchError.terminalNotFound }
                    return try SessionTerminal.prepareTerminalLaunch(command, directory: directory, terminal: { terminal })
                }
            )
            XCTFail("the restart must refuse")
        } catch CodexServiceError.restartUnavailable {
        }
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(second.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
                       "the launch prepared for the first session is discarded")
    }

    func testSessionsAreStoppedOnlyOnceTheirResumeIsPrepared() async throws {
        let process = try sleeper()
        let directory: URL = self.directory, terminal = self.terminal
        let stopped = try await CodexService.shared.stopForRestart(
            [session(process, id: "one")],
            codexHome: "/managed/home",
            binary: "/usr/local/bin/codex",
            prepare: { try SessionTerminal.prepareTerminalLaunch($0, directory: directory, terminal: { terminal }) }
        )
        defer { stopped.resumes.forEach { $0.launch.discard() } }

        XCTAssertEqual(stopped.survivors, [])
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        let launch = try XCTUnwrap(stopped.resumes.first?.launch)
        let script = try String(contentsOf: launch.script, encoding: .utf8)
        XCTAssertTrue(script.contains("CODEX_HOME='/managed/home' '/usr/local/bin/codex' resume 'one' -C '/tmp'"), script)
    }
}
