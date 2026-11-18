import Foundation
import Darwin

/// The one way the app runs another program. Every launch in the app goes
/// through here (`CommandRunnerCoverageTests` reads the sources for any
/// other), so each gets the same handling: standard output and standard
/// error are read while the program runs, so one that writes more than a
/// pipe holds is never left blocked on a full pipe; one still running at its
/// time limit, or when its `Control` is cancelled, is stopped with `SIGTERM`,
/// then `SIGKILL`; text that must stay off the command line goes on standard
/// input. `ClaudeService.runClaude` runs `claude` through it, so a hung CLI
/// cannot stall an account switch waiting to verify; `ProcessTable` reads
/// the process list through it; `LoginProcessRunner` runs sign-ins through
/// it with a `Control` the UI cancels.
///
/// `start` launches a program that outlives the call (a watchdog, an update
/// helper) and returns its `Process` for the caller to stop.
enum CommandRunner {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let errorOutput: Data
        /// Whether `output` stopped at `Command.outputLimit`.
        var outputTruncated = false

        /// Standard output as UTF-8 text, invalid bytes replaced.
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    enum Failure: Error, Equatable {
        case timedOut(seconds: TimeInterval)
        /// `Control.cancel()` stopped it.
        case cancelled
    }

    /// Where the program's standard error goes.
    enum ErrorOutput: Sendable {
        /// Collected apart, in `Result.errorOutput`.
        case separate
        /// Into the same stream as standard output, in the order written,
        /// for programs whose reply spans both.
        case merged
        /// Discarded.
        case discarded
    }

    /// One program to run.
    struct Command: Sendable {
        var executable: URL
        var arguments: [String] = []
        /// The whole environment; nil inherits the app's. Either way the
        /// credential variables the app inherited are left out
        /// (`childEnvironment`).
        var environment: [String: String]?
        var currentDirectory: URL?
        /// Written whole to standard input and closed once the program
        /// starts; nil gives it no standard input.
        var input: Data?
        var errorOutput: ErrorOutput = .separate
        /// The most bytes of standard output kept; the rest is read and
        /// dropped, so the program is never blocked. Nil keeps everything.
        var outputLimit: Int?

        init(_ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil,
             currentDirectory: URL? = nil, input: Data? = nil, errorOutput: ErrorOutput = .separate,
             outputLimit: Int? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.input = input
            self.errorOutput = errorOutput
            self.outputLimit = outputLimit
        }

        init(_ path: String, _ arguments: [String] = [], environment: [String: String]? = nil,
             currentDirectory: URL? = nil, input: Data? = nil, errorOutput: ErrorOutput = .separate,
             outputLimit: Int? = nil) {
            self.init(URL(fileURLWithPath: path), arguments, environment: environment, currentDirectory: currentDirectory,
                      input: input, errorOutput: errorOutput, outputLimit: outputLimit)
        }
    }

    /// Lets the caller stop a run before its time limit and see its output
    /// as it arrives; `LoginProcessRunner` cancels a sign-in through it and
    /// watches the output for the sign-in page's address.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var stop: (() -> Void)?
        /// Called on a background queue with all output read so far, each
        /// time more arrives.
        let onOutput: (@Sendable (Data) -> Void)?

        init(onOutput: (@Sendable (Data) -> Void)? = nil) {
            self.onOutput = onOutput
        }

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// Stops the run, or the run about to start.
        func cancel() {
            let stop: (() -> Void)? = lock.withLock {
                cancelled = true
                return self.stop
            }
            stop?()
        }

        fileprivate func attach(_ stop: @escaping () -> Void) -> Bool {
            lock.withLock {
                self.stop = stop
                return !cancelled
            }
        }

