import Darwin
import Foundation

private let slotsLog = FileLog("SessionSlots")

/// Serves the sessions of every provider whose CLI can run each session in
/// a slot of its own (`AIProviderType.isolatedProviders`) from several
/// accounts at once through `SessionSlots`, instead of the router. Only the
/// provider's `ProviderSessionIsolation` knows its CLI; everything here is
/// the same for every provider.
extension AppState {
    /// One provider's slots as `maintainSessionSlots` and
    /// `refreshSlotProcesses` last found them. Paths and account IDs are
    /// unique across providers, since each provider's slots live under its
    /// own root, so readers merge every provider's maps.
    struct SessionSlotState {
        /// The slot directory each running process reads; read by
        /// `sessionAttribution` and `slotAccount(forSession:)`.
        var directoryByProcess: [Int32: String] = [:]
        /// The folder each slot's process runs in (its `PWD`), by slot path,
        /// read with `directoryByProcess` (`slotFolders`); names a run with
        /// no session record in the events (`unrecordedRunName`).
        var folderByDirectory: [String: String] = [:]
        /// The slots a process that may hold a session reads
        /// (`slotRunDirectories`): only these become runs when no live
        /// session record names their process.
        var runDirectories: Set<String> = []
        /// The account serving each slot that has running sessions.
        var directoryServing: [String: UUID] = [:]
        /// Accounts whose slot a running session reads; they are read and
        /// planned as in use.
        var servedAccounts: Set<UUID> = []
        /// Accounts whose access token a slot holds, for running or new
        /// sessions; read by `credentialIsUsable` and
        /// `renewSavedCredential`, because renewing such an account's saved
        /// copy revokes the token those slots hold.
        var credentialAccounts: Set<UUID> = []
        /// Sessions `SessionPacer` moves to another account to balance
        /// load, applied to one-session slots by `serveSessionSlots`.
        var sessionMoves: [String: UUID] = [:]
        /// The sessions among `sessionMoves` that move to spend an
        /// allowance that would otherwise expire (`SessionPacer.Plan.remainders`),
        /// for the event `serveSessionSlots` records when it moves one.
        var remainderMoves: [String: RemainderMove] = [:]
        /// The CLI's background-session processes, read with the slots: its
        /// workers are sessions on the shared sign-in, its attach clients
        /// and other commands no sessions.
        var background = BackgroundSessionProcesses()
        /// Watches the session slot directory for a launcher's request to
        /// fill its slot; installed by `watchSlotRequests`.
        var slotRequestWatcher: DispatchSourceFileSystemObject?
        /// The slots `fillRequestedSlots` is filling, so a second request
        /// meanwhile does not fill one twice.
        var filling: Set<String> = []
        /// Whether this run of AccountDock has written the provider's
        /// `SessionSlots.startedFile` and, after its first pass, its
        /// `readyFile`.
        var startedMarked = false
        var readyMarked = false
        /// Whether the last `refreshSlotProcesses` read the whole process
        /// list (`processScanSucceeded`). Until it has, the maps above keep
        /// what the last whole reading found, and `serveSessionSlots` and
        /// `serveRunning` remove no slot a process may still read: a list
        /// that failed or came back short names no process, which would
        /// read as every session having ended.
        var scanSucceeded = false
        /// The processes each slot was last seen read by in a whole
        /// reading, with their start times (`slotReaders`).
        /// `serveSessionSlots` removes a claimed slot as gone only once
        /// every one of them has ended (`sessionGoneBlocker`), so a process
        /// whose environment one reading missed keeps its slot.
        var readers: [String: [SlotReader]] = [:]
        /// The CLI's own registry of the session each process holds, as
        /// the last whole reading found it (`CLISessionRegistry`); names the
        /// session of a slot `restoreMissingSlots` recreates when no live
        /// record does yet, as on the first pass after launch.
        var registry: [Int32: CLISessionRegistry.Entry] = [:]
        /// The account the credential audit last recorded for each slot
        /// `restoreMissingSlots` looked up (`CredentialAudit.lastSlotAccounts`),
        /// and every slot looked up, found or not, so the trail is read once
        /// per slot.
        var auditAccounts: [String: UUID] = [:]
        var auditLooked: Set<String> = []
        /// Why each claimed slot past its grace was kept rather than removed
        /// as gone, so the log records each reason once per slot.
        var removalHeld: [String: String] = [:]
        /// Missing slots `restoreMissingSlots` could not write again, so the
        /// log records each once until it succeeds.
        var restoreFailures: Set<String> = []
        /// The sessions seen reading each claimed slot, by its live record
        /// or the CLI's registry (`noteSlotSessions`); a pin or a registry
        /// entry naming one of them keeps the slot (`SlotGoneEvidence`).
        var slotSessions: [String: Set<String>] = [:]
        /// When each claimed slot was last read in a whole scan; its grace
        /// runs from then (`SlotGoneEvidence.idleSince`).
        var lastSeenInUse: [String: Date] = [:]
        /// Processes the CLI's registry lists whose environment the last
        /// whole reading could not read (absent from it, or listed with
        /// none): the slot such a process reads is unknown, so its
        /// registry entry still speaks for the slot of its session.
        var unreadProcesses: Set<Int32> = []
        /// Since when more claimed slots than `maximumGoneRemovals` have
        /// stood to be removed as gone in one pass (`goneRemovals`).
        var massRemovalSince: Date?
        /// The session the credential audit last named for each claimed slot
        /// that records none itself (`CredentialAudit.lastSlotSessions`), and
        /// every slot looked up, found or not, so the trail is read once per
        /// slot.
        var auditSessions: [String: String] = [:]
        var auditSessionsLooked: Set<String> = []
        /// The slots the last pass offered back to their sessions, by path,
        /// with the session; the pass that finds one read again records that
        /// its session took it back.
        var reclaimOffered: [String: String] = [:]

        /// Drops a removed account.
        mutating func forget(_ id: UUID) {
            servedAccounts.remove(id)
            credentialAccounts.remove(id)
            directoryServing = directoryServing.filter { $0.value != id }
            sessionMoves = sessionMoves.filter { $0.value != id }
            remainderMoves = remainderMoves.filter { $0.value.account != id }
        }
    }

    /// One process seen reading a slot: its ID and when it started, so a
    /// later process given the same ID is not taken for it.
    struct SlotReader: Equatable, Sendable {
        var pid: Int32
        var startedAt: Date?
    }

    /// The slot directory each running process reads, over every provider.
    var slotDirectoryByProcess: [Int32: String] {
        sessionSlotStates.values.reduce(into: [:]) { $0.merge($1.directoryByProcess) { kept, _ in kept } }
    }

    /// The account serving each slot that has running sessions, over every
    /// provider.
    var slotDirectoryServing: [String: UUID] {
        sessionSlotStates.values.reduce(into: [:]) { $0.merge($1.directoryServing) { kept, _ in kept } }
    }

    /// `SessionSlotState.servedAccounts` over every provider.
    var slotServedAccounts: Set<UUID> {
        sessionSlotStates.values.reduce(into: []) { $0.formUnion($1.servedAccounts) }
    }

    /// `SessionSlotState.credentialAccounts` over every provider.
    var slotCredentialAccounts: Set<UUID> {
        sessionSlotStates.values.reduce(into: []) { $0.formUnion($1.credentialAccounts) }
    }

    /// The provider's background-session processes, as `refreshSlotProcesses`
    /// last read them; none for a provider without slots.
    func backgroundProcesses(_ provider: AIProviderType) -> BackgroundSessionProcesses {
        sessionSlotStates[provider]?.background ?? BackgroundSessionProcesses()
    }

    /// Whether the provider's settings distribute sessions and its CLI
    /// starts each session on an account of its own; a route to another
    /// provider needs the router, which then serves the sessions.
    func sessionSlotsWanted(_ provider: AIProviderType) -> Bool {
        guard provider.capabilities.sessionIsolation != nil else { return false }
        let policy = failoverConfig.policy(for: provider)
        return policy.distributeSessions && !policy.usesRouter(for: provider)
    }

    /// Whether any provider's sessions are wanted in slots.
    var sessionSlotsWanted: Bool {
        AIProviderType.isolatedProviders.contains { sessionSlotsWanted($0) }
    }

    /// Whether new terminal sessions of the provider start on accounts
    /// picked from the pool.
    func sessionSlotsInUse(_ provider: AIProviderType) -> Bool {
        guard sessionSlotsWanted(provider), let slots = SessionSlots(provider) else { return false }
        return slots.launcherInstalled
    }

    /// Whether any provider's new terminal sessions start on accounts
    /// picked from the pool.
    var sessionSlotsInUse: Bool {
        AIProviderType.isolatedProviders.contains { sessionSlotsInUse($0) }
    }

    /// Runs on every quota cycle: keeps each isolated provider's launcher,
    /// its session slots and the pool and resume files current while its
    /// sessions are distributed, and afterwards removes them, keeping the
    /// slots running sessions still read. `processesRead` says
    /// `refreshSlotProcesses` has just run, as the quota cycle runs it
    /// before counting sessions. One call runs at a time; a call made
    /// meanwhile runs once more after it.
    func maintainSessionSlots(now: Date = Date(), processesRead: Bool = false) async {
        if slotMaintenanceRunning {
            slotMaintenanceRequested = true
            return
        }
        slotMaintenanceRunning = true
        await maintainSessionSlotsOnce(now: now, processesRead: processesRead)
        while slotMaintenanceRequested {
            slotMaintenanceRequested = false
            await maintainSessionSlotsOnce(now: Date(), processesRead: false)
        }
        slotMaintenanceRunning = false
        await applySlotRestarts(now: now)
    }

    /// Records, for every provider whose sessions are served from slots,
    /// that AccountDock runs (`SessionSlots.markStarted`), before its first
    /// pass over the slots: a launch then waits for that pass instead of
    /// starting the CLI unchanged. Called as AccountDock starts, and by
    /// each pass for a provider whose slots are turned on later.
    func markSlotsStarting() {
        for provider in AIProviderType.isolatedProviders where sessionSlotsWanted(provider) {
            guard let slots = SessionSlots(provider) else { continue }
            markStarted(slots, provider: provider)
        }
    }

    private func markStarted(_ slots: SessionSlots, provider: AIProviderType) {
        guard sessionSlotStates[provider]?.startedMarked != true else { return }
        slots.markStarted(pid: getpid(), name: Self.ownProcessName)
        sessionSlotStates[provider, default: SessionSlotState()].startedMarked = true
    }

    /// The name `ps -o comm=` ends with for AccountDock's own process: its
    /// executable's file name.
    nonisolated static var ownProcessName: String {
        Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
    }

