import Foundation
import Darwin

private final class ProcessListOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); data.append(value); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Pauses provider CLI processes with SIGSTOP and resumes exactly those PIDs with
/// SIGCONT. Records are persisted so quitting AccountDock cannot strand an agent.
final class AgentSuspensionService: @unchecked Sendable {
    static let shared = AgentSuspensionService()

    private struct Record: Codable {
        let pid: Int32
        let provider: AIProviderType
        let command: String
    }

    private let lock = NSLock()
    private let key = "app.accountdock.suspendedAgents"
    private var records: [Record] = []
    private var watchdogs: [AIProviderType: Process] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved.filter { Darwin.kill($0.pid, 0) == 0 }
            persist()
        }
    }

    /// Stops the provider's agent processes that no interactive shell owns.
    /// A shell takes its terminal back from a stopped foreground job, so a
    /// continued agent would be left in the background, unable to read its
    /// terminal; those sessions are paused through `AgentPauseGate` instead.
    @discardableResult
    func suspend(provider: AIProviderType) async -> Int {
        await Task.detached(priority: .utility) { [self] in
            suspendSynchronously(provider: provider)
        }.value
    }

    private func suspendSynchronously(provider: AIProviderType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let existing = Set(records.map(\.pid))
        var added = 0
        for process in runningProcesses(provider: provider)
        where !existing.contains(process.pid) && !process.ownedByInteractiveShell {
            if Darwin.kill(process.pid, SIGSTOP) == 0 {
                records.append(Record(pid: process.pid, provider: provider, command: process.command))
                added += 1
            }
        }
        persist()
        if added > 0 { startWatchdog(provider: provider) }
        return added
    }

    @discardableResult
    func resume(provider: AIProviderType) async -> Int {
        await Task.detached(priority: .utility) { [self] in
            resumeSynchronously(provider: provider)
        }.value
    }

    private func resumeSynchronously(provider: AIProviderType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var resumed = 0
        records.removeAll { record in
            guard record.provider == provider else { return false }
            // PID reuse protection: only continue a process that still resembles
            // the provider command AccountDock originally stopped.
            guard currentCommand(pid: record.pid).map({ Self.matchesCommand($0, provider: provider) }) == true else {
                return true
            }
            if Darwin.kill(record.pid, SIGCONT) == 0 { resumed += 1 }
            return true
        }
        persist()
        watchdogs.removeValue(forKey: provider)?.terminate()
        return resumed
    }

    func suspendedCount(provider: AIProviderType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.provider == provider && Darwin.kill($0.pid, 0) == 0 }.count
    }

    func hasSuspendedAgents(provider: AIProviderType) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records.contains { $0.provider == provider && Darwin.kill($0.pid, 0) == 0 }
    }

    func resumeAllSynchronously() {
        for provider in AIProviderType.implementedProviders { _ = resumeSynchronously(provider: provider) }
    }

    private func runningProcesses(provider: AIProviderType) -> [(pid: Int32, command: String, ownedByInteractiveShell: Bool)] {
        let process = Process()
        let pipe = Pipe()
        let outputBuffer = ProcessListOutput()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputBuffer.append(data) }
        }
        guard (try? process.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let output = String(decoding: outputBuffer.snapshot(), as: UTF8.self)
        let rows: [(pid: Int32, ppid: Int32, tty: String, command: String)] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            return (pid, ppid, String(parts[2]), String(parts[3]))
        }
        let parents = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        let commands = Dictionary(rows.map { ($0.pid, $0.command) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { row in
            guard !Self.descends(row.pid, from: getpid(), parents: parents),
                  Self.matchesCommand(row.command, provider: provider) else { return nil }
            let interactive = Self.isInteractiveShellJob(tty: row.tty, parentCommand: commands[row.ppid])
            return (row.pid, row.command, interactive)
        }
    }

    /// Whether a process runs as a job of a shell attached to a terminal.
    static func isInteractiveShellJob(tty: String, parentCommand: String?) -> Bool {
        guard tty != "??", !tty.isEmpty, let parentCommand,
              let executable = parentCommand.split(whereSeparator: \.isWhitespace).first else { return false }
        let name = URL(fileURLWithPath: String(executable).trimmingCharacters(in: CharacterSet(charactersIn: "-")))
            .lastPathComponent.lowercased()
        return ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "login"].contains(name)
    }

    /// AccountDock runs provider CLIs itself for status checks and window
    /// warm-ups and waits for them to exit; pausing one of those would stall
    /// the refresh that started it, so the app's own process tree is excluded.
    static func descends(_ pid: Int32, from ancestor: Int32, parents: [Int32: Int32]) -> Bool {
        var current = pid
        var visited: Set<Int32> = []
        while current > 1, visited.insert(current).inserted {
            if current == ancestor { return true }
            guard let parent = parents[current] else { return false }
            current = parent
        }
        return false
    }

    private func currentCommand(pid: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func matchesCommand(_ command: String, provider: AIProviderType) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let executableNames = tokens.map {
            URL(fileURLWithPath: $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))).lastPathComponent.lowercased()
        }
        guard let first = executableNames.first else { return false }
        let directOrRuntimeScript: (String) -> Bool = { expected in
            first == expected || ((first == "node" || first == "bun" || first == "deno")
                && executableNames.dropFirst().first == expected)
        }
        guard let executable = provider.capabilities.cliExecutableName else { return false }
        return directOrRuntimeScript(executable)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func startWatchdog(provider: AIProviderType) {
        watchdogs[provider]?.terminate()
        let pids = records.filter { $0.provider == provider }.map { String($0.pid) }
        guard !pids.isEmpty else { return }
        let parent = getpid()
        // If AccountDock crashes or is force-killed, this tiny independent
        // watchdog continues every process it stopped. Normal resumption
        // terminates the watchdog first.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(parent) 2>/dev/null; do sleep 5; done; kill -CONT \(pids.joined(separator: " ")) 2>/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { watchdogs[provider] = process }
    }
}
