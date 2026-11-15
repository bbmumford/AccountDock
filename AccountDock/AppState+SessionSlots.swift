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
        /// Watches the one-session slot directory for a launcher's request
        /// for a spare; installed by `watchSpareRequests`.
        var spareRequestWatcher: DispatchSourceFileSystemObject?

        /// Drops a removed account.
        mutating func forget(_ id: UUID) {
            servedAccounts.remove(id)
            credentialAccounts.remove(id)
            directoryServing = directoryServing.filter { $0.value != id }
            sessionMoves = sessionMoves.filter { $0.value != id }
            remainderMoves = remainderMoves.filter { $0.value.account != id }
        }
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
    /// each account's slot and the pool file current while its sessions
    /// are distributed, and afterwards removes them, keeping the slots
    /// running sessions still read. `processesRead` says
    /// `refreshSlotProcesses` has just run, as the quota cycle runs it
    /// before counting sessions. One call runs at a time; a call made
    /// meanwhile, as when a launcher asks for a spare, runs once more after
    /// it.
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

    /// Fills spares at once when a launcher has asked for one
    /// (`SessionSlots.takeSpareRequests`), instead of at the next quota
    /// cycle: the launcher waits only a few seconds before it starts its
    /// session on a shared credential. The watch is on the provider's
    /// one-session slot directory, where the launcher leaves its request.
    func watchSpareRequests(_ slots: SessionSlots, provider: AIProviderType) {
        guard sessionSlotStates[provider]?.spareRequestWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: slots.sessionRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = open(slots.sessionRoot.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, await Task.detached(priority: .userInitiated, operation: { slots.takeSpareRequests() }).value else { return }
                await self.maintainSessionSlots()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sessionSlotStates[provider, default: SessionSlotState()].spareRequestWatcher = source
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
            await serveSessionSlots(slots, provider: provider, members: [], inUse: inUse, now: now)
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
        watchSpareRequests(slots, provider: provider)
        let members = await buildPool(provider, now: now, forRouter: false)
        if mirrorsRouterPool { routerPoolMembers = members }
        let open = Set(members.filter { $0.weight > 0 }.compactMap { UUID(uuidString: $0.accountID) })
        let served = await serveRunning(slots, provider: provider, members: members, inUse: inUse, newSessions: open)
        var resumes = resumeTargets(provider, now: now)
        for (session, restart) in slotRestartResumes where restart.provider == provider {
            resumes[session] = restart.account
        }
        let spares = await serveSessionSlots(slots, provider: provider, members: members, inUse: inUse,
                                             resumeAccounts: Set(resumes.values), now: now)
        let activeForResume = accounts.first { $0.provider == provider && $0.isActive }?.id
        let resumeEntries = resumes.compactMap { session, account -> (session: String, path: String)? in
            if spares.contains(account) { return (session, slots.directory(for: account).path) }
            return account == activeForResume ? (session, SessionSlots.activeEntry) : nil
        }.sorted { $0.session < $1.session }
        await Task.detached(priority: .utility) { slots.writeResumes(resumeEntries) }.value
        let slotServed = Set((sessionSlotStates[provider]?.directoryServing ?? [:]).values)
        sessionSlotStates[provider, default: SessionSlotState()].servedAccounts = slotServed
        sessionSlotStates[provider, default: SessionSlotState()].credentialAccounts = slotServed.union(served).union(spares)
        let active = accounts.first { $0.provider == provider && $0.isActive }?.id
        // The launcher names an account by its slot's path. The active
        // account's slot holds no credential, so when no spare of it is left
        // the launcher starts the CLI on the default credential.
        let entries: [(path: String, weight: Double)] = members.compactMap { member in
            guard let id = UUID(uuidString: member.accountID), member.weight > 0 else { return nil }
            if id == active { return (spares.contains(id) ? slots.directory(for: id).path : SessionSlots.activeEntry, member.weight) }
            return served.contains(id) || spares.contains(id) ? (slots.directory(for: id).path, member.weight) : nil
        }
        await Task.detached(priority: .utility) { slots.writePool(entries) }.value
    }

    /// Reads which slot each running process reads, for `refreshSessions`
    /// and `maintainSessionSlots`, and each isolated CLI's background-session
    /// processes, from one fresh `ProcessTable`; run first on every quota
    /// cycle, and the readers after it within seconds reuse that table
    /// (`ProcessTable.current(maxAge:)`).
    func refreshSlotProcesses() async {
        let isolated = AIProviderType.isolatedProviders.compactMap { provider in
            SessionSlots(provider).map { (provider, $0) }
        }
        guard !isolated.isEmpty else { return }
        let read = await Task.detached(priority: .utility) { () -> [([Int32: String], BackgroundSessionProcesses)] in
            let table = ProcessTable.read() ?? ProcessTable(entries: [])
            return isolated.map { _, slots in
                let background = slots.background.map {
                    BackgroundSessionProcesses(table: table, executable: slots.executable, support: $0)
                } ?? BackgroundSessionProcesses()
                return (slots.directoriesByProcess(in: table), background)
            }

        }.value
        for ((provider, slots), (directories, background)) in zip(isolated, read) {
            sessionSlotStates[provider, default: SessionSlotState()].background = background
            let byProcess = Self.sessionSlotDirectories(directories, background: background)
            sessionSlotStates[provider, default: SessionSlotState()].directoryByProcess = byProcess
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

    /// Spare one-session slots kept filled for each account taking new
    /// sessions: `minimumSpares`, or two more than the most sessions seen
    /// running at once in the last day when that is more, up to
    /// `maximumSpares`. A terminal that restores every session at once
    /// after a restart then finds a slot for each, at a moment AccountDock
    /// is itself still starting and cannot fill more.
    nonisolated static func spareTarget(peakSessions: Int) -> Int {
        min(max(minimumSpares, peakSessions + 2), maximumSpares)
    }
    nonisolated static let minimumSpares = 3
    nonisolated static let maximumSpares = 16
    /// How long a count of running sessions stays the peak `spareTarget`
    /// is taken from.
    nonisolated static let sessionPeakLifetime: TimeInterval = 24 * 60 * 60

    /// The peak after `running` sessions are seen at `now`: a higher count
    /// replaces it, an expired one is replaced by the current count, and a
    /// peak still being matched has its date moved on hourly, not on every
    /// cycle, so it is rarely written.
    nonisolated static func sessionPeak(stored: (count: Int, at: Date)?, running: Int, now: Date) -> (count: Int, at: Date) {
        guard let stored, now.timeIntervalSince(stored.at) < sessionPeakLifetime else { return (running, now) }
        if running > stored.count { return (running, now) }
        if running == stored.count, now.timeIntervalSince(stored.at) > 60 * 60 { return (running, now) }
        return stored
    }

    /// The most sessions of the provider seen running at once in the last
    /// day, kept across launches: after a restart no session runs yet, at
    /// the very moment the spare count has to cover all of them.
    func recentSessionPeak(_ provider: AIProviderType, now: Date) -> Int {
        let key = "slotSessionPeak." + provider.capabilities.storageKey
        let saved = UserDefaults.standard.dictionary(forKey: key)
        var stored: (count: Int, at: Date)?
        if let count = saved?["count"] as? Int, let at = saved?["at"] as? Double {
            stored = (count, Date(timeIntervalSince1970: at))
        }
        let peak = Self.sessionPeak(stored: stored, running: liveSessions[provider]?.count ?? 0, now: now)
        if stored?.count != peak.count || stored?.at != peak.at {
            UserDefaults.standard.set(["count": peak.count, "at": peak.at.timeIntervalSince1970], forKey: key)
        }
        return peak.count
    }

    /// How long a slot `serveSlot` wrote is trusted to still hold what was
    /// written: a spare, which nothing else touches, and a slot a session
    /// reads, whose CLI can replace its item.
    nonisolated static let spareRecheckInterval: TimeInterval = 10 * 60
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
    static let slotClaimGrace: TimeInterval = 2 * 60
    /// The same for a slot claimed by `sessionLaunch`, whose command may be
    /// copied and run some minutes later.
    static let requestedClaimGrace: TimeInterval = 30 * 60
    /// A session moved to balance load stays where it went at least this
    /// long, so it is not moved back before its new cache has paid off.
    static let balanceMoveInterval: TimeInterval = 30 * 60

    /// Keeps the one-session slots: each claimed slot serves its account, or
    /// the pool's highest-weight account once its own leaves the pool, and
    /// moves to the account `SessionPacer` chose for its session between
    /// two of the session's turns; a move rewrites the slot, which the CLI
    /// reads again before its next request. Spare slots are kept for each
    /// account in `members` with a positive weight, the active one
    /// included, and the rest removed; the isolation's
    /// `currentSlotCredential` keeps the active account's token renewed
    /// while slots hold it. `resumeAccounts` keep
    /// spares too, for sessions resumed on them. Returns the accounts that
    /// have a spare slot.
    @discardableResult
    private func serveSessionSlots(_ slots: SessionSlots, provider: AIProviderType, members: [RouterPoolMember],
                                   inUse: Set<String>, resumeAccounts: Set<UUID> = [], now: Date) async -> Set<UUID> {
        let activeID = accounts.first { $0.provider == provider && $0.isActive }?.id
        let pooled = Set(members.compactMap { UUID(uuidString: $0.accountID) })
        let open = Set(members.filter { $0.weight > 0 }.compactMap { UUID(uuidString: $0.accountID) })
            .union(resumeAccounts)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let fallback = members.max { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : rhs.accountID == activeID?.uuidString
        }.flatMap { UUID(uuidString: $0.accountID) } ?? activeID
        // The pool's accounts, the one taking most new sessions first.
        let byWeight = members.sorted { $0.weight > $1.weight }.compactMap { UUID(uuidString: $0.accountID) }
        // Sessions on an account that can no longer serve them, each placed
        // where the pool lasts longest with it.
        let placements = members.isEmpty ? [:] : strandedPlacements(provider, slots: slots, members: members, now: now)
        let byProcess = sessionSlotStates[provider]?.directoryByProcess ?? [:]
        let sessionsByDirectory: [String: AgentSession] = (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            if let pid = session.processID, let directory = byProcess[pid] { result[directory] = session }
        }
        maintainPins(provider, sessionsBySlot: sessionsByDirectory.mapValues(\.sessionID), now: now)
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
        func serve(_ directory: URL, _ id: UUID, spare: Bool = false, reason: String,
                   session: AgentSession? = nil) async -> Bool {
            guard let value = await credential(id) else { return false }
            return await serveSlot(slots, directory, credential: value,
                                   recheck: spare ? Self.spareRecheckInterval : Self.claimedRecheckInterval,
                                   account: id, reason: reason, session: session?.sessionID,
                                   process: session?.processID, now: now)
        }
        let spareTarget = Self.spareTarget(peakSessions: recentSessionPeak(provider, now: now))
        var sparesOf: [UUID: Int] = [:]
        var remove: [URL] = []
        var removeSpares: [URL] = []
        for slot in await Task.detached(priority: .utility, operation: { slots.sessionSlots() }).value {
            let path = slot.directory.path
            guard let claimedAt = slot.claimedAt else {
                guard let id = slot.account, open.contains(id), sparesOf[id, default: 0] < spareTarget,
                      await serve(slot.directory, id, spare: true, reason: "serveSessionSlots.spare") else {
                    removeSpares.append(slot.directory)
                    continue
                }
                sparesOf[id, default: 0] += 1
                continue
            }
            // A move made before AccountDock last started is dated by the
            // slot's account file, which every move rewrites.
            if slotDirectoryMovedAt[path] == nil, let assigned = slot.assignedAt, assigned > claimedAt {
                slotDirectoryMovedAt[path] = assigned
            }
            guard inUse.contains(path) else {
                let grace = slot.requested ? Self.requestedClaimGrace : Self.slotClaimGrace
                if now.timeIntervalSince(claimedAt) > grace { remove.append(slot.directory) }
                else if let id = slot.account { sessionSlotStates[provider, default: SessionSlotState()].directoryServing[path] = id }
                continue
            }
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
            let balance = session.flatMap { session -> UUID? in
                guard let destination = sessionSlotStates[provider]?.sessionMoves[session.sessionID],
                      pooled.contains(destination), !session.isWorking,
                      model == nil || !cannotServe(destination),
                      slotDirectoryMovedAt[path].map({ now.timeIntervalSince($0) >= Self.balanceMoveInterval }) ?? true
                else { return nil }
                return destination
            }
            let choice = Self.slotChoice(current: slot.account, pinned: pinned,
                                         requested: session.flatMap { requestedSlotMoves.removeValue(forKey: $0.sessionID) },
                                         balance: balance, cannotServe: cannotServe, modelSpent: modelSpent,
                                         byWeight: byWeight, placed: session.flatMap { placements[$0.sessionID] },
                                         fallback: fallback)
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
                    let why = requested ? "a request asked for it"
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
            let from = slot.account.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "its account"
            let to = accounts.first { $0.id == target }.map { messageName($0) } ?? "another account"
            let subject = Self.eventName(of: session)
            slotDirectoryMovedAt[path] = now
            noteSlotAssignment(path, from: slot.account, to: target, at: now)
            // The model's own limit is named when it is what the account
            // has run out of, whether or not the account's other sessions
            // can stay.
            let spent = slot.account.flatMap { id in accounts.first { $0.id == id } }.flatMap { account in
                model.flatMap { limitingModel(account, models: [$0], now: now) }
            }
            let why = pinned != nil ? "it is pinned there"
                : requested ? "a request asked for it"
                : spent.map { "\(from) has no \($0) allowance left" + (modelSpent ? "; its other sessions stay" : "") }
                ?? "\(from) can no longer serve it"
            // A move to spend an allowance that would otherwise expire names
            // that allowance, and holds the account for `balanceMoveInterval`.
            if balanced, let session, let remainder = sessionSlotStates[provider]?.remainderMoves[session.sessionID],
               remainder.account == target {
                remainderMovedAt[target] = now
                failoverEvents.record(provider, Self.remainderMoveEvent(session: subject, account: to,
                                                                        percentLeft: remainder.percentLeft,
                                                                        resetsAt: remainder.resetsAt, now: now))
                continue
            }
            failoverEvents.record(provider, balanced
                ? "Moved \(subject) from \(from) to \(to) to balance load; it rebuilds its prompt cache there at its next request."
                : "Moved \(subject) from \(from) to \(to): \(why).")
        }
        for id in open where sparesOf[id, default: 0] < spareTarget {
            guard let value = await credential(id) else { continue }
            let missing = spareTarget - sparesOf[id, default: 0]
            let made = await Task.detached(priority: .utility) {
                (0..<missing).filter { _ in slots.makeSpare(for: id, credential: value, reason: "serveSessionSlots.newSpare") }.count
            }.value
            sparesOf[id, default: 0] += made
        }
        if !remove.isEmpty || !removeSpares.isEmpty {
            for directory in remove {
                sessionSlotStates[provider]?.directoryServing[directory.path] = nil
                slotDirectoryMovedAt[directory.path] = nil
                slotAccountHistory[directory.path] = nil
                slotSessionsByDirectory[directory.path] = nil
            }
            for directory in remove + removeSpares { slotCredentialWritten[directory.path] = nil }
            await Task.detached(priority: .utility) {
                remove.forEach { slots.remove($0, reason: "serveSessionSlots.sessionGone") }
                removeSpares.forEach { slots.removeSpare($0, reason: "serveSessionSlots.spareNotWanted") }
            }.value
        }
        return Set(sparesOf.filter { $0.value > 0 }.keys)
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
    /// else `fallback`; a requested move (`requested`) wins, and failing
    /// one a balancing move (`balance`, already checked by the caller to be
    /// allowed). A pinned session (`pinned`) keeps its pinned account
    /// whatever else would apply, and a request for it is dropped: only
    /// unpinning frees it.
    nonisolated static func slotChoice(current: UUID?, pinned: UUID?, requested: UUID?, balance: UUID?,
                                       cannotServe: (UUID) -> Bool, modelSpent: Bool, byWeight: [UUID],
                                       placed: UUID? = nil, fallback: UUID?) -> SlotChoice {
        if let pinned { return SlotChoice(target: pinned, keptPinned: cannotServe(pinned)) }
        let target = current.flatMap { cannotServe($0) ? nil : $0 }
            ?? (modelSpent ? byWeight.first { !cannotServe($0) } : placed.flatMap { cannotServe($0) ? nil : $0 } ?? fallback)
        if let requested { return SlotChoice(target: requested, requested: true) }
        if let balance, balance != target { return SlotChoice(target: balance, balanced: true) }
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

    /// Writes a current credential to the slot of every account in
    /// `newSessions` and every slot a running session reads, and deletes the
    /// other slots. A running session's slot keeps its own account while
    /// that account is in the pool, and otherwise serves the pool's
    /// highest-weight account, so the session continues on an account with
    /// room. Returns the accounts in `newSessions` whose slot holds a
    /// credential.
    @discardableResult
    private func serveRunning(_ slots: SessionSlots, provider: AIProviderType, members: [RouterPoolMember],
                              inUse: Set<String>, newSessions: Set<UUID> = []) async -> Set<UUID> {
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
        var ready = Set<UUID>()
        var credentials: [UUID: SlotCredential] = [:]
        // A session of a CLI that reads only the account it started on
        // stays on its own: its slot is never rewritten for another.
        let keepsOwn = slots.isolation.movesNeedRestart
        for slot in newSessions.subtracting([activeID].compactMap { $0 }).union(running) {
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
            let recheck = running.contains(slot) ? Self.claimedRecheckInterval : Self.spareRecheckInterval
            if await serveSlot(slots, directory, credential: credential, recheck: recheck, account: servingID,
                               reason: running.contains(slot) ? "serveRunning.running" : "serveRunning.newSession") {
                ready.insert(slot)
            } else {
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
        let keep = ready.union(running)
        let stale = slots.slotDirectories().filter { directory in
            UUID(uuidString: directory.lastPathComponent).map { !keep.contains($0) } ?? false
        }
        if !stale.isEmpty {
            for directory in stale { slotCredentialWritten[directory.path] = nil }
            await Task.detached(priority: .utility) { stale.forEach { slots.remove($0, reason: "serveRunning.stale") } }.value
        }
        return ready.intersection(newSessions)
    }
}
