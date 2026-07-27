import SwiftUI

/// Unified provider cost tab with today's combined total and available history.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var visibleDailyCount = 7

    private struct ProviderModelCost: Identifiable {
        let id: String
        let provider: String
        let icon: String
        let model: String
        let cost: Double
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
        let summary = appState.costSummary
        let today = summary.dailyCosts.first(where: { $0.date == todayString() })

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

            HStack(spacing: 10) {
                providerTodayCost(
                    name: "Claude",
                    icon: AIProviderType.claudeCode.iconName,
                    cost: summary.todayCost
                )
                providerTodayCost(
                    name: "Codex",
                    icon: AIProviderType.codex.iconName,
                    cost: max(0, appState.combinedTodayCost - summary.todayCost)
                )
            }

            let modelCosts = combinedTodayModelCosts(claude: today?.modelBreakdown ?? [:])
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
                            Text(formatCost(item.cost))
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.textSecondary)
                        }
                        .font(.caption2)
                    }
                }

                if let today {
                    HStack {
                        Label("Claude: \(today.sessionCount) sessions", systemImage: "terminal")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                        Spacer()
                        Text("\(formatTokenCount(today.totalTokens)) tokens")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private func combinedTodayModelCosts(claude: [String: Double]) -> [ProviderModelCost] {
        let claudeRows = claude.compactMap { model, cost -> ProviderModelCost? in
            guard cost > 0 else { return nil }
            return ProviderModelCost(
                id: "claude-\(model)",
                provider: "Claude",
                icon: AIProviderType.claudeCode.iconName,
                model: model,
                cost: cost
            )
        }
        let codexRows = appState.codexTodayModelCosts.compactMap { model, cost -> ProviderModelCost? in
            guard cost > 0 else { return nil }
            return ProviderModelCost(
                id: "codex-\(model)",
                provider: "Codex",
                icon: AIProviderType.codex.iconName,
                model: model,
                cost: cost
            )
        }
        return (claudeRows + codexRows).sorted { $0.cost > $1.cost }
    }

    private func providerTodayCost(name: String, icon: String, cost: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(name)
            Spacer()
            Text(formatCost(cost))
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

        let last7 = combinedCostForLastDays(7, today: todayStr, formatter: formatter)
        let last30 = combinedCostForLastDays(30, today: todayStr, formatter: formatter)

        return HStack(spacing: 10) {
            periodCard(title: "Last 7 Days", cost: last7)
            periodCard(title: "Last 30 Days", cost: last30)
        }
        .sectionPadding()
    }

    private func combinedCostForLastDays(_ days: Int, today: String, formatter: DateFormatter) -> Double {
        guard let todayDate = formatter.date(from: today) else { return 0 }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let start = formatter.string(from: startDate)
        return combinedDailyCosts
            .filter { $0.date >= start && $0.date <= today }
            .reduce(0) { $0 + $1.total }
    }

    private func periodCard(title: LocalizedStringKey, cost: Double) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.textSecondary)
            Text(formatCost(cost))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
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
                    legendDot(color: .brand, label: "Claude")
                    legendDot(color: Color.brand.opacity(0.48), label: "Codex")
                }
                Text("Total: \(formatCost(visibleCosts.reduce(0) { $0 + $1.total }))")
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
        let claude: Double
        let codex: Double
        var total: Double { claude + codex }
        var id: String { date }
    }

    private var combinedDailyCosts: [CombinedDailyCost] {
        let claude = Dictionary(
            uniqueKeysWithValues: appState.costSummary.dailyCosts.map { ($0.date, $0.totalCost) }
        )
        return Set(claude.keys).union(appState.codexDailyCosts.keys)
            .map {
                CombinedDailyCost(
                    date: $0,
                    claude: claude[$0] ?? 0,
                    codex: appState.codexDailyCosts[$0] ?? 0
                )
            }
            .sorted { $0.date > $1.date }
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
        let claudeRatio = maxCost > 0 ? day.claude / maxCost : 0
        let codexRatio = maxCost > 0 ? day.codex / maxCost : 0

        return HStack(spacing: 8) {
            Text(shortDate(day.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? .brand : .secondary)
                .frame(width: 40, alignment: .leading)

            Text(formatWholeCost(day.total))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isToday ? .brand : .primary)
                .frame(width: 56, alignment: .trailing)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(isToday ? Color.brand : Color.brand.opacity(0.72))
                        .frame(width: max(0, geo.size.width * claudeRatio))
                    Rectangle()
                        .fill(Color.brand.opacity(isToday ? 0.48 : 0.34))
                        .frame(width: max(0, geo.size.width * codexRatio))
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                if day.claude > 0 {
                    Text("C \(formatWholeCost(day.claude))")
                }
                if day.codex > 0 {
                    Text("X \(formatWholeCost(day.codex))")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How We Calculate")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                Text("Costs are calculated from local Claude and Codex session logs. Each daily bar stacks Claude and Codex into one combined total.")
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let v = VerifiedAgainst.load() {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Verified against ccusage \(v.ccusageVersion) on \(v.verifiedOn) — \(v.windowDays)-day total matched to the cent.")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .cardStyle()
            .sectionPadding()
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
        if count >= 1_000_000 {
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
