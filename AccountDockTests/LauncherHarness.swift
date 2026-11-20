import Foundation
@testable import AccountDock

/// Runs a provider's installed launcher in a temporary home with AccountDock
/// played by the test: a stand-in process whose ID and name `started`
/// records (a `sleep` the harness starts, which `ps -o comm=` names), the
/// `ready` mark its first pass leaves, and a responder that fills the
/// session slots launchers ask for, as `AppState.fillRequestedSlots` does.
/// Nothing outside the temporary directory is read or written.
final class LauncherHarness: @unchecked Sendable {
    let slots: SessionSlots
    /// The directory holding the stand-in CLI, after the launcher on `PATH`.
    let realBin: URL
    private var dock: Process?
    private var responder: Thread?
    private let stop = NSLock()
    private var stopped = false

    init(slots: SessionSlots, realBin: URL) {
        self.slots = slots
        self.realBin = realBin
    }

    deinit {
        stopResponding()
        stopDock()
    }

    /// Starts the stand-in AccountDock and records it as running, with its
    /// first pass done when `ready`.
    func startDock(ready: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        dock = process
        slots.markStarted(pid: process.processIdentifier, name: "sleep")
        if ready { markReady() }
    }

    func markReady() {
        guard let dock else { return }
        slots.markReady(pid: dock.processIdentifier)
    }

    /// Ends the stand-in AccountDock, as when it quits or crashes.
    func stopDock() {
        guard let dock, dock.isRunning else { return }
        dock.terminate()
        dock.waitUntilExit()
    }

    /// Fills each slot a launcher asks for, every `interval`, through
    /// `fill`, which is given the request and the account it asks for, or
    /// `active` for the active account; the default writes `credential`
    /// when given (`SessionSlots.fill`) and else the account file alone, for
    /// an isolation whose credential store a test must not touch.
    func respond(active: UUID, credential: SlotCredential? = nil, interval: TimeInterval = 0.02,
                 fill: (@Sendable (SessionSlots.WantedSlot, UUID) -> Void)? = nil) {
        let slots = slots
        let thread = Thread { [weak self] in
            while let self, !self.isStopped {
                for request in slots.wantedSlots() {
                    let account = request.account ?? active
                    if let fill {
                        fill(request, account)
                    } else if let credential {
                        _ = slots.fill(request.directory, account: account, credential: credential, reason: "test.fill",
                                       session: request.session)
                    } else {
                        _ = slots.assign(request.directory, to: account, reason: "test.fill", session: request.session)
                        try? FileManager.default.removeItem(at: request.directory.appendingPathComponent(SessionSlots.wantedFile))
                    }
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        responder = thread
        thread.start()
    }

    private var isStopped: Bool { stop.withLock { stopped } }

    func stopResponding() {
        stop.withLock { stopped = true }
    }

    /// Runs `executable` through the launcher, from `directory` when given,
    /// and returns what the stand-in CLI printed.
    func launch(_ arguments: [String], environment: [String: String] = [:], directory: URL? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(slots.executable) \"$@\"", "sh"] + arguments
        var base = ["PATH": slots.binDirectory.path + ":" + realBin.path + ":/usr/bin:/bin", "HOME": slots.home.path]
        if let directory {
            process.currentDirectoryURL = directory
            base["PWD"] = directory.path
        }
        process.environment = base.merging(environment) { $1 }
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension SessionSlots {
    /// A session slot as a launch and AccountDock leave it: made and claimed
    /// under `sessionRoot`, then filled for `account` (`fill`); nil when it
    /// could not be written.
    func filledSlot(for account: UUID, credential: SlotCredential, reason: String) -> URL? {
        let directory = sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(Self.claimedMarker),
                                                    withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return fill(directory, account: account, credential: credential, reason: reason) ? directory : nil
    }
}
