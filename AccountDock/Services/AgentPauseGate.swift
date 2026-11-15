import Foundation

private let gateLog = FileLog("PauseGate")

/// Pauses Claude Code and Codex sessions between tool calls without stopping
/// their processes.
///
/// A `PostToolUse` hook runs `accountdock-gate.sh` after every tool call. It
/// returns at once unless a pause file exists; then it waits until AccountDock
/// removes the file, which holds the session before its next model request. The session's terminal stays attached and
/// usable throughout, which a `SIGSTOP` cannot guarantee: an interactive shell
/// takes the terminal back from a stopped foreground job and leaves the
/// continued agent in the background.
///
/// While a pause holds new turns, which every pause AccountDock writes does,
/// every session is held at its next tool call, including sessions that were
/// not seen mid-turn when the pause began and the subagents and workflow
/// agents running inside a session, which share its session ID. The pause
/// file's session list counts the sessions for display and orders the steps
/// released within headroom. A `UserPromptSubmit` hook runs the same script,
/// so a turn started during the pause waits before its first request instead
/// of being refused at the limit. The CLI's `continuationEvents` run it too,
/// so a session that compacts its conversation waits before the compaction's
/// request and before the request that continues the turn afterwards.
enum AgentPauseGate {
    static let marker = "# accountdock-gate"
    /// A session waits at most this long in one hook call.
    static let maximumWait: TimeInterval = 24 * 60 * 60
    /// Room between a wait's end and the hook timeout, so the CLI never
    /// records a full wait as a hook failure.
    static let timeoutMargin = 120

    /// The timeout the gate hook is installed with: the full wait, or the
    /// longest the CLI accepts (`PauseGateSupport.maximumHookTimeout`).
    static func hookTimeout(_ provider: AIProviderType) -> Int {
        let full = Int(maximumWait) + timeoutMargin
        return min(full, provider.capabilities.pauseGate?.maximumHookTimeout ?? full)
    }

    /// How long one hook call of `provider` waits.
    static func waitLimit(_ provider: AIProviderType) -> Int { max(1, hookTimeout(provider) - timeoutMargin) }

    /// Whether a wait cut short by the CLI's hook limit ends by refusing the
    /// step, so a pause outlasting one hook call still holds the session:
    /// the refused step is asked for again and waits again.
    ///
    /// Not while the CLI's requests go through the router
    /// (`ProviderRequestHold`): the step then goes on and its next request
    /// waits in the router, which costs no model request.
    static func refusesAtWaitLimit(_ provider: AIProviderType, requestsHeld: Bool? = nil) -> Bool {
        waitLimit(provider) < Int(maximumWait) && !(requestsHeld ?? ProviderRequestHold.isActive(provider))
    }

    /// The command each gate hook runs, which `synchronize` compares with the
    /// installed one to repair a stale entry.
    static func hookCommand(_ provider: AIProviderType, requestsHeld: Bool? = nil) -> String? {
        guard let key = key(provider) else { return nil }
        let script = scriptURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let refusal = refusesAtWaitLimit(provider, requestsHeld: requestsHeld) ? " refuse" : ""
        return "/bin/sh '\(script)' \(key) \(waitLimit(provider))\(refusal) \(marker)"
    }

