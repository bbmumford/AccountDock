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

/// Shows enabled providers together, grouped by provider, with one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("showClaudeProvider") private var showClaudeProvider = true
    @AppStorage("showCodexProvider") private var showCodexProvider = true

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
                                provider == .claudeCode ? "Claude" : "Codex",
                                systemImage: provider.iconName
                            )
                            .font(.headline)
                            .foregroundStyle(.brand)
                            .sectionPadding()

                            ForEach(accounts(for: provider)) { account in
                                if provider == .claudeCode {
                                    accountUsageCard(account: account, usage: appState.accountUsage[account.id])
                                } else {
                                    codexAccountCard(account)
                                }
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
        if showClaudeProvider { providers.append(.claudeCode) }
        if showCodexProvider { providers.append(.codex) }
        return providers
    }

    private var visibleAccounts: [Account] {
        appState.accounts.filter { visibleProviders.contains($0.provider) }
    }

    private func accounts(for provider: AIProviderType) -> [Account] {
        appState.accounts.filter { $0.provider == provider }
    }

    private func codexAccountCard(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                accountHeader(account)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(
                        account.isActive
                        ? "This account is active at ~/.codex/auth.json and is currently used by Codex on this Mac."
                        : "This account is stored in an isolated managed Codex home. Make it active to use it at ~/.codex/auth.json."
                    )
            }
            if let usage = appState.accountUsage[account.id] {
                if let session = usage.fiveHour {
                    usageRow(
                        label: "Session",
                        resetText: session.resetTimeString,
                        utilization: session.utilization ?? 0
                    )
                }
                if let weekly = usage.sevenDay {
                    usageRow(
                        label: "Weekly",
                        resetText: weekly.resetTimeString,
                        utilization: weekly.utilization ?? 0
                    )
                }
            } else if let error = appState.accountUsageErrors[account.id] {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: account.credentialLocation == nil ? "exclamationmark.triangle" : "checkmark.shield")
                    .foregroundStyle(account.credentialLocation == nil ? .orange : .green)
                Text(account.credentialLocation == nil
                     ? "Credentials need to be captured again."
                     : "Credentials isolated in a managed Codex home.")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Spacer()
            }
        }
        .cardStyle(fill: account.isActive ? .cardFillStrong : .cardFill)
        .sectionPadding()
    }

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        let stats = appState.activityStats
        let claudeTurns = showClaudeProvider ? stats.conversationTurns : 0
        let codexTurns = showCodexProvider
            ? appState.codexTodayModelActivity.values.reduce(0, +)
            : 0
        let claudeCost = showClaudeProvider ? appState.costSummary.todayCost : 0
        let codexCost = showCodexProvider
            ? max(0, appState.combinedTodayCost - appState.costSummary.todayCost)
            : 0
        let combinedCost = claudeCost + codexCost
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
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(claudeTurns + codexTurns)", label: "Turns",
                             tooltip: "Combined Claude conversation turns and Codex response activity today")
                activityStat(icon: "clock", value: stats.activeCodingTimeString, label: "Active",
                             tooltip: "Claude active time today. Codex session timing is not available in its local usage records.")
                activityStat(icon: "doc.text", value: "\(stats.linesWritten)", label: "Lines",
                             tooltip: "Lines written by Claude Edit/Write tools. Codex does not record an equivalent local total.")
                activityStat(icon: "dollarsign.circle", value: String(format: "$%.0f", combinedCost), label: "Cost",
                             tooltip: "Estimated API-equivalent cost of visible Claude and Codex activity today.")
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
        let claude = (showClaudeProvider ? appState.activityStats.modelUsage : [:])
            .filter { $0.value > 0 && isDisplayableModel($0.key) }
            .sorted { $0.key < $1.key }
            .map {
                TodayModel(
                    id: "claude-\($0.key)",
                    name: $0.key,
                    count: $0.value,
                    tooltip: "Claude \($0.key) activity today"
                )
            }
        let codex = (showCodexProvider ? appState.codexTodayModelActivity : [:])
            .filter { $0.value > 0 && isDisplayableModel($0.key) }
            .sorted { $0.key < $1.key }
            .map {
                TodayModel(
                    id: "codex-\($0.key)",
                    name: displayCodexModel($0.key),
                    count: $0.value,
                    tooltip: "Codex \($0.key) activity today"
                )
            }
        return claude + codex
    }

    private func isDisplayableModel(_ model: String) -> Bool {
        let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty &&
            !cleaned.localizedCaseInsensitiveContains("synthetic") &&
            cleaned != "<unknown>"
    }

    private func displayCodexModel(_ raw: String) -> String {
        raw.split(separator: "-")
            .map {
                let part = String($0)
                if part.lowercased() == "gpt" { return "GPT" }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
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

    private func accountUsageCard(account: Account, usage: UsageAPIResponse?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(account)
            if let usage = usage {
                usageBars(usage)
                extraUsageRow(usage.extraUsage)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                HStack {
                    Image(systemName: errorState.isRateLimited ? "timer" : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
                        .foregroundStyle(errorState.isExpired ? .yellow : .red)
                    Text(errorState.message)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Token expired. Switch to this account in Claude Code to refresh.")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .cardStyle(fill: account.isActive ? .cardFill : .cardFill)
        .sectionPadding()
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.subheadline)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            Text(account.displayEmail(obfuscated: !showFullEmail))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if account.isActive {
                Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .brand)
            }

            Spacer()

            if let sub = account.displaySubscriptionType {
                Badge(text: sub, color: .brand)
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse) -> some View {
        if let session = usage.fiveHour {
            usageRow(label: "Session", resetText: session.resetTimeString, utilization: session.utilization ?? 0)
        }
        if let weekly = usage.sevenDay {
            usageRow(label: "Weekly", resetText: weekly.resetTimeString, utilization: weekly.utilization ?? 0)
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
                    Text("Resets in \(resetText)")
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
