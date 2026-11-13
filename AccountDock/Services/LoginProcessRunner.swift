import Foundation
import Darwin
import AppKit

private final class LoginProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Opens the first authorization URL emitted by a login CLI. Some CLIs open
/// their browser themselves, while others only print a device URL when stdout
/// is redirected; keeping this in the shared runner gives every provider the
/// same cancellable login behavior.
private final class LoginBrowserLauncher: @unchecked Sendable {
    private let log = FileLog("Login")
    private let lock = NSLock()
    private let preferredHosts: Set<String>
    private var opened = false

    init(preferredHosts: [String]) {
        self.preferredHosts = Set(preferredHosts.map { $0.lowercased() })
    }

    func inspect(_ text: String) {
        lock.lock()
        guard !opened else { lock.unlock(); return }
        let range = NSRange(text.startIndex..., in: text)
        let regex = try? NSRegularExpression(pattern: #"https?://[^\s\u{001B}\]\[<>\"']+"#)
        let urls = regex?.matches(in: text, range: range).compactMap { match -> URL? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);")))
        } ?? []
        let url = urls.first(where: { url in
            guard !preferredHosts.isEmpty, let host = url.host?.lowercased() else { return false }
            return preferredHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        }) ?? (preferredHosts.isEmpty ? urls.first : nil)
        guard let url else {
            lock.unlock()
            return
        }
        opened = true
        lock.unlock()
        DispatchQueue.main.async { [log] in
            let accepted = LoginBrowser.open(url)
            if accepted {
                log.info("Opened provider authorization URL")
            } else {
                log.error("macOS rejected the provider authorization URL")
            }
        }
    }
}

enum LoginProcessError: LocalizedError {
    case cancelled
    case timedOut
    case failed(Int32, String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Browser login was cancelled. You can try again."
        case .timedOut:
            return "Browser login timed out. You can try again."
        case let .failed(status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Login process exited with status \(status)." : detail
        case let .launchFailed(message):
            return "Could not start the login process: \(message)"
        }
    }
}

/// Runs one browser-login CLI process at a time and keeps a process handle so
/// the UI can cancel it. The deadline is enforced outside the child process,
/// ensuring a failed OAuth callback cannot leave AccountDock permanently busy.
final class LoginProcessRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancelledProcess: ObjectIdentifier?

    func cancel() {
        lock.lock()
        let process = activeProcess
        if let process {
            cancelledProcess = ObjectIdentifier(process)
        }
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        openFirstBrowserURL: Bool = false,
        preferredBrowserHosts: [String] = [],
        timeout: TimeInterval = LoginProcessRunner.timeout
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let output = LoginProcessOutput()
                let browserLauncher = openFirstBrowserURL
                    ? LoginBrowserLauncher(preferredHosts: preferredBrowserHosts)
                    : nil

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    output.append(data)
                    browserLauncher?.inspect(output.string())
                }

                self.lock.lock()
                guard self.activeProcess == nil else {
                    self.lock.unlock()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: LoginProcessError.failed(
                        1, "Another browser login is already in progress."
                    ))
                    return
                }
                self.activeProcess = process
                self.cancelledProcess = nil
                self.lock.unlock()

                // After the process is registered, so a cancel made while the
                // last-used browser is looked up still stops it.
                process.environment = LoginBrowser.environment(environment)
                do {
                    try process.run()
                } catch {
                    self.clear(process)
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: LoginProcessError.launchFailed(error.localizedDescription))
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    if self.wasCancelled(process) {
                        self.stop(process)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                let timedOut = process.isRunning && !self.wasCancelled(process)
                if timedOut {
                    self.stop(process)
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                output.append(remaining)
                let text = output.string()
                browserLauncher?.inspect(text)

                let wasCancelled = self.wasCancelled(process)
                self.clear(process)
                if wasCancelled {
                    continuation.resume(throwing: LoginProcessError.cancelled)
                } else if timedOut {
                    continuation.resume(throwing: LoginProcessError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: LoginProcessError.failed(process.terminationStatus, text))
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }

    private func wasCancelled(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledProcess == ObjectIdentifier(process)
    }

    private func clear(_ process: Process) {
        lock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        if cancelledProcess == ObjectIdentifier(process) {
            cancelledProcess = nil
        }
        lock.unlock()
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
