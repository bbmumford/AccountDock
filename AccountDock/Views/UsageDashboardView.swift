import AppKit
import SwiftUI

/// Hover tooltip that works inside MenuBarExtra panels (where `.help()` doesn't).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(tooltip)
                    .font(.caption)
                    .padding(8)
                    .frame(width: 200)
                    .environment(\.locale, locale)
            }
    }
}

/// An account card's session count, with how many of its sessions are
/// pinned (`AppState.sessionPins`) and how many were refused at a usage
/// limit. Resting the pointer on it, or clicking it, lists the sessions in
/// a popover, one row each (`AppState.sessionSummary`) with the Sessions
/// page's controls (pin, pause or play, move).
private struct SessionCountLabel: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let sessions: Set<String>
    /// Open until the user clicks elsewhere: set by a click on the label,
    /// or once the pointer reaches the open list, so its controls can be used.
    @State private var pinnedOpen = false
    /// Opened by resting the pointer on the label.
    @State private var hoverOpen = false
    @State private var labelProbe = ScreenFrameProbe()
    @State private var listProbe = ScreenFrameProbe()
    @State private var watcher: Task<Void, Never>?

    var body: some View {
        let pinned = sessions.filter { appState.sessionPins.isPinned($0) }.count
        let refused = sessions.filter { appState.sessionRefusals[$0] != nil }.count
        Button {
            if pinnedOpen { close() } else { pinnedOpen = true }
        } label: {
            HStack(spacing: 4) {
                Text((sessions.count == 1 ? "1 session" : "\(sessions.count) sessions") + (pinned > 0 ? " · \(pinned) pinned" : ""))
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                if refused > 0 {
                    Text("\(refused) refused at a limit")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .buttonStyle(.plain)
        .background(ScreenFrameProbeView(probe: labelProbe))
        .onHover { inside in
            if inside { openOnHover() }
        }
        .popover(isPresented: Binding(get: { pinnedOpen || hoverOpen },
                                      set: { if !$0 { close() } }),
                 arrowEdge: .bottom) {
            SessionPinList(provider: provider, sessions: sessions.sorted {
                appState.sessionSummary([$0]).localizedCaseInsensitiveCompare(appState.sessionSummary([$1])) == .orderedAscending
            })
            .environmentObject(appState)
            .background(ScreenFrameProbeView(probe: listProbe))
        }
        .onDisappear { close() }
    }

    /// Opens the list once the pointer has rested on the label briefly,
    /// then follows the pointer by position: reaching the list keeps it
    /// open (`pinnedOpen`) until the user clicks elsewhere, so a menu opened
    /// from it does not close it; leaving the label for half a second
    /// without reaching the list closes it.
    private func openOnHover() {
        guard !pinnedOpen, watcher == nil else { return }
        watcher = Task { @MainActor in
            defer { watcher = nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, labelProbe.contains(NSEvent.mouseLocation) else { return }
            hoverOpen = true
            var outsideSince: Date?
            while !Task.isCancelled, hoverOpen, !pinnedOpen {
                let point = NSEvent.mouseLocation
                if listProbe.windowContains(point) {
                    pinnedOpen = true
                    break
                }
                if labelProbe.contains(point) {
                    outsideSince = nil
                } else if let since = outsideSince {
                    if Date().timeIntervalSince(since) > 0.5 {
                        hoverOpen = false
                        break
                    }
                } else {
                    outsideSince = Date()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func close() {
        watcher?.cancel()
        watcher = nil
        pinnedOpen = false
        hoverOpen = false
    }
}

/// One row per session of an account card: the session and the icon
/// controls the Sessions page shows for it (`SessionControlButtons`): the
/// lock pinning it to its subscription, or for a session on the shared
/// sign-in its restart into a slot of its own; pause or play; and its move
/// menu, which for a pinned session refused at its account's limit is the
/// way out beside switching its model.
private struct SessionPinList: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let sessions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sessions, id: \.self) { id in
                row(id)
            }
        }
        .padding(8)
        .frame(minWidth: 300, maxWidth: 520, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        let pinned = appState.sessionPins.isPinned(id)
        let inSlot = appState.slotAccount(ofSession: id, provider: provider) != nil
        let ungated = appState.sessionsWithoutGate(provider).contains { $0.sessionID == id }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: appState.sessionSummary([id]))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                SessionControlButtons(provider: provider, session: id,
                                      state: appState.sessionRowState(provider, session: id),
                                      pinned: pinned, inSlot: inSlot,
                                      gated: provider.capabilities.pauseGate != nil && !ungated,
                                      moveMenu: appState.sessionMoveMenu(provider, session: id))
            }
            if pinned, appState.sessionRefusals[id] != nil {
                HStack(spacing: 8) {
                    Text("pinned · refused at limit")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                    if let choice = appState.switchModelChoice(for: id, provider: provider) {
                        Button {
                            Task { await appState.switchSessionModel(id) }
                        } label: {
                            Image(systemName: "cpu")
                        }
                        .buttonStyle(.borderless)
                        .help("Switch model: changes this session to \(choice.label) from its terminal once its turn has ended. The move menu unpins and moves it instead.")
                        .accessibilityLabel("Switch model to \(choice.label)")
                    }
                }
            }
        }
    }
}

/// Shows enabled providers in the same grouped order configured in Accounts.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage(ProviderVisibility.storageKey) private var hiddenProviders = ""
    @AppStorage("sessionLaunchDirectory") private var sessionLaunchDirectory = ""
    /// The tile session button's "Keep here": whether a session it opens
    /// is pinned to the subscription.
    @AppStorage("keepOpenedSessionsHere") private var keepOpenedSessionsHere = true
    @State private var sessionLaunchError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if visibleAccounts.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if visibleAccounts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.textSecondary)
                        Text("Usage data unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    todayActivityCard

                    ForEach(visibleProviders) { provider in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(
                                    provider.capabilities.displayName,
                                    systemImage: provider.iconName
                                )
                                .font(.headline)
                                .foregroundStyle(.brand)
                                Spacer()
                                ProviderFailoverSwitch(provider: provider, place: "the usage tab")
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                if appState.rebalanceAvailable(provider) {
                                    RebalanceButton(provider: provider)
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                }
                            }
                            .sectionPadding()

                            // The Sessions page's Outlook line; a click opens
                            // that page, where it expands.
                            if let outlook = appState.capacityOutlook(provider) {
                                CapacityOutlookView(provider: provider, outlook: outlook, expandable: false)
                                    .sectionPadding()
                            }
                            if let routed = appState.routedStatus[provider] {
                                RoutedRequestsBanner(provider: provider, status: routed)
                            }
                            if let pause = appState.agentPauseStatus[provider] {
                                AgentPauseBanner(provider: provider, status: pause)
                            }
                            let ungated = appState.sessionsWithoutGate(provider)
                            if !ungated.isEmpty {
                                UngatedSessionsLine(provider: provider, sessions: ungated)
                            }
                            if let unisolated = appState.unisolatedSessions[provider], !unisolated.isEmpty {
                                UnisolatedSessionsLine(provider: provider, sessions: unisolated)
                            }
                            if appState.agentPauseStatus[provider] == nil, let pace = appState.paceOutlook(provider) {
                                PaceOutlookLine(outlook: pace)
                            }
                            if let outlook = appState.weekOutlook(provider) {
                                WeekOutlookLine(outlook: outlook, limit: provider.capabilities.weeklyQuotaLabel.lowercased(),
                                                pausesSessions: appState.pausingProviders.contains(provider))
                            }

                            ForEach(accounts(for: provider)) { account in
                                accountCard(account)
                            }
                        }
                    }
                }

                // Last updated
                if let lastRefresh = appState.lastUsageRefresh {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text(lastRefresh, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
            // Report this VStack's intrinsic height to MainMenuView so it can
            // size the popover frame to fit the Usage tab's content exactly.
            // See MainMenuView.swift for the measurement contract.
            .measureUsageContentHeight()
        }
        .alert("Session not started", isPresented: Binding(
            get: { sessionLaunchError != nil },
            set: { if !$0 { sessionLaunchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionLaunchError ?? "")
        }
    }

    private var visibleProviders: [AIProviderType] {
        var providers: [AIProviderType] = []
        for account in appState.accounts where providerIsVisible(account.provider) {
            if !providers.contains(account.provider) {
                providers.append(account.provider)
            }
        }
        return providers
    }

    private func providerIsVisible(_ provider: AIProviderType) -> Bool {
        provider.capabilities.isImplemented && !ProviderVisibility.hidden(in: hiddenProviders).contains(provider)
    }

    private var visibleAccounts: [Account] {
        appState.accounts.filter { providerIsVisible($0.provider) }
    }

    private func accounts(for provider: AIProviderType) -> [Account] {
        appState.accounts.filter { $0.provider == provider }
    }

    /// One account's windows, extra usage where the provider has it, and
    /// what stops it from being read.
    private func accountCard(_ account: Account) -> some View {
        let status = appState.status(of: account)
        return VStack(alignment: .leading, spacing: 10) {
            accountHeader(account, status: status)
            if status.needsSignIn {
                signInPrompt(account)
            }
            if let access = status.accessNotice {
                HStack(alignment: .top) {
                    Image(systemName: access.symbol)
                        .foregroundStyle(access.tone.color)
                    Text(access.text)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            if let usage = appState.accountUsage[account.id] {
                usageBars(usage, provider: account.provider, hasSessionWindow: account.planHasSessionWindow == true)
                if account.provider.capabilities.supportsExtraUsage {
                    extraUsageRow(usage.extraUsage)
                }
                limitResetRows(usage.limitResets)
                if let stale = status.staleReading { staleUsageNotice(stale) }
            } else if let problem = status.readingProblem {
                HStack {
                    Image(systemName: problem.symbol)
                        .foregroundStyle(problem.tone.color)
                    Text(problem.text)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            }
            if status.needsCapture {
                Label("Credentials need to be captured again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle(fill: account.isActive ? .cardFillStrong : .cardFill)
        .sectionPadding()
    }

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        let summary = appState.todaySummary(hidden: ProviderVisibility.hidden(in: hiddenProviders))
        func metricProviders(_ metric: ActivityMetric) -> String {
            let names = summary.reporting(metric).map { $0.capabilities.displayName }
            return names.isEmpty ? "none currently visible" : names.joined(separator: ", ")
        }
        let models = todayModels(summary)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(.brand)
                Text("Today's Activity")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            // Top stats row
            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(summary.turns)", label: "Turns",
                             tooltip: "Providers: \(metricProviders(.turns)). Conversation turns, or the model responses a provider records, today.")
                activityStat(icon: "clock", value: ActivityStats(activeCodingMinutes: summary.activeMinutes).activeCodingTimeString, label: "Active",
                             tooltip: "Providers: \(metricProviders(.activeTime)). Active session timing from local session records.")
                activityStat(icon: "doc.text", value: "\(summary.linesChanged)", label: "Lines",
                             tooltip: "Providers: \(metricProviders(.linesChanged)). Lines added and removed by file edits today.")
                activityStat(icon: "dollarsign.circle", value: UsageFormat.cost(summary.cost), label: "Cost",
                             tooltip: "Providers: \(metricProviders(.cost)). API-equivalent cost from local token records and provider pricing today.")
            }

            if !models.isEmpty {
                HStack(spacing: 0) {
                    ForEach(models) { model in
                        modelStat(
                            name: model.name,
                            count: model.count,
                            tooltip: model.tooltip
                        )
                    }
                }
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private struct TodayModel: Identifiable {
        let id: String
        let name: String
        let count: Int
        let tooltip: LocalizedStringKey
    }

    /// Today's models of the providers `summary` counts, provider by provider.
    private func todayModels(_ summary: TodaySummary) -> [TodayModel] {
        summary.byProvider.flatMap { entry -> [TodayModel] in
            let provider = entry.provider
            return entry.day.modelActivity
                .filter { $0.value > 0 && isDisplayableModel($0.key) }
                .sorted { $0.key < $1.key }
                .map {
                    TodayModel(
                        id: "\(provider.rawValue)-\($0.key)",
                        name: provider.displayModelName($0.key),
                        count: $0.value,
                        tooltip: "\(provider.capabilities.displayName) \($0.key) activity today"
                    )
                }
        }
    }

    private func isDisplayableModel(_ model: String) -> Bool {
        let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty &&
            !cleaned.localizedCaseInsensitiveContains("synthetic") &&
            cleaned != "<unknown>"
    }


    private func activityStat(icon: String, value: String, label: LocalizedStringKey, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelStat(name: String, count: Int, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count > 0 ? .primary : .quaternary)
                HStack(spacing: 3) {
                    Circle()
                        .fill(modelColor(name))
                        .frame(width: 7, height: 7)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? .tertiary : .quaternary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelColor(_ name: String) -> Color {
        name.hasPrefix("GPT") ? Color.brand.opacity(0.5) : .brand
    }

    // MARK: - Per-Account Card

    /// Shown while the provider rejects the account's sign-in. The usage
    /// shown beside it is the last reading, not a limit reached, so the
    /// account is described as signed out rather than exhausted.
    private func signInPrompt(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Needs sign-in. \(account.provider.capabilities.displayName) rejected this account's saved sign-in; its usage below is the last reading.")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Sign In") {
                Task { await appState.reauthenticateAccount(account) }
            }
            .controlSize(.small)
            .disabled(appState.isLoggingIn)
        }
        .padding(.top, 4)
    }

    /// The reading shown is from before a failed one (`AccountStatus.staleReading`).
    @ViewBuilder
    private func staleUsageNotice(_ notice: AccountStatus.Notice) -> some View {
        HStack(spacing: 5) {
            Image(systemName: notice.symbol)
            Text(notice.text)
                .lineLimit(1)
            Spacer()
            if let since = notice.since {
                Text(since, style: .relative)
                    .monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(notice.tone.color)
    }

    @ViewBuilder
    private func accountHeader(_ account: Account, status: AccountStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.subheadline)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.headerTitle(obfuscated: !showFullEmail))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    ForEach(status.cardTitleBadges, id: \.text) { Badge($0) }
                    if let sessions = appState.accountSessions[account.id], !sessions.isEmpty {
                        SessionCountLabel(provider: account.provider, sessions: sessions)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                AccountEmailLabel(email: account.email, alwaysVisible: showFullEmail)
            }

            Spacer()

            ForEach(status.cardPlanBadges, id: \.text) { Badge($0) }
            sessionButton(account)
        }
    }

    /// Starts a session on this subscription in the terminal chosen from the
    /// menu, in a folder chosen next. It is pinned there
    /// (`AppState.sessionLaunch`) unless "Keep here" is unchecked or Option
    /// is held while choosing (`SessionPins.pinsOpenedSession`); unpinned,
    /// it stays until failover or balancing moves it.
    @ViewBuilder
    private func sessionButton(_ account: Account) -> some View {
        if account.provider.capabilities.sessionIsolation != nil {
            let blocker = appState.sessionLaunchBlocker(account)
            Menu {
                ForEach(SessionTerminal.available) { terminal in
                    Button {
                        let pinned = SessionPins.pinsOpenedSession(
                            keepHere: keepOpenedSessionsHere,
                            optionHeld: NSEvent.modifierFlags.contains(.option))
                        Task { await openSession(on: account, using: terminal, pinned: pinned) }
                    } label: {
                        Label(terminal.title, systemImage: terminal.systemImage)
                    }
                }
                Divider()
                Toggle("Keep here", isOn: $keepOpenedSessionsHere)
                    .help("Pins the session to this subscription, so nothing automatic moves it. Hold Option while choosing a terminal to open one unpinned.")
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(blocker != nil)
            .help(blocker ?? "Open a session on this subscription, pinned here unless Keep here is unchecked or Option is held.")
        }
    }

    @MainActor
    private func openSession(on account: Account, using terminal: SessionTerminal, pinned: Bool) async {
        if let blocker = appState.sessionLaunchBlocker(account) {
            sessionLaunchError = blocker
            return
        }
        // The copied command runs in whatever folder it is pasted into; a
        // terminal started here needs its folder chosen.
        let directory: URL?
        if terminal == .clipboard {
            directory = nil
        } else {
            guard let chosen = chooseSessionDirectory() else { return }
            directory = chosen
        }
        guard let command = await appState.sessionLaunch(on: account, in: directory, pinned: pinned) else {
            sessionLaunchError = "\(appState.messageName(account)) cannot start a session right now. Check that it is signed in."
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let message = await terminal.start(command, in: directory ?? home, name: appState.messageName(account)) {
            sessionLaunchError = message
        }
    }

    /// The folder the session starts in, starting from the last one chosen.
    @MainActor
    private func chooseSessionDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        panel.message = "Choose the folder the session starts in."
        if !sessionLaunchDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: sessionLaunchDirectory, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        sessionLaunchDirectory = url.path
        return url
    }

    /// The account's windows. A session window nothing has started, or one
    /// the reply leaves out on a plan that has one (`hasSessionWindow`), is
    /// shown at 0% as not started; only a plan without one has no limit.
    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse, provider: AIProviderType, hasSessionWindow: Bool) -> some View {
        switch usage.sessionWindowDisplay(hasSessionWindow: hasSessionWindow,
                                          supportsSessionQuota: provider.capabilities.supportsSessionQuota) {
        case .window:
            if let session = usage.fiveHour {
                usageRow(
                    label: LocalizedStringKey(provider.capabilities.sessionQuotaLabel),
                    resetText: session.resetLabelString,
                    utilization: session.utilization
                )
            }
        case .notStarted:
            usageRow(
                label: LocalizedStringKey(provider.capabilities.sessionQuotaLabel),
                resetText: UsageAPIResponse.unstartedWindowText(
                    length: usage.fiveHour?.windowSeconds.map(TimeInterval.init) ?? Allowance.sessionWindow),
                utilization: 0
            )
        case .noLimit:
            Label("No \(provider.capabilities.sessionQuotaLabel.lowercased()) limit on this account", systemImage: "infinity")
                .font(.caption)
                .foregroundStyle(.textSecondary)
        case .absent:
            EmptyView()
        }
        if let weekly = usage.sevenDay {
            usageRow(
                label: LocalizedStringKey(provider.capabilities.longWindowLabel(for: weekly)),
                resetText: weekly.resetLabelString,
                utilization: weekly.utilization,
                inner: usage.modelWeeklyLimits.map { limit in
                    ModelShare(name: limit.model, percent: limit.percent,
                               fractionOfBar: (limit.usedPercentOfWeekly ?? limit.percent * limit.allowancePercentOfWeekly / 100) / 100)
                }
            )
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if let extra {
            let enabled = extra.isEnabled == true
            let iconColor: Color = enabled ? .orange : .gray
            let statusColor: Color = enabled ? .orange : .gray
            HStack(spacing: 6) {
                Image(systemName: enabled ? "bolt.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text("Extra usage")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text(LocalizedStringKey(enabled ? "On" : "Off"))
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
    }

    /// One row per kind of limit reset the account still holds, with resets
    /// that end the same day counted together: what they refill, how many
    /// are left and the last day they can be used. Resets that cannot be used
    /// yet, or are paused, are shown dimmed.
    @ViewBuilder
    private func limitResetRows(_ resets: LimitResets?) -> some View {
        if let resets {
            ForEach(resets.availableGroups) { group in
                let ready = group.ready
                HStack(spacing: 6) {
                    Image(systemName: ready ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(ready ? Color.green : Color.gray)
                    Text(LocalizedStringKey(group.kind))
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                    Text(limitResetDetail(group))
                        .font(.caption)
                        .foregroundStyle(ready ? Color.green : Color.gray)
                }
                .help(group.labels.joined(separator: "\n"))
            }
        }
    }

    private func limitResetDetail(_ group: LimitResets.Group) -> String {
        var parts = [group.resetsTotal > group.resetsLeft ? "\(group.resetsLeft) of \(group.resetsTotal) left" : "\(group.resetsLeft) left"]
        if !group.ready { parts.append("not usable yet") }
        if let end = group.endDay {
            parts.append("use by \(end.formatted(.dateTime.day().month(.abbreviated)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Usage Row

    /// A model's own weekly limit, drawn inside the bar of the whole weekly
    /// limit: `fractionOfBar` is the part of the whole allowance the model
    /// has used, and `percent` how much of its own limit that is.
    /// The colour of a model's part of the weekly bar, by the bar's own
    /// colour, so the part always reads apart from it: the orange the Extra
    /// usage row uses in a bar at rest, red in an orange bar, and `deepRed`
    /// in a red one.
    static func modelShareColor(in severity: UsageLevel.Severity) -> Color {
        switch severity {
        case .critical: deepRed
        case .high: .red
        case .normal, .unknown: .orange
        }
    }

    /// The red a bar at its limit is drawn in, taken part of the way to
    /// black: the same hue at a greater depth, in light and dark appearance
    /// alike, so a model's part of a red bar matches the bar.
    static let deepRed = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        var red = NSColor.systemRed
        appearance.performAsCurrentDrawingAppearance { red = NSColor.systemRed.usingColorSpace(.sRGB) ?? .systemRed }
        return red.blended(withFraction: 0.38, of: .black) ?? red
    }))

    struct ModelShare {
        let name: String
        let percent: Double
        let fractionOfBar: Double
    }

    private func usageRow(label: LocalizedStringKey, resetText: String?, utilization: Double?,
                          inner: [ModelShare] = []) -> some View {
        let level = UsageLevel(utilization: utilization)
        let color = level.color(normal: .brand)
        return VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                ForEach(inner, id: \.name) { share in
                    let shareLevel = UsageLevel(utilization: share.percent)
                    HStack(spacing: 3) {
                        Circle().fill(Self.modelShareColor(in: level.severity)).frame(width: 6, height: 6)
                        Text("\(share.name) \(shareLevel.percentText)")
                            .font(.caption)
                            .foregroundStyle(shareLevel.color(normal: .textSecondary))
                    }
                    .help("\(share.name) has used \(shareLevel.percentText) of its own weekly limit; the darker part of the bar is its share of the whole weekly allowance.")
                }
                Spacer()
                if let resetText {
                    Text(resetText)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.progressTrack)
                            .frame(height: 7)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: max(0, geo.size.width * level.fraction), height: 7)

                        // Each model's part of what is used, from the leading edge.
                        ForEach(inner, id: \.name) { share in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Self.modelShareColor(in: level.severity))
                                .frame(width: max(0, geo.size.width * min(level.fraction, max(0, share.fractionOfBar))), height: 7)
                        }
                    }
                }
                .frame(height: 7)

                Text(level.percentText)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(color)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/// Sessions started before the pause hook was installed, which a pause
/// cannot hold until they are restarted (`AppState.sessionsWithoutGate`).
private struct UngatedSessionsLine: View {
    let provider: AIProviderType
    let sessions: [AgentSession]

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .help(places)
            .sectionPadding()
    }

    private var text: String {
        let name = provider.capabilities.displayName
        let count = sessions.count == 1 ? "1 \(name) session" : "\(sessions.count) \(name) sessions"
        let verb = sessions.count == 1 ? "was" : "were"
        let pronoun = sessions.count == 1 ? "it" : "them"
        return "\(count) \(verb) started before AccountDock's pause hook was installed, so a pause cannot hold \(pronoun). Restart \(pronoun) to fix this."
    }

    private var places: String {
        sessions.map { session in
            session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? session.sessionID
        }.joined(separator: "\n")
    }
}

/// Sessions that read no slot of their own (`AppState.unisolatedSessions`).
/// Resting the pointer on the line lists them (`AppState.sessionSummary`),
/// each with a restart into its own slot or why it cannot have one now, and
/// one action restarting every idle one in agterm. A session in the CLI's
/// background service (`AppState.backgroundSessionStates`) is marked as
/// such; its restart stops it and resumes it in its attach client's tab.
private struct UnisolatedSessionsLine: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let sessions: [AgentSession]
    @State private var overLine = false
    @State private var overList = false

    var body: some View {
        Label(sessions.count == 1 ? "1 session not isolated" : "\(sessions.count) sessions not isolated",
              systemImage: "square.on.square.dashed")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .sectionPadding()
            .onHover { overLine = $0 }
            .popover(isPresented: Binding(get: { overLine || overList }, set: { if !$0 { overLine = false; overList = false } }),
                     arrowEdge: .bottom) {
                list.onHover { overList = $0 }.environmentObject(appState)
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Started outside a slot of its own: by full path, from an IDE or the desktop app, before the pool was ready, or in the background service, whose workers read the shared sign-in. These share the sign-in and cannot be moved one at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sessions, id: \.sessionID) { session in
                let background = appState.backgroundSessionStates[session.sessionID]
                let blocker = AppState.restartBlocker(session, terminal: appState.unisolatedTerminals[session.sessionID],
                                                      background: background,
                                                      refused: appState.sessionRefusals[session.sessionID] != nil)
                let stuck = appState.stuckBackgroundSessions[session.sessionID]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: appState.sessionSummary([session.sessionID])
                             + (background != nil ? " · background session" : ""))
                            .font(.caption)
                        if let stuck {
                            let name = appState.accounts.first { $0.id == stuck.account }.map { appState.messageName($0) } ?? "its account"
                            Text(verbatim: "On \(name), which can no longer serve it; telling it to read its sign-in again does not move it.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let blocker {
                            Text(blocker)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Restart in its own slot") {
                        Task { await appState.restartInOwnSlot(session.sessionID) }
                    }
                    .controlSize(.small)
                    .disabled(blocker != nil)
                    .help(background != nil
                          ? "Stops the background session and resumes it in its attach client's agterm tab, through the launcher."
                          : "Ends the session and resumes it in its agterm tab, through the launcher.")
                }
            }
            let ready = sessions.filter {
                AppState.restartBlocker($0, terminal: appState.unisolatedTerminals[$0.sessionID],
                                        background: appState.backgroundSessionStates[$0.sessionID],
                                        refused: appState.sessionRefusals[$0.sessionID] != nil) == nil

            }
            if sessions.count > 1 {
                Button("Restart all idle unisolated sessions") {
                    Task { await appState.restartIdleUnisolatedSessions(provider) }
                }
                .controlSize(.small)
                .disabled(ready.isEmpty)
            }
        }
        .padding(8)
        .frame(minWidth: 260, maxWidth: 460, alignment: .leading)
    }
}

/// When the active account runs out and when sessions would be paused, at
/// the active account's current pace (`AppState.paceOutlook`).
private struct PaceOutlookLine: View {
    let outlook: AppState.PaceOutlook

    var body: some View {
        Label(text, systemImage: "gauge.with.dots.needle.67percent")
            .font(.caption)
            .foregroundStyle(soon ? Color.orange : Color.textSecondary)
            .help("Estimated from the active account's use over the last few readings, with work moving between accounts as failover would move it.")
            .sectionPadding()
    }

    /// A pause within the next two hours is shown in orange.
    private var soon: Bool { outlook.holdAt.map { $0.timeIntervalSinceNow < 2 * 3600 } ?? false }

    private var text: String {
        var parts: [String] = []
        if let runsOut = outlook.runsOutAt, let limit = outlook.limit {
            let window = outlook.afterCurrentWindow ? " in a later window than this one" : ""
            let room = outlook.resumesAt.map { ", and has room again \(UsageFormat.atClock($0))" } ?? ""
            parts.append("At the current pace, \(outlook.account) reaches its \(limit)\(window) \(Self.when(runsOut))\(room).")
        } else {
            parts.append("At the current pace, \(outlook.account) does not run out this week.")
        }
        if let hold = outlook.holdAt {
            parts.append(outlook.pausesSessions
                ? "Sessions pause \(Self.when(hold)), when every included account is used up."
                : "Every included account is used up \(Self.when(hold)); its sessions are not paused, so they stop at the limit until it resets.")
        } else {
            parts.append(outlook.pausesSessions ? "No pause is expected this week." : "No account runs out this week.")
        }
        return parts.joined(separator: " ")
    }

    /// "in about 40 min (9:12 am)", or the day and time beyond a day
    /// (`UsageFormat.until`).
    static func when(_ date: Date) -> String { UsageFormat.until(date) }
}

/// One line summarising the coming week under the current strategy, from
/// the demand forecast.
private struct WeekOutlookLine: View {
    let outlook: QuotaSimulator.Outcome
    /// The long window's name, such as "weekly limit" or "monthly limit".
    let limit: String
    let pausesSessions: Bool

    var body: some View {
        Label(text, systemImage: outlook.unmet > 0.5 ? "exclamationmark.circle" : "calendar")
            .font(.caption)
            .foregroundStyle(outlook.unmet > 0.5 ? Color.orange : Color.textSecondary)
            .help("Simulated from your usage by hour of the week over the next seven days, with the current failover strategy. Percentages are of one account's weekly allowance.")
            .sectionPadding()
    }

    private var text: String {
        if let shortfall = outlook.firstShortfall, outlook.unmet > 0.5 {
            return "At your usual pace, which differs from the current one, every account's \(limit) is used up \(shortfall.formatted(.dateTime.weekday(.abbreviated).hour().minute())); about \(Int(outlook.unmet.rounded()))% of the next 7 days' work would \(pausesSessions ? "wait" : "be refused") until it resets."
        }
        if outlook.expired > 0.5 {
            return "At your usual pace, about \(Int(outlook.expired.rounded()))% of allowance resets unused this week."
        }
        return "At your usual pace, this week's allowances cover your work with nothing left to expire."
    }
}
