#if DEBUG
import AppKit
import SwiftUI

/// The Sessions page's sections the screenshot renderer shows in place of
/// the live ones (`SessionsView`), which would be read from the pause files
/// and session slots; nil in every other launch.
private struct SampleSessionsSectionsKey: EnvironmentKey {
    static let defaultValue: [SessionsSection]? = nil
}

extension EnvironmentValues {
    var sampleSessionsSections: [SessionsSection]? {
        get { self[SampleSessionsSectionsKey.self] }
        set { self[SampleSessionsSectionsKey.self] = newValue }
    }
}

/// Renders the README screenshots from sample accounts, so no real identity,
/// usage or cost appears in them. `Tools/render_screenshots.sh` launches a
/// copy of a Debug build under a separate bundle identifier with
/// `ACCOUNTDOCK_SCREENSHOT_DIR` set and a temporary home directory
/// (`CFFIXED_USER_HOME`). The separate identifier gives the copy its own
/// preferences, because the settings views write the failover order and
/// other preferences as they appear; the temporary home keeps the installed
/// app's pause files, session slots, logs and the CLIs' settings out of the
/// images and out of reach of anything the samples write.
@MainActor
enum ScreenshotRenderer {
    static let productionBundleIdentifier = "app.accountdock.mac"

    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ACCOUNTDOCK_SCREENSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Whether this process's home directory is another than the user
    /// account's own, and not a parent of it: the render script's temporary
    /// home, which every home-relative path the app reads or writes then
    /// resolves into.
    static var homeIsSandboxed: Bool {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return false }
        let account = URL(fileURLWithPath: String(cString: directory)).resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        return home != "/" && !(account + "/").hasPrefix(home + "/")
    }

    /// Writes every screenshot and exits without running termination
    /// handlers, which would continue CLI processes the installed app paused.
    static func run(appState: AppState, config: MenuBarConfig, into directory: URL) async {
        guard Bundle.main.bundleIdentifier != productionBundleIdentifier else {
            FileHandle.standardError.write(Data("Refusing to render under the production bundle identifier\n".utf8))
            exit(2)
        }
        guard homeIsSandboxed else {
            FileHandle.standardError.write(Data("Refusing to render with the user's own home directory; run Tools/render_screenshots.sh\n".utf8))
            exit(2)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        defaults.set(440.0, forKey: "menuPanelWidth")
        defaults.set(false, forKey: "showFullEmail")
        appState.loadScreenshotSamples()
        config.modules = [.claudePercentages, .claudeSessionReset, .codexPercentages, .kimiPercentages, .dailyCost]
        FailoverConfigStore.shared.update(.claudeCode) { policy in
            policy.enabled = true
            policy.intelligentBalancingEnabled = true
            policy.suspendAgentsWhenExhausted = true
            policy.distributeSessions = true
            policy.rebalanceAutomatically = true
        }
        FailoverConfigStore.shared.update(.codex) { policy in
            policy.enabled = true
            policy.suspendAgentsWhenExhausted = true
        }
        // Claude Code's slot launcher, written into the temporary home, so
        // the settings and the usage tab show the session-slot controls as
        // they are once AccountDock has installed it.
        try? SessionSlots(.claudeCode)?.installLauncher()

        let pages: [(String, AnyView, CGSize)] = [
            ("menu-usage", AnyView(MainMenuView(initialTab: .usage, maximumHeight: 1600)), CGSize(width: 440, height: 0)),
            ("menu-costs", AnyView(MainMenuView(initialTab: .costs, maximumHeight: 1600)), CGSize(width: 440, height: 0)),
            ("menu-accounts", AnyView(MainMenuView(initialTab: .accounts, maximumHeight: 1600)), CGSize(width: 440, height: 0)),
            ("menu-bar", AnyView(
                MenuBarStripView(appState: appState, config: config, onWidth: { _ in })
                    .frame(height: 24)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            ), CGSize(width: 0, height: 32)),
        ]
        var failed = false
        for (name, view, size) in pages {
            let url = directory.appendingPathComponent("\(name).png")
            if await !write(view.environmentObject(appState).environmentObject(config).environmentObject(UpdateChecker.shared), size: size, to: url) {
                FileHandle.standardError.write(Data("Could not render \(name)\n".utf8))
                failed = true
            }
        }
        // A grouped form fills the height it is given, so it is laid out
        // taller than its content and the empty rows below are cut off.
        let settings = FailoverSettingsView(providers: [.claudeCode]).frame(width: 660, height: 2600)
        if await !write(settings.environmentObject(appState).environmentObject(config).environmentObject(UpdateChecker.shared),
                        size: CGSize(width: 660, height: 2600), trimBottom: true,
                        to: directory.appendingPathComponent("settings-failover.png")) {
            FileHandle.standardError.write(Data("Could not render settings-failover\n".utf8))
            failed = true
        }

        appState.loadScreenshotSamples(failoverStates: true)
        let banners = VStack(spacing: 10) {
            if let routed = appState.routedStatus[.claudeCode] {
                RoutedRequestsBanner(provider: .claudeCode, status: routed)
            }
            if let pause = appState.agentPauseStatus[.codex] {
                AgentPauseBanner(provider: .codex, status: pause)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 440)
        if await !write(banners.environmentObject(appState).environmentObject(config).environmentObject(UpdateChecker.shared), size: CGSize(width: 440, height: 0),
                  to: directory.appendingPathComponent("failover-banners.png")) {
            FileHandle.standardError.write(Data("Could not render failover-banners\n".utf8))
            failed = true
        }

        // Last, since it lists a session on the shared sign-in as
        // unisolated, which the usage tab would show too.
        appState.loadScreenshotSamples()
        let sessions = MainMenuView(initialTab: .sessions, maximumHeight: 1600)
            .environment(\.sampleSessionsSections, appState.screenshotSessionSections())
        if await !write(sessions.environmentObject(appState).environmentObject(config).environmentObject(UpdateChecker.shared),
                        size: CGSize(width: 440, height: 0), to: directory.appendingPathComponent("menu-sessions.png")) {
            FileHandle.standardError.write(Data("Could not render menu-sessions\n".utf8))
            failed = true
        }
        exit(failed ? 1 : 0)
    }

    /// Lays the view out in an off-screen window and captures it at the
    /// screen's scale. A zero width or height takes the view's own size.
    /// With `trimBottom`, the rows below the content are cut off
    /// (`trimmedBottom`).
    private static func write<V: View>(_ view: V, size: CGSize, trimBottom: Bool = false, to url: URL) async -> Bool {
        // Drawn as in the window the user has in front: the capture window
        // is never key, which would otherwise grey out prominent buttons.
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .environment(\.appearsActive, true))
        host.appearance = NSAppearance(named: .darkAqua)
        let fitting = host.fittingSize
        let frame = CGRect(
            x: 0, y: 0,
            width: size.width > 0 ? size.width : fitting.width,
            height: size.height > 0 ? size.height : fitting.height
        )
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = frame
        // Ordered in but fully transparent: appearance callbacks and the
        // measured popover height only arrive for a window on screen.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // A measured height changes the view's own size, so a free dimension
        // is re-fitted until it stops changing.
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 150_000_000)
            let fitted = host.fittingSize
            let next = CGRect(
                x: 0, y: 0,
                width: size.width > 0 ? size.width : fitted.width,
                height: size.height > 0 ? size.height : fitted.height
            )
            if next.size != host.frame.size {
                window.setContentSize(next.size)
                host.frame = next
            }
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = trimBottom ? trimmedBottom(rep) : rep
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// `rep` without the rows at its bottom that are all the colour of its
    /// bottom-left pixel, keeping `margin` of them below the content. Only
    /// an 8-bit, interleaved bitmap, as `cacheDisplay` makes, is trimmed;
    /// any other is returned whole.
    private static func trimmedBottom(_ rep: NSBitmapImageRep, margin: Int = 16) -> NSBitmapImageRep {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, !rep.isPlanar, rep.pixelsHigh > 1 else { return rep }
        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = rep.bitsPerPixel / 8
        let width = rep.pixelsWide
        let reference = (0..<bytesPerPixel).map { data[(rep.pixelsHigh - 1) * bytesPerRow + $0] }
        func isBackground(_ row: Int) -> Bool {
            let start = row * bytesPerRow
            for x in 0..<width {
                for byte in 0..<bytesPerPixel where abs(Int(data[start + x * bytesPerPixel + byte]) - Int(reference[byte])) > 2 {
                    return false
                }
            }
            return true
        }
        var contentRows = rep.pixelsHigh
        while contentRows > 1, isBackground(contentRows - 1) { contentRows -= 1 }
        let height = min(rep.pixelsHigh, contentRows + margin)
        guard height < rep.pixelsHigh,
              let cropped = rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else { return rep }
        return NSBitmapImageRep(cgImage: cropped)
    }
}

