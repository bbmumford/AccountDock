import Foundation
import AppKit

/// The login CLI's output so far, as `CommandRunner.Control` hands it over.
private final class LoginProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func replace(with newData: Data) {
        lock.lock()
        data = newData
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

/// Runs one browser-login CLI process at a time through `CommandRunner` and
/// keeps its `CommandRunner.Control` so the UI can cancel it. The deadline
/// is enforced outside the child process, ensuring a failed OAuth callback
/// cannot leave AccountDock permanently busy.
final class LoginProcessRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var active: CommandRunner.Control?

    func cancel() {
        let control = lock.withLock { active }
        control?.cancel()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        openFirstBrowserURL: Bool = false,
        preferredBrowserHosts: [String] = [],
        timeout: TimeInterval = LoginProcessRunner.timeout
    ) async throws -> String {
        let output = LoginProcessOutput()
        let browserLauncher = openFirstBrowserURL ? LoginBrowserLauncher(preferredHosts: preferredBrowserHosts) : nil
        let control = CommandRunner.Control { data in
            output.replace(with: data)
            browserLauncher?.inspect(output.string())
        }
        let registered = lock.withLock { () -> Bool in
            guard active == nil else { return false }
            active = control
            return true
        }
        guard registered else {
            throw LoginProcessError.failed(1, "Another browser login is already in progress.")
        }
        defer { lock.withLock { if active === control { active = nil } } }

        // After the run is registered, so a cancel made while the last-used
        // browser is looked up still stops it.
        let command = CommandRunner.Command(executable, arguments, environment: LoginBrowser.environment(environment),
                                            errorOutput: .merged)
        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(command, timeout: timeout, control: control)
        } catch CommandRunner.Failure.cancelled {
            throw LoginProcessError.cancelled
        } catch CommandRunner.Failure.timedOut {
            throw LoginProcessError.timedOut
        } catch {
            throw LoginProcessError.launchFailed(error.localizedDescription)
        }
        let text = result.text
        browserLauncher?.inspect(text)
        guard result.status == 0 else { throw LoginProcessError.failed(result.status, text) }
        return text
    }
}

