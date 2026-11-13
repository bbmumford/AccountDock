import XCTest
@testable import AccountDock

final class BoundedProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in `claude` running `body` under `/bin/sh`.
    private func stub(_ body: String) throws -> String {
        let url = directory.appendingPathComponent("claude-\(UUID().uuidString)")
        try PrivateFile.writeAtomically(Data("#!/bin/sh\n\(body)\n".utf8), to: url, mode: 0o755)
        return url.path
    }

    func testAClaudeThatHangsIsStoppedAtTheTimeout() async throws {
        let claude = try stub("exec /bin/sleep 60")
        let started = Date()
        do {
            _ = try await ClaudeService.runClaude(executable: claude, args: ["auth", "status"], environment: nil, timeout: 0.5)
            XCTFail("a hung CLI must time out")
        } catch ClaudeServiceError.cliTimedOut(let seconds) {
            XCTAssertEqual(seconds, 0.5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testOutputLargerThanAPipeHoldsIsCollectedFromBothStreams() async throws {
        let tool = try stub("head -c 300000 /dev/zero | tr '\\0' a\nhead -c 300000 /dev/zero | tr '\\0' b 1>&2")
        let result = try await BoundedProcess.run(executable: URL(fileURLWithPath: tool), arguments: [], timeout: 30)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 300_000)
        XCTAssertEqual(result.errorOutput.count, 300_000)
        XCTAssertEqual(Set(result.output), [UInt8(ascii: "a")])
    }

    func testTheSignedOutStatusClaudeExitsOneWithIsReturned() async throws {
        let claude = try stub(#"printf '{"loggedIn":false}'; echo 'warning' 1>&2; exit 1"#)
        let output = try await ClaudeService.runClaude(executable: claude, args: ["auth", "status"], environment: nil, timeout: 30)
        XCTAssertEqual(output, #"{"loggedIn":false}"#)
    }

    func testAFailingClaudeReportsItsExitStatus() async throws {
        let claude = try stub("exit 3")
        do {
            _ = try await ClaudeService.runClaude(executable: claude, args: ["--version"], environment: nil, timeout: 30)
            XCTFail("a failing CLI must throw")
        } catch ClaudeServiceError.cliError(let message) {
            XCTAssertEqual(message, "exit 3")
        }
    }
}