extension AppState {
    /// Sample accounts, usage and costs for the screenshots. Nothing here is
    /// saved: account and usage persistence only happen through
    /// `saveAccounts` and `recordUsage`, which this does not call.
    func loadScreenshotSamples(failoverStates: Bool = false) {
        let now = Date()
        func iso(_ offset: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: now.addingTimeInterval(offset))
        }
        func usage(_ session: Double?, _ sessionReset: TimeInterval, _ weekly: Double, _ weeklyReset: TimeInterval,
                   weeklySeconds: Int? = nil) -> UsageAPIResponse {
            UsageAPIResponse(
                fiveHour: session.map { UsageWindow(utilization: $0, resetsAt: iso(sessionReset), windowSeconds: 5 * 3600) },
                sevenDay: UsageWindow(utilization: weekly, resetsAt: iso(weeklyReset), windowSeconds: weeklySeconds),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
                iguanaNecktie: nil, extraUsage: nil
            )
        }
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        let claudePersonal = Account(email: "alex@example.com", displayName: "Alex Rivera", provider: .claudeCode,
                                     subscriptionType: "max", isActive: true, lastUsed: now, customLabel: "Personal")
        let claudeWork = Account(email: "alex.rivera@northwind.example", displayName: "Alex Rivera", provider: .claudeCode,
                                 orgName: "Northwind", subscriptionType: "max", lastUsed: now.addingTimeInterval(-3 * hour),
                                 customLabel: "Northwind")
        let claudeLab = Account(email: "lab@example.com", displayName: "Research Lab", provider: .claudeCode,
                                subscriptionType: "pro", lastUsed: now.addingTimeInterval(-2 * day), customLabel: "Lab")
        let codex = Account(email: "alex@example.com", displayName: "Alex Rivera", provider: .codex,
                            subscriptionType: "pro", isActive: true, lastUsed: now, customLabel: "Personal",
                            credentialLocation: "codex-personal")
        let codexTeam = Account(email: "builds@northwind.example", displayName: "Northwind Builds", provider: .codex,
                                subscriptionType: "plus", lastUsed: now.addingTimeInterval(-day), customLabel: "Builds",
                                credentialLocation: "codex-builds")
        let kimi = Account(email: "alex@example.com", displayName: "Alex Rivera", provider: .kimi,
                           subscriptionType: "Moderato", isActive: true, lastUsed: now, customLabel: "Kimi Coding",
                           credentialLocation: "kimi-coding")
        func resets(_ grants: [(kind: [LimitResets.RefilledLimit], left: Int, days: Double)]) -> LimitResets {
            LimitResets(grants: grants.enumerated().map { index, grant in
                LimitResets.Grant(id: "sample-\(index)", label: "Sample reset", resetsTotal: grant.left,
                                  resetsLeft: grant.left, endsAt: iso(grant.days * day), refills: grant.kind)
            })
        }
        accounts = [claudePersonal, claudeWork, claudeLab, codex, codexTeam, kimi]
        var personalUsage = usage(64, 2.2 * hour, 41, 3.5 * day)
        personalUsage.limitResets = resets([([.weekly, .model("Fable")], 1, 29), ([.model("Fable")], 1, 118)])
        var workUsage = usage(8, 4.6 * hour, 72, 1.2 * day)
        workUsage.limitResets = resets([([.model("Fable")], 2, 118)])
        var codexUsage = usage(37, 3.1 * hour, 55, 2.4 * day)
        codexUsage.limitResets = resets([([.all], 1, 20)])
        // Lab's small plan has filled its session window, which the
        // Sessions page's sample shows its sessions waiting for.
        accountUsage = [
            claudePersonal.id: personalUsage,
            claudeWork.id: workUsage,
            claudeLab.id: usage(100, Self.sampleLabResetMinutes * 60, 31, 5.8 * day),
            codex.id: codexUsage,
            codexTeam.id: usage(nil, 0, 12, 6.1 * day),
            kimi.id: usage(22, 1.4 * hour, 30, 19 * day, weeklySeconds: 30 * 24 * 3600),
        ]
        accountUsageErrors = [:]
        claudeAvailable = true
        codexAvailable = true
        kimiAvailable = true
        isLoading = false
        errorMessage = nil
        lastUsageRefresh = now.addingTimeInterval(-40)

