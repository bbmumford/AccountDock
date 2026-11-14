import AppKit

/// AppState's part in the credential audit (`CredentialAudit`): the accounts
/// it attributes entries to, the events its mismatches raise, the account
/// each session and agent is seen served by, what running processes' own
/// evidence says about the token they hold, and the `audit` request and the
/// Settings section that read the trail.
extension AppState {
    var credentialAudit: CredentialAudit { .shared }

    /// A process whose own evidence names another account's token than the
    /// one AccountDock believes it reads; `signalFlaggedProcesses` tells it
    /// to read its sign-in again.
    struct FlaggedCredentialProcess: Equatable {
        var provider: AIProviderType
        var session: String
        var process: Int32?
        /// The slot directory it reads; nil for the shared sign-in.
        var slot: String?
        var observed: UUID
        var believed: UUID?
        var at: Date
    }

    // MARK: - Accounts and events

    /// Hands the audit the accounts entries are attributed to and owners
    /// matched against. Called from `init` and whenever `accounts` changes.
    func syncCredentialAuditAccounts() {
        credentialAudit.updateAccounts(accounts.map {
            CredentialAudit.Account(id: $0.id, provider: $0.provider, label: $0.effectiveDisplayName(obfuscated: true),
                                    email: $0.email, isActive: $0.isActive, location: $0.credentialLocation)
        })
    }

    /// Records every change of a provider's active account, whatever path
    /// made it, as a `switch`. Called by `accounts`' observer.
    func credentialAuditAccountsChanged(from old: [Account]) {
        syncCredentialAuditAccounts()
        for provider in AIProviderType.allCases {
            let before = old.active(for: provider)?.id
            guard let after = accounts.active(for: provider)?.id, before != after else { continue }
            credentialAudit.record(.switch, provider, account: after, outcome: "activeChanged", reason: "accounts.active",
                                   detail: before.map { "from \($0.uuidString)" })
        }
    }

    /// Records each new mismatch as an event the user sees. Not installed
    /// while tests run, so no test writes the real event log.
    func installCredentialAuditEvents() {
        guard !CredentialAudit.isTesting else { return }
        credentialAudit.onMismatch { provider, message in
            Task { @MainActor in FailoverEventLog.shared.record(provider, message) }
        }
    }

    // MARK: - Serving records

    /// Records the account `decision` names for a running session, once per
    /// change of account. Called by `refreshSessions` for every session.
    func recordServed(_ provider: AIProviderType, session: AgentSession, decision: SessionAttribution.Decision,
                      now: Date) {
        credentialAudit.recordServed(provider, session: session.sessionID, account: decision.account,
                                     source: String(describing: decision.source),
                                     model: sessionModel(session.sessionID, now: now), process: session.processID,
                                     observedAt: decision.observedAt)
    }

    /// Records one transcript request of a session or one of its agents
    /// (`CredentialAudit.noteRequest`): its serving account when that
    /// changed, and a cache rebuilt whole as a change of account, which a
    /// session's own request also notes in `sessionCacheRebuiltAt`.
    func recordTranscriptRequest(_ provider: AIProviderType, _ request: TranscriptRequest,
                                 decision: SessionAttribution.Decision?) {
        guard request.limitRefusal == nil else { return }
        let rebuilt = credentialAudit.noteRequest(
            provider, session: request.session, agent: request.agent, account: decision?.account,
            source: decision.map { String(describing: $0.source) },
            sample: CredentialAudit.CacheSample(at: request.at, contextTokens: request.contextTokens,
                                                cacheReadTokens: request.cacheReadTokens,
                                                cacheWriteTokens: request.cacheWriteTokens,
                                                model: request.model ?? request.agentModel),
            cacheLifetime: request.cacheLifetime
        )
        if rebuilt, request.agent == nil { sessionCacheRebuiltAt[request.session] = request.at }
    }

    // MARK: - Process evidence

    /// The account AccountDock believes a process reads: its slot's, else
    /// the live credential's owner, else the active account; and which.
    func believedCredentialAccount(_ provider: AIProviderType, process: Int32?) -> (account: UUID?, source: String) {
        if let process, let directory = slotDirectoryByProcess[process], let id = slotDirectoryServing[directory] {
            return (id, "slot")
        }
        if let owner = liveCredentialOwner(provider) { return (owner, "liveCredential") }
        return (activeAccount(for: provider)?.id, "activeAccount")
    }

    /// Records what a process's own evidence (`source`) says about the
    /// token it holds, and flags the process when that is not the account
    /// AccountDock believes it reads. A process on the shared sign-in that
    /// holds an account switched away from is still flagged; the entry says
    /// so, since signalling moves it.
    func noteProcessCredential(_ provider: AIProviderType, session: String, process: Int32?, observed: UUID,
                               source: String, observedAt: Date?) {
        let believed = believedCredentialAccount(provider, process: process)
        var detail: String?
        if believed.account != observed, believed.source != "slot", let away = lastSwitchedAway[observed] {
            detail = "AccountDock switched away from that account at \(away.formatted(.iso8601)); "
                + "a session not signalled since keeps the token it read before."
        }
        if credentialAudit.recordProcessCredential(provider, session: session, process: process, observed: observed,
                                                   believed: believed.account, source: source,
                                                   believedSource: believed.source, observedAt: observedAt,
                                                   detail: detail) != nil {
            flaggedCredentialProcesses[session] = FlaggedCredentialProcess(
                provider: provider, session: session, process: process,
                slot: believed.source == "slot" ? process.flatMap { slotDirectoryByProcess[$0] } : nil,
                observed: observed, believed: believed.account, at: Date()
            )
        } else if believed.account == observed {
            flaggedCredentialProcesses[session] = nil
        }
    }