    static var providers: [AIProviderType] { AIProviderType.implementedProviders.filter { $0.capabilities.pauseGate != nil } }

    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock", isDirectory: true)
    }
    static var pauseDirectory: URL { supportDirectory.appendingPathComponent("Pause", isDirectory: true) }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("bin/accountdock-gate.sh") }

    /// Name used by the gate script, the session records and the pause file.
    static func key(_ provider: AIProviderType) -> String? { provider.capabilities.pauseGate?.key }

    static func pauseFileURL(_ provider: AIProviderType, directory: URL = pauseDirectory) -> URL? {
        key(provider).map { directory.appendingPathComponent("\($0).json") }
    }

    private static func hookFileURL(_ provider: AIProviderType) -> URL? {
        provider.capabilities.pauseGate.map {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0.hookFile)
        }
    }

    /// The event the gate waits on: the one each CLI awaits after a model
    /// response.
    static func gateEvent(_ provider: AIProviderType) -> String {
        provider.capabilities.pauseGate?.gateEvent ?? "PostToolUse"
    }

    /// Every event the gate hook is installed for.
    static func gateEvents(_ provider: AIProviderType) -> [String] {
        [gateEvent(provider), "UserPromptSubmit"] + (provider.capabilities.pauseGate?.continuationEvents ?? [])
    }

    // MARK: - Pause file

    struct PauseFile: Codable, Equatable {
        var sessions: [String]
        var reason: String
        var pausedAt: Date
        var resumeAt: Date?
        /// New turns wait at their start while this file exists.
        var holdsNewTurns: Bool?
        /// Started by the user. It holds while the active account is one
        /// failover excludes, and releases no steps within headroom.
        var manual: Bool?
        /// Set when the pause holds only the sessions of this account until
        /// its limiting window resets at `resumeAt`, keeping their prompt
        /// caches; they continue on it, not elsewhere.
        var account: UUID?
        /// The listed sessions also wait at the start of a new turn, while
        /// other sessions' new turns go on (`holdsNewTurns` holds them all).
        var holdsListedNewTurns: Bool?
        /// Sessions the user paused one at a time (`pauseOne`), also listed
        /// in `sessions`. Whatever ends the pause around them, they stay
        /// held until the user plays them or resumes all
        /// (`narrowToChosen`).
        var chosen: [String]?

        /// A pause the user started for sessions chosen one at a time
        /// (`pauseOne`): it holds only its listed sessions, and only the
        /// user ends it, so `AppState`'s capacity checks leave it alone.
        var holdsOnlyChosenSessions: Bool {
            manual == true && holdsNewTurns != true && account == nil
        }

        /// The sessions in `chosen` still listed.
        var chosenListed: [String] {
            (chosen ?? []).filter(sessions.contains)
        }
    }

    static func read(_ provider: AIProviderType, directory: URL = pauseDirectory) -> PauseFile? {
        guard let url = pauseFileURL(provider, directory: directory),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PauseFile.self, from: data)
    }

    static func write(_ pause: PauseFile, for provider: AIProviderType, directory: URL = pauseDirectory) {
        guard let url = pauseFileURL(provider, directory: directory) else { return }
        // A new pause starts without the previous one's continuation or
        // resumed sessions.
        if !FileManager.default.fileExists(atPath: url.path) {
            if let continued = continuationURL(provider, directory: directory) {
                try? FileManager.default.removeItem(at: continued)
            }
            removeResumed(provider, directory: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(pause).write(to: url, options: .atomic)
        } catch {
            gateLog.warning("Could not write the \(provider.rawValue) pause file: \(error.localizedDescription)")
        }
    }

    /// Ends the pause. `continuation` says where the held sessions go on,
    /// such as "on Kimi K3" or "on account Work"; the gate shows it to the
    /// user and the agent as each session continues.
    static func release(_ provider: AIProviderType, continuation: String? = nil, directory: URL = pauseDirectory) {
        guard let url = pauseFileURL(provider, directory: directory) else { return }
        if let continuation, let continued = continuationURL(provider, directory: directory) {
            try? Data(sanitizedForScript(continuation).utf8).write(to: continued, options: .atomic)
        }
        try? FileManager.default.removeItem(at: url)
        removeResumed(provider, directory: directory)
    }

    /// Where the sessions of the last released pause continue.
    static func continuation(_ provider: AIProviderType, directory: URL = pauseDirectory) -> String? {
        continuationURL(provider, directory: directory).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func continuationURL(_ provider: AIProviderType, directory: URL) -> URL? {
        key(provider).map { directory.appendingPathComponent("\($0).continued") }
    }

    /// One line the gate can place in its JSON reply as is.
    static func sanitizedForScript(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "\"" && $0 != "\\" && !CharacterSet.newlines.contains($0) }
            .prefix(160).map(Character.init))
    }

    /// Keeps the pause on for `sessions` only, and the sessions the user
    /// paused one at a time (`PauseFile.chosen`), each held at its next tool
    /// call and new turn. Every other waiting session continues
    /// `continuation`, which the gate tells it.
    static func narrow(
        _ provider: AIProviderType, to sessions: [String], reason: String, continuation: String?,
        directory: URL = pauseDirectory
    ) {
        // The note is written before the sessions it concerns are let go; a
        // new pause file starts without one, so it follows that write.
        func note() {
            if let continuation, let continued = continuationURL(provider, directory: directory) {
                try? Data(sanitizedForScript(continuation).utf8).write(to: continued, options: .atomic)
            }
        }
        let existing = read(provider, directory: directory)
        if existing != nil { note() }
        var pause = existing ?? PauseFile(sessions: [], reason: reason, pausedAt: Date(), resumeAt: nil)
        pause.sessions = sessions + (existing?.chosenListed ?? []).filter { !sessions.contains($0) }
        pause.reason = reason
        pause.holdsNewTurns = false
        pause.holdsListedNewTurns = true
        pause.manual = nil
        pause.account = nil
        write(pause, for: provider, directory: directory)
        if existing == nil { note() }
    }

    static func isActive(_ provider: AIProviderType, directory: URL = pauseDirectory) -> Bool {
        guard let pause = read(provider, directory: directory) else { return false }
        return !pause.sessions.isEmpty || pause.holdsNewTurns == true
    }

    /// Lets one paused session take one more step: the gate consumes the
    /// allowance and holds the session again at its next tool call.
    static func allowStep(_ provider: AIProviderType, session: String, directory: URL = pauseDirectory) {
        guard let key = key(provider) else { return }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("\(key)-\(session).allow").path, contents: nil)
    }

    static func hasPendingStep(_ provider: AIProviderType, session: String, directory: URL = pauseDirectory) -> Bool {
        guard let key = key(provider) else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(key)-\(session).allow").path)
    }

    /// Sessions currently held inside the gate; the script keeps a marker
    /// file for each while it waits.
    static func waitingSessions(_ provider: AIProviderType, directory: URL = pauseDirectory) -> Set<String> {
        Set(sessionFiles(provider, suffix: ".waiting", directory: directory))
    }

    /// The process of each gate waiting now, by session, read from its
    /// marker file. `AppState.resumeFrontmostSession` finds through it the
    /// session in the window the user is looking at.
    static func waitingGates(_ provider: AIProviderType, directory: URL = pauseDirectory) -> [String: Int32] {
        guard let key = key(provider) else { return [:] }
        var gates: [String: Int32] = [:]
        for session in sessionFiles(provider, suffix: ".waiting", directory: directory) {
            let url = directory.appendingPathComponent("\(key)-\(session).waiting")
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                gates[session] = pid
            }
        }
        return gates
    }

    /// Lets one session go on for the rest of the pause while the others
    /// stay held: the gate stops holding it at once, at its later tool calls
    /// and at its new turns. The next pause holds it again.
    static func resume(_ provider: AIProviderType, session: String, directory: URL = pauseDirectory) {
        guard let key = key(provider) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("\(key)-\(session).resumed").path, contents: nil)
    }

    /// Holds a resumed session again, at its next tool call, for as long as
    /// the pause lasts.
    static func hold(_ provider: AIProviderType, session: String, directory: URL = pauseDirectory) {
        guard let key = key(provider), var pause = read(provider, directory: directory) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key)-\(session).resumed"))
        if !pause.sessions.contains(session) {
            pause.sessions.append(session)
            write(pause, for: provider, directory: directory)
        }
    }

    /// Holds one session at the user's request. With no pause in effect it
    /// writes a pause of the user's that lists only `session`: the gate
    /// holds it at its next tool call and new turn, and lets every other
    /// session's tool calls and turns pass (`holdsNewTurns` false,
    /// `holdsListedNewTurns` true). With a pause in effect, such as one at
    /// a limit holding the sessions of one account, the session is held by
    /// it again (`hold`). Either way it is marked `chosen`, so it stays held
    /// when that pause ends (`narrowToChosen`). Returns whether a new pause
    /// was written.
    @discardableResult
    static func pauseOne(_ provider: AIProviderType, session: String, at now: Date = Date(),
                         directory: URL = pauseDirectory) -> Bool {
        guard key(provider) != nil else { return false }
        guard read(provider, directory: directory) == nil else {
            hold(provider, session: session, directory: directory)
            if var pause = read(provider, directory: directory), pause.chosen?.contains(session) != true {
                pause.chosen = (pause.chosen ?? []) + [session]
                write(pause, for: provider, directory: directory)
            }
            return false
        }
        write(PauseFile(sessions: [session], reason: "paused by you", pausedAt: now, resumeAt: nil,
                        holdsNewTurns: false, manual: true, holdsListedNewTurns: true, chosen: [session]),
              for: provider, directory: directory)
        return true
    }

    /// Ends a pause except for the sessions the user paused one at a time
    /// (`PauseFile.chosen`): the pause becomes the user's own, listing only
    /// them, as `pauseOne` writes it, and every other session continues
    /// `continuation`. A pause holding only such sessions is left as it is.
    /// Returns whether a pause stays in effect; with none chosen, nothing
    /// is written and the caller releases the pause. Read by
    /// `AppState.endPause`, through which every pause ends.
    static func narrowToChosen(_ provider: AIProviderType, continuation: String?,
                               directory: URL = pauseDirectory) -> Bool {
        guard let pause = read(provider, directory: directory) else { return false }
        if pause.holdsOnlyChosenSessions { return true }
        let chosen = pause.chosenListed
        guard !chosen.isEmpty else { return false }
        if let continuation, let continued = continuationURL(provider, directory: directory) {
            try? Data(sanitizedForScript(continuation).utf8).write(to: continued, options: .atomic)
        }
        write(PauseFile(sessions: chosen, reason: "paused by you", pausedAt: pause.pausedAt, resumeAt: nil,
                        holdsNewTurns: false, manual: true, holdsListedNewTurns: true, chosen: chosen),
              for: provider, directory: directory)
        return true
    }

    /// The sessions the provider's pause holds now: those it lists, those
    /// waiting in the gate and, while it holds new turns, every one of
    /// `running`, less those the user resumed. Empty with no pause.
    /// `AppState.pausedSessions` lists them and `playOne` ends a pause
    /// left holding none.
    static func heldSessions(_ provider: AIProviderType, running: Set<String>,
                             directory: URL = pauseDirectory) -> Set<String> {
        guard let pause = read(provider, directory: directory) else { return [] }
        let held = Set(pause.sessions).union(waitingSessions(provider, directory: directory))
        return (pause.holdsNewTurns == true ? held.union(running) : held)
            .subtracting(resumedSessions(provider, directory: directory))
    }

    /// Lets one session go on while the pause holds the others (`resume`)
    /// and drops it from the pause's list. When the pause then holds no
    /// session that is running or waiting in the gate, it is released with
    /// `continuation`, so no pause is left in effect that holds nothing.
    /// Returns whether the pause was released.
    @discardableResult
    static func playOne(_ provider: AIProviderType, session: String, running: Set<String>,
                        continuation: String? = nil, directory: URL = pauseDirectory) -> Bool {
        guard var pause = read(provider, directory: directory) else { return false }
        resume(provider, session: session, directory: directory)
        if pause.sessions.contains(session) || pause.chosen?.contains(session) == true {
            pause.sessions.removeAll { $0 == session }
            pause.chosen?.removeAll { $0 == session }
            write(pause, for: provider, directory: directory)
        }
        // A listed session whose process is gone holds nothing, though the
        // list keeps it until its record shows it ended.
        let present = running.union(waitingSessions(provider, directory: directory))
        guard heldSessions(provider, running: running, directory: directory).isDisjoint(with: present) else { return false }
        release(provider, continuation: continuation, directory: directory)
        return true
    }

    /// Ends the user's resumes of `sessions`, so the pause holds them again.
    static func clearResumed(_ provider: AIProviderType, sessions: [String], directory: URL = pauseDirectory) {
        guard let key = key(provider) else { return }
        for session in sessions {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key)-\(session).resumed"))
        }
    }

    /// Sessions resumed by the user during the current pause.
    static func resumedSessions(_ provider: AIProviderType, directory: URL = pauseDirectory) -> Set<String> {
        Set(sessionFiles(provider, suffix: ".resumed", directory: directory))
    }

    private static func removeResumed(_ provider: AIProviderType, directory: URL) {
        guard let key = key(provider) else { return }
        for session in sessionFiles(provider, suffix: ".resumed", directory: directory) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key)-\(session).resumed"))
        }
    }

    /// Session IDs of the provider's `<key>-<session><suffix>` files.
    private static func sessionFiles(_ provider: AIProviderType, suffix: String, directory: URL) -> [String] {
        guard let key = key(provider),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let prefix = "\(key)-"
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { String($0.dropFirst(prefix.count).dropLast(suffix.count)) }
    }

    // MARK: - Session activity

    /// Sessions whose current turn is still running: the last lifecycle event
    /// was a prompt submission and the agent process is alive.
    static func turningSessions(
        _ provider: AIProviderType,
        directory: URL = AgentSessions.directory,
        now: Date = Date(),
        isAlive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 }
    ) -> [String] {
        AgentSessions.live(provider, directory: directory, now: now, isAlive: isAlive)
            .filter(\.isWorking).map(\.sessionID)
    }

    /// The sessions of `pause` still to be counted: a session leaves the list
    /// once it ended after the pause began, or once its process no longer
    /// runs (`isRunning`). Any other activity keeps it listed: a prompt
    /// during the pause waits at its start, and a session's subagents report
    /// back to it as prompts.
    static func stillHeld(_ pause: PauseFile, records: [String: AgentSession],
                          isRunning: (AgentSession) -> Bool = { AgentSessions.isRunning($0) }) -> [String] {
        pause.sessions.filter { session in
            guard let record = records[session], let observedAt = record.observedAt else { return true }
            // A session whose process is gone, or whose process ID now
            // belongs to another program, ended without a SessionEnd.
            if record.processID != nil, !isRunning(record) { return false }
            return record.event != "SessionEnd" || observedAt <= pause.pausedAt
        }
    }

    // MARK: - Hook installation

    /// Installs the gate hook for providers that pause agents and removes it
    /// for the rest. Safe to call repeatedly. `rewrite` writes a current
    /// gate again too; one written with the same events and timeout keeps its
    /// install time, since running sessions keep running it.
    static func synchronize(enabledFor enabled: Set<AIProviderType>, rewrite: Bool = false) {
        do {
            try writeScript()
            for provider in providers {
                guard let url = hookFileURL(provider), let command = hookCommand(provider) else { continue }
                let timeout = hookTimeout(provider)
                let wanted = enabled.contains(provider)
                // Current only when every event runs this command with this
                // timeout, so a gate written with other arguments is replaced.
                guard let format = provider.capabilities.pauseGate?.format else { continue }
                let current = HookConfigEditor.hasHooks(format, at: url, events: gateEvents(provider), marker: marker,
                                                        command: command, timeout: timeout)
                if wanted, current, installedMarker(provider) == nil {
                    // Installed before the time was kept: when is unknown, and
                    // the hook file's modification time records unrelated
                    // edits too, so every session counts as having the gate.
                    markInstalled(provider, at: .distantPast)
                }
                guard wanted != current || (!wanted && isInstalled(at: url)) || (wanted && rewrite) else { continue }
                if wanted, !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { continue }
                // A repair that keeps the events and timeout leaves running
                // sessions' gates working, since they run the same script;
                // any other write is one sessions started earlier never read.
                let sameShape = HookConfigEditor.hasHooks(format, at: url, events: gateEvents(provider), marker: marker,
                                                          timeout: timeout)
                if wanted {
                    // Each event's marked hooks are replaced, so a gate written
                    // with other arguments is not added to.
                    try HookConfigEditor.install(format, at: url, events: gateEvents(provider), command: command,
                                                 timeout: timeout, marker: marker)
                } else {
                    try HookConfigEditor.uninstall(format, at: url, events: gateEvents(provider), marker: marker)
                }
                if wanted {
                    if !sameShape || installedMarker(provider) == nil { markInstalled(provider, at: Date()) }
                } else {
                    try? FileManager.default.removeItem(at: installedURL(provider))
                }
                gateLog.info("Pause gate \(wanted ? "installed" : "removed") for \(url.path)")
            }
        } catch {
            gateLog.warning("Pause gate update failed: \(error.localizedDescription)")
        }
    }

    /// When the provider's gate hook was written in the form its CLI now
    /// reads. A CLI reads its hooks when it starts, so a session started
    /// earlier runs without the gate and a pause cannot hold it
    /// (`AppState.sessionsWithoutGate`). Nil while no gate is installed.
    static func installedAt(_ provider: AIProviderType, directory: URL = pauseDirectory) -> Date? {
        installedMarker(provider, directory: directory)
    }

    private static func installedURL(_ provider: AIProviderType, directory: URL = pauseDirectory) -> URL {
        directory.appendingPathComponent("\(key(provider) ?? provider.capabilities.storageKey).installed")
    }

    private static func installedMarker(_ provider: AIProviderType, directory: URL = pauseDirectory) -> Date? {
        guard let text = try? String(contentsOf: installedURL(provider, directory: directory), encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func markInstalled(_ provider: AIProviderType, at date: Date, directory: URL = pauseDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(ISO8601DateFormatter().string(from: date).utf8).write(to: installedURL(provider, directory: directory), options: .atomic)
    }

    static func isInstalled(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    private static func writeScript() throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pauseDirectory, withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Fast path: one file test per tool call while nothing is paused.
    /// While waiting it keeps a marker file holding its process ID, for
    /// AccountDock's display and for finding the session to resume, and sets
    /// a terminal title naming the resume shortcut (pushed and popped, so the
    /// session's own title returns). A session the user resumed
    /// (`resume(_:session:)`) is not held. A wait cut short by the CLI's hook limit while the pause
    /// still holds refuses the step with exit status 2 and a reason
    /// (`refusesAtWaitLimit`). When the wait ends, a provider whose CLI reads
    /// the hook's reply (`PauseGateSupport.reply`) is told the pause length
    /// and where the session continues, and its agent is told to check the
    /// subagents, workflows and background work it started, whose requests
    /// may have failed during the pause without anything resuming them.
    /// Every way a pause ends reaches the session through this one reply.
    static var script: String {
        let replies = providers.compactMap { $0.capabilities.pauseGate }.compactMap { gate -> String? in
            switch gate.reply {
            case .systemMessageAndContext:
                // `PreCompact` takes no added context; the agent is told at
                // the `SessionStart` that follows the compaction.
                #"\#(gate.key)) if [ "$event" = PreCompact ]; then printf '{"systemMessage":"AccountDock paused this session for %s min; it continues %s."}\n' "$minutes" "$where"; else printf '{"systemMessage":"AccountDock paused this session for %s min; it continues %s.","hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$minutes" "$where" "${event:-PostToolUse}" "$note"; fi ;;"#
            case .message:
                #"\#(gate.key)) printf '{"message":"%s"}\n' "$note" ;;"#
            case nil:
                nil
            }
        }
        return scriptTemplate
            .replacingOccurrences(of: "@REPLIES@", with: replies.joined(separator: "\n    "))
            .replacingOccurrences(of: "@SHORTCUT@", with: SessionResumeShortcut.display)
    }

    private static let scriptTemplate = #"""
    #!/bin/sh
    # accountdock-gate: holds a paused session after a tool call or around a
    # compaction, and a new turn at its start while the pause holds new
    # turns, or that session's.
    provider="$1"
    limit="${2:-86400}"
    refuse=0
    [ "$3" = refuse ] && refuse=1
    dir="$HOME/Library/Application Support/AccountDock/Pause"
    pause="$dir/$provider.json"
    [ -f "$pause" ] || exit 0
    payload=$(/bin/cat)
    sid=$(printf '%s' "$payload" | /usr/bin/sed -n 's/.*"session_\{0,1\}[iI]d"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._:-]*\)".*/\1/p' | /usr/bin/head -n 1)
    [ -n "$sid" ] || exit 0
    event=$(printf '%s' "$payload" | /usr/bin/sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | /usr/bin/head -n 1)
    # A session starting, resuming or cleared is not held; one continuing
    # after compaction is about to send its next request.
    if [ "$event" = "SessionStart" ]; then
        printf '%s' "$payload" | /usr/bin/grep -Eq '"source"[[:space:]]*:[[:space:]]*"compact"' || exit 0
    fi
    newturn=0
    [ "$event" = "UserPromptSubmit" ] && newturn=1
    resumed="$dir/$provider-$sid.resumed"
    held() {
        [ -f "$pause" ] || return 1
        [ -f "$resumed" ] && return 1
        /usr/bin/grep -Eq '"holdsNewTurns"[[:space:]]*:[[:space:]]*true' "$pause" 2>/dev/null && return 0
        /usr/bin/grep -q "\"$sid\"" "$pause" 2>/dev/null || return 1
        [ "$newturn" = 0 ] && return 0
        /usr/bin/grep -Eq '"holdsListedNewTurns"[[:space:]]*:[[:space:]]*true' "$pause" 2>/dev/null
    }
    held || exit 0
    allow="$dir/$provider-$sid.allow"
    # One step granted while capacity remains: take it and continue.
    [ "$newturn" = 0 ] && /bin/rm "$allow" 2>/dev/null && exit 0
    marker="$dir/$provider-$sid.waiting"
    echo "$$" > "$marker" 2>/dev/null
    trap '/bin/rm -f "$marker"' EXIT
    trap 'exit 0' INT TERM HUP
    start=$(/bin/date +%s)
    titled=0
    if { printf '\033[22;0t\033]0;%s\007' "⏸ Paused by AccountDock · @SHORTCUT@ resumes" > /dev/tty; } 2>/dev/null; then titled=1; fi
    expired=0
    while held; do
        [ $(( $(/bin/date +%s) - start )) -ge "$limit" ] && expired=1 && break
        [ "$newturn" = 0 ] && /bin/rm "$allow" 2>/dev/null && break
        /bin/sleep 2
    done
    [ "$titled" = 1 ] && { printf '\033[23;0t' > /dev/tty; } 2>/dev/null
    # The CLI's hook limit ended the wait with the pause still on: refuse the
    # step, which the agent asks for again and which then waits again.
    if [ "$refuse" = 1 ] && [ "$expired" = 1 ] && held; then
        if [ "$newturn" = 1 ]; then
            echo "AccountDock has paused this session, so this message was not sent to the model. Send it again once AccountDock shows the pause has ended." >&2
        else
            echo "AccountDock has paused this session, so this tool call did not run. Call it again unchanged: the call waits until the pause ends and then runs." >&2
        fi
        exit 2
    fi
    minutes=$(( ($(/bin/date +%s) - start + 59) / 60 ))
    where=$(/bin/cat "$dir/$provider.continued" 2>/dev/null)
    [ -f "$pause" ] && held && where="one step at a time while the pause lasts"
    [ -f "$pause" ] && [ -f "$resumed" ] && where="because you resumed it, while other sessions stay paused"
    where="${where:-on the same account, another account or another provider}"
    note="AccountDock held this session for $minutes min while it was paused, and it has now continued $where. Requests that subagents, background agents, workflows, teammates or background commands made during the pause may have failed with an API, rate-limit or usage-limit error, or been interrupted. Before going on, check every one you started: confirm each is still running or has finished and reported its result. Resume or restart any that stopped, failed or never reported back, without repeating work that already completed."
    case "$provider" in
        @REPLIES@
    esac
    exit 0
    """#
}