        let formatter = DayKey.makeFormatter()
        // Thirty days of a weekday-heavy pattern, ending with today.
        let pattern: [Double] = [38.4, 52.1, 29.7, 61.3, 44.8, 12.6, 9.1]
        let claudeDays: [Double] = (0..<30).map { day -> Double in
            let scale = 0.8 + Double((day * 7) % 5) * 0.1
            return pattern[day % 7] * scale
        }
        let codexDays = claudeDays.map { ($0 * 0.27 * 10).rounded() / 10 }
        let kimiDays = claudeDays.map { ($0 * 0.06 * 10).rounded() / 10 }
        var claudeDaily: [DailyCost] = []
        var codexDaily: [String: Double] = [:]
        var kimiDaily: [String: Double] = [:]
        var codexTokens: [String: Int] = [:]
        var kimiTokens: [String: Int] = [:]
        for (index, cost) in claudeDays.enumerated() {
            let key = formatter.string(from: now.addingTimeInterval(-Double(claudeDays.count - 1 - index) * day))
            claudeDaily.append(DailyCost(
                date: key, totalCost: cost,
                modelBreakdown: ["claude-opus-4-8": cost * 0.71, "claude-sonnet-4-6": cost * 0.24, "claude-haiku-4-5": cost * 0.05],
                sessionCount: 6 + index, inputTokens: 180_000 * (index + 2), outputTokens: 95_000 * (index + 3),
                cacheWriteTokens: 1_400_000 * (index + 1), cacheReadTokens: 21_000_000 * (index + 2),
                modelTokens: ["claude-opus-4-8": 16_000_000 * (index + 2), "claude-sonnet-4-6": 5_500_000 * (index + 2),
                              "claude-haiku-4-5": 1_100_000 * (index + 2)]
            ))
            codexDaily[key] = codexDays[index]
            kimiDaily[key] = kimiDays[index]
            codexTokens[key] = Int(codexDays[index] * 310_000)
            kimiTokens[key] = Int(kimiDays[index] * 2_400_000)
        }
        costSummary = CostSummary(todayCost: claudeDays.last ?? 0, dailyCosts: claudeDaily)
        let codexToday = codexDays.last ?? 0
        let kimiToday = kimiDays.last ?? 0
        providerCosts = [
            .codex: CostParser.ProviderCostHistory(
                dailyCosts: codexDaily,
                todayModelActivity: ["gpt-5.5-codex": 214],
                todayModelCosts: ["gpt-5.5-codex": codexToday * 0.86, "gpt-5.5-mini": codexToday * 0.14],
                todayLinesChanged: 1_284,
                todayTokens: codexTokens.values.max() ?? 0,
                dailyTokens: codexTokens,
                todayModelTokens: ["gpt-5.5-codex": Int(codexToday * 270_000), "gpt-5.5-mini": Int(codexToday * 40_000)],
                todaySessions: 9
            ),
            .kimi: CostParser.ProviderCostHistory(
                dailyCosts: kimiDaily,
                todayModelActivity: ["k3": 88],
                todayModelCosts: ["k3": kimiToday],
                todayLinesChanged: 0,
                todayTokens: Int(kimiToday * 2_400_000),
                dailyTokens: kimiTokens,
                todayModelTokens: ["k3": Int(kimiToday * 2_400_000)],
                todaySessions: 3
            ),
        ]
        combinedTodayCost = (claudeDays.last ?? 0) + codexToday + kimiToday
        activityStats = ActivityStats(
            conversationTurns: 342, activeCodingMinutes: 287,
            toolUsage: ["Edit": 412, "Read": 655, "Bash": 298, "Grep": 141],
            linesWritten: 3_916,
            modelUsage: ["Opus": 271, "Sonnet": 64]
        )
        providerCosts[.claudeCode] = CostParser.ProviderCostHistory(
            claude: costSummary, activity: activityStats, today: formatter.string(from: now)
        )
        routedStatus = [:]
        agentPauseStatus = [:]
        routedSessions = [:]
        unisolatedSessions = [:]
        unisolatedTerminals = [:]
        // The account cards' session counts, by the sessions the Sessions
        // page's sample lists, one of them pinned.
        accountSessions = Dictionary(grouping: Self.sampleSessions, by: \.account)
            .reduce(into: [UUID: Set<String>]()) { result, entry in
                guard let account = accounts.first(where: { $0.provider == entry.key.provider && $0.customLabel == entry.key.label })
                else { return }
                result[account.id] = Set(entry.value.map(\.id))
            }
        sessionPins = SessionPins()
        for sample in Self.sampleSessions where sample.pinned {
            if let account = accounts.first(where: { $0.provider == sample.account.provider && $0.customLabel == sample.account.label }) {
                _ = sessionPins.pin(sample.id, slotAccount: account.id, provider: sample.account.provider, at: now)
            }
        }
        if failoverStates {
            routedStatus[.claudeCode] = RoutedStatus(
                since: now.addingTimeInterval(-18 * 60), target: "Kimi", model: "k3",
                backingAccount: "Kimi Coding", resumeAt: now.addingTimeInterval(52 * 60), turns: 23
            )
            agentPauseStatus[.codex] = AgentPauseStatus(
                sessions: 2, waiting: 1, stoppedProcesses: 0,
                since: now.addingTimeInterval(-6 * 60), resumeAt: now.addingTimeInterval(41 * 60),
                reason: "Every included Codex account has reached its limit."
            )
        }
    }

    /// The account a sample session runs on, by provider and label.
    struct ScreenshotAccount: Hashable {
        let provider: AIProviderType
        let label: String
    }

    /// One sample session of the Sessions page and the account cards.
    struct ScreenshotSession {
        let id: String
        let folder: String
        let model: String
        /// Its slot's account, or for one on the shared sign-in the active
        /// account it follows.
        let account: ScreenshotAccount
        let state: SessionRowState
        var pinned = false
        var shared = false
        var pausedByYou = false
        /// Held until its account's session window resets
        /// (`sampleLabResetMinutes`).
        var heldForReset = false
    }

    /// Minutes until the sample Lab account's full session window resets,
    /// read by its usage and by the sessions held for it.
    static let sampleLabResetMinutes: Double = 52

    /// One session of each state a Sessions page row shows, across the
    /// three providers: on Claude Code, Lab's sessions wait for its reset
    /// while one the user played goes on, one session is pinned and one runs
    /// on the shared sign-in; on Codex, one session the user paused and one
    /// refused at a limit.
    static let sampleSessions: [ScreenshotSession] = {
        let personal = ScreenshotAccount(provider: .claudeCode, label: "Personal")
        let northwind = ScreenshotAccount(provider: .claudeCode, label: "Northwind")
        let lab = ScreenshotAccount(provider: .claudeCode, label: "Lab")
        let codexPersonal = ScreenshotAccount(provider: .codex, label: "Personal")
        let builds = ScreenshotAccount(provider: .codex, label: "Builds")
        let kimi = ScreenshotAccount(provider: .kimi, label: "Kimi Coding")
        return [
            ScreenshotSession(id: "sample-api-gateway", folder: "api-gateway", model: "claude-opus-5-5",
                              account: northwind, state: .running, pinned: true),
            ScreenshotSession(id: "sample-data-pipeline", folder: "data-pipeline", model: "claude-opus-5-5",
                              account: lab, state: .waiting, heldForReset: true),
            ScreenshotSession(id: "sample-design-system", folder: "design-system", model: "claude-sonnet-5-5",
                              account: lab, state: .stopsAtNextStep, heldForReset: true),
            ScreenshotSession(id: "sample-docs-site", folder: "docs-site", model: "claude-sonnet-5-5",
                              account: lab, state: .resumedWhileOthersPaused),
            ScreenshotSession(id: "sample-infra-scripts", folder: "infra-scripts", model: "claude-opus-5-5",
                              account: personal, state: .notIsolated, shared: true),
            ScreenshotSession(id: "sample-web-dashboard", folder: "web-dashboard", model: "claude-opus-5-5",
                              account: northwind, state: .running),
            ScreenshotSession(id: "sample-cli-tools", folder: "cli-tools", model: "gpt-5.5-codex",
                              account: builds, state: .refusedAtLimit),
            ScreenshotSession(id: "sample-release-notes", folder: "release-notes", model: "gpt-5.5-codex",
                              account: codexPersonal, state: .waiting, pausedByYou: true),
            ScreenshotSession(id: "sample-prototype", folder: "prototype", model: "k3",
                              account: kimi, state: .running),
        ]
    }()

    /// The Sessions page's sample sections (`sampleSessions`), each
    /// session's move menu listing every account of its provider with its
    /// sample room. The session on the shared sign-in is also listed as
    /// unisolated, idle in a known terminal, so its row offers the restart
    /// into a slot of its own (`SessionControlButtons`).
    func screenshotSessionSections(now: Date = Date()) -> [SessionsSection] {
        func account(_ sample: ScreenshotAccount) -> Account? {
            accounts.first { $0.provider == sample.provider && $0.customLabel == sample.label }
        }
        let labReset = now.addingTimeInterval(Self.sampleLabResetMinutes * 60)
        let pausedAt: [AIProviderType: Date] = [
            .claudeCode: now.addingTimeInterval(-14 * 60),
            .codex: now.addingTimeInterval(-6 * 60),
        ]
        for sample in Self.sampleSessions where sample.shared {
            unisolatedSessions[sample.account.provider, default: []].append(AgentSession(
                sessionID: sample.id, provider: sample.account.provider.capabilities.pauseGate?.key, event: "Stop",
                workingDirectory: nil, processID: nil, host: nil, observedAt: now))
            unisolatedTerminals[sample.id] = "sample"
        }
        return [AIProviderType.claudeCode, .codex, .kimi].map { provider in
            let candidates = accounts.filter { $0.provider == provider }.map { candidate in
                let usage = accountUsage[candidate.id]
                return SessionMoveCandidate(
                    account: candidate.id, name: messageName(candidate),
                    sessionUsed: usage?.fiveHour?.utilization, weeklyUsed: usage?.sevenDay?.utilization,
                    needsSignIn: false, atLimit: (usage?.fiveHour?.utilization ?? 0) >= 100, excluded: false)
            }
            let entries = Self.sampleSessions.filter { $0.account.provider == provider }.compactMap { sample -> SessionsSection.Entry? in
                guard let serving = account(sample.account) else { return nil }
                let row = SessionRow(
                    provider: provider, id: sample.id,
                    label: Self.sessionLabel(id: sample.id, name: nil, directory: sample.folder,
                                             model: CostParser.shortModelName(sample.model)),
                    account: sample.shared ? "shared sign-in · " + messageName(serving) : messageName(serving),
                    state: sample.state, pinned: sample.pinned, inSlot: !sample.shared, gated: true,
                    pausedByYou: sample.pausedByYou, resumeAt: sample.heldForReset ? labReset : nil)
                let menu = SessionMoveMenu.build(
                    candidates: candidates, current: serving.id,
                    pinnedTo: sample.pinned ? (id: serving.id, name: messageName(serving)) : nil,
                    shared: sample.shared, balancingChoice: nil)
                return SessionsSection.Entry(row: row, moveMenu: menu)
            }
            return SessionsSection(
                provider: provider, entries: entries,
                pauseLine: Self.sessionPauseLine(pausedAt: pausedAt[provider], rows: entries.map(\.row)),
                canPauseAll: true, canResumeAll: pausedAt[provider] != nil, canRebalance: true)
        }
    }
}
#endif