    /// Tells every flagged process to read its sign-in again: sessions on
    /// the shared sign-in through `moveRunningSessions`, and slot sessions
    /// by having their slot written afresh at the next slot pass. Returns
    /// what was done, for the request and the Settings button.
    @discardableResult
    func signalFlaggedProcesses(_ only: AIProviderType? = nil) -> String {
        let flagged = flaggedCredentialProcesses.values.filter { only == nil || $0.provider == only }
        guard !flagged.isEmpty else { return "No session is flagged." }
        for provider in Set(flagged.filter { $0.slot == nil }.map(\.provider)) {
            moveRunningSessions(provider, reason: "audit.signalFlagged")
        }
        for slot in flagged.compactMap(\.slot) { slotCredentialWritten[slot] = nil }
        for item in flagged { flaggedCredentialProcesses[item.session] = nil }
        return "Told \(flagged.count) flagged session(s) to read their sign-in again."
    }

    /// When a refusal's words name the reset of the limit it met
    /// ("resets 2am", "resets 2:30pm (Australia/Melbourne)", and a weekly
    /// limit's "resets Nov 20 at 12pm"), that reset as a date: the first
    /// such time, on the named day when there is one, at or after the
    /// refusal, in the named time zone or else `calendar`'s.
    nonisolated static func refusalResetDate(_ words: String, at: Date, calendar: Calendar = .current) -> Date? {
        let pattern = #"resets\s+(?:([a-z]{3,9})\.?\s+(\d{1,2}),?\s+)?(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
              let hourRange = Range(match.range(at: 3), in: words), var hour = Int(words[hourRange]),
              let meridiemRange = Range(match.range(at: 5), in: words), (1...12).contains(hour) else { return nil }
        let minute = Range(match.range(at: 4), in: words).flatMap { Int(words[$0]) } ?? 0
        if words[meridiemRange].lowercased() == "pm" { hour = hour % 12 + 12 } else { hour %= 12 }
        var calendar = calendar
        if let zoneRange = Range(match.range(at: 6), in: words),
           let zone = TimeZone(identifier: words[zoneRange].trimmingCharacters(in: .whitespaces)) {
            calendar.timeZone = zone
        }
        var components = DateComponents(hour: hour, minute: minute)
        if let monthRange = Range(match.range(at: 1), in: words) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: String(words[monthRange].prefix(3)).lowercased()),
                  let dayRange = Range(match.range(at: 2), in: words), let day = Int(words[dayRange]) else { return nil }
            components.month = month + 1
            components.day = day
        }
        return calendar.nextDate(after: at.addingTimeInterval(-60), matching: components, matchingPolicy: .nextTime)
    }

    /// The one account whose five-hour or weekly window resets within ten
    /// minutes of `reset`; nil when none or several do.
    nonisolated static func account(resettingAt reset: Date, among windows: [(id: UUID, resets: [Date])]) -> UUID? {
        let matching = windows.filter { $0.resets.contains { abs($0.timeIntervalSince(reset)) < 10 * 60 } }
        return matching.count == 1 ? matching[0].id : nil
    }

    /// The provider's accounts with the resets of their five-hour and weekly
    /// windows, from their last readings.
    func resetWindows(_ provider: AIProviderType) -> [(id: UUID, resets: [Date])] {
        accounts.filter { $0.provider == provider }.map { account in
            (id: account.id, resets: [accountUsage[account.id]?.fiveHour?.resetsAtDate,
                                      accountUsage[account.id]?.sevenDay?.resetsAtDate].compactMap { $0 })
        }
    }

    /// The account a refusal's reset time names among the provider's
    /// accounts, from their last readings.
    func account(namedByRefusal words: String, at: Date, provider: AIProviderType) -> UUID? {
        guard let reset = Self.refusalResetDate(words, at: at) else { return nil }
        return Self.account(resettingAt: reset, among: resetWindows(provider))
    }

    /// The account that refused a request: `attributed`, unless the reset
    /// the refusal states matches none of its windows and exactly one other
    /// account's, which is then the account whose token the request
    /// carried (`byReset`).
    nonisolated static func refusingAccount(words: String, at: Date, attributed: UUID,
                                            windows: [(id: UUID, resets: [Date])],
                                            calendar: Calendar = .current) -> (account: UUID, byReset: Bool) {
        guard let reset = refusalResetDate(words, at: at, calendar: calendar),
              let named = account(resettingAt: reset, among: windows), named != attributed else { return (attributed, false) }
        let attributedMatches = windows.first { $0.id == attributed }?.resets
            .contains { abs($0.timeIntervalSince(reset)) < 10 * 60 } ?? false
        return attributedMatches ? (attributed, false) : (named, true)
    }

    // MARK: - Reading the trail

    /// Opens the audit file in Console, or reveals it in Finder when there
    /// is no file yet or Console cannot open it.
    func openCredentialAudit() {
        let url = credentialAudit.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            return
        }
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealCredentialAudit() {
        NSWorkspace.shared.activateFileViewerSelecting([credentialAudit.fileURL])
    }
}
