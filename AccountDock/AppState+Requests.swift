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
        /// one running session to another account and pins it there unless
        /// balancing would place it there itself (`AppState.moveSession`);
        /// `rebalance` plans, and
        /// with `apply` makes, the moves that let a provider's slot sessions
        /// last longest (`AppState.applyRebalance`); `pin` pins one running
        /// slot session to the account its slot serves (`SessionPins`), and
        /// `unpin` frees it; `audit` returns credential audit entries
        /// (`CredentialAudit.entries`), and `signalSessions` tells the
        /// sessions the audit flagged, of `provider` when given, to read
        /// their sign-in again (`signalFlaggedProcesses`).
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
        /// For `rebalance`: the provider (its raw value or display name)
        /// whose slot sessions are rebalanced.
        var provider: String?
        /// For `rebalance`: make the moves; false or absent returns the
        /// plan only (`AppState.rebalancePreview`).
        var apply: Bool?
        /// For `audit`: entries observed or written at or after this ISO
        /// 8601 time; all when absent. With `account` (an ID, label or
        /// email), only entries attributed to it or naming it as owner.
        var since: String?
        /// For `audit`: the newest this many entries; 1,000 when absent.
        var limit: Int?
    }

    struct ExternalOutcome: Codable {
        var ok: Bool
        var detail: String
        var account: String?
        var handledAt: Date
        /// For `rebalance`: one line per move, session from → to.
        var moves: [String]?
        /// For `audit`: the matching credential audit entries, oldest first.
        var entries: [CredentialAuditEntry]?
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
            // The same move the Sessions page's move menu makes.
            guard let sessionID = request.session, liveSession(sessionID) != nil else {
                return outcome(false, "No running session has that ID.")
            }
            if let model = request.model { noteSessionModel(sessionID, model: model, at: now) }
            let moved = await moveSession(sessionID, to: named(request.account), now: now)
            return outcome(moved.ok, moved.detail, moved.account)
        case "pin", "unpin":
            guard let sessionID = request.session, liveSession(sessionID) != nil || sessionPins.isPinned(sessionID) else {
                return outcome(false, "No running session has that ID.")
            }
            let result = request.action == "pin" ? pinSession(sessionID, now: now) : unpinSession(sessionID)
            let answer = Self.pinRequestOutcome(result) { id in accounts.first { $0.id == id }.map { messageName($0) } ?? "its account" }
            let account: Account? = switch result {
            case .pinned(let id), .alreadyPinned(let id), .unpinned(let id): accounts.first { $0.id == id }
            case .notInSlot, .notPinned: nil
            }
            return outcome(answer.ok, answer.detail, account)
        case "rebalance":
            guard let provider = AIProviderType.implementedProviders.first(where: { provider in
                request.provider.map {
                    $0.caseInsensitiveCompare(provider.rawValue) == .orderedSame
                        || $0.caseInsensitiveCompare(provider.capabilities.displayName) == .orderedSame
                } ?? rebalanceAvailable(provider)
            }), rebalanceAvailable(provider) else {
                return outcome(false, "That provider's sessions do not run in slots of their own, so they cannot be rebalanced.")
            }
            let preview = request.apply == true ? await applyRebalance(provider, now: now) : rebalancePreview(provider, now: now)
            var result = outcome(true, (request.apply == true ? "" : "Not applied. ") + preview.outcome)
            result.moves = preview.lines
            return result
        case "audit":
            let since: Date?
            if let text = request.since {
                guard let parsed = CredentialAudit.date(text) else {
                    return outcome(false, "`since` is not an ISO 8601 time.")
                }
                since = parsed
            } else {
                since = nil
            }
            let entries = credentialAudit.entries(since: since, account: request.account, limit: request.limit ?? 1_000)
            var result = outcome(true, "\(entries.count) credential audit entr\(entries.count == 1 ? "y" : "ies").",
                                 named(request.account))
            result.entries = entries
            return result
        case "signalSessions":
            let provider = request.provider.flatMap { text in
                AIProviderType.implementedProviders.first {
                    $0.rawValue.caseInsensitiveCompare(text) == .orderedSame
                        || $0.capabilities.displayName.caseInsensitiveCompare(text) == .orderedSame
                }
            }
            return outcome(true, signalFlaggedProcesses(provider))
        default:
            return outcome(false, "Unknown action \(request.action).")
        }
    }
}
