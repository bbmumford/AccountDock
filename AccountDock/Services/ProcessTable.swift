import Foundation
import Darwin

/// One reading of the running processes: each one's ID, parent, terminal,
/// command line and environment. It is the app's only reader of the process
/// list (`CommandRunnerCoverageTests` reads the sources for any other `ps`);
/// every question about running processes is asked of a table:
/// `AppState.refreshSlotProcesses` reads one fresh on every quota cycle for
/// the slots processes read (`SessionSlots`) and the background-session
/// processes (`BackgroundSessionProcesses`), and `current(maxAge:)` hands
/// that reading to `AgtermTerminalInput`, which looks up the terminal of the
/// sessions the cycle found within seconds. Readers that act on a process
/// now (`CLIProcessScan`, `AgentSuspensionService`,
/// `ClaudeService.runningProcesses`, `CodexService`) read a fresh one.

///
/// The table comes from two listings taken together: `ps -axww`, which
/// prints each command line exactly, and `ps -axEww`, which appends each
/// process's environment to it, so the environment is what follows the
/// command line there. The environment of another user's process is not
/// readable and is empty.
struct ProcessTable: Sendable {
    struct Entry: Equatable, Sendable {
        var pid: Int32
        var ppid: Int32
        /// The controlling terminal's name, `??` for none.
        var tty: String
        /// The executable and its arguments, separated by spaces.
        var command: String
        /// The environment entries, `NAME=value`, separated by spaces.
        var environment: String

        init(pid: Int32, ppid: Int32 = 0, tty: String = "??", command: String, environment: String = "") {
            self.pid = pid
            self.ppid = ppid
            self.tty = tty
            self.command = command
            self.environment = environment
        }

        /// The command's words; a word holding a space is split.
        var words: [String] { command.split(separator: " ").map(String.init) }

        /// The last path component of the command's first word.
        var executableName: String {
            (words.first.map { $0 as NSString }?.lastPathComponent) ?? ""
        }

        /// The command line, then the environment, as `ps -E` prints it.
        var commandLine: String { environment.isEmpty ? command : command + " " + environment }

        /// The value of the first environment entry named `name`; nil when
        /// there is none.
        func environmentValue(_ name: String) -> String? {
            let prefix = name + "="
            return environment.split(separator: " ").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
    }

    /// The columns of a listing `init(listing:plain:columns:)` reads, after
    /// which comes the command line.
    enum Columns: Sendable {
        case pidPPIDTTY
        case pidPPID
        case pid
    }

    let entries: [Entry]
    let readAt: Date
    private let byPID: [Int32: Entry]

    init(entries: [Entry], readAt: Date = Date()) {
        self.entries = entries
        self.readAt = readAt
        byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Parses `listing`, `ps -E` output in `columns` then the command line
    /// and environment. With `plain`, the same listing without `-E`, each
    /// process's command is its line there and its environment the rest of
    /// its `-E` line. Without it, as in tests that give only the `-E`
    /// listing, the environment starts at the first word after the
    /// executable shaped like an upper-case `NAME=` entry.
    init(listing: String, plain: String? = nil, columns: Columns = .pidPPIDTTY, readAt: Date = Date()) {
        let commands = plain.map { Self.rows($0, columns: columns) }.map { rows in
            Dictionary(rows.map { ($0.pid, $0.rest) }, uniquingKeysWith: { first, _ in first })
        }
        let entries = Self.rows(listing, columns: columns).map { row -> Entry in
            let split: (command: String, environment: String)
            if let command = commands?[row.pid] {
                split = row.rest.hasPrefix(command)
                    ? (command, row.rest.dropFirst(command.count).trimmingCharacters(in: .whitespaces))
                    : (command, "")
            } else {
                split = Self.splitEnvironment(row.rest)
            }
            return Entry(pid: row.pid, ppid: row.ppid, tty: row.tty, command: split.command, environment: split.environment)
        }
        self.init(entries: entries, readAt: readAt)
    }

    func entry(_ pid: Int32) -> Entry? { byPID[pid] }

    /// Each process's parent, by process ID.
    var parents: [Int32: Int32] { byPID.mapValues(\.ppid) }

    // MARK: - Reading

    /// How long one `ps` may run.
    static let timeout: TimeInterval = 10

    /// Reads every process, or only `pid`; nil when `ps` cannot run.
    static func read(pid: Int32? = nil) -> ProcessTable? {
        let selection = pid.map { ["-p", String($0)] } ?? ["-ax"]
        let columns = ["-o", "pid=,ppid=,tty=,command="]
        let now = Date()
        guard let plain = list(["-ww"] + selection + columns),
              let environment = list(["-Eww"] + selection + columns) else { return nil }
        let table = ProcessTable(listing: environment, plain: plain, readAt: now)
        if pid == nil { cache.store(table) }
        return table
    }

    /// The last full reading when it is at most `maxAge` old, else a fresh
    /// one; nil when `ps` cannot run.
    static func current(maxAge: TimeInterval) -> ProcessTable? {
        if let cached = cache.table, Date().timeIntervalSince(cached.readAt) <= maxAge { return cached }
        return read()
    }

    /// `read()` off the calling thread.
    static func readInBackground() async -> ProcessTable? {
        await Task.detached(priority: .utility) { read() }.value
    }

    /// `current(maxAge:)` off the calling thread.
    static func currentInBackground(maxAge: TimeInterval) async -> ProcessTable? {
        await Task.detached(priority: .utility) { current(maxAge: maxAge) }.value
    }

    private static func list(_ arguments: [String]) -> String? {
        guard let result = try? CommandRunner.runSynchronously(
            CommandRunner.Command("/bin/ps", arguments, errorOutput: .discarded), timeout: timeout
        ) else { return nil }
        // `ps -p` exits 1 when the process is gone; its empty listing says so.
        return result.status == 0 || result.status == 1 ? result.text : nil
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProcessTable?
        var table: ProcessTable? { lock.withLock { stored } }
        func store(_ table: ProcessTable) { lock.withLock { stored = table } }
    }

    private static let cache = Cache()

    // MARK: - Parsing

    private struct Row {
        var pid: Int32
        var ppid: Int32
        var tty: String
        var rest: String
    }

    private static func rows(_ text: String, columns: Columns) -> [Row] {
        let count: Int
        switch columns {
        case .pidPPIDTTY: count = 3
        case .pidPPID: count = 2
        case .pid: count = 1
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: count, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == count + 1, let pid = Int32(fields[0]) else { return nil }
            let ppid = count >= 2 ? Int32(fields[1]) : 0
            guard let ppid else { return nil }
            return Row(pid: pid, ppid: ppid, tty: count == 3 ? String(fields[2]) : "??",
                       rest: String(fields[count]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Splits an `-E` command line without its plain line at the first word
    /// after the executable shaped like an upper-case environment entry.
    private static func splitEnvironment(_ line: String) -> (command: String, environment: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard let start = words.indices.dropFirst().first(where: { isEnvironmentEntry(words[$0]) }) else { return (line, "") }
        return (words[..<start].joined(separator: " "), words[start...].joined(separator: " "))
    }

    private static func isEnvironmentEntry(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } && !word[word.startIndex].isNumber
    }
}
