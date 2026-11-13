#if DEBUG
import AppKit
import SwiftUI

/// Renders the README screenshots from sample accounts, so no real identity,
/// usage or cost appears in them. `Tools/render_screenshots.sh` launches a
/// copy of a Debug build under a separate bundle identifier with
/// `ACCOUNTDOCK_SCREENSHOT_DIR` set; the separate identifier gives the copy
/// its own preferences, because the settings views write the failover order
/// and other preferences as they appear.
@MainActor
enum ScreenshotRenderer {
    static let productionBundleIdentifier = "app.accountdock.mac"

    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ACCOUNTDOCK_SCREENSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Writes every screenshot and exits without running termination
    /// handlers, which would continue CLI processes the installed app paused.
    static func run(appState: AppState, config: MenuBarConfig, into directory: URL) async {
        guard Bundle.main.bundleIdentifier != productionBundleIdentifier else {
            FileHandle.standardError.write(Data("Refusing to render under the production bundle identifier\n".utf8))
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
            policy.routeTarget = "kimi"
            policy.routeModel = "k3"
        }
        FailoverConfigStore.shared.update(.codex) { policy in
            policy.enabled = true
            policy.suspendAgentsWhenExhausted = true
        }

        let pages: [(String, AnyView, CGSize)] = [
            ("menu-usage", AnyView(MainMenuView(initialTab: .usage, maximumHeight: 1400)), CGSize(width: 440, height: 0)),
            ("menu-costs", AnyView(MainMenuView(initialTab: .costs, maximumHeight: 1400)), CGSize(width: 440, height: 0)),
            ("menu-accounts", AnyView(MainMenuView(initialTab: .accounts, maximumHeight: 1400)), CGSize(width: 440, height: 0)),
            ("settings-failover", AnyView(FailoverSettingsView().frame(width: 660, height: 1150)), CGSize(width: 660, height: 1150)),
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
            failed = true
        }
        exit(failed ? 1 : 0)
    }

    /// Lays the view out in an off-screen window and captures it at the
    /// screen's scale. A zero width or height takes the view's own size.
    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) async -> Bool {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
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
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
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
        accountUsage = [
            claudePersonal.id: personalUsage,
            claudeWork.id: workUsage,
            claudeLab.id: usage(0, 5 * hour, 18, 5.8 * day),
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
                todayModelTokens: ["gpt-5.5-codex": Int(codexToday * 270_000), "gpt-5.5-mini": Int(codexToday * 40_000)]
            ),
            .kimi: CostParser.ProviderCostHistory(
                dailyCosts: kimiDaily,
                todayModelActivity: ["k3": 88],
                todayModelCosts: ["k3": kimiToday],
                todayLinesChanged: 0,
                todayTokens: Int(kimiToday * 2_400_000),
                dailyTokens: kimiTokens,
                todayModelTokens: ["k3": Int(kimiToday * 2_400_000)]
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
}
#endif
