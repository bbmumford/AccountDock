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

/// Shows enabled providers in the same grouped order configured in Accounts.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage(ProviderVisibility.storageKey) private var hiddenProviders = ""

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
                            Label(
                                provider.capabilities.displayName,
                                systemImage: provider.iconName
                            )
                            .font(.headline)
                            .foregroundStyle(.brand)
                            .sectionPadding()

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
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(account)
            if appState.needsSignIn(account) {
                signInPrompt(account)
            }
            if let usage = appState.accountUsage[account.id] {
                usageBars(usage, provider: account.provider)
                if account.provider.capabilities.supportsExtraUsage {
                    extraUsageRow(usage.extraUsage)
                }
                staleUsageNotice(account)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                HStack {
                    Image(systemName: account.providerUnavailableLabel != nil
                        ? "nosign"
                        : (errorState.isRateLimited
                            ? "timer"
                            : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle")))
                        .foregroundStyle(errorState.isExpired ? .yellow : .red)
                    Text(errorState.message)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            } else if account.provider.capabilities.credentialStore == .keychain {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Token expired. Switch to this account in \(account.provider.rawValue) to refresh.")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                }
                .padding(.top, 4)
            }
            if account.provider.capabilities.credentialStore == .files, account.credentialLocation == nil {
                Label("Credentials need to be captured again.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle(fill: account.isActive ? .cardFillStrong : .cardFill)
        .sectionPadding()
    }

    private func longQuotaLabel(for provider: AIProviderType, window: UsageWindow) -> LocalizedStringKey {
        if !provider.capabilities.longWindowReportsLength {
            return LocalizedStringKey(provider.capabilities.weeklyQuotaLabel)
        }
        guard let seconds = window.windowSeconds else { return "Weekly" }
        let days = seconds / 86_400
        return days == 7 ? "Weekly" : LocalizedStringKey("\(days)-day quota")
    }

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        func reporting(_ metric: ActivityMetric) -> [AIProviderType] {
            visibleProviders.filter { $0.capabilities.activityMetrics.contains(metric) }
        }
        let combinedTurns = reporting(.turns).reduce(0) { $0 + appState.todayTurns(for: $1) }
        let combinedCost = reporting(.cost).reduce(0) { $0 + todayCost(for: $1) }
        let combinedLines = reporting(.linesChanged).reduce(0) { $0 + appState.todayLinesChanged(for: $1) }
        let activeMinutes = reporting(.activeTime).reduce(0) { $0 + (appState.providerCosts[$1]?.todayActiveMinutes ?? 0) }
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
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(combinedTurns)", label: "Turns",
                             tooltip: "Providers: \(metricProviders(.turns)). Conversation turns, or the model responses a provider records, today.")
                activityStat(icon: "clock", value: ActivityStats(activeCodingMinutes: activeMinutes).activeCodingTimeString, label: "Active",
                             tooltip: "Providers: \(metricProviders(.activeTime)). Active session timing from local session records.")
                activityStat(icon: "doc.text", value: "\(combinedLines)", label: "Lines",
                             tooltip: "Providers: \(metricProviders(.linesChanged)). Lines added and removed by file edits today.")
                activityStat(icon: "dollarsign.circle", value: String(format: "$%.0f", combinedCost), label: "Cost",
                             tooltip: "Providers: \(metricProviders(.cost)). API-equivalent cost from local token records and provider pricing today.")
            }

            if !todayModels.isEmpty {
                HStack(spacing: 0) {
                    ForEach(todayModels) { model in
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

    private var todayModels: [TodayModel] {
        visibleProviders.flatMap(todayModels(for:))
    }

    private func todayCost(for provider: AIProviderType) -> Double {
        appState.todayCost(for: provider)
    }

    private func todayModels(for provider: AIProviderType) -> [TodayModel] {
        appState.todayModelActivity(for: provider)
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

    private func metricProviders(_ metric: ActivityMetric) -> String {
        let names = visibleProviders
            .filter { $0.capabilities.activityMetrics.contains(metric) }
            .map { $0.capabilities.displayName }
        return names.isEmpty ? "none currently visible" : names.joined(separator: ", ")
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

    @ViewBuilder
    private func staleUsageNotice(_ account: Account) -> some View {
        if let error = appState.accountUsageErrors[account.id],
           let cachedAt = error.cachedAt {
            HStack(spacing: 5) {
                Image(systemName: error.isRateLimited ? "timer" : "clock.arrow.circlepath")
                Text(error.message)
                    .lineLimit(1)
                Spacer()
                Text(cachedAt, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.subheadline)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.headerTitle(obfuscated: !showFullEmail))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if account.isActive {
                        Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .brand)
                    }
                    if let sessions = appState.accountSessions[account.id], !sessions.isEmpty {
                        Text(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                            .help("\(account.provider.rawValue) sessions running on this account.")
                    }
                }
                AccountEmailLabel(email: account.email, alwaysVisible: showFullEmail)
            }

            Spacer()

            if let sub = account.displaySubscriptionType {
                Badge(text: sub, color: .brand)
            }
            if let unavailable = account.providerUnavailableLabel {
                Badge(text: unavailable, color: .orange)
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse, provider: AIProviderType) -> some View {
        if let session = usage.fiveHour {
            usageRow(
                label: LocalizedStringKey(provider.capabilities.sessionQuotaLabel),
                resetText: session.resetLabelString,
                utilization: session.utilization ?? 0
            )
        } else if usage.reportsNoSessionWindow, provider.capabilities.supportsSessionQuota {
            Label("No \(provider.capabilities.sessionQuotaLabel.lowercased()) limit on this account", systemImage: "infinity")
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        if let weekly = usage.sevenDay {
            usageRow(
                label: longQuotaLabel(for: provider, window: weekly),
                resetText: weekly.resetLabelString,
                utilization: weekly.utilization ?? 0
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

    // MARK: - Usage Row

    private func usageRow(label: LocalizedStringKey, resetText: String?, utilization: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
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
                            .fill(colorForUtilization(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)), height: 7)
                    }
                }
                .frame(height: 7)

                Text("\(Int(utilization))%")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(utilization))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func colorForUtilization(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 60 { return .orange }
        return .brand
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
            let room = outlook.resumesAt.map { ", and has room again at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
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

    /// "in about 40 min (9:12 am)", or the day and time beyond today.
    static func when(_ date: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSinceNow / 60).rounded()))
        let clock = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in about \(minutes) min (\(clock))" }
        if minutes < 24 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            return "in about \(hours) h\(rest > 0 ? " \(rest) min" : "") (\(clock))"
        }
        return "around \(clock)"
    }
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
