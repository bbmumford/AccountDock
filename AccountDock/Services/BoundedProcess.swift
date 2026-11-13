import Foundation
import Darwin

/// Runs a command-line tool to completion within a time limit and collects
/// what it writes. Standard output and standard error are read while the
/// tool runs, so a tool that writes more than a pipe holds is never left
/// blocked on a full pipe; a tool still running at the limit is stopped with
/// `SIGTERM`, then `SIGKILL`. `ClaudeService.runClaude` runs `claude` through
/// it, so a hung CLI cannot stall an account switch waiting to verify.
enum BoundedProcess {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let errorOutput: Data
    }

    enum Failure: Error, Equatable {
        case timedOut(seconds: TimeInterval)
    }

    /// How long output is still collected once the tool has exited, for
    /// descendants that inherited its pipes and keep them open.
    static let drainGrace: TimeInterval = 1

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result(catching: {
                    try runSynchronously(executable: executable, arguments: arguments,
                                         environment: environment, timeout: timeout)
                }))
            }
        }
    }

    private static func runSynchronously(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = Collector(), errorOutput = Collector()
        process.standardOutput = output.pipe
        process.standardError = errorOutput.pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        output.start()
        errorOutput.start()
        do {
            try process.run()
        } catch {
            output.stop()
            errorOutput.stop()
            throw error
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        let deadline = DispatchTime.now() + drainGrace
        let result = Result(
            status: process.terminationStatus,
            output: output.finish(by: deadline),
            errorOutput: errorOutput.finish(by: deadline)
        )
        if timedOut { throw Failure.timedOut(seconds: timeout) }
        return result
    }

    /// Reads one pipe as data arrives, until end of file or `finish`.
    private final class Collector: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)

        func start() {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    ended.signal()
                } else {
                    lock.lock()
                    data.append(chunk)
                    lock.unlock()
                }
            }
        }

        func stop() {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        func finish(by deadline: DispatchTime) -> Data {
            _ = ended.wait(timeout: deadline)
            stop()
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
