import XCTest
@testable import AccountDock

final class CommandRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
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
        let result = try await CommandRunner.run(executable: URL(fileURLWithPath: tool), arguments: [], timeout: 30)
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

    func testMergedOutputKeepsBothStreamsAndALimitCapsIt() async throws {
        let tool = try stub("printf out; printf err 1>&2; head -c 100000 /dev/zero")
        let merged = try await CommandRunner.run(CommandRunner.Command(URL(fileURLWithPath: tool), errorOutput: .merged),
                                                 timeout: 30)
        XCTAssertEqual(merged.output.count, 100_006)
        XCTAssertTrue(merged.errorOutput.isEmpty)
        let capped = try await CommandRunner.run(CommandRunner.Command(URL(fileURLWithPath: tool), errorOutput: .discarded,
                                                                       outputLimit: 3), timeout: 30)
        XCTAssertEqual(capped.text, "out")
        XCTAssertTrue(capped.outputTruncated)
        XCTAssertEqual(capped.status, 0, "output past the limit is read and dropped, so the tool finishes")
    }

    func testACancelledRunIsStoppedAndSaysSo() async throws {
        let tool = try stub("printf ready; exec /bin/sleep 60")
        let seen = expectation(description: "output seen as it arrives")
        seen.assertForOverFulfill = false
        let control = CommandRunner.Control { data in
            if data == Data("ready".utf8) { seen.fulfill() }
        }
        let started = Date()
        let run = Task { try await CommandRunner.run(CommandRunner.Command(URL(fileURLWithPath: tool)), timeout: 60, control: control) }
        await fulfillment(of: [seen], timeout: 10)
        control.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled run must throw")
        } catch CommandRunner.Failure.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)

        let early = CommandRunner.Control()
        early.cancel()
        do {
            _ = try await CommandRunner.run(CommandRunner.Command(URL(fileURLWithPath: tool)), timeout: 60, control: early)
            XCTFail("a run cancelled before it starts must throw")
        } catch CommandRunner.Failure.cancelled {}
    }

    func testAStartedProgramRunsOnUntilStopped() throws {
        let process = try CommandRunner.start(CommandRunner.Command("/bin/sleep", ["60"]))
        XCTAssertTrue(process.isRunning)
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
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
