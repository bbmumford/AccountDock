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
    func maintainSessionSlots(now: Date = Date()) async {
        guard let provider = AIProviderType.routedProvider, let slots = SessionSlots(provider) else { return }
        let byProcess = await Task.detached(priority: .utility) { slots.directoriesByProcess() }.value
        slotDirectoryByProcess = byProcess
        let inUse = Set(byProcess.values)
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
        let members = await buildPool(provider, now: now, forRouter: false)
        routerPoolMembers = members
        let open = Set(members.filter { $0.weight > 0 }.compactMap { UUID(uuidString: $0.accountID) })
        let served = await serveRunning(slots, provider: provider, members: members, inUse: inUse, newSessions: open)
        let resumes = resumeTargets(provider, now: now)
        let spares = await serveSessionSlots(slots, provider: provider, members: members, inUse: inUse,
                                             resumeAccounts: Set(resumes.values), now: now)
        let activeForResume = accounts.first { $0.provider == provider && $0.isActive }?.id
        let resumeEntries = resumes.compactMap { session, account -> (session: String, path: String)? in
            if account == activeForResume { return (session, SessionSlots.activeEntry) }
            return spares.contains(account) ? (session, slots.directory(for: account).path) : nil
        }.sorted { $0.session < $1.session }
        await Task.detached(priority: .utility) { slots.writeResumes(resumeEntries) }.value
        slotServedAccounts = Set(slotDirectoryServing.values)
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
    func accountCannotServe(_ id: UUID, provider: AIProviderType, planner: FailoverPlanner, now: Date) -> Bool {
        guard let account = accounts.first(where: { $0.id == id && $0.provider == provider }) else { return true }
        let tier = planner.tier(quotaState(for: account, now: now), now: now)
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
    static let sparesPerAccount = 2
    /// A claimed one-session slot that no process reads this long after its
    /// claim has lost its session.
    static let slotClaimGrace: TimeInterval = 2 * 60
    /// A session moved to balance load stays where it went at least this
    /// long, so it is not moved back before its new cache has paid off.
    static let balanceMoveInterval: TimeInterval = 30 * 60

    /// Keeps the one-session slots: each claimed slot serves its account, or
    /// the pool's highest-weight account once its own leaves the pool, and
    /// moves to the account `SessionPacer` chose for its session between
    /// two of the session's turns; a move rewrites the slot, which the CLI
    /// reads again before its next request. Spare slots are kept for each
    /// account in `members` with a positive weight other than the active
    /// one, and the rest removed: a slot holds a copy of the access token
    /// only, which nothing renews for the active account, whose sessions
    /// renew the default credential instead. Moves therefore go between
    /// the other accounts. `resumeAccounts` keep spares too, for sessions
    /// resumed on them. Returns the accounts that have a spare slot.
    @discardableResult
    private func serveSessionSlots(_ slots: SessionSlots, provider: AIProviderType, members: [RouterPoolMember],
                                   inUse: Set<String>, resumeAccounts: Set<UUID> = [], now: Date) async -> Set<UUID> {
        let activeID = accounts.first { $0.provider == provider && $0.isActive }?.id
        let pooled = Set(members.compactMap { UUID(uuidString: $0.accountID) })
        let open = Set(members.filter { $0.weight > 0 }.compactMap { UUID(uuidString: $0.accountID) })
            .union(resumeAccounts)
            .subtracting([activeID].compactMap { $0 })
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let fallback = members.max { lhs, rhs in
            lhs.weight != rhs.weight ? lhs.weight < rhs.weight : rhs.accountID == activeID?.uuidString
        }.flatMap { UUID(uuidString: $0.accountID) } ?? activeID
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
        for slot in await Task.detached(priority: .utility, operation: { slots.sessionSlots() }).value {
            let path = slot.directory.path
            guard let claimedAt = slot.claimedAt else {
                guard let id = slot.account, open.contains(id), sparesOf[id, default: 0] < Self.sparesPerAccount,
                      await serve(slot.directory, id) else {
                    remove.append(slot.directory)
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
                if now.timeIntervalSince(claimedAt) > Self.slotClaimGrace { remove.append(slot.directory) }
                else if let id = slot.account { slotDirectoryServing[path] = id }
                continue
            }
            var target = slot.account.flatMap {
                accountCannotServe($0, provider: provider, planner: planner, now: now) ? nil : $0
            } ?? fallback
            let session = sessionsByDirectory[path]
            var balanced = false
            if let session, let destination = slotSessionMoves[session.sessionID], destination != target,
               pooled.contains(destination), destination != activeID, !session.isWorking,
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
            failoverEvents.record(provider, balanced
                ? "Moved the session\(place) from \(from) to \(to) to balance load; it rebuilds its prompt cache there at its next request."
                : "Moved the session\(place) from \(from) to \(to): \(from) can no longer serve it.")
        }
        for id in open where sparesOf[id, default: 0] < Self.sparesPerAccount {
            guard let value = await credential(id) else { continue }
            let missing = Self.sparesPerAccount - sparesOf[id, default: 0]
            let made = await Task.detached(priority: .utility) {
                (0..<missing).filter { _ in slots.makeSpare(for: id, credential: value) }.count
            }.value
            sparesOf[id, default: 0] += made
        }
        if !remove.isEmpty {
            for directory in remove {
                slotDirectoryServing[directory.path] = nil
                slotDirectoryMovedAt[directory.path] = nil
            }
            await Task.detached(priority: .utility) { remove.forEach(slots.remove) }.value
        }
        return Set(sparesOf.filter { $0.value > 0 }.keys)
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
