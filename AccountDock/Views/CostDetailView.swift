import SwiftUI

/// Unified provider cost tab with today's combined total and available history.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showCostLast7Days") private var showLast7Days = true
    @AppStorage("showCostLast30Days") private var showLast30Days = true
    @AppStorage("showCostAllTime") private var showAllTime = true
    @State private var visibleDailyCount = 7
    @State private var showingCalculationInfo = false

    private struct ProviderModelCost: Identifiable {
        let id: String
        let provider: String
        let icon: String
        let model: String
        let cost: Double
        let tokens: Int
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                todayCard
                periodSummaryCards
                dailyHistorySection
                pricingInfoSection
            }
            .padding(.vertical, 12)
            .measureUsageContentHeight()
        }
    }

    // MARK: - Summary Cards

    private var todayCard: some View {
        return VStack(spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text(todayDisplayDate())
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
            }

            Text(formatCost(appState.combinedTodayCost))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.brand)

            Text("\(formatTokenCount(todayProviders.reduce(0) { $0 + appState.todayTokens(for: $1) })) tokens")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.textSecondary)

            HStack(spacing: 10) {
                ForEach(todayProviders) { provider in
                    providerTodayCost(
                        name: provider.capabilities.displayName,
                        icon: provider.iconName,
                        cost: appState.todayCost(for: provider),
                        tokens: appState.todayTokens(for: provider)
                    )
                }
            }

            let modelCosts = combinedTodayModelCosts()
            if !modelCosts.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(modelCosts) { item in
                        HStack {
                            Image(systemName: item.icon)
                                .frame(width: 12)
                            Text(item.provider)
                                .fontWeight(.medium)
                            Text(item.model)
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                            Spacer()
                            Text(formatTokenCount(item.tokens))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.textSecondary)
                            Text(formatCost(item.cost))
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.textSecondary)
                        }
                        .font(.caption2)
                    }
                }

                ForEach(todayProviders) { provider in
                    HStack {
                        Label("\(provider.capabilities.displayName): \(appState.todaySessions(for: provider)) sessions", systemImage: "terminal")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                        Spacer()
                        Text("\(formatTokenCount(appState.todayTokens(for: provider))) tokens")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    /// Providers with sessions, tokens or cost today, in registry order.
    private var todayProviders: [AIProviderType] {
        costProviders.filter { provider in
            appState.todayCost(for: provider) > 0 || appState.todayTokens(for: provider) > 0
                || appState.todaySessions(for: provider) > 0
        }
    }

    /// Providers with any recorded cost history, in registry order.
    private var costProviders: [AIProviderType] {
        AIProviderType.implementedProviders.filter { !appState.dailyCosts(for: $0).isEmpty }
    }

    private func combinedTodayModelCosts() -> [ProviderModelCost] {
        costProviders.flatMap { provider in
            let tokens = appState.todayModelTokens(for: provider)
            return appState.todayModelCosts(for: provider).compactMap { model, cost -> ProviderModelCost? in
                guard cost > 0 else { return nil }
                return ProviderModelCost(
                    id: "\(provider.rawValue)-\(model)",
                    provider: provider.capabilities.displayName,
                    icon: provider.iconName,
                    model: model,
                    cost: cost,
                    tokens: tokens[model] ?? 0
                )
            }
        }.sorted { $0.cost > $1.cost }
    }

    private func providerTodayCost(name: String, icon: String, cost: Double, tokens: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(name)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatCost(cost))
                Text("\(formatTokenCount(tokens)) tokens")
                    .font(.system(size: 8))
            }
            .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(7)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 7))
    }

    private var periodSummaryCards: some View {
        let todayStr = todayString()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let last7 = combinedDaysInLast(7, today: todayStr, formatter: formatter)
        let last30 = combinedDaysInLast(30, today: todayStr, formatter: formatter)
        let allTime = combinedDailyCosts

        return VStack(spacing: 10) {
            HStack {
                Text("Cost summaries")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Menu {
                    Toggle("Last 7 Days", isOn: $showLast7Days)
                    Toggle("Last 30 Days", isOn: $showLast30Days)
                    Toggle("All Time", isOn: $showAllTime)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose cost summary periods")
            }

            if showLast7Days || showLast30Days {
                HStack(spacing: 10) {
                    if showLast7Days {
                        periodCard(title: "Last 7 Days", days: last7)
                    }
                    if showLast30Days {
                        periodCard(title: "Last 30 Days", days: last30)
                    }
                }
            }

            if showAllTime {
                periodCard(title: "All Time", days: allTime)
            }
        }
        .sectionPadding()
    }

    private func combinedDaysInLast(_ days: Int, today: String, formatter: DateFormatter) -> [CombinedDailyCost] {
        guard let todayDate = formatter.date(from: today) else { return [] }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let start = formatter.string(from: startDate)
        return combinedDailyCosts.filter { $0.date >= start && $0.date <= today }
    }

    private func periodCard(title: LocalizedStringKey, days: [CombinedDailyCost]) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.textSecondary)
            Text(formatCost(days.reduce(0) { $0 + $1.total }))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("\(formatTokenCount(days.reduce(0) { $0 + $1.totalTokens })) tokens")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func costForLastDays(_ days: Int, costs: [DailyCost], today: String, formatter: DateFormatter) -> Double {
        guard let todayDate = formatter.date(from: today) else { return 0 }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let startStr = formatter.string(from: startDate)
        return costs.filter { $0.date >= startStr && $0.date <= today }.reduce(0) { $0 + $1.totalCost }
    }

    // MARK: - Daily History

    private var dailyHistorySection: some View {
        let costs = combinedDailyCosts
        let visibleCosts = Array(costs.prefix(visibleDailyCount))
        let maxCost = visibleCosts.map(\.total).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily History")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(Array(costProviders.enumerated()), id: \.element) { index, provider in
                        legendDot(color: segmentColor(index, isToday: true), label: provider.capabilities.displayName)
                    }
                }
                Text("Total: \(formatCost(visibleCosts.reduce(0) { $0 + $1.total })) · \(formatTokenCount(visibleCosts.reduce(0) { $0 + $1.totalTokens }))")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.textSecondary)
            }
            .padding(.horizontal, 16)

            if costs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.textSecondary)
                    Text("No cost data available")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 1) {
                    ForEach(visibleCosts) { day in
                        dailyRow(day: day, maxCost: maxCost)
                    }
                }
                .padding(.horizontal, 16)

                if visibleDailyCount < costs.count {
                    Button("Show More") {
                        visibleDailyCount = min(visibleDailyCount + 7, costs.count)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
    }

    private struct CombinedDailyCost: Identifiable {
        let date: String
        let costs: [AIProviderType: Double]
        let tokens: [AIProviderType: Int]
        var total: Double { costs.values.reduce(0, +) }
        var totalTokens: Int { tokens.values.reduce(0, +) }
        var id: String { date }
    }

    private var combinedDailyCosts: [CombinedDailyCost] {
        let byProvider = Dictionary(uniqueKeysWithValues: costProviders.map { ($0, appState.dailyCosts(for: $0)) })
        let tokensByProvider = Dictionary(uniqueKeysWithValues: costProviders.map { ($0, appState.dailyTokens(for: $0)) })
        let dates = byProvider.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        return dates.map { date in
            CombinedDailyCost(
                date: date,
                costs: byProvider.compactMapValues { $0[date] },
                tokens: tokensByProvider.compactMapValues { $0[date] }
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// Each provider's segment is a lighter step of the accent colour.
    private func segmentColor(_ index: Int, isToday: Bool) -> Color {
        let base = isToday ? 1.0 : 0.72
        return Color.brand.opacity(max(0.2, base - Double(index) * 0.28))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func dailyRow(day: CombinedDailyCost, maxCost: Double) -> some View {
        let isToday = day.date == todayString()

        return HStack(spacing: 8) {
            Text(shortDate(day.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? .brand : .secondary)
                .frame(width: 40, alignment: .leading)

            Text(formatWholeCost(day.total))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isToday ? .brand : .primary)
                .frame(width: 56, alignment: .trailing)

            Text(formatTokenCount(day.totalTokens))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.textSecondary)
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(costProviders.enumerated()), id: \.element) { index, provider in
                        let ratio = maxCost > 0 ? (day.costs[provider] ?? 0) / maxCost : 0
                        Rectangle()
                            .fill(segmentColor(index, isToday: isToday))
                            .frame(width: max(0, geo.size.width * ratio))
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                ForEach(costProviders) { provider in
                    if let cost = day.costs[provider], cost > 0 {
                        Text("\(provider.capabilities.shortBadge) \(formatWholeCost(cost))")
                    }
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(.textSecondary)
            .frame(width: 92, alignment: .trailing)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isToday ? .cardFillStrong : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Pricing Info

    private var pricingInfoSection: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("How costs are calculated")
            Image(systemName: "info.circle")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.textSecondary)
        .contentShape(Rectangle())
        .onHover { showingCalculationInfo = $0 }
        .popover(isPresented: $showingCalculationInfo, arrowEdge: .bottom) {
            calculationInfo
                .padding(12)
                .frame(width: 320)
        }
        .sectionPadding()
    }

    private var calculationInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How costs are calculated")
                .font(.caption.weight(.semibold))
            Text("AccountDock reads local provider activity and prices each request using that provider’s model-specific input, output, cache, long-context, and recorded reasoning data when available. Provider totals are combined consistently across Today, summary periods, and Daily History. Subscription quota usage is separate from these API-equivalent cost estimates.")
                .font(.caption2)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let v = VerifiedAgainst.load() {
                Label(
                    "Claude totals were verified against ccusage \(v.ccusageVersion) on \(v.verifiedOn). Other providers use their native local token records and provider pricing.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.4f", cost)
        }
    }

    private func formatWholeCost(_ cost: Double) -> String {
        String(format: "$%.0f", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func todayDisplayDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: Date())
    }

    private func shortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateStr }
        return "\(month)/\(day)"
    }
}