    /// Fills a session slot as soon as its launcher asks
    /// (`SessionSlots.takeSlotRequests`), instead of at the next quota
    /// cycle: the launcher waits for it before it starts the CLI. The watch
    /// is on the provider's session slot directory, where the launcher
    /// leaves its request.
    func watchSlotRequests(_ slots: SessionSlots, provider: AIProviderType) {
        guard sessionSlotStates[provider]?.slotRequestWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: slots.sessionRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = open(slots.sessionRoot.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, await Task.detached(priority: .userInitiated, operation: { slots.takeSlotRequests() }).value else { return }
                await self.fillRequestedSlots(provider, slots: slots)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sessionSlotStates[provider, default: SessionSlotState()].slotRequestWatcher = source
    }

    /// The accounts a session slot a launcher asked for may be filled for,
    /// in order: a pinned session's pin alone, since a pinned session
    /// always comes back on its pin and waits there when the pin cannot
    /// serve it; else the account the launcher asked for (`requested`: the
    /// one its session last ran on, or the pool's pick), then the active
    /// account; each named once.
    nonisolated static func filledSlotAccounts(pinned: UUID?, requested: UUID?, active: UUID?) -> [UUID] {
        if let pinned { return [pinned] }
        return [requested, active].compactMap { $0 }.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    /// The account a slot offered back to its session serves: its
    /// session's pin when it has one, else the account it served. A pinned
    /// session's slot on another account is offered only once it holds the
    /// pin's credential (`pinServed`); otherwise nil, and the slot is not
    /// offered, so the session never resumes on that other account's token
    /// and the resume file names its pin instead.
    nonisolated static func reclaimAccount(own: UUID, pinned: UUID?, pinServed: Bool) -> UUID? {
        guard let pinned, pinned != own else { return own }
        return pinServed ? pinned : nil
    }

    /// Fills every session slot a launcher of `provider` waits on
    /// (`SessionSlots.wantedSlots`) for the first account of
    /// `filledSlotAccounts` whose credential can be written, so the session
    /// starts in its own slot on that account. A pinned session's slot is
    /// named for its pin even when no credential of the pin can be written
    /// now (it needs signing in again): the session starts there and waits,
    /// held by the pinned rules, never on another account. A slot whose
    /// launcher has ended is left for the pass that removes slots no process
    /// reads. Called when a launcher asks and at the start of every pass.
    func fillRequestedSlots(_ provider: AIProviderType, slots: SessionSlots, now: Date = Date()) async {
        guard sessionSlotsWanted(provider) else { return }
        let wanted = await Task.detached(priority: .userInitiated) { slots.wantedSlots() }.value
        let active = accounts.first { $0.provider == provider && $0.isActive }?.id
        for request in wanted {
            let path = request.directory.path
            guard sessionSlotStates[provider]?.filling.contains(path) != true else { continue }
            if let pid = request.claimer, !(Darwin.kill(pid, 0) == 0 || errno == EPERM) { continue }
            sessionSlotStates[provider, default: SessionSlotState()].filling.insert(path)
            defer { sessionSlotStates[provider]?.filling.remove(path) }
            let pinned = sessionPins.account(of: request.session)
            let candidates = Self.filledSlotAccounts(pinned: pinned, requested: request.account, active: active)
            let directory = request.directory
            let session = request.session
            let process = request.claimer
            var filled: (account: Account, credential: Bool)?
            for id in candidates {
                guard let account = accounts.first(where: { $0.id == id && $0.provider == provider }),
                      pinned == id || !needsSignIn(account) else { continue }
                let credential = await slots.isolation.currentSlotCredential(
                    for: account, minimumLifetime: readsLiveCredential(account) ? 60 : 2 * 60 * 60, from: self
                )
                guard credential != nil || pinned == id else { continue }
                let made = await Task.detached(priority: .userInitiated) {
                    slots.fill(directory, account: id, credential: credential, reason: "fillRequestedSlots",
                               session: session, process: process)
                }.value
                guard made else { break }
                if let credential { slotCredentialWritten[path] = (Self.credentialDigest(credential.contents), Date()) }
                noteSlotAssignment(path, from: nil, to: id, at: Date())
                filled = (account, credential != nil)
                break
            }
            guard let filled else {
                slotsLog.warning("[fillRequestedSlots] Session slot \(request.directory.lastPathComponent) not filled: no account it may serve has a credential to write")
                continue
            }
            slotsLog.info("[fillRequestedSlots] Filled session slot \(request.directory.lastPathComponent) for \(messageName(filled.account))\(session.map { " (resumes \($0.prefix(8)))" } ?? "")")
            if !filled.credential, let session {
                failoverEvents.record(provider, "Session \(session.prefix(8)) is pinned to \(messageName(filled.account)), whose sign-in cannot be written to its slot now: it starts in its own slot on \(messageName(filled.account)) and waits there until that account is signed in again, or until you unpin it.")
            }
        }
    }
    private func maintainSessionSlotsOnce(now: Date, processesRead: Bool) async {
        let isolated = AIProviderType.isolatedProviders.compactMap { provider in
            SessionSlots(provider).map { (provider, $0) }
        }
        guard !isolated.isEmpty else { return }
        if !processesRead { await refreshSlotProcesses() }
        for (provider, slots) in isolated {
            await maintainSessionSlots(provider, slots: slots, now: now)
        }
    }

    private func maintainSessionSlots(_ provider: AIProviderType, slots: SessionSlots, now: Date) async {
        await Task.detached(priority: .utility) { slots.isolation.restoreSharedState() }.value
        let inUse = Set((sessionSlotStates[provider]?.directoryByProcess ?? [:]).values)
        // The router's pool mirrors the slot pool of the provider it would
        // serve, so `applyRouterState` starts from it when the router is
        // turned on.
        let mirrorsRouterPool = provider.capabilities.requestRouter != nil
        guard sessionSlotsWanted(provider) else {
            if slots.launcherInstalled || FileManager.default.fileExists(atPath: slots.launcher.path) {
                slots.removeLauncher()
                slotsLog.info("Launcher removed; sessions it started keep their accounts until they exit")
            }
            if mirrorsRouterPool, !routerInUse { routerPoolMembers = [] }
            sessionSlotStates[provider, default: SessionSlotState()].sessionMoves = [:]
            await serveRunning(slots, provider: provider, members: [], inUse: inUse)
            await serveSessionSlots(slots, provider: provider, members: [], inUse: inUse, offersBack: false, now: now)
            let served = Set((sessionSlotStates[provider]?.directoryServing ?? [:]).values)
            sessionSlotStates[provider, default: SessionSlotState()].servedAccounts = served
            sessionSlotStates[provider, default: SessionSlotState()].credentialAccounts = served
            return
        }
        if !slots.launcherInstalled {
            do {
                try slots.installLauncher()
                slotsLog.info("Launcher installed at \(slots.launcher.path)")
            } catch {
                slotsLog.error("Launcher not installed: \(error.localizedDescription)")
                return
            }
        }
        markStarted(slots, provider: provider)
        watchSlotRequests(slots, provider: provider)
        await fillRequestedSlots(provider, slots: slots, now: now)
        let members = await buildPool(provider, now: now, forRouter: false)
        if mirrorsRouterPool { routerPoolMembers = members }
        await serveRunning(slots, provider: provider, members: members, inUse: inUse)
        var resumes = resumeTargets(provider, now: now)
        for (session, restart) in slotRestartResumes where restart.provider == provider {
            resumes[session] = restart.account
        }
        let pass = await serveSessionSlots(slots, provider: provider, members: members, inUse: inUse, now: now)
        // A session resumed on an account asks for it by the path naming it;
        // the launcher makes the slot.
        let accountEntries = resumes.map { session, account in (session: session, path: slots.directory(for: account).path) }
            .sorted { $0.session < $1.session }
        let continues = pass.reclaims.isEmpty || slots.isolation.continueArgumentScript.isEmpty ? []
            : Self.continueEntries(pass.reclaims, records: Array(AgentSessions.records(provider).values),
                                   running: Set((liveSessions[provider] ?? []).map(\.sessionID)))
        let resumeEntries = Self.resumeTable(reclaims: pass.reclaims, continues: continues, accounts: accountEntries)
        await Task.detached(priority: .utility) { slots.writeResumes(resumeEntries) }.value
        let slotServed = Set((sessionSlotStates[provider]?.directoryServing ?? [:]).values)
        sessionSlotStates[provider, default: SessionSlotState()].servedAccounts = slotServed
        sessionSlotStates[provider, default: SessionSlotState()].credentialAccounts = slotServed
            .union(pass.reclaims.map(\.account))
        // The launcher names an account by the path `directory(for:)` gives
        // it and asks AccountDock to fill its session slot for that account.
        let entries: [(path: String, weight: Double)] = members.compactMap { member in
            guard let id = UUID(uuidString: member.accountID), member.weight > 0 else { return nil }
            return (slots.directory(for: id).path, member.weight)
        }
        await Task.detached(priority: .utility) { slots.writePool(entries) }.value
        // Launches waiting since AccountDock started go on now.
        if sessionSlotStates[provider]?.readyMarked != true {
            let pid = getpid()
            await Task.detached(priority: .utility) { slots.markReady(pid: pid) }.value
            sessionSlotStates[provider, default: SessionSlotState()].readyMarked = true
        }
    }
    /// Reads which slot each running process reads, for `refreshSessions`
    /// and `maintainSessionSlots`, and each isolated CLI's background-session
    /// processes, from one fresh `ProcessTable`; run first on every quota
    /// cycle, and the readers after it within seconds reuse that table
    /// (`ProcessTable.current(maxAge:)`). A reading that is not whole
    /// (`processScanSucceeded`), as when `ps` does not finish on a loaded
    /// machine, changes none of the maps and marks the scan failed, so no
    /// slot is removed on it.
    func refreshSlotProcesses() async {
        let isolated = AIProviderType.isolatedProviders.compactMap { provider in
            SessionSlots(provider).map { (provider, $0) }
        }
        guard !isolated.isEmpty else { return }
        let ownPID = getpid()
        typealias Reading = (directories: [Int32: String], background: BackgroundSessionProcesses,
                             folders: [String: String], runs: Set<String>, registry: [Int32: CLISessionRegistry.Entry]?,
                             startedAt: [Int32: Date], unread: Set<Int32>)
        let read = await Task.detached(priority: .utility) { () -> [Reading]? in
            guard let table = ProcessTable.read(), Self.processScanSucceeded(table, ownPID: ownPID) else { return nil }
            return isolated.map { provider, slots in
                let background = slots.background.map {
                    BackgroundSessionProcesses(table: table, executable: slots.executable, support: $0)
                } ?? BackgroundSessionProcesses()
                let directories = Self.processSlotDirectories(slots.directoriesByProcess(in: table), ownPID: ownPID)
                let registry = CLISessionRegistry.read(provider)
                let runs = Self.slotRunDirectories(directories, table: table,
                                                   names: Set(provider.capabilities.cliProcessNames + [slots.executable]),
                                                   registry: registry)
                let startedAt = directories.keys.reduce(into: [Int32: Date]()) { $0[$1] = ProcessAncestry.startTime(of: $1) }
                return (directories, background, Self.slotFolders(directories, table: table), runs, registry, startedAt,
                        Self.unreadProcesses(Set((registry ?? [:]).keys), table: table))
            }
        }.value
        guard let read else {
            for (provider, _) in isolated {
                sessionSlotStates[provider, default: SessionSlotState()].scanSucceeded = false
            }
            slotsLog.warning("[refreshSlotProcesses] The process list could not be read whole; the slots keep what the last whole reading found, and none is removed until one succeeds")
            return
        }
        for ((provider, slots), reading) in zip(isolated, read) {
            let (directories, background, folders, runs) = (reading.directories, reading.background, reading.folders,
                                                            reading.runs)
            sessionSlotStates[provider, default: SessionSlotState()].background = background
            let byProcess = Self.sessionSlotDirectories(directories, background: background)
            sessionSlotStates[provider, default: SessionSlotState()].directoryByProcess = byProcess
            sessionSlotStates[provider, default: SessionSlotState()].folderByDirectory = folders
            sessionSlotStates[provider, default: SessionSlotState()].runDirectories = runs
            sessionSlotStates[provider, default: SessionSlotState()].registry = reading.registry ?? [:]
            sessionSlotStates[provider, default: SessionSlotState()].unreadProcesses = reading.unread
            sessionSlotStates[provider, default: SessionSlotState()].readers = Self.slotReaders(
                previous: sessionSlotStates[provider]?.readers ?? [:], byProcess: byProcess, startedAt: reading.startedAt,
                stillRuns: { Self.readerRuns($0) }
            )
            sessionSlotStates[provider, default: SessionSlotState()].scanSucceeded = true
            // A slot in use that `serveSessionSlots` has not served yet, as
            // on the first cycle after launch, serves the account the slot
            // itself records; `refreshSessions` would otherwise count its
            // session on the active account until the next cycle.
            let serving = sessionSlotStates[provider]?.directoryServing ?? [:]
            let unknown = Set(byProcess.values).filter { serving[$0] == nil }
            guard !unknown.isEmpty else { continue }
            let recorded = await Task.detached(priority: .utility) {
                unknown.reduce(into: [String: UUID]()) { $0[$1] = slots.recordedAccount(forSlotAt: $1) }
            }.value
            for (path, id) in recorded where sessionSlotStates[provider]?.directoryServing[path] == nil {
                sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = id
            }
        }
    }

    /// The slots processes read, less those of processes that are no
    /// session (`BackgroundSessionProcesses.nonSessions`): an attach client
    /// started with the slot variable already set, as from a shell a slot
    /// session opened, reads a slot while its session runs in a worker on
    /// the shared sign-in, and `serveSessionSlots` releases a slot no listed
    /// process reads.
    nonisolated static func sessionSlotDirectories(_ directories: [Int32: String],
                                                   background: BackgroundSessionProcesses) -> [Int32: String] {
        directories.filter { !background.nonSessions.contains($0.key) }
    }

    /// Whether `table` lists every process: it lists any at all, and it
    /// lists AccountDock's own (`ownPID`), which a whole `ps -ax` always
    /// does. A list cut short would name no process for slots whose
    /// sessions still run, and `serveSessionSlots` would take them for
    /// ended.
    nonisolated static func processScanSucceeded(_ table: ProcessTable, ownPID: Int32) -> Bool {
        !table.entries.isEmpty && table.entry(ownPID) != nil
    }

    /// The readers of each slot after a whole reading: the processes that
    /// read it now (`byProcess`, with `startedAt`), and, for a slot none
    /// reads now, those of its `previous` readers that `stillRuns`, so a
    /// process whose environment the reading missed still holds its slot.
    /// A slot with no reader left is dropped.
    nonisolated static func slotReaders(previous: [String: [SlotReader]], byProcess: [Int32: String],
                                        startedAt: [Int32: Date], stillRuns: (SlotReader) -> Bool) -> [String: [SlotReader]] {
        var readers: [String: [SlotReader]] = [:]
        for (pid, directory) in byProcess.sorted(by: { $0.key < $1.key }) {
            readers[directory, default: []].append(SlotReader(pid: pid, startedAt: startedAt[pid]))
        }
        for (directory, old) in previous where readers[directory] == nil {
            let running = old.filter(stillRuns)
            if !running.isEmpty { readers[directory] = running }
        }
        return readers
    }

    /// Whether `reader` still runs: its process ID is alive (`isAlive`, by
    /// default `kill(pid, 0)`, which another user's process answers with
    /// `EPERM`) and, when both are known, started when the reader did, so
    /// a later process given the same ID is not taken for it.
    nonisolated static func readerRuns(_ reader: SlotReader,
                                       isAlive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 || errno == EPERM },
                                       startTime: (Int32) -> Date? = ProcessAncestry.startTime(of:)) -> Bool {
        guard isAlive(reader.pid) else { return false }
        guard let recorded = reader.startedAt, let started = startTime(reader.pid) else { return true }
        return abs(started.timeIntervalSince(recorded)) < 1
    }

    /// The slots processes read (`directories`, by process ID), less
    /// AccountDock's own process (`ownPID`): started from a shell inside a
    /// slot session, it inherits that session's slot variable without
    /// reading the slot, and as a reader it would hold the slot for as long
    /// as the app runs.
    nonisolated static func processSlotDirectories(_ directories: [Int32: String], ownPID: Int32) -> [Int32: String] {
        directories.filter { $0.key != ownPID }
    }

    /// Of the processes the CLI's registry lists (`registered`), those
    /// whose environment `table` does not show: absent from it, or listed
    /// with none. Read into `SessionSlotState.unreadProcesses`.
    nonisolated static func unreadProcesses(_ registered: Set<Int32>, table: ProcessTable) -> Set<Int32> {
        registered.filter { table.entry($0)?.environment.isEmpty ?? true }
    }

    /// Whether the process a registry `entry` names still runs it: alive
    /// (`isAlive`) and, when both are known, started within
    /// `AgentSessions.registryStartTolerance` of when the entry says, so a
    /// later process given the same ID is not taken for it.
    nonisolated static func registryEntryRuns(_ entry: CLISessionRegistry.Entry,
                                              isAlive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 || errno == EPERM },
                                              startTime: (Int32) -> Date? = ProcessAncestry.startTime(of:)) -> Bool {
        guard isAlive(entry.pid) else { return false }
        guard let listed = entry.startedAt, let started = startTime(entry.pid) else { return true }
        return abs(started.timeIntervalSince(listed)) <= AgentSessions.registryStartTolerance
    }