        fileprivate func detach() {
            lock.withLock { stop = nil }
        }
    }

    /// How long output is still collected once the program has exited, for
    /// descendants that inherited its pipes and keep them open.
    static let drainGrace: TimeInterval = 1

    /// How long a program asked to stop has before it is killed.
    static let stopGrace: TimeInterval = 2

    /// Runs `command` off the calling thread. `timeout` of `.infinity` sets
    /// no limit.
    static func run(_ command: Command, timeout: TimeInterval, control: Control? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result(catching: {
                    try runSynchronously(command, timeout: timeout, control: control)
                }))
            }
        }
    }

    /// Variables that point a CLI at a credential slot or another home,
    /// which the app inherits when it is started from a shell inside a slot
    /// session. A `claude`, `codex` or `kimi` the app runs with one of them
    /// reads that session's slot rather than the shared sign-in, so a check
    /// of the live credential answers for the slot: with the slot gone it
    /// reports the live sign-in signed out. The launcher's own exports are
    /// `ProviderSessionIsolation.launcherExportLines`.
    static let inheritedCredentialVariables = [
        "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR",
        "CODEX_HOME", "ACCOUNTDOCK_CODEX_SLOT", "ACCOUNTDOCK_CODEX_ACCOUNT_ID",
        "KIMI_CODE_HOME", "ACCOUNTDOCK_KIMI_SLOT", "KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST",
    ]

    /// The environment a child is started with: `requested`, or the app's
    /// own (`inherited`) when nil, less each `inheritedCredentialVariables`
    /// entry still holding the value the app inherited. A caller that sets
    /// one of them to another value, as `ClaudeIsolatedLogin` and the Codex
    /// managed homes do, keeps it.
    static func childEnvironment(_ requested: [String: String]?,
                                 inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = requested ?? inherited
        for name in inheritedCredentialVariables {
            if let value = inherited[name], environment[name] == value { environment[name] = nil }
        }
        return environment
    }

    /// `run(_:timeout:control:)` for the call sites that name the parts.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        try await run(Command(executable, arguments, environment: environment, input: input), timeout: timeout)
    }

    /// Runs `command` on the calling thread, for callers already off the
    /// main thread that cannot wait asynchronously.
    static func runSynchronously(_ command: Command, timeout: TimeInterval, control: Control? = nil) throws -> Result {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = childEnvironment(command.environment)
        if let directory = command.currentDirectory { process.currentDirectoryURL = directory }
        let inputPipe = command.input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let output = Collector(limit: command.outputLimit, onData: control?.onOutput)
        process.standardOutput = output.pipe
        let errorOutput: Collector?
        switch command.errorOutput {
        case .separate:
            errorOutput = Collector(limit: nil, onData: nil)
            process.standardError = errorOutput?.pipe
        case .merged:
            errorOutput = nil
            process.standardError = output.pipe
        case .discarded:
            errorOutput = nil
            process.standardError = FileHandle.nullDevice
        }
        // A latch: signalled once at exit, and every wait that takes the
        // signal gives it back, so each later wait sees the exit too.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        output.start()
        errorOutput?.start()
        do {
            try process.run()
        } catch {
            output.stop()
            errorOutput?.stop()
            throw error
        }
        if let inputPipe, let input = command.input {
            // A program that exits without reading it must not end this process.
            signal(SIGPIPE, SIG_IGN)
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }

        let stop = { terminate(process, exited: exited) }
        if let control, !control.attach(stop) { stop() }
        defer { control?.detach() }

        var timedOut = false
        let waited: DispatchTimeoutResult = timeout.isFinite
            ? exited.wait(timeout: .now() + timeout)
            : { exited.wait(); return .success }()
        if waited == .timedOut {
            timedOut = true
            stop()
        } else {
            exited.signal()
        }
        exited.wait()
        exited.signal()
        let deadline = DispatchTime.now() + drainGrace
        let collected = output.finish(by: deadline)
        let result = Result(
            status: process.terminationStatus,
            output: collected.data,
            errorOutput: errorOutput?.finish(by: deadline).data ?? Data(),
            outputTruncated: collected.truncated
        )
        if control?.isCancelled == true { throw Failure.cancelled }
        if timedOut { throw Failure.timedOut(seconds: timeout) }
        return result
    }

    /// Launches `command` and returns without waiting, its output discarded
    /// unless `command.errorOutput` and the standard output are wanted by no
    /// one: for a program that outlives the call. The caller stops it with
    /// `Process.terminate()`.
    @discardableResult
    static func start(_ command: Command) throws -> Process {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = childEnvironment(command.environment)
        if let directory = command.currentDirectory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// `SIGTERM`, then `SIGKILL` after `stopGrace`; returns once it exits
    /// or was killed. `exited` is the exit latch `runSynchronously` waits
    /// on; the signal taken here is given back.

    private static func terminate(_ process: Process, exited: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + stopGrace) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        exited.signal()
    }

    /// Reads one pipe as data arrives, until end of file or `finish`.
    private final class Collector: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        private let limit: Int?
        private let onData: (@Sendable (Data) -> Void)?
        private let ended = DispatchSemaphore(value: 0)

        init(limit: Int?, onData: (@Sendable (Data) -> Void)?) {
            self.limit = limit
            self.onData = onData
        }

        func start() {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    ended.signal()
                    return
                }
                let snapshot: Data? = lock.withLock {
                    if let limit, data.count + chunk.count > limit {
                        data.append(chunk.prefix(max(0, limit - data.count)))
                        truncated = true
                    } else {
                        data.append(chunk)
                    }
                    return onData == nil ? nil : data
                }
                if let snapshot { onData?(snapshot) }
            }
        }

        func stop() {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        func finish(by deadline: DispatchTime) -> (data: Data, truncated: Bool) {
            _ = ended.wait(timeout: deadline)
            stop()
            return lock.withLock { (data, truncated) }
        }
    }
}
