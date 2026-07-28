import XCTest
@testable import AccountDock

final class LoginProcessRunnerTests: XCTestCase {
    func testLoginProcessTimesOut() async {
        let runner = LoginProcessRunner()
        do {
            _ = try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 0.15
            )
            XCTFail("Expected the login process to time out")
        } catch let error as LoginProcessError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginProcessCanBeCancelledAndReused() async {
        let runner = LoginProcessRunner()
        let attempt = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                environment: ProcessInfo.processInfo.environment
            )
        }

        try? await Task.sleep(for: .milliseconds(100))
        runner.cancel()

        do {
            _ = try await attempt.value
            XCTFail("Expected the login process to be cancelled")
        } catch let error as LoginProcessError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await runner.run(
                executable: "/usr/bin/true",
                arguments: [],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1
            )
        } catch {
            XCTFail("Runner remained blocked after cancellation: \(error)")
        }
    }
}
