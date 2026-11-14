import Foundation

/// The processes of a CLI's background-session service
/// (`BackgroundSessionSupport`) among the user's processes, read from the
/// process list `SessionSlots.processList` gives once a quota cycle.
///
/// A worker runs a background session: its lifecycle record names it, it
/// reads no slot, so the session runs on the CLI's shared sign-in
/// (`AppState.noteUnisolatedSessions`). A process running one of the
/// service's management commands, the attach client and the supervisor
/// included, is no session and keeps no slot: `AppState.refreshSlotProcesses`
/// leaves it out of `slotDirectoryByProcess`, so `serveSessionSlots`
/// releases a slot only such a process reads, and `refreshSessions` counts
/// no session record it left.
struct BackgroundSessionProcesses: Equatable, Sendable {
    /// Worker processes, by process ID.
    var workers: Set<Int32> = []
    /// Attach clients, by process ID, with the session ID or the start of
    /// it each names; nil for a client that names none.
    var attachClients: [Int32: String?] = [:]
    /// Processes running a management command, attach clients included,
    /// or a launch with the background flag.
    var nonSessions: Set<Int32> = []
    /// Each process's parent.
    var parents: [Int32: Int32] = [:]
    /// Processes running a shell, as a session's Bash tool starts one.
    var shells: Set<Int32> = []

    /// Shells by executable name; a login shell's name starts with `-`.
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    init() {}

    /// Parses `ps -Eww -o pid=,ppid=,command=` output. A process is the
    /// CLI's when its first word, the executable, is named `executable`;
    /// the words after it are its arguments, and its environment follows.
    init(processList text: String, executable: String, support: BackgroundSessionSupport) {
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 3, let pid = Int32(words[0]), let parent = Int32(words[1]) else { continue }
            parents[pid] = parent
            let name = (String(words[2]) as NSString).lastPathComponent
            if Self.shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name) {
                shells.insert(pid)
                continue
            }
            guard name == executable else { continue }
            let arguments = words.dropFirst(3).map(String.init)
            guard let first = arguments.first else { continue }
            if support.workerCommands.contains(first) {
                workers.insert(pid)
            } else if support.managementCommands.contains(first) {
                nonSessions.insert(pid)
                if first == support.attachCommand {
                    // The first word after the command that is neither an
                    // option nor an environment entry names the session.
                    let named = arguments.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }
                    attachClients[pid] = .some(named)
                }
            } else if arguments.prefix(while: { !$0.contains("=") }).contains(support.backgroundFlag) {
                nonSessions.insert(pid)
            }
        }
    }

    func isWorker(_ pid: Int32?) -> Bool {
        pid.map { workers.contains($0) } ?? false
    }

    /// The attach client showing the session with `sessionID`, the newest
    /// when several do; nil when none names it.
    func attachClient(of sessionID: String) -> Int32? {
        attachClients.compactMap { pid, named -> Int32? in
            guard let named, !named.isEmpty, sessionID.hasPrefix(named) else { return nil }
            return pid
        }.max()
    }

    /// Whether a shell runs anywhere below `pid`: a background session's
    /// Bash tool runs its commands in shells its worker starts, and one
    /// still running is work the session would lose if it stopped.
    func hasShell(under pid: Int32) -> Bool {
        var children: [Int32: [Int32]] = [:]
        for (child, parent) in parents { children[parent, default: []].append(child) }
        var pending = children[pid] ?? []
        var seen = Set<Int32>()
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            if shells.contains(next) { return true }
            pending += children[next] ?? []
        }
        return false
    }
}

/// What decides whether a background session may be stopped and resumed in
/// a slot of its own (`AppState.restartBlocker`), read when the unisolated
/// sessions are noted and again just before a restart.
struct BackgroundSessionState: Equatable, Sendable {
    /// When its transcript, or a subagent's, last changed; nil when none
    /// was found.
    var transcriptChangedAt: Date?
    /// Whether a shell runs under its worker (`hasShell(under:)`).
    var shellRunning = false
    /// The attach client showing it in a terminal.
    var attachProcess: Int32?

    /// How long its transcripts must have been quiet: a turn that ended
    /// may still be finishing a subagent's work or a background task.
    static let quietPeriod: TimeInterval = 2 * 60

    func transcriptsQuiet(now: Date) -> Bool {
        transcriptChangedAt.map { now.timeIntervalSince($0) >= Self.quietPeriod } ?? true
    }

    /// The newest modification time of the session's transcript,
    /// `<project>/<session>.jsonl` under `root`, and of every transcript
    /// below `<project>/<session>/subagents`, where its subagents and
    /// workflow subagents write theirs.
    static func transcriptChangedAt(session: String, root: URL) -> Date? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        var newest: Date?
        func note(_ date: Date?) {
            guard let date else { return }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for project in projects {
            let transcript = project.appendingPathComponent(session + ".jsonl")
            if fm.fileExists(atPath: transcript.path) { note(modified(transcript)) }
            var pending = [project.appendingPathComponent(session, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)]
            while let directory = pending.popLast() {
                let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                for item in items {
                    if item.pathExtension == "jsonl" {
                        note(modified(item))
                    } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        pending.append(item)
                    }
                }
            }
        }
        return newest
    }
}

/// Runs a background-session command of the CLI, such as stopping one;
/// replaced by a fake in tests.
protocol BackgroundSessionControl: Sendable {
    /// Ends the background session with `sessionID`. Returns whether the
    /// command succeeded.
    func stop(_ sessionID: String, executable: String, support: BackgroundSessionSupport) async -> Bool
}

/// `<cli> stop <id>`, run directly rather than through the launcher, limited
/// to `timeout`.
struct CLIBackgroundSessionControl: BackgroundSessionControl {
    static let timeout: TimeInterval = 30

    func stop(_ sessionID: String, executable: String, support: BackgroundSessionSupport) async -> Bool {
        guard let result = try? await BoundedProcess.run(
            executable: URL(fileURLWithPath: executable),
            arguments: [support.stopCommand, sessionID],
            timeout: Self.timeout
        ) else { return false }
        return result.status == 0
    }
}