    /// What `serveSessionSlots` knows of a claimed slot no process read in
    /// this cycle's scan, for `sessionGoneBlocker`.
    struct SlotGoneEvidence {
        /// This cycle's scan read the whole process list.
        var scanSucceeded: Bool
        /// The processes seen reading the slot (`SessionSlotState.readers`).
        var readers: [SlotReader] = []
        /// Registry entries holding a session seen reading the slot, whose
        /// process the scan could not read (`unreadProcesses`).
        var registered: [CLISessionRegistry.Entry] = []
        /// A pin names a session seen reading the slot, or the slot itself.
        var pinned = false
        /// Since when no whole scan has seen it read: the later of its claim
        /// and `SessionSlotState.lastSeenInUse`.
        var idleSince: Date
        /// `slotClaimGrace`, or `requestedClaimGrace` for a slot claimed by
        /// `sessionLaunch`; a pinned slot waits `pinnedClaimGrace` if longer.
        var grace: TimeInterval
    }

    /// Why a claimed slot must still be kept; nil when `serveSessionSlots`
    /// may remove it as gone. The slot stays within its grace from
    /// `idleSince`, and past it needs evidence that its session ended: this
    /// cycle's scan read the whole process list, every process seen
    /// reading it has ended (`stillRuns`), the CLI's registry lists no
    /// unread live process with its session (`registryRuns`), and, for a
    /// pinned session, `pinnedClaimGrace` has passed too. Removing the slot
    /// of a session that still runs deletes its credential under it, and
    /// the CLI then falls back to the shared sign-in, off the account it
    /// was on or pinned to.
    nonisolated static func sessionGoneBlocker(_ evidence: SlotGoneEvidence, now: Date,
                                               stillRuns: (SlotReader) -> Bool,
                                               registryRuns: (CLISessionRegistry.Entry) -> Bool) -> SlotKeep? {
        let idle = now.timeIntervalSince(evidence.idleSince)
        if idle <= evidence.grace { return .withinGrace }
        guard evidence.scanSucceeded else { return .held("the process list could not be read whole this cycle") }
        if let running = evidence.readers.first(where: stillRuns) {
            return .held("process \(running.pid), seen reading it, still runs")
        }
        if let entry = evidence.registered.first(where: registryRuns) {
            return .held("the CLI's registry lists process \(entry.pid) with its session \(entry.sessionID.prefix(8))")
        }
        if evidence.pinned, idle <= max(evidence.grace, pinnedClaimGrace) {
            return .held("its session is pinned, and a pinned session's slot is kept \(Int(pinnedClaimGrace / 60)) minutes after it was last read")
        }
        return nil
    }

    /// Why `sessionGoneBlocker` keeps a slot: still within its grace, which
    /// is the usual case and not logged, or held for the reason given,
    /// which `serveSessionSlots` logs once per slot.
    enum SlotKeep: Equatable {
        case withinGrace
        case held(String)
    }

    /// A claimed slot whose session is pinned is kept this long after a
    /// whole scan last saw it read: its credential is the pin, and a slot
    /// removed under a session still running sends it to the shared
    /// sign-in, off the pinned account.
    nonisolated static let pinnedClaimGrace: TimeInterval = 60 * 60

    /// The most claimed slots one pass removes as gone. More at once is
    /// what a process list read short looks like rather than sessions
    /// ending, and deleting the slots of sessions still running sends each
    /// to the shared sign-in, so such a pass removes none of them.
    nonisolated static let maximumGoneRemovals = 3
    /// How long more than `maximumGoneRemovals` slots must stand to be
    /// removed, pass after pass, before they go, `maximumGoneRemovals` a
    /// pass: as many sessions can end together, as when a terminal closes.
    nonisolated static let massRemovalHold: TimeInterval = 30 * 60

    /// Which of `candidates` (slot paths `serveSessionSlots` would remove
    /// as gone) one pass removes, and since when more than
    /// `maximumGoneRemovals` have stood (`heldSince`, kept in
    /// `SessionSlotState.massRemovalSince`): all of them up to that many;
    /// beyond it none, until they have stood for `massRemovalHold`, then
    /// the first `maximumGoneRemovals` by path. `started` says a hold began
    /// with this pass, which `serveSessionSlots` logs and records.
    nonisolated static func goneRemovals(_ candidates: [String], heldSince: Date?, now: Date)
        -> (remove: [String], heldSince: Date?, started: Bool) {
        guard candidates.count > maximumGoneRemovals else { return (candidates, nil, false) }
        guard let heldSince else { return ([], now, true) }
        guard now.timeIntervalSince(heldSince) >= massRemovalHold else { return ([], heldSince, false) }
        return (Array(candidates.sorted().prefix(maximumGoneRemovals)), heldSince, false)
    }

    /// The one-session slots a running process reads (`byProcess`) that are
    /// no longer on disk (`present`, the slot paths `SessionSlots.sessionSlots`
    /// found), in path order; `isSessionSlot` says which paths are
    /// one-session slots. `restoreMissingSlots` recreates them.
    nonisolated static func missingSlots(byProcess: [Int32: String], present: Set<String>,
                                         isSessionSlot: (String) -> Bool) -> [String] {
        Set(byProcess.values).filter { !present.contains($0) && isSessionSlot($0) }.sorted()
    }

