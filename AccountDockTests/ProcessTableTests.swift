import XCTest
@testable import AccountDock

final class ProcessTableTests: XCTestCase {
    /// The two listings `ProcessTable.read` takes: the plain one gives each
    /// command exactly, even an argument shaped like an environment entry,
    /// and the environment is what follows it in the `-E` one.
    func testTheEnvironmentIsWhatFollowsThePlainCommand() throws {
        let plain = """
          101     1 ttys001  /Users/me/.local/bin/codex -c model_provider="accountdock" resume x
          102   101 ??       make CC=clang all
          103     1 ??       /usr/sbin/someone-elses-daemon
        """
        let environment = """
          101     1 ttys001  /Users/me/.local/bin/codex -c model_provider="accountdock" resume x ACCOUNTDOCK_CODEX_SLOT=/s/AAA TERM=xterm
          102   101 ??       make CC=clang all HOME=/Users/me AGTERM_SESSION_ID=agt-3
          103     1 ??       /usr/sbin/someone-elses-daemon
        """
        let table = ProcessTable(listing: environment, plain: plain)
        let codex = try XCTUnwrap(table.entry(101))
        XCTAssertEqual(codex.tty, "ttys001")
        XCTAssertEqual(codex.command, #"/Users/me/.local/bin/codex -c model_provider="accountdock" resume x"#)
        XCTAssertEqual(codex.executableName, "codex")
        XCTAssertEqual(codex.environmentValue("ACCOUNTDOCK_CODEX_SLOT"), "/s/AAA")
        XCTAssertNil(codex.environmentValue("ACCOUNTDOCK_CODEX"))
        let make = try XCTUnwrap(table.entry(102))
        XCTAssertEqual(make.command, "make CC=clang all")
        XCTAssertEqual(make.ppid, 101)
        XCTAssertNil(make.environmentValue("CC"), "an argument is no environment entry")
        XCTAssertEqual(make.environmentValue("AGTERM_SESSION_ID"), "agt-3")
        XCTAssertEqual(table.entry(103)?.environment, "", "another user's environment is unreadable")
        XCTAssertEqual(table.parents, [101: 1, 102: 101, 103: 1])
    }

    /// Without the plain listing, as tests give it, the environment starts
    /// at the first upper-case entry after the executable.
    func testAnEnvironmentListingAloneSplitsAtTheFirstUpperCaseEntry() throws {
        let table = ProcessTable(listing: """
          7 -zsh HOME=/Users/me
          8 /bin/claude --resume x lower_case=kept CLAUDE_SECURESTORAGE_CONFIG_DIR=/slots/A PATH=/bin
          9 /bin/claude
        """, columns: .pid)
        XCTAssertEqual(table.entry(7)?.command, "-zsh")
        XCTAssertEqual(table.entry(7)?.environmentValue("HOME"), "/Users/me")
        XCTAssertEqual(table.entry(8)?.command, "/bin/claude --resume x lower_case=kept")
        XCTAssertEqual(table.entry(8)?.environmentValue("CLAUDE_SECURESTORAGE_CONFIG_DIR"), "/slots/A")
        XCTAssertEqual(table.entry(9)?.command, "/bin/claude")
        XCTAssertEqual(table.entry(9)?.environment, "")
    }

    /// A reading of this test's own process holds its command and
    /// environment, and refreshes the table later readers reuse.
    func testAReadingFindsThisProcessAndIsReusedWhileFresh() throws {
        let pid = getpid()
        let own = try XCTUnwrap(ProcessTable.read(pid: pid)?.entry(pid))
        XCTAssertFalse(own.command.isEmpty)
        XCTAssertNotNil(own.environmentValue("XCTestConfigurationFilePath"))
        let full = try XCTUnwrap(ProcessTable.read())
        XCTAssertNotNil(full.entry(pid))
        let reused = try XCTUnwrap(ProcessTable.current(maxAge: 600))
        XCTAssertGreaterThanOrEqual(reused.readAt, full.readAt)
    }
}

/// Reads the app's sources so that every program the app runs goes through
/// `CommandRunner` and every read of the process list through
/// `ProcessTable`.
final class CommandRunnerCoverageTests: XCTestCase {
    private func sources() throws -> [(name: String, lines: [String])] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountDock", isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "the app's sources were found")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n")) }
    }

    /// `Process()` as a constructor, not the end of a longer name, and the
    /// other ways to start a program.
    private static let launch = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(Process\(\)|posix_spawn|popen\(|NSTask\b)|\.launch\(\)"#)

    func testOnlyTheCommandRunnerLaunchesAndOnlyTheProcessTableRunsPs() throws {
        var offenders: [String] = []
        for source in try sources() {
            for (index, line) in source.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if source.name != "CommandRunner.swift",
                   Self.launch.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    offenders.append("\(source.name):\(index + 1) launches a program")
                }
                if source.name != "ProcessTable.swift", line.contains("\"/bin/ps\"") {
                    offenders.append("\(source.name):\(index + 1) runs ps")
                }
            }
        }
        XCTAssertEqual(offenders, [], "launches outside CommandRunner and process lists outside ProcessTable")
    }

    func testTheScanFindsALaunchAndIgnoresANameEndingInProcess() {
        func matches(_ line: String) -> Bool {
            Self.launch.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertTrue(matches("        let process = Process()"))
        XCTAssertFalse(matches("        Set(directoriesByProcess().values)"))
    }

}
