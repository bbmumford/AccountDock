import Foundation

private let requestLog = FileLog("Requests")

/// Requests another program leaves for AccountDock as JSON files in
/// `requestDirectory`, so a script or agent watching sessions can ask for
/// fresh readings or for one session to be moved without driving the menu.
/// `runQuotaCycle` handles them once per cycle and writes each outcome
/// under `Done` in the same directory, by the request's file name.
extension AppState {
    struct ExternalRequest: Codable {
        /// `refresh` reads usage from the provider now; `moveSession` moves
        /// one running session to another account.
        var action: String
        var session: String?
        /// An account's ID, label or email. For `refresh`, the account to
        /// read (the active accounts when absent); for `moveSession`, the
        /// destination (the account with most room for the session's model
        /// when absent).
        var account: String?
        /// The model the session uses, when the requester knows it better
        /// than `sessionModel` does.
        var model: String?
    }

    struct ExternalOutcome: Codable {
        var ok: Bool
        var detail: String
        var account: String?
        var handledAt: Date
    }

    nonisolated static var requestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Requests", isDirectory: true)
    }

    func handleExternalRequests(now: Date = Date()) async {
        let fm = FileManager.default
        let directory = Self.requestDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let done = directory.appendingPathComponent("Done", isDirectory: true)
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let outcome: ExternalOutcome
            if let request = try? JSONDecoder().decode(ExternalRequest.self, from: data) {
                outcome = await handle(request, now: now)
            } else {
                outcome = ExternalOutcome(ok: false, detail: "The request could not be read.", account: nil, handledAt: now)
            }
            requestLog.info("\(name): \(outcome.ok ? "done" : "not done") — \(outcome.detail)")
            try? fm.createDirectory(at: done, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(outcome).write(to: done.appendingPathComponent(name), options: .atomic)
            try? fm.removeItem(at: url)
        }
    }

    private func handle(_ request: ExternalRequest, now: Date) async -> ExternalOutcome {
        func outcome(_ ok: Bool, _ detail: String, _ account: Account? = nil) -> ExternalOutcome {
            ExternalOutcome(ok: ok, detail: detail, account: account.map { messageName($0) }, handledAt: now)
        }
        func named(_ text: String?) -> Account? {
            guard let text, !text.isEmpty else { return nil }
            return accounts.first {
                $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame
                    || $0.email.caseInsensitiveCompare(text) == .orderedSame
                    || $0.customLabel?.caseInsensitiveCompare(text) == .orderedSame
            }
        }
        switch request.action {
        case "refresh":
            if let account = named(request.account) {
                return outcome(await readUsageNow(account), "Usage read for \(messageName(account)).", account)
            }
            await readActiveUsageNow()
            return outcome(true, "Usage read for the active accounts.")
        case "moveSession":
            guard let sessionID = request.session,
                  let provider = AIProviderType.implementedProviders.first(where: { provider in
                      liveSessions[provider]?.contains { $0.sessionID == sessionID } == true
                  }),
                  let session = liveSessions[provider]?.first(where: { $0.sessionID == sessionID }) else {
                return outcome(false, "No running session has that ID.")
            }
            if let model = request.model { noteSessionModel(sessionID, model: model, at: now) }
            let model = sessionModel(sessionID, now: now)
            let policy = failoverConfig.policy(for: provider)
            let planner = FailoverPlanner(settings: plannerSettings(provider))
            let slot = session.processID.flatMap { slotDirectoryByProcess[$0] }
            let current = sessionAttribution(provider, now: now).decide(session: sessionID, process: session.processID)?.account
            // The limit the session met is learned before anything is chosen.
            if let current, let account = accounts.first(where: { $0.id == current }) { await readUsageNow(account) }
            func hasRoom(_ account: Account) -> Bool {
                !accountCannotServe(account.id, provider: provider, planner: planner, now: now, model: model)
            }
            let wanted = named(request.account)
            // A session on the shared sign-in keeps the token it holds until
            // it is told to read the sign-in again, so it can still be on an
            // account that was active earlier. When the active account has
            // room for its model, reading the sign-in again is the whole move.
            if slot == nil, let active = activeAccount(for: provider), wanted == nil || wanted?.id == active.id,
               credentialModule(for: provider)?.liveCredential != nil, hasRoom(active) {
                moveRunningSessions(provider)
                return outcome(true, "Sessions on the shared sign-in were told to read it again; \(messageName(active)) is the active account and has allowance left.", active)
            }
            let target = wanted ?? accounts
                .filter { $0.provider == provider && $0.id != current && !needsSignIn($0) && !policy.excludedAccountIDs.contains($0.id) && hasRoom($0) }
                .min { (plannedUsage($0, now: now, model: model)?.sevenDay?.utilization ?? 100) < (plannedUsage($1, now: now, model: model)?.sevenDay?.utilization ?? 100) }
            let modelName = model.map { CostParser.shortModelName($0) } ?? "its model"
            guard let target else { return outcome(false, "No other account has allowance left for \(modelName).") }
            guard target.id != current else { return outcome(false, "The session is already on \(messageName(target)).", target) }
            if let slot, let root = SessionSlots(provider)?.sessionRoot.path, slot.hasPrefix(root + "/") {
                requestedSlotMoves[sessionID] = target.id
                await maintainSessionSlots(now: now)
                let moved = slotDirectoryServing[slot] == target.id
                return outcome(moved, moved ? "Moved to \(messageName(target)); the session uses it from its next request."
                                            : "The session's slot could not be written for \(messageName(target)).", target)
            }
            // The session reads a credential it shares with others, which
            // only moves by making the destination the active account.
            guard provider.capabilities.switchReachesRunningSessions
                    || credentialModule(for: provider)?.liveCredential != nil else {
                return outcome(false, "The session's sign-in cannot be changed while it runs.")
            }
            if policy.activeAccountLocked { return outcome(false, "The active account is locked, and the session shares its sign-in.") }
            let previous = activeAccount(for: provider)?.id
            await switchTo(target, refreshAfter: false)
            let switched = activeAccount(for: provider)?.id == target.id
            if switched { moveRunningSessions(provider, from: previous) }
            return outcome(switched, switched ? "Switched the active account to \(messageName(target)); every session on the shared sign-in moves with it."
                                              : "The switch to \(messageName(target)) did not complete.", target)
        default:
            return outcome(false, "Unknown action \(request.action).")
        }
    }
}