    /// The accounts a recreated slot may serve, in order: the one it was
    /// last assigned (`history`), the one serving it (`serving`), the one
    /// the credential audit last recorded for it (`audit`), its session's
    /// pin (`pinned`), then the one the pool would place it on
    /// (`fallback`); each named once. `restoreMissingSlots` takes the first
    /// whose credential can be written.
    nonisolated static func restoredSlotAccounts(history: UUID?, serving: UUID?, audit: UUID?, pinned: UUID?,
                                                 fallback: UUID?) -> [UUID] {
        [history, serving, audit, pinned, fallback].compactMap { $0 }.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    // MARK: - Slots offered back to their sessions

    /// A one-session slot whose session has ended, offered back to it: the
    /// resume file maps `session` to `path`, and the launcher resuming it
    /// takes the slot, which serves `account`. `folder` is where the
    /// session ran, for a `--continue` there (`continueEntries`).
    struct SlotReclaim: Equatable {
        var session: String
        var path: String
        var account: UUID
        var folder: String?
    }

    /// What `serveSessionSlots` leaves for the resume file: the slots
    /// offered back to their sessions.
    struct SlotPass {
        var reclaims: [SlotReclaim] = []
    }

    /// How long a slot stays offered to its session with no launcher taking
    /// it, from when it was first offered; then it is removed. A terminal
    /// restores its sessions within minutes of a restart, and a session
    /// resumed by hand within the hour still finds its slot.
    nonisolated static let reclaimGrace: TimeInterval = 60 * 60

    /// What becomes of a claimed slot no process reads.
    enum ReclaimChoice: Equatable {
        /// Offered to its session: marked `SessionSlots.reclaimableMarker`,
        /// kept with its credential served, and named in the resume file.
        case offer
        /// The offer is taken back and the slot removed.
        case retire
        /// No offer: the rules for a claimed slot apply.
        case none
    }

    /// Whether `serveSessionSlots` offers a claimed slot no process reads
    /// back to its session. Only a slot that `knowsSession`, whose session
    /// `ended` by `sessionGoneBlocker`'s evidence (a pin aside), that serves
    /// an account, and that is the slot `reclaimSlots` chose for its session
    /// (`chosen`) is offered; not while that session runs in another slot
    /// (`runsInSlot`) or moves by a restart to another account
    /// (`restarting`), which the resume file names for it instead. An
    /// offer stands for `reclaimGrace` from `reclaimableSince`; one that no
    /// longer applies is retired.
    nonisolated static func reclaimChoice(knowsSession: Bool, chosen: Bool, ended: Bool, hasAccount: Bool,
                                          runsInSlot: Bool, restarting: Bool, reclaimableSince: Date?,
                                          now: Date) -> ReclaimChoice {
        let offered = reclaimableSince != nil
        guard knowsSession, chosen, hasAccount, !runsInSlot, !restarting, offered || ended else {
            return offered ? .retire : .none
        }
        if let since = reclaimableSince, now.timeIntervalSince(since) > reclaimGrace { return .retire }
        return .offer
    }

    /// The slot offered to each session among `candidates` (claimed slots no
    /// process reads, with the session each was last read by and its claim
    /// time): the one claimed last, the slot its newest run had, by path on
    /// a tie.
    nonisolated static func reclaimSlots(_ candidates: [(path: String, session: String, claimedAt: Date)]) -> [String: String] {
        var chosen: [String: (path: String, claimedAt: Date)] = [:]
        for candidate in candidates {
            if let held = chosen[candidate.session],
               held.claimedAt > candidate.claimedAt || (held.claimedAt == candidate.claimedAt && held.path < candidate.path) {
                continue
            }
            chosen[candidate.session] = (candidate.path, candidate.claimedAt)
        }
        return chosen.mapValues(\.path)
    }

    /// Resume-file lines for a `--continue` in a folder: the folder and the
    /// slot offered to the one session of `reclaims` that ran there, only
    /// where that is unambiguous: one offered slot in the folder, no
    /// `running` session's record there, and no newer record there than its
    /// session's (`records`, by `observedAt`), since the CLI continues the
    /// folder's newest conversation.
    nonisolated static func continueEntries(_ reclaims: [SlotReclaim], records: [AgentSession],
                                            running: Set<String>) -> [(session: String, path: String)] {
        var byFolder: [String: [SlotReclaim]] = [:]
        for reclaim in reclaims {
            guard let folder = reclaim.folder, folder.hasPrefix("/") else { continue }
            byFolder[folder, default: []].append(reclaim)
        }
        return byFolder.compactMap { folder, found -> (session: String, path: String)? in
            guard found.count == 1, let only = found.first else { return nil }
            let here = records.filter { $0.workingDirectory == folder }
            guard !here.contains(where: { running.contains($0.sessionID) }) else { return nil }
            if let newest = here.max(by: { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }),
               newest.sessionID != only.session { return nil }
            return (folder, only.path)
        }.sorted { $0.session < $1.session }
    }

    /// The resume file's lines: each offered slot for its session first,
    /// then the `--continue` folders, then `accounts`, the account-level
    /// entries, for the sessions no offered slot is named for.
    nonisolated static func resumeTable(reclaims: [SlotReclaim], continues: [(session: String, path: String)],
                                        accounts: [(session: String, path: String)]) -> [(session: String, path: String)] {
        let offered = reclaims.sorted { $0.session < $1.session }.map { (session: $0.session, path: $0.path) }
        let named = Set(offered.map(\.session))
        return offered + continues + accounts.filter { !named.contains($0.session) }
    }

    /// The folder each slot's process runs in, by slot path: the `PWD` in
    /// the environment of the process reading it (`directories`, by process
    /// ID, from `table`), the lowest process ID first when several read
    /// one. A run that keeps no session record is named by it.
    nonisolated static func slotFolders(_ directories: [Int32: String], table: ProcessTable) -> [String: String] {
        var folders: [String: String] = [:]
        for (pid, directory) in directories.sorted(by: { $0.key < $1.key }) where folders[directory] == nil {
            guard let entry = table.entries.first(where: { $0.pid == pid }),
                  let folder = entry.environmentValue("PWD"), folder.hasPrefix("/") else { continue }
            folders[directory] = folder
        }
        return folders
    }

    /// The slots read (`directories`, by process ID, from `table`) by a
    /// process that may hold a session: one the CLI's `registry` lists, or,
    /// for a CLI that keeps none (nil), any process of the CLI's own (its
    /// executable is among `names`). Every other process
    /// with the slot in its environment is no session: a helper a session
    /// started that outlived it, such as an MCP server or a script, and a
    /// CLI the registry does not list, which has not started its session
    /// (it waits at a prompt before it) and sends no request. Read by
    /// `serveSessionSlots`, which places and charges a run without a
    /// session record only in these slots.
    nonisolated static func slotRunDirectories(_ directories: [Int32: String], table: ProcessTable, names: Set<String>,
                                               registry: [Int32: CLISessionRegistry.Entry]?) -> Set<String> {
        Set(directories.compactMap { pid, directory -> String? in
            if let registry { return registry[pid] == nil ? nil : directory }
            guard let entry = table.entries.first(where: { $0.pid == pid }), names.contains(entry.executableName) else {
                return nil
            }
            return directory
        })
    }

    /// How the events and plans name a run with no session record in the
    /// slot at `slot`: by the folder it runs in ("a run in ~/ORBTR"), never
    /// by the slot's path.
    func unrecordedRunName(_ provider: AIProviderType, slot: String) -> String {
        Self.runName(folder: sessionSlotStates[provider]?.folderByDirectory[slot])
    }

    /// "a run in ~/ORBTR" for a run in `folder`; "a run with no session
    /// record" when its folder is unknown.
    nonisolated static func runName(folder: String?) -> String {
        guard let folder else { return eventName(of: nil) }
        return "a run in " + (folder as NSString).abbreviatingWithTildeInPath
    }

    /// The account serving the slot a running session reads, when the
    /// session runs in one; its usage readings belong to that account.
    func slotAccount(forSession sessionID: String?, provider: AIProviderType) -> UUID? {
        guard let sessionID,
              let pid = liveSessions[provider]?.first(where: { $0.sessionID == sessionID })?.processID else { return nil }
        return slotAccount(forProcess: pid)
    }

    /// The account serving the slot a process reads, when it reads one.
    func slotAccount(forProcess pid: Int32) -> UUID? {
        slotDirectoryByProcess[pid].flatMap { slotDirectoryServing[$0] }
    }

    /// Seconds a session in a moved slot may still be using the account it
    /// left: the CLI reads its slot again only before a request, and caches
    /// what it read for about half a minute.
    nonisolated static let slotMoveSettling: TimeInterval = 2 * 60

    /// One assignment of a slot to an account (`slotAccountHistory`).
    struct SlotAssignment: Equatable {
        var account: UUID
        var at: Date
    }

    /// Records that the slot at `path` now serves `account`, after `from`.
    /// A slot first seen moving is taken to have served `from` until then.
    func noteSlotAssignment(_ path: String, from: UUID?, to account: UUID, at: Date) {
        var history = slotAccountHistory[path] ?? []
        if history.isEmpty, let from { history.append(SlotAssignment(account: from, at: .distantPast)) }
        history.append(SlotAssignment(account: account, at: at))
        slotAccountHistory[path] = Array(history.suffix(16))
    }

    /// The account serving a slot's session at `time`: the first
    /// assignment, then each later one made by `time` once
    /// `slotMoveSettling` has passed since it, or once the session's cache
    /// was rebuilt whole (`rebuiltAt`) between the move and `time`, which
    /// shows its requests reached the new account. Until then the CLI may
    /// still hold the token it read before the move. Nil without history.
    nonisolated static func servingSlotAccount(at time: Date, history: [SlotAssignment], rebuiltAt: Date?) -> UUID? {
        guard var current = history.first?.account else { return nil }
        for assignment in history.dropFirst() where assignment.at <= time {
            let settled = time.timeIntervalSince(assignment.at) >= slotMoveSettling
            let rebuilt = rebuiltAt.map { $0 >= assignment.at && $0 <= time } ?? false
            if settled || rebuilt { current = assignment.account }
        }
        return current
    }

    /// The account serving `session` at `time` by its slot's history, when
    /// it reads a slot AccountDock has seen move; nil otherwise.
    func slotAccount(forSession session: String, process: Int32?, at time: Date) -> UUID? {
        guard let process, let directory = slotDirectoryByProcess[process],
              let history = slotAccountHistory[directory] else { return nil }
        return Self.servingSlotAccount(at: time, history: history, rebuiltAt: sessionCacheRebuiltAt[session])
    }

    /// Whether something the session reported at `reportedAt` came too
    /// soon after its slot moved to tell which account served it. Judged by
    /// the report's own time: a reading written then and read later, as
    /// after AccountDock restarts, still belongs to neither account.
    func sessionSlotIsSettling(_ sessionID: String?, provider: AIProviderType, reportedAt: Date) -> Bool {
        guard let sessionID,
              let pid = liveSessions[provider]?.first(where: { $0.sessionID == sessionID })?.processID,
              let directory = slotDirectoryByProcess[pid],
              let moved = slotDirectoryMovedAt[directory] else { return false }
        return reportedAt.timeIntervalSince(moved) < Self.slotMoveSettling
    }

    /// Whether an account can no longer serve the sessions on it: the
    /// planner finds it at its limit or unusable. A reading too old for the
    /// pool does not count, so a session never moves for a stale reading.
    /// With `model`, the question is asked for one session using that model,
    /// whose own weekly limit may be spent while the account has room for
    /// the rest (`plannedUsage`). `wholeAllowance` judges by the whole
    /// allowance alone, as for a slot session whose model is unknown: it is
    /// no part of the sessions sharing the sign-in, whose models narrow the
    /// question without `model`.
    func accountCannotServe(_ id: UUID, provider: AIProviderType, planner: FailoverPlanner, now: Date,
                            model: String? = nil, wholeAllowance: Bool = false) -> Bool {
        guard let account = accounts.first(where: { $0.id == id && $0.provider == provider }) else { return true }
        let state = quotaState(for: account, now: now, model: model, wholeAllowance: wholeAllowance && model == nil)
        switch planner.servingVerdict(state, now: now, lead: 0) {
        case .atLimit, .ineligible: return true
        case .canServe, .nearLimit: return false
        }
    }

    /// The account each recent session that is not running last ran on,
    /// where that account can still serve it, so resuming it by ID
    /// continues it there with its cache and thinking.
    func resumeTargets(_ provider: AIProviderType, now: Date) -> [String: UUID] {
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let running = Set((liveSessions[provider] ?? []).map(\.sessionID))
        // By account and the model the session uses: an account can have
        // room for one model and none for another.
        var usable: [String: Bool] = [:]
        var targets: [String: UUID] = [:]
        // A pinned session resumes on its pinned account, room or not.
        for (session, pin) in sessionPins.pinned(provider) where !running.contains(session) {
            targets[session] = pin.account
        }
        for (session, entry) in sessionRates.entries where !running.contains(session) && targets[session] == nil {
            let model = sessionModel(session, now: now)
            let key = entry.account.uuidString + "|" + (model ?? "")
            let canServe = usable[key] ?? !accountCannotServe(entry.account, provider: provider, planner: planner, now: now, model: model)
            usable[key] = canServe
            if canServe { targets[session] = entry.account }
        }
        return targets
    }

    /// How an event names a session, so two events about different
    /// sessions never read alike: its folder and the start of its ID, or,
    /// for a slot no session record names, what that is, a run of the CLI
    /// that keeps none, as a one-off command does.
    nonisolated static func eventName(of session: AgentSession?) -> String {
        guard let session else { return "a run with no session record" }
        let id = String(session.sessionID.prefix(8))
        guard let directory = session.workingDirectory else { return "session \(id)" }
        return "session \(id) in " + (directory as NSString).abbreviatingWithTildeInPath
    }

    /// How long a slot `serveSlot` wrote is trusted to still hold what was
    /// written: one no CLI reads, as a slot offered back to its session,
    /// which nothing else touches, and a slot a session reads, whose CLI can
    /// replace its item.
    nonisolated static let idleRecheckInterval: TimeInterval = 10 * 60
    nonisolated static let claimedRecheckInterval: TimeInterval = 60

    /// Writes `credential` to a slot through `SessionSlots.serve`, unless
    /// the same credential was written or found there within `recheck`.
    /// Every slot is served on every quota cycle and each `serve` reads the
    /// slot's credential back, which may start a process, so most cycles
    /// skip it. `account`, `reason`, `session` and `process` are what the
    /// audit records for a write.
    func serveSlot(_ slots: SessionSlots, _ directory: URL, credential: SlotCredential, recheck: TimeInterval,
                   account: UUID?, reason: String, session: String? = nil, process: Int32? = nil,
                   now: Date = Date()) async -> Bool {
        let digest = Self.credentialDigest(credential.contents)
        if let written = slotCredentialWritten[directory.path], written.digest == digest,
           now.timeIntervalSince(written.at) < recheck { return true }
        let served = await Task.detached(priority: .utility) {
            slots.serve(directory, credential: credential, account: account, reason: reason, session: session, process: process)
        }.value
        slotCredentialWritten[directory.path] = served ? (digest, now) : nil
        return served
    }
    /// A claimed one-session slot that no process reads this long after its
    /// claim has lost its session.
    nonisolated static let slotClaimGrace: TimeInterval = 2 * 60
    /// The same for a slot claimed by `sessionLaunch`, whose command may be
    /// copied and run some minutes later.
    nonisolated static let requestedClaimGrace: TimeInterval = 30 * 60
    /// How long an account a session moved to for a remainder or a window
    /// rests (`RemainderSpending.resting`), and the least time between two
    /// automatic rebalances. A moved session itself is held for its cache's
    /// lifetime (`moveHold`).
    static let balanceMoveInterval: TimeInterval = 30 * 60

    /// Records, after a whole scan, when each slot in use (`inUse`) was last
    /// read (`SessionSlotState.lastSeenInUse`) and the sessions reading it
    /// (`SessionSlotState.slotSessions`): each one's live record
    /// (`sessionsByDirectory`), and the session the CLI's registry names for
    /// each process reading it. `slotGoneEvidence` reads both once no
    /// process is seen reading the slot.
    func noteSlotSessions(_ provider: AIProviderType, inUse: Set<String>, sessionsByDirectory: [String: AgentSession],
                          now: Date) {
        guard var state = sessionSlotStates[provider], state.scanSucceeded else { return }
        for path in inUse { state.lastSeenInUse[path] = now }
        for (path, session) in sessionsByDirectory { state.slotSessions[path, default: []].insert(session.sessionID) }
        for (pid, path) in state.directoryByProcess {
            if let entry = state.registry[pid] { state.slotSessions[path, default: []].insert(entry.sessionID) }
        }
        sessionSlotStates[provider] = state
    }

    /// What is known of the claimed `slot`, claimed at `claimedAt`, that no
    /// process read in this cycle's scan (`SlotGoneEvidence`): the sessions
    /// seen reading it, by their records, the registry and its status line
    /// (`slotSessionsByDirectory`), and their pins.
    func slotGoneEvidence(_ provider: AIProviderType, slot: SessionSlots.SessionSlot, claimedAt: Date) -> SlotGoneEvidence {
        let state = sessionSlotStates[provider] ?? SessionSlotState()
        let path = slot.directory.path
        let sessions = (state.slotSessions[path] ?? []).union([slotSessionsByDirectory[path]].compactMap { $0 })
        return SlotGoneEvidence(
            scanSucceeded: state.scanSucceeded, readers: state.readers[path] ?? [],
            registered: state.registry.values
                .filter { sessions.contains($0.sessionID) && state.unreadProcesses.contains($0.pid) }
                .sorted { $0.pid < $1.pid },
            pinned: sessionPins.slots[path] != nil || sessions.contains { sessionPins.isPinned($0) },
            idleSince: state.lastSeenInUse[path].map { max($0, claimedAt) } ?? claimedAt,
            grace: slot.requested ? Self.requestedClaimGrace : Self.slotClaimGrace
        )
    }

    /// Recreates, at the same path, each one-session slot a running process
    /// still reads (`SessionSlotState.directoryByProcess`) whose directory
    /// is gone from disk (`present`, the slots `serveSessionSlots` found).
    /// The CLI names its slot once, in its environment, and with the
    /// directory and its credential gone reads the shared sign-in instead,
    /// off the account it was on or pinned to; written again, the slot is
    /// read at its next request. Each serves the first account of
    /// `restoredSlotAccounts` that can be written, claimed so no launcher
    /// hands it to another session, recorded in the credential audit
    /// (`serveSessionSlots.restore`) and as an event. Only after a whole
    /// process reading, and only for an isolation whose slot can be
    /// recreated in place (`ProviderSessionIsolation.restoresRemovedSlot`).
    /// Returns whether any slot was recreated.
    private func restoreMissingSlots(_ slots: SessionSlots, provider: AIProviderType, present: [SessionSlots.SessionSlot],
                                     sessionsByDirectory: [String: AgentSession], fallback: UUID?, now: Date) async -> Bool {
        guard slots.isolation.restoresRemovedSlot, let state = sessionSlotStates[provider], state.scanSucceeded else {
            return false
        }
        let missing = Self.missingSlots(byProcess: state.directoryByProcess, present: Set(present.map(\.directory.path)),
                                        isSessionSlot: { slots.isSessionSlot($0) })
        guard !missing.isEmpty else { return false }
        // The audit trail is read only for slots nothing in memory names an
        // account for, as after AccountDock restarts, and once per slot.
        let unread = missing.filter {
            slotAccountHistory[$0]?.last == nil && state.directoryServing[$0] == nil && !state.auditLooked.contains($0)
        }
        if !unread.isEmpty {
            let audit = slots.audit
            let found = await Task.detached(priority: .utility) { audit.lastSlotAccounts(Set(unread)) }.value
            sessionSlotStates[provider, default: SessionSlotState()].auditAccounts.merge(found) { _, new in new }
            sessionSlotStates[provider, default: SessionSlotState()].auditLooked.formUnion(unread)
        }
        var restored = false
        for path in missing {
            let processes = state.directoryByProcess.filter { $0.value == path }.keys.sorted()
            let session = sessionsByDirectory[path]
            let sessionID = session?.sessionID ?? processes.lazy.compactMap { state.registry[$0]?.sessionID }.first
                ?? slotSessionsByDirectory[path]
            let pinned = sessionPins.account(of: sessionID) ?? sessionPins.slots[path]?.account
            let wasOn = [slotAccountHistory[path]?.last?.account, state.directoryServing[path],
                         sessionSlotStates[provider]?.auditAccounts[path]]
            let candidates = Self.restoredSlotAccounts(history: wasOn[0], serving: wasOn[1], audit: wasOn[2],
                                                       pinned: pinned, fallback: fallback)
            var served: Account?
            for id in candidates {
                guard let account = accounts.first(where: { $0.id == id && $0.provider == provider }), !needsSignIn(account),
                      let credential = await slots.isolation.currentSlotCredential(
                          for: account, minimumLifetime: readsLiveCredential(account) ? 60 : 2 * 60 * 60, from: self
                      ) else { continue }
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                let process = processes.first
                let made = await Task.detached(priority: .utility) {
                    slots.restoreClaimedSlot(directory, account: id, credential: credential,
                                             reason: "serveSessionSlots.restore", session: sessionID, process: process)
                }.value
                guard made else { break }
                slotCredentialWritten[path] = (Self.credentialDigest(credential.contents), now)
                sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = id
                noteSlotAssignment(path, from: nil, to: id, at: now)
                served = account
                break
            }
            let name = session.map { Self.eventName(of: $0) } ?? sessionID.map { "session \($0.prefix(8))" }
                ?? unrecordedRunName(provider, slot: path)
            guard let served else {
                if sessionSlotStates[provider, default: SessionSlotState()].restoreFailures.insert(path).inserted {
                    slotsLog.warning("[restoreMissingSlots] The slot of \(name) is gone while it runs and could not be written again; it is tried again on every pass")
                }
                continue
            }
            sessionSlotStates[provider]?.restoreFailures.remove(path)
            restored = true
            let account = messageName(served)
            let reads = pinned == served.id ? "\(account) again, where it is pinned"
                : wasOn.contains(served.id) ? "\(account) again, the account it was on"
                : "\(account), where the pool places it"
            slotsLog.info("[restoreMissingSlots] Restored slot \(URL(fileURLWithPath: path).lastPathComponent) for \(account)")
            failoverEvents.record(provider, "Restored the slot of \(name), which was removed while it ran; it reads \(reads).")
        }
        return restored
    }

    /// Keeps the session slots: each claimed slot serves its account, or
    /// the pool's highest-weight account once its own leaves the pool, and
    /// moves to the account `SessionPacer` chose for its session between
    /// two of the session's turns; a move rewrites the slot, which the CLI
    /// reads again before its next request. The isolation's
    /// `currentSlotCredential` keeps the active account's token renewed
    /// while slots hold it. A slot no launch claimed, which only an earlier
    /// AccountDock made ahead of launches, is removed. A claimed slot whose
    /// session has ended is offered back to it for `reclaimGrace`
    /// (`reclaimChoice`), its credential kept current, so the session
    /// resumed after AccountDock or the machine restarts takes the slot and
    /// the account it had; with `offersBack` off, as once the provider's
    /// sessions are no longer served from slots, none is. Returns the slots
    /// offered.
    @discardableResult
    private func serveSessionSlots(_ slots: SessionSlots, provider: AIProviderType, members: [RouterPoolMember],
                                   inUse: Set<String>, offersBack: Bool = true, now: Date) async -> SlotPass {
        let activeID = accounts.first { $0.provider == provider && $0.isActive }?.id
        let pooled = Set(members.compactMap { UUID(uuidString: $0.accountID) })
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let fallback = members.max { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : rhs.accountID == activeID?.uuidString
        }.flatMap { UUID(uuidString: $0.accountID) } ?? activeID
        // The pool's accounts, the one taking most new sessions first.
        let byWeight = members.sorted { $0.weight > $1.weight }.compactMap { UUID(uuidString: $0.accountID) }
        let byProcess = sessionSlotStates[provider]?.directoryByProcess ?? [:]
        let sessionsByDirectory: [String: AgentSession] = (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            if let pid = session.processID, let directory = byProcess[pid] { result[directory] = session }
        }
        noteSlotSessions(provider, inUse: inUse, sessionsByDirectory: sessionsByDirectory, now: now)
        var slotList = await Task.detached(priority: .utility, operation: { slots.sessionSlots() }).value
        // A slot a running process still reads but that is gone from disk
        // is recreated first, so the pass below serves it like any other.
        if await restoreMissingSlots(slots, provider: provider, present: slotList, sessionsByDirectory: sessionsByDirectory,
                                     fallback: fallback, now: now) {
            slotList = await Task.detached(priority: .utility, operation: { slots.sessionSlots() }).value
        }
        // Runs in claimed slots whose process left no session record, by
        // slot, so they are placed with the sessions rather than all sent to
        // `fallback`; a slot only helpers or a CLI not yet holding a session
        // read is none (`slotRunDirectories`).
        let runs = sessionSlotStates[provider]?.runDirectories ?? []
        let unrecorded = slotList.compactMap { slot -> (path: String, account: UUID)? in
            guard slot.claimedAt != nil, inUse.contains(slot.directory.path), runs.contains(slot.directory.path),
                  sessionsByDirectory[slot.directory.path] == nil, let account = slot.account else { return nil }
            return (slot.directory.path, account)
        }
        // Sessions on an account that can no longer serve them, each placed
        // where the pool lasts longest with it, keyed by session ID, or by
        // slot path for a run without a session record.
        let placements = members.isEmpty ? [:]
            : strandedPlacements(provider, slots: slots, members: members, unrecorded: unrecorded, now: now)
        maintainPins(provider, sessionsBySlot: sessionsByDirectory.mapValues(\.sessionID), now: now)
        // Sessions waiting on their account for its reset keep it, and one
        // lane admission keeps there stays even once the user plays it; so
        // does a run with no session record admission keeps, by its slot.
        let waiting = waitingSessions(provider)
        let admissionHeld = admissionHolds(provider)
        let admissionHeldRuns = admissionHeldRuns[provider] ?? [:]
        var credentials: [UUID: SlotCredential] = [:]
        func credential(_ id: UUID) async -> SlotCredential? {
            if let known = credentials[id] { return known }
            guard let account = accounts.first(where: { $0.id == id }),
                  let current = await slots.isolation.currentSlotCredential(
                      for: account, minimumLifetime: readsLiveCredential(account) ? 60 : 2 * 60 * 60, from: self
                  ) else { return nil }
            credentials[id] = current
            return current
        }
        func serve(_ directory: URL, _ id: UUID, idle: Bool = false, reason: String,
                   session: AgentSession? = nil, sessionID: String? = nil) async -> Bool {
            guard let value = await credential(id) else { return false }
            return await serveSlot(slots, directory, credential: value,
                                   recheck: idle ? Self.idleRecheckInterval : Self.claimedRecheckInterval,
                                   account: id, reason: reason, session: session?.sessionID ?? sessionID,
                                   process: session?.processID, now: now)
        }
        // Claimed slots no process reads, and the session each was last read
        // by; the credential audit's trail is read only for a slot nothing
        // else names a session for, once per slot.
        let idle = slotList.filter { $0.claimedAt != nil && !inUse.contains($0.directory.path) }
        func knownSession(_ slot: SessionSlots.SessionSlot) -> String? {
            let state = sessionSlotStates[provider] ?? SessionSlotState()
            let path = slot.directory.path
            return Self.knownSlotSession(recorded: slot.session, statusLine: slotSessionsByDirectory[path],
                                         seen: state.slotSessions[path] ?? [], audit: state.auditSessions[path])
        }
        // A slot still unfilled, or claimed within its grace, as a launch's
        // own before its CLI starts, is offered to no one and not looked up.
        let unnamed = idle.filter {
            $0.account != nil && now.timeIntervalSince($0.claimedAt ?? now) > Self.slotClaimGrace && knownSession($0) == nil
                && !(sessionSlotStates[provider]?.auditSessionsLooked.contains($0.directory.path) ?? false)
        }.map(\.directory.path)
        if !unnamed.isEmpty {
            let audit = slots.audit
            let found = await Task.detached(priority: .utility) { audit.lastSlotSessions(Set(unnamed)) }.value
            sessionSlotStates[provider, default: SessionSlotState()].auditSessions.merge(found) { _, new in new }
            sessionSlotStates[provider, default: SessionSlotState()].auditSessionsLooked.formUnion(unnamed)
        }
        let idleSessions: [String: String] = idle.reduce(into: [:]) { result, slot in
            if let id = knownSession(slot) { result[slot.directory.path] = id }
        }
        let chosenSlots = Self.reclaimSlots(idle.compactMap { slot in
            idleSessions[slot.directory.path].map { (path: slot.directory.path, session: $0, claimedAt: slot.claimedAt ?? .distantPast) }
        })
        // A session running in a slot needs no other, and one restarting on
        // another account is named in the resume file for that account.
        let inSlots = Set(sessionsByDirectory.values.map(\.sessionID))
        let restarting = Set(slotRestartResumes.filter { $0.value.provider == provider }.keys)
            .union(pendingSlotRestarts.filter { $0.value.provider == provider }.keys)
        let stateBefore = sessionSlotStates[provider] ?? SessionSlotState()
        let registrySessions: [String: String] = stateBefore.directoryByProcess.sorted { $0.key < $1.key }
            .reduce(into: [:]) { result, entry in
                if result[entry.value] == nil, let id = stateBefore.registry[entry.key]?.sessionID { result[entry.value] = id }
            }
        var reclaims: [SlotReclaim] = []
        var newlyOffered: [SlotReclaim] = []
        var retire: [URL] = []
        var retract: [URL] = []
        var sessionRecords: [(directory: URL, session: String, folder: String?)] = []
        // Offers `slot` back to `id`: served for its pin or else the account
        // it serves (`reclaimAccount`), marked, and listed for the resume
        // file. A pinned session's slot on another account whose pin cannot
        // be written now is not offered. An unpinned slot whose credential
        // cannot be written now keeps the token it holds, and the next pass
        // writes it.
        func offer(_ slot: SessionSlots.SessionSlot, session id: String) async -> Bool {
            guard let own = slot.account else { return false }
            let directory = slot.directory
            let pinned = sessionPins.account(of: id)
            let served = await serve(directory, pinned ?? own, idle: true, reason: "serveSessionSlots.reclaimable", sessionID: id)
            guard let account = Self.reclaimAccount(own: own, pinned: pinned, pinServed: served) else { return false }
            if slot.reclaimableSince == nil,
               !(await Task.detached(priority: .utility, operation: { slots.markReclaimable(directory) }).value) {
                return false
            }
            if account != own {
                slots.assign(directory, to: account, reason: "serveSessionSlots.reclaimable", session: id)
                noteSlotAssignment(directory.path, from: own, to: account, at: now)
            }
            let reclaim = SlotReclaim(session: id, path: directory.path, account: account, folder: slot.folder)
            reclaims.append(reclaim)
            if slot.reclaimableSince == nil { newlyOffered.append(reclaim) }
            return true
        }
        var taken: [(path: String, session: String, account: UUID?)] = []
        // Read once, when a slot first needs the fallback.
        var fallbackRunning: [SessionPacer.RebalanceSession]?
        var fallbackAccounts: [CapacityOutlook.Account]?
        var remove: [URL] = []
        var removeUnclaimed: [URL] = []
        for slot in slotList {
            let path = slot.directory.path
            // Every launch makes its slot claimed, so one never claimed was
            // made ahead of a launch by an earlier AccountDock.
            guard let claimedAt = slot.claimedAt else {
                removeUnclaimed.append(slot.directory)
                continue
            }
            // A move made before AccountDock last started is dated by the
            // slot's account file, which every move rewrites.
            if slotDirectoryMovedAt[path] == nil, let assigned = slot.assignedAt, assigned > claimedAt {
                slotDirectoryMovedAt[path] = assigned
            }
            // A slot offered back that a process reads again is claimed:
            // the offer is over.
            if slot.reclaimableSince != nil, inUse.contains(path) { retract.append(slot.directory) }
            guard inUse.contains(path) else {
                let evidence = slotGoneEvidence(provider, slot: slot, claimedAt: claimedAt)
                let blocker = Self.sessionGoneBlocker(evidence, now: now, stillRuns: { Self.readerRuns($0) },
                                                      registryRuns: { Self.registryEntryRuns($0) })
                // A pin keeps a slot longer before it is removed, but its
                // session has ended by the same evidence without it.
                var unpinned = evidence
                unpinned.pinned = false
                let ended = blocker == nil || (blocker != .withinGrace && Self.sessionGoneBlocker(
                    unpinned, now: now, stillRuns: { Self.readerRuns($0) }, registryRuns: { Self.registryEntryRuns($0) }
                ) == nil)
                let id = idleSessions[path]
                switch Self.reclaimChoice(knowsSession: offersBack && id != nil, chosen: id.map { chosenSlots[$0] == path } ?? false,
                                          ended: ended, hasAccount: slot.account != nil,
                                          runsInSlot: id.map(inSlots.contains) ?? false,
                                          restarting: id.map(restarting.contains) ?? false,
                                          reclaimableSince: slot.reclaimableSince, now: now) {
                case .offer:
                    if let id, await offer(slot, session: id) { continue }
                    // An offer that no longer stands is taken back before
                    // the slot goes, as a launcher may be taking it.
                    if slot.reclaimableSince != nil {
                        retire.append(slot.directory)
                        continue
                    }
                case .retire:
                    retire.append(slot.directory)
                    continue
                case .none:
                    break
                }
                switch blocker {
                case nil:
                    remove.append(slot.directory)
                    continue
                case .held(let reason):
                    if sessionSlotStates[provider]?.removalHeld[path] != reason {
                        sessionSlotStates[provider, default: SessionSlotState()].removalHeld[path] = reason
                        slotsLog.info("[serveSessionSlots] Kept the claimed slot \(slot.directory.lastPathComponent), which no process read in this scan: \(reason)")
                    }
                case .withinGrace:
                    break
                }
                if let id = slot.account { sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = id }
                continue
            }
            sessionSlotStates[provider]?.removalHeld[path] = nil
            // The slot records the session reading it, for the resume file
            // once that session ends; a slot offered back is now its
            // session's again.
            let reading = sessionsByDirectory[path]
            if let id = reading?.sessionID ?? registrySessions[path] ?? slotSessionsByDirectory[path] {
                let folder = reading?.workingDirectory ?? stateBefore.folderByDirectory[path] ?? slot.folder
                if id != slot.session || folder != slot.folder {
                    sessionRecords.append((slot.directory, id, folder))
                }
            }
            if let offered = stateBefore.reclaimOffered[path] { taken.append((path, offered, slot.account)) }
            // Each session is judged for the model it uses: one whose model's
            // own limit is spent moves to an account with room for that
            // model, and the account's other sessions stay. With no such
            // account it stays where it is.
            // A slot whose process left no session record is named by its
            // status line; one whose model is still unknown is judged by
            // the whole allowance, never by the shared sessions' models.
            let session = sessionsByDirectory[path]
            let model = sessionModel(session?.sessionID ?? slotSessionsByDirectory[path], now: now)
            func cannotServe(_ id: UUID) -> Bool {
                accountCannotServe(id, provider: provider, planner: planner, now: now, model: model, wholeAllowance: true)
            }
            let modelSpent = model != nil && slot.account.map {
                cannotServe($0) && !accountCannotServe($0, provider: provider, planner: planner, now: now, wholeAllowance: true)
            } == true
            let pinned = sessionPins.account(of: session?.sessionID)
            // The pacer's move waits out the session's hold (`moveHold`),
            // which `SessionPacer.plan` already honours.
            let balance = session.flatMap { session -> UUID? in
                guard let destination = sessionSlotStates[provider]?.sessionMoves[session.sessionID],
                      pooled.contains(destination), !session.isWorking, !cannotServe(destination),
                      slotDirectoryMovedAt[path].map({
                          !Self.withinHold(movedAt: $0, cacheLifetime: sessionRates.entries[session.sessionID]?.cacheLifetime,
                                           now: now)
                      }) ?? true
                else { return nil }
                return destination
            }
            let placed = session.map { placements[$0.sessionID] } ?? placements[path]
            let waitsOn = session.flatMap { waiting[$0.sessionID] }
            let heldOn = session.map { admissionHeld[$0.sessionID] } ?? admissionHeldRuns[path]
            // An account that can no longer serve sends its session to the
            // pool's fallback only where the cycle's ledger shows room for
            // it beside everything else sent there (`ledgerFallback`).
            let falling = pinned == nil && !modelSpent && (slot.account.map(cannotServe) ?? false)
                && (placed.map(cannotServe) ?? true) && heldOn == nil && waitsOn == nil
            var fallen: (lane: UUID, charge: LaneLedger.Charge)?
            if falling {
                if fallbackRunning == nil { fallbackRunning = slotRebalanceSessions(provider, slots: slots, now: now) }
                if fallbackAccounts == nil { fallbackAccounts = capacityOutlookAccounts(provider, now: now) }
                let candidates = ([fallback].compactMap { $0 } + byWeight).reduce(into: [UUID]()) { result, id in
                    if !result.contains(id) { result.append(id) }
                }
                fallen = ledgerFallback(provider, id: session?.sessionID ?? path, from: slot.account, byWeight: candidates,
                                        cannotServe: cannotServe, running: fallbackRunning ?? [],
                                        accounts: fallbackAccounts ?? [], now: now)
            }
            let choice = Self.slotChoice(current: slot.account, pinned: pinned,
                                         requested: session.flatMap { requestedSlotMoves.removeValue(forKey: $0.sessionID) },
                                         balance: balance, cannotServe: cannotServe, modelSpent: modelSpent,
                                         byWeight: byWeight, placed: placed,
                                         fallback: falling ? fallen?.lane : fallback, waitsOn: waitsOn, heldOn: heldOn)
            if let fallen, choice.target == fallen.lane, !choice.requested {
                laneLedgers[provider] = { var ledger = laneLedger(provider, now: now); ledger.charge(fallen.charge); return ledger }()
            }
            let target = choice.target
            let balanced = choice.balanced
            let requested = choice.requested
            if let session, let pinned {
                if choice.keptPinned {
                    if pinnedKeptAtLimit.insert(session.sessionID).inserted {
                        let on = accounts.first { $0.id == pinned }.map { messageName($0) } ?? "its account"
                        failoverEvents.record(provider, "Kept the pinned \(Self.eventName(of: session)) on \(on) although \(on) can no longer serve it; unpin it or switch its model to move on.")
                    }
                } else {
                    pinnedKeptAtLimit.remove(session.sessionID)
                }
            }
            if pinned == nil, modelSpent, target == nil, let session, let model, sessionsWithoutModelRoom.insert(session.sessionID).inserted {
                failoverEvents.record(provider, "No account has \(CostParser.shortModelName(model)) allowance left for \(Self.eventName(of: session)); it stays where it is and will be refused until one resets or it changes model.")
                if let fallback = Self.modelFallback(for: model, policy: failoverConfig.policy(for: provider), provider: provider) {
                    pendingModelFallbacks[session.sessionID] = fallback
                }
            } else if !modelSpent, let session {
                sessionsWithoutModelRoom.remove(session.sessionID)
                pendingModelFallbacks[session.sessionID] = nil
            }
            // A CLI that reads only the account it started on keeps its slot's
            // account; the move becomes a restart in a slot of the new one,
            // made once the session is idle and never for a pinned one.
            let move = Self.slotMove(current: slot.account, target: target, needsRestart: slots.isolation.movesNeedRestart,
                                     pinned: pinned != nil, idle: session?.isIdle ?? false, working: session?.isWorking ?? false)
            if move == .restart || move == .wait, let current = slot.account, let target {
                if await serve(slot.directory, current, reason: "serveSessionSlots.claimed", session: session) {
                    sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = current
                }
                guard let session else { continue }
                if move == .restart {
                    let from = accounts.first { $0.id == current }.map { messageName($0) } ?? "its account"
                    let spent = accounts.first { $0.id == current }.flatMap { account in
                        model.flatMap { limitingModel(account, models: [$0], now: now) }
                    }
                    let why = requested && automaticSlotMoves.contains(session.sessionID)
                        ? "the automatic rebalance makes the sessions last longer that way"
                        : requested ? "a request asked for it"
                        : balanced ? "to balance load; it rebuilds its prompt cache there"
                        : spent.map { "\(from) has no \($0) allowance left" } ?? "\(from) can no longer serve it"
                    pendingSlotRestarts[session.sessionID] = PendingSlotRestart(
                        provider: provider, session: session.sessionID, from: current, to: target, why: why, requested: requested
                    )
                } else if requested {
                    requestedSlotMoves[session.sessionID] = target
                }
                continue
            }
            let serveReason = slot.account == target ? "serveSessionSlots.claimed" : "serveSessionSlots.move"
            guard let target, await serve(slot.directory, target, reason: serveReason, session: session) else {
                if let id = slot.account { sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = id }
                continue
            }
            sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = target
            guard slot.account != target else { continue }
            slots.assign(slot.directory, to: target, reason: "serveSessionSlots.move", session: session?.sessionID,
                         process: session?.processID)
            // The session's first request there writes its whole context.
            quotaTrends[target]?.settle(at: now)
            if let session { noteRunwayArrival(session.sessionID, on: target, now: now) }
            let from = slot.account.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "its account"
            let to = accounts.first { $0.id == target }.map { messageName($0) } ?? "another account"
            let subject = session.map { Self.eventName(of: $0) } ?? unrecordedRunName(provider, slot: path)
            slotDirectoryMovedAt[path] = now
            noteSlotAssignment(path, from: slot.account, to: target, at: now)
            // The model's own limit is named when it is what the account
            // has run out of, whether or not the account's other sessions
            // can stay.
            let spent = slot.account.flatMap { id in accounts.first { $0.id == id } }.flatMap { account in
                model.flatMap { limitingModel(account, models: [$0], now: now) }
            }
            // A session leaving the account of its window placement leaves
            // the placement, and the event says why: the window is used up
            // or refused it, or the placement's time has passed.
            let placement = session.flatMap { windowPlacements[$0.sessionID] }.flatMap { $0.account == slot.account ? $0 : nil }
            if let session, windowPlacements[session.sessionID].map({ $0.account != target }) == true {
                windowPlacements[session.sessionID] = nil
            }
            let leaving = placement.flatMap { placement -> String? in
                let refused = accounts.first { $0.id == placement.account }
                    .map { recordedLimitRefusal($0, model: model, now: now) } ?? false
                return Self.windowLeaveReason(account: from, cannotServe: cannotServe(placement.account), refused: refused,
                                              until: placement.until, now: now)
            }
            // A move the automatic rebalance asked for says so, rather than
            // that a request asked for it.
            let automatic = requested && session.map { automaticSlotMoves.remove($0.sessionID) != nil } == true
            let why = pinned != nil ? "it is pinned there"
                : automatic ? "the automatic rebalance makes the sessions last longer that way; it rebuilds its prompt cache there"
                : requested ? "a request asked for it"
                : spent.map { "\(from) has no \($0) allowance left" + (modelSpent ? "; its other sessions stay" : "") }
                ?? leaving ?? "\(from) can no longer serve it"
            // A rebalance's move into a session window is a window
            // placement as the pacer's own is, and recorded the same way.
            if requested, let session, let use = requestedWindowUses.removeValue(forKey: session.sessionID),
               use.account == target {
                remainderMovedAt[target] = now
                recordWindowPlacement(session.sessionID, use: use, now: now)
                failoverEvents.record(provider, Self.windowMoveEvent(session: subject, from: from, account: to, until: use.until,
                                                                     now: now))
                continue
            }
            // A move to spend an allowance that would otherwise expire names
            // that allowance, and rests the account for `balanceMoveInterval`;
            // a move into a session window is recorded as a window placement.
            if balanced, let session, let remainder = sessionSlotStates[provider]?.remainderMoves[session.sessionID],
               remainder.account == target {
                remainderMovedAt[target] = now
                if remainder.window {
                    recordWindowPlacement(session.sessionID, use: SessionPacer.WindowUse(account: target, until: remainder.resetsAt),
                                          now: now)
                }
                failoverEvents.record(provider, remainder.window
                    ? Self.windowMoveEvent(session: subject, from: from, account: to, until: remainder.resetsAt, now: now)
                    : Self.remainderMoveEvent(session: subject, account: to, percentLeft: remainder.percentLeft,
                                              resetsAt: remainder.resetsAt, now: now))
                continue
            }
            // A move the user asked for is theirs; every other one is
            // session balancing's, and its event says so.
            let actor = requested && !automatic ? "Moved" : "Session balancing moved"
            failoverEvents.record(provider, balanced
                ? "Session balancing moved \(subject) from \(from) to \(to) to balance load" + (leaving.map { ", since \($0)" } ?? "")
                    + "; it rebuilds its prompt cache there at its next request."
                : "\(actor) \(subject) from \(from) to \(to): \(why).")
        }
        // A rebalance's window, and its being automatic, outlive no request
        // they belong to.
        requestedWindowUses = requestedWindowUses.filter { requestedSlotMoves[$0.key] != nil }
        automaticSlotMoves = automaticSlotMoves.filter { requestedSlotMoves[$0] != nil }
        let gone = Self.goneRemovals(remove.map(\.path), heldSince: sessionSlotStates[provider]?.massRemovalSince, now: now)
        sessionSlotStates[provider, default: SessionSlotState()].massRemovalSince = gone.heldSince
        if gone.started {
            slotsLog.error("[serveSessionSlots] STOPPED: this pass would remove \(remove.count) claimed slots at once as gone, more than \(Self.maximumGoneRemovals); none is removed. Slots: \(remove.map(\.lastPathComponent).sorted().joined(separator: ", "))")
            failoverEvents.record(provider, "Kept \(remove.count) session slots one pass would have removed at once: so many sessions seeming to end together is more likely a failed reading of the running processes, and removing a running session's slot sends it to the shared sign-in. If no session reads them for \(Int(Self.massRemovalHold / 60)) minutes they are removed \(Self.maximumGoneRemovals) at a time.")
        }
        remove = remove.filter { gone.remove.contains($0.path) }
        // Offers taken back, offers that ended unclaimed, and the sessions
        // slots record; a retired slot a launcher took meanwhile stays.
        let records = sessionRecords
        let (retracted, retired) = (retract, retire)
        let removedOffers: [URL] = retract.isEmpty && retire.isEmpty && records.isEmpty ? [] : await Task.detached(priority: .utility) {
            retracted.forEach { slots.retractReclaimable($0) }
            records.forEach { slots.recordSession($0.session, folder: $0.folder, in: $0.directory) }
            return retired.filter { slots.removeReclaimable($0, reason: "serveSessionSlots.reclaimEnded") }
        }.value
        if !remove.isEmpty || !removeUnclaimed.isEmpty || !removedOffers.isEmpty {
            for directory in remove + removedOffers {
                sessionSlotStates[provider]?.directoryServing[directory.path] = nil
                sessionSlotStates[provider]?.readers[directory.path] = nil
                sessionSlotStates[provider]?.removalHeld[directory.path] = nil
                sessionSlotStates[provider]?.slotSessions[directory.path] = nil
                sessionSlotStates[provider]?.lastSeenInUse[directory.path] = nil
                sessionSlotStates[provider]?.auditSessions[directory.path] = nil
                slotDirectoryMovedAt[directory.path] = nil
                slotAccountHistory[directory.path] = nil
                slotSessionsByDirectory[directory.path] = nil
            }
            for directory in remove + removeUnclaimed + removedOffers { slotCredentialWritten[directory.path] = nil }
            let unclaimed = removeUnclaimed
            await Task.detached(priority: .utility) {
                remove.forEach { slots.remove($0, reason: "serveSessionSlots.sessionGone") }
                unclaimed.forEach { slots.removeUnclaimed($0, reason: "serveSessionSlots.neverClaimed") }
            }.value
        }
        noteReclaims(provider, offered: newlyOffered, taken: taken, removed: removedOffers.count)
        sessionSlotStates[provider, default: SessionSlotState()].reclaimOffered =
            Dictionary(reclaims.map { ($0.path, $0.session) }) { first, _ in first }
        return SlotPass(reclaims: reclaims)
    }

    /// Records the slots this pass offered back to their sessions, and each
    /// session that took its slot back, as events, and the offers removed
    /// unclaimed in the app log. One slot offered alone, as when one
    /// session ends, is logged only.
    private func noteReclaims(_ provider: AIProviderType, offered: [SlotReclaim],
                              taken: [(path: String, session: String, account: UUID?)], removed: Int) {
        func accountName(_ id: UUID?) -> String {
            id.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "its account"
        }
        func sessionName(_ id: String) -> String {
            (liveSessions[provider] ?? []).first { $0.sessionID == id }.map { Self.eventName(of: $0) } ?? "session \(id.prefix(8))"
        }
        if !offered.isEmpty {
            let listed = offered.prefix(6).map { "\($0.session.prefix(8)) (\(accountName($0.account)))" }.joined(separator: ", ")
                + (offered.count > 6 ? " and \(offered.count - 6) more" : "")
            slotsLog.info("[serveSessionSlots] Offered \(offered.count) slot(s) back to their ended sessions: \(listed)")
            if offered.count > 1 {
                failoverEvents.record(provider, "Kept the slots of \(offered.count) sessions that no longer run in them, each for its own session for \(Int(Self.reclaimGrace / 60)) minutes: resumed by ID, it takes its slot back and continues on the account it was on (\(listed)).")
            }
        }
        for item in taken {
            failoverEvents.record(provider, "\(sessionName(item.session)) took back the slot it had and continues on \(accountName(item.account)).")
        }
        if removed > 0 {
            slotsLog.info("[serveSessionSlots] Removed \(removed) slot(s) offered back to sessions that did not resume within \(Int(Self.reclaimGrace / 60)) minutes or now run elsewhere")
        }
    }

    /// The session a claimed slot was last read by: the one it records
    /// itself (`SessionSlots.sessionFile`), its status line's, the only one
    /// this run saw reading it (`seen`), or the credential audit's; nil
    /// when none names one or this run saw several and the slot records
    /// none.
    nonisolated static func knownSlotSession(recorded: String?, statusLine: String?, seen: Set<String>,
                                             audit: String?) -> String? {
        recorded ?? statusLine ?? (seen.count == 1 ? seen.first : nil) ?? audit
    }

    /// How a claimed slot's session reaches the account `slotChoice` chose.
    enum SlotMove: Equatable {
        /// It stays where it is.
        case none
        /// The slot is rewritten for the new account under the running CLI.
        case rewrite
        /// The CLI reads only its first account: the session is ended and
        /// resumed in a slot of the new one (`applySlotRestarts`).
        case restart
        /// As `restart`, but not now: the session is mid-turn or not yet
        /// stopped, or pinned, which only unpinning frees; its slot keeps
        /// its account.
        case wait
    }

    /// The move from `current` to `target` for a session `idle` between
    /// turns or not, `working` on one, `pinned` or not, of a CLI whose
    /// moves restart it (`needsRestart`) or rewrite its slot.
    nonisolated static func slotMove(current: UUID?, target: UUID?, needsRestart: Bool, pinned: Bool,
                                     idle: Bool, working: Bool) -> SlotMove {
        guard let target, target != current else { return .none }
        guard needsRestart, current != nil else { return .rewrite }
        return !pinned && idle && !working ? .restart : .wait
    }

    /// What `serveSessionSlots` decides for one claimed slot.
    struct SlotChoice: Equatable {
        /// The account the slot serves now; nil when none can.
        var target: UUID?
        /// A move asked for through `requestedSlotMoves`.
        var requested = false
        /// A move `SessionPacer` chose to balance load.
        var balanced = false
        /// The slot's session is pinned and stays on an account that can no
        /// longer serve it.
        var keptPinned = false
    }

    /// The account a claimed slot serves: its own while that can serve the
    /// session, else, when only the session's model is spent there, the
    /// first account by weight with room for it, else the account
    /// `strandedPlacements` placed it on (`placed`) while that can serve it,
    /// else `fallback`, which `serveSessionSlots` gives only when the
    /// cycle's ledger shows it carries the session (`ledgerFallback`), and
    /// nil otherwise, so the slot stays; a requested move (`requested`) wins, and failing
    /// one a balancing move (`balance`, already checked by the caller to be
    /// allowed). A pinned session (`pinned`) keeps its pinned account
    /// whatever else would apply, and a request for it is dropped: only
    /// unpinning frees it. A session that waits on its account
    /// (`waitsOn`, from `sessionWaits`) keeps that account although it
    /// cannot serve it now; only a requested move takes it elsewhere. One
    /// lane admission keeps on an account (`heldOn`, from `admissionHolds`,
    /// played or not) goes only where admission places it, never to
    /// `fallback`, since admission found no lane that carries it. An
    /// account that cannot serve is never where an automatic rule moves a
    /// slot: a `placed`, `fallback` or `balance` account at its limit is
    /// passed over, and the slot stays rather than moving from one account
    /// at its limit to another.
    nonisolated static func slotChoice(current: UUID?, pinned: UUID?, requested: UUID?, balance: UUID?,
                                       cannotServe: (UUID) -> Bool, modelSpent: Bool, byWeight: [UUID],
                                       placed: UUID? = nil, fallback: UUID?, waitsOn: UUID? = nil,
                                       heldOn: UUID? = nil) -> SlotChoice {
        if let pinned { return SlotChoice(target: pinned, keptPinned: cannotServe(pinned)) }
        // No automatic rule moves a session onto an account that can no
        // longer serve it: such a fallback or balancing move is dropped.
        func serving(_ id: UUID?) -> UUID? { id.flatMap { cannotServe($0) ? nil : $0 } }
        let target = serving(current)
            ?? (modelSpent ? byWeight.first { !cannotServe($0) } : serving(placed) ?? heldOn ?? serving(fallback))
        if let requested { return SlotChoice(target: requested, requested: true) }
        if let waitsOn { return SlotChoice(target: waitsOn) }
        if let balance = serving(balance), balance != target { return SlotChoice(target: balance, balanced: true) }
        return SlotChoice(target: target)
    }

    /// Writes the account's renewed access token to every session slot that
    /// serves it, at once. The renewal revoked the token those slots held,
    /// and a session that reads its slot before the next quota cycle rewrites
    /// it is refused and told to sign in again. The active account's slots
    /// hold the live credential's token, which its saved copy does not
    /// change. Called by `renewSavedCredential`.
    /// The shell command that starts a session on `account` in `directory`.
    /// It runs the CLI on a one-session slot of the account's own, claimed
    /// for it, so the session stays on the account until failover or
    /// balancing moves the slot (`serveSessionSlots`). The active account's
    /// sessions read the default credential instead, which nothing copies
    /// into a slot, and follow the active account. Nil when the account
    /// cannot serve a session or its credential cannot be written.
    /// Why a session cannot be started on `account` now, for the usage
    /// tiles' session button: it needs signing in, or it is at its limit,
    /// where failover would move the session as soon as it starts.
    func sessionLaunchBlocker(_ account: Account, now: Date = Date()) -> String? {
        if needsSignIn(account) { return "\(messageName(account)) needs signing in again." }
        if let reason = account.cliUnavailableReason { return "\(messageName(account)) cannot serve a session: \(reason)." }
        let planner = FailoverPlanner(settings: plannerSettings(account.provider))
        if accountCannotServe(account.id, provider: account.provider, planner: planner, now: now) {
            return "\(messageName(account)) is at its usage limit, so failover would move the session to another account straight away. Choose a subscription with room, or use one of its resets first."
        }
        return nil
    }

    /// With `pinned`, the session the command starts is pinned to the
    /// account (`SessionPins.pinSlot`), so nothing automatic moves it.
    /// With a `directory` the command first changes to it; without one it
    /// starts the session wherever it is run, as the copied command does.
    func sessionLaunch(on account: Account, in directory: URL?, pinned: Bool = true) async -> String? {
        guard !needsSignIn(account), let slots = SessionSlots(account.provider),
              let cli = slots.realExecutable(preferred: slots.isolation.preferredExecutable) else { return nil }
        let start = directory.map { "cd \(Self.shellQuoted($0.path)) && " } ?? ""
        let lifetime: TimeInterval = readsLiveCredential(account) ? 60 : 2 * 60 * 60
        let id = account.id
        let credential = await slots.isolation.currentSlotCredential(for: account, minimumLifetime: lifetime, from: self)
        var slot: URL?
        if let credential {
            slot = await Task.detached(priority: .userInitiated, operation: {
                slots.makeRequestedSlot(for: id, credential: credential, reason: "sessionLaunch")
            }).value
        }
        // The sessions of the account the CLI's own credential belongs to
        // can still read it when no slot could be filled.
        guard let slot else { return readsLiveCredential(account) ? start + Self.shellQuoted(cli) : nil }
        sessionSlotStates[account.provider, default: SessionSlotState()].directoryServing[slot.path] = id
        noteSlotAssignment(slot.path, from: nil, to: id, at: Date())
        sessionSlotStates[account.provider, default: SessionSlotState()].credentialAccounts.insert(id)
        if pinned {
            sessionPins.pinSlot(slot.path, account: id, provider: account.provider, at: Date())
            sessionPins.save()
        }
        slotsLog.info("Slot claimed for a session started on \(messageName(account))\(pinned ? ", pinned there" : "")")
        let assignments = slots.isolation.launchAssignments(forSlot: slot).map { "\($0.name)=\(Self.shellQuoted($0.value)) " }
        let arguments = slots.isolation.launchArguments(forSlot: slot).map { " " + Self.shellQuoted($0) }
        return start + assignments.joined() + Self.shellQuoted(cli) + arguments.joined()
    }

    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func reissueSlotCredential(for account: Account) async {
        guard let slots = SessionSlots(account.provider),
              let saved = credentialModule(for: account.provider)?.liveCredential?.savedCopy(account,
                                                                                             reason: "reissueSlotCredential"),
              let credential = slots.isolation.slotCredential(from: saved) else { return }
        let id = account.id
        let serving = sessionSlotStates[account.provider]?.directoryServing ?? [:]
        let holding = await Task.detached(priority: .utility) { slots.directories(holding: id, serving: serving) }.value
        // The renewal revoked what these slots held, so each is written now
        // whatever `serveSlot` last found there.
        for path in holding { slotCredentialWritten[path] = nil }
        let processes = slotDirectoryByProcess.reduce(into: [String: Int32]()) { $0[$1.value] = $1.key }
        var written = 0
        for path in holding where await serveSlot(slots, URL(fileURLWithPath: path), credential: credential, recheck: 0,
                                                  account: id, reason: "reissueSlotCredential",
                                                  session: slotSessionsByDirectory[path], process: processes[path]) {
            written += 1
        }
        slotsLog.info("Renewed credential of \(messageName(account)) written to \(written) slot(s)")
    }

    /// Keeps the account-level slots (`SessionSlots.directory(for:)`) that
    /// running sessions read, which no launch hands to a session any more:
    /// writes a current credential to each and deletes the rest. A running
    /// session's slot keeps its own account while that account is in the
    /// pool, and otherwise serves the pool's highest-weight account, so the
    /// session continues on an account with room.
    private func serveRunning(_ slots: SessionSlots, provider: AIProviderType, members: [RouterPoolMember],
                              inUse: Set<String>) async {
        let active = accounts.first { $0.provider == provider && $0.isActive }
        let activeID = active?.id
        let running = Set(inUse.compactMap { slots.account(forDirectory: $0) })
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        // A running session's slot keeps its account until the planner finds
        // it unable to serve; with no pool at all every slot follows the
        // fallback, as when distribution was turned off.
        let pooled = members.isEmpty ? Set<UUID>() : Set(running.filter {
            !accountCannotServe($0, provider: provider, planner: planner, now: Date())
        }).union(members.compactMap { UUID(uuidString: $0.accountID) })
        let fallback = members.max { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : rhs.accountID == activeID?.uuidString
        }.flatMap { UUID(uuidString: $0.accountID) } ?? activeID
        var credentials: [UUID: SlotCredential] = [:]
        // A session of a CLI that reads only the account it started on
        // stays on its own: its slot is never rewritten for another.
        let keepsOwn = slots.isolation.movesNeedRestart
        for slot in running {
            let servingID = pooled.contains(slot) || keepsOwn ? slot : fallback
            guard let servingID, let account = accounts.first(where: { $0.id == servingID }) else { continue }
            if credentials[servingID] == nil {
                let lifetime: TimeInterval = readsLiveCredential(account) ? 60 : 2 * 60 * 60
                guard let current = await slots.isolation.currentSlotCredential(for: account, minimumLifetime: lifetime,
                                                                                 from: self) else {
                    slotsLog.warning("No current credential for \(messageName(account)); its slot is not updated")
                    continue
                }
                credentials[servingID] = current
            }
            guard let credential = credentials[servingID] else { continue }
            let directory = slots.directory(for: slot)
            if !(await serveSlot(slots, directory, credential: credential, recheck: Self.claimedRecheckInterval,
                                 account: servingID, reason: "serveRunning.running")) {
                slotsLog.error("Slot for \(slot.uuidString) not written")
            }
        }
        for slot in running {
            sessionSlotStates[provider, default: SessionSlotState()].directoryServing[slots.directory(for: slot).path] = pooled.contains(slot) || keepsOwn ? slot : fallback
        }
        for path in (sessionSlotStates[provider]?.directoryServing ?? [:]).keys
        where slots.account(forDirectory: path) != nil && !inUse.contains(path) {
            sessionSlotStates[provider]?.directoryServing[path] = nil
        }
        let stale = slots.slotDirectories().filter { directory in
            UUID(uuidString: directory.lastPathComponent).map { !running.contains($0) } ?? false
        }
        // `running` comes from the process scan; after one that did not
        // read the whole list it may lack slots sessions still read.
        if !stale.isEmpty, sessionSlotStates[provider]?.scanSucceeded == true {
            for directory in stale { slotCredentialWritten[directory.path] = nil }
            await Task.detached(priority: .utility) { stale.forEach { slots.remove($0, reason: "serveRunning.stale") } }.value
        }
    }
}
