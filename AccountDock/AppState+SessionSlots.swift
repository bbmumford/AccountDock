import Foundation

private let slotsLog = FileLog("SessionSlots")

/// Serves the routed provider's sessions from several accounts at once
/// through `SessionSlots` when its CLI supports them, instead of the router.
extension AppState {
    /// Whether the routed provider's settings distribute sessions and its CLI
    /// starts each session on an account of its own; a route to another
    /// provider needs the router, which then serves the sessions.
    var sessionSlotsWanted: Bool {
        guard let provider = AIProviderType.routedProvider, provider.capabilities.sessionSlots != nil else { return false }
        let policy = failoverConfig.policy(for: provider)
        return policy.distributeSessions && !policy.usesRouter(for: provider)
    }

    /// Whether new terminal sessions of the routed provider start on
    /// accounts picked from the pool.
    var sessionSlotsInUse: Bool {
        guard sessionSlotsWanted, let provider = AIProviderType.routedProvider,
              let slots = SessionSlots(provider) else { return false }
        return slots.launcherInstalled
    }

    /// Runs on every quota cycle: keeps the launcher, each account's slot and
    /// the pool file current while sessions are distributed, and afterwards
    /// removes them, keeping the slots running sessions still read.
    /// `processesRead` says `refreshSlotProcesses` has just run, as the
    /// quota cycle runs it before counting sessions. One call runs at a
    /// time; a call made meanwhile, as when a launcher asks for a spare,
    /// runs once more after it.
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
    }

    /// Fills spares at once when a launcher has asked for one
    /// (`SessionSlots.takeSpareRequests`), instead of at the next quota
    /// cycle: the launcher waits only a few seconds before it starts its
    /// session on a shared credential. The watch is on the one-session slot
    /// directory, where the launcher leaves its request.
    func watchSpareRequests(_ slots: SessionSlots) {
        guard spareRequestWatcher == nil else { return }
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
        spareRequestWatcher = source
    }

    private func maintainSessionSlotsOnce(now: Date, processesRead: Bool) async {
        guard let provider = AIProviderType.routedProvider, let slots = SessionSlots(provider) else { return }
        if !processesRead { await refreshSlotProcesses() }
        let inUse = Set(slotDirectoryByProcess.values)
        guard sessionSlotsWanted else {
            if slots.launcherInstalled || FileManager.default.fileExists(atPath: slots.launcher.path) {
                slots.removeLauncher()
                slotsLog.info("Launcher removed; sessions it started keep their accounts until they exit")
            }
            if !routerInUse { routerPoolMembers = [] }
            slotSessionMoves = [:]
            await serveRunning(slots, provider: provider, members: [], inUse: inUse)
            await serveSessionSlots(slots, provider: provider, members: [], inUse: inUse, now: now)
            slotServedAccounts = Set(slotDirectoryServing.values)
            slotCredentialAccounts = slotServedAccounts
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
        watchSpareRequests(slots)
        let members = await buildPool(provider, now: now, forRouter: false)
        routerPoolMembers = members
        let open = Set(members.filter { $0.weight > 0 }.compactMap { UUID(uuidString: $0.accountID) })
        let served = await serveRunning(slots, provider: provider, members: members, inUse: inUse, newSessions: open)
        let resumes = resumeTargets(provider, now: now)
        let spares = await serveSessionSlots(slots, provider: provider, members: members, inUse: inUse,
                                             resumeAccounts: Set(resumes.values), now: now)
        let activeForResume = accounts.first { $0.provider == provider && $0.isActive }?.id
        let resumeEntries = resumes.compactMap { session, account -> (session: String, path: String)? in
            if spares.contains(account) { return (session, slots.directory(for: account).path) }
            return account == activeForResume ? (session, SessionSlots.activeEntry) : nil
        }.sorted { $0.session < $1.session }
        await Task.detached(priority: .utility) { slots.writeResumes(resumeEntries) }.value
        slotServedAccounts = Set(slotDirectoryServing.values)
        slotCredentialAccounts = slotServedAccounts.union(served).union(spares)
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
    /// and `maintainSessionSlots`; run first on every quota cycle.
    func refreshSlotProcesses() async {
        guard let provider = AIProviderType.routedProvider, let slots = SessionSlots(provider) else { return }
        slotDirectoryByProcess = await Task.detached(priority: .utility) { slots.directoriesByProcess() }.value
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
    static let slotMoveSettling: TimeInterval = 2 * 60

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
    /// the rest (`plannedUsage`).
    func accountCannotServe(_ id: UUID, provider: AIProviderType, planner: FailoverPlanner, now: Date,
                            model: String? = nil) -> Bool {
        guard let account = accounts.first(where: { $0.id == id && $0.provider == provider }) else { return true }
        let tier = planner.tier(quotaState(for: account, now: now, model: model), now: now)
        return tier == .exhausted || tier == .ineligible
    }

    /// The account each recent session that is not running last ran on,
    /// where that account can still serve it, so `claude --resume <id>`
    /// continues it there with its cache and thinking.
    func resumeTargets(_ provider: AIProviderType, now: Date) -> [String: UUID] {
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let running = Set((liveSessions[provider] ?? []).map(\.sessionID))
        var usable: [UUID: Bool] = [:]
        var targets: [String: UUID] = [:]
        for (session, entry) in sessionRates.entries where !running.contains(session) {
            let canServe = usable[entry.account] ?? !accountCannotServe(entry.account, provider: provider, planner: planner, now: now)
            usable[entry.account] = canServe
            if canServe { targets[session] = entry.account }
        }
        return targets
    }

    /// Spare one-session slots kept filled for each account taking new
    /// sessions.
    static let sparesPerAccount = 3
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
    /// included, and the rest removed; `claudeCredential` keeps the active
    /// account's token renewed while slots hold it. `resumeAccounts` keep
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
        let sessionsByDirectory: [String: AgentSession] = (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            if let pid = session.processID, let directory = slotDirectoryByProcess[pid] { result[directory] = session }
        }
        var credentials: [UUID: String] = [:]
        func credential(_ id: UUID) async -> String? {
            if let known = credentials[id] { return known }
            guard let account = accounts.first(where: { $0.id == id }),
                  let json = await claudeCredential(account, minimumLifetime: account.isActive ? 60 : 2 * 60 * 60),
                  let accessOnly = SessionSlots.accessOnly(json) else { return nil }
            credentials[id] = accessOnly
            return accessOnly
        }
        func serve(_ directory: URL, _ id: UUID) async -> Bool {
            guard let value = await credential(id) else { return false }
            return await Task.detached(priority: .utility) { slots.serve(directory, credential: value) }.value
        }
        var sparesOf: [UUID: Int] = [:]
        var remove: [URL] = []
        var removeSpares: [URL] = []
        for slot in await Task.detached(priority: .utility, operation: { slots.sessionSlots() }).value {
            let path = slot.directory.path
            guard let claimedAt = slot.claimedAt else {
                guard let id = slot.account, open.contains(id), sparesOf[id, default: 0] < Self.sparesPerAccount,
                      await serve(slot.directory, id) else {
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
                else if let id = slot.account { slotDirectoryServing[path] = id }
                continue
            }
            // Each session is judged for the model it uses: one whose model's
            // own limit is spent moves to an account with room for that
            // model, and the account's other sessions stay. With no such
            // account it stays where it is.
            let session = sessionsByDirectory[path]
            let model = sessionModel(session?.sessionID, now: now)
            func cannotServe(_ id: UUID) -> Bool {
                accountCannotServe(id, provider: provider, planner: planner, now: now, model: model)
            }
            let modelSpent = model != nil && slot.account.map {
                cannotServe($0) && !accountCannotServe($0, provider: provider, planner: planner, now: now)
            } == true
            var target = slot.account.flatMap { cannotServe($0) ? nil : $0 }
                ?? (modelSpent ? byWeight.first { !cannotServe($0) } : fallback)
            var balanced = false
            if let session, let destination = slotSessionMoves[session.sessionID], destination != target,
               pooled.contains(destination), !session.isWorking, model == nil || !cannotServe(destination),
               slotDirectoryMovedAt[path].map({ now.timeIntervalSince($0) >= Self.balanceMoveInterval }) ?? true {
                target = destination
                balanced = true
            }
            guard let target, await serve(slot.directory, target) else {
                if let id = slot.account { slotDirectoryServing[path] = id }
                continue
            }
            slotDirectoryServing[path] = target
            guard slot.account != target else { continue }
            slots.assign(slot.directory, to: target)
            let from = slot.account.flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "its account"
            let to = accounts.first { $0.id == target }.map { messageName($0) } ?? "another account"
            let place = session?.workingDirectory.map { " in " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            slotDirectoryMovedAt[path] = now
            let why = modelSpent
                ? "\(from) has no \(model.map { CostParser.shortModelName($0) } ?? "model") allowance left; its other sessions stay"
                : "\(from) can no longer serve it"
            failoverEvents.record(provider, balanced
                ? "Moved the session\(place) from \(from) to \(to) to balance load; it rebuilds its prompt cache there at its next request."
                : "Moved the session\(place) from \(from) to \(to): \(why).")
        }
        for id in open where sparesOf[id, default: 0] < Self.sparesPerAccount {
            guard let value = await credential(id) else { continue }
            let missing = Self.sparesPerAccount - sparesOf[id, default: 0]
            let made = await Task.detached(priority: .utility) {
                (0..<missing).filter { _ in slots.makeSpare(for: id, credential: value) }.count
            }.value
            sparesOf[id, default: 0] += made
        }
        if !remove.isEmpty || !removeSpares.isEmpty {
            for directory in remove {
                slotDirectoryServing[directory.path] = nil
                slotDirectoryMovedAt[directory.path] = nil
            }
            await Task.detached(priority: .utility) {
                remove.forEach(slots.remove)
                removeSpares.forEach { slots.removeSpare($0) }
            }.value
        }
        return Set(sparesOf.filter { $0.value > 0 }.keys)
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

    func sessionLaunch(on account: Account, in directory: URL) async -> String? {
        guard account.provider.capabilities.sessionSlots != nil, !needsSignIn(account),
              let slots = SessionSlots(account.provider),
              let cli = slots.realExecutable(preferred: ClaudeService.shared.claudePath) else { return nil }
        let start = "cd \(Self.shellQuoted(directory.path)) && "
        let lifetime: TimeInterval = account.isActive ? 60 : 2 * 60 * 60
        let id = account.id
        let accessOnly = await claudeCredential(account, minimumLifetime: lifetime).flatMap(SessionSlots.accessOnly)
        var slot: URL?
        if let accessOnly {
            slot = await Task.detached(priority: .userInitiated, operation: { () -> URL? in
                guard let slot = slots.makeSlot(for: id, credential: accessOnly), slots.claimRequested(slot) else { return nil }
                return slot
            }).value
        }
        // The active account's sessions can still read the CLI's own
        // credential when no slot could be filled.
        guard let slot else { return account.isActive ? start + Self.shellQuoted(cli) : nil }
        slotDirectoryServing[slot.path] = id
        slotCredentialAccounts.insert(id)
        slotsLog.info("Slot claimed for a session started on \(messageName(account))")
        return start + "CLAUDE_SECURESTORAGE_CONFIG_DIR=\(Self.shellQuoted(slot.path)) \(Self.shellQuoted(cli))"
    }

    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func reissueSlotCredential(for account: Account) async {
        guard account.provider == AIProviderType.routedProvider,
              let slots = SessionSlots(account.provider),
              let json = credentialModule(for: account.provider)?.liveCredential?.savedCopy(account),
              let accessOnly = SessionSlots.accessOnly(json) else { return }
        let id = account.id
        let serving = slotDirectoryServing
        let written = await Task.detached(priority: .utility) {
            slots.directories(holding: id, serving: serving)
                .filter { slots.serve(URL(fileURLWithPath: $0), credential: accessOnly) }.count
        }.value
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
        var credentials: [UUID: String] = [:]
        for slot in newSessions.subtracting([activeID].compactMap { $0 }).union(running) {
            let servingID = pooled.contains(slot) ? slot : fallback
            guard let servingID, let account = accounts.first(where: { $0.id == servingID }) else { continue }
            if credentials[servingID] == nil {
                let lifetime: TimeInterval = account.isActive ? 60 : 2 * 60 * 60
                guard let json = await claudeCredential(account, minimumLifetime: lifetime),
                      let accessOnly = SessionSlots.accessOnly(json) else {
                    slotsLog.warning("No current credential for \(messageName(account)); its slot is not updated")
                    continue
                }
                credentials[servingID] = accessOnly
            }
            guard let credential = credentials[servingID] else { continue }
            let directory = slots.directory(for: slot)
            if await Task.detached(priority: .utility, operation: { slots.serve(directory, credential: credential) }).value {
                ready.insert(slot)
            } else {
                slotsLog.error("Slot for \(slot.uuidString) not written")
            }
        }
        for slot in running {
            slotDirectoryServing[slots.directory(for: slot).path] = pooled.contains(slot) ? slot : fallback
        }
        for path in slotDirectoryServing.keys where slots.account(forDirectory: path) != nil && !inUse.contains(path) {
            slotDirectoryServing[path] = nil
        }
        let keep = ready.union(running)
        let stale = slots.slotDirectories().filter { directory in
            UUID(uuidString: directory.lastPathComponent).map { !keep.contains($0) } ?? false
        }
        if !stale.isEmpty {
            await Task.detached(priority: .utility) { stale.forEach(slots.remove) }.value
        }
        return ready.intersection(newSessions)
    }
}
