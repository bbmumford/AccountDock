import WidgetKit
import SwiftUI

// MARK: - Brand Color

private let brandColor = Color(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0)

// MARK: - Timeline Entry

struct AccountDockEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    static var placeholder: AccountDockEntry {
        AccountDockEntry(
            date: .now,
            data: WidgetData(
                providerOrder: ["Claude Code", "Codex"],
                accounts: [
                    WidgetAccountData(
                        provider: "Claude Code",
                        providerName: "Claude",
                        iconName: "brain.head.profile",
                        email: "us***@ex***.com",
                        displayName: "My Org",
                        subscriptionType: "Pro",
                        isActive: true,
                        windows: [
                            WidgetWindow(label: "Session", utilization: 42, resetsAt: .now.addingTimeInterval(8_100)),
                            WidgetWindow(label: "Weekly limit", utilization: 28, resetsAt: .now.addingTimeInterval(259_200)),
                        ],
                        hasError: false,
                        errorMessage: nil
                    ),
                    WidgetAccountData(
                        provider: "Codex",
                        providerName: "Codex",
                        iconName: "chevron.left.forwardslash.chevron.right",
                        email: "co***@ex***.com",
                        displayName: "Plus",
                        subscriptionType: "Plus",
                        isActive: true,
                        windows: [
                            WidgetWindow(label: "Weekly", utilization: 14, resetsAt: .now.addingTimeInterval(518_400)),
                        ],
                        hasError: false,
                        errorMessage: nil
                    ),
                ],
                todayCost: 3.45,
                conversationTurns: 18,
                activeCodingTime: "1h 30m",
                linesWritten: 326,
                modelUsage: ["Opus": 12, "Sonnet": 5, "GPT 5.3 Codex": 18],
                lastUpdated: .now
            )
        )
    }
}

// MARK: - Timeline Provider

struct AccountDockProvider: TimelineProvider {
    func placeholder(in context: Context) -> AccountDockEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (AccountDockEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccountDockEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry() -> AccountDockEntry {
        AccountDockEntry(date: .now, data: WidgetData.load())
    }
}

// MARK: - Widget Entry View

struct AccountDockWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: AccountDockEntry

    var body: some View {
        if let data = entry.data {
            switch family {
            case .systemSmall:
                SmallWidgetView(data: data)
            case .systemMedium:
                MediumWidgetView(data: data)
            case .systemLarge:
                LargeWidgetView(data: data)
            default:
                SmallWidgetView(data: data)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(brandColor)
                .widgetAccentable()
            Text("Open AccountDock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("to load data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared Pieces

/// The header row: one icon per provider shown, then the app's name.
private struct ProviderIconsHeader: View {
    let accounts: [WidgetAccountData]
    var font: Font = .caption.weight(.semibold)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                Image(systemName: account.displayIconName)
                    .font(.caption)
                    .foregroundStyle(brandColor)
                    .widgetAccentable()
            }
            Text("AccountDock")
                .font(font)
                .lineLimit(1)
        }
    }
}

/// A thin horizontal bar filled to `level`; empty when the level is unknown.
private struct LevelBar: View {
    let level: UsageLevel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.quaternary)
                    .frame(height: 5)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(level.color(normal: .green))
                    .frame(width: max(0, geo.size.width * level.fraction), height: 5)
            }
        }
        .frame(height: 5)
    }
}

/// Time left until `date`, counting down live between timeline reloads;
/// nothing once it has passed or when the reset is unknown.
private struct ResetCountdown: View {
    let date: Date?
    var font: Font = .caption2

    var body: some View {
        if let date, date > .now {
            Text(date, style: .relative)
                .font(font)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Small Widget

private struct SmallWidgetView: View {
    let data: WidgetData

    private var providerAccounts: [WidgetAccountData] { data.providerAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProviderIconsHeader(accounts: providerAccounts)
                Spacer()
            }

            if !providerAccounts.isEmpty {
                Spacer(minLength: 2)
                ForEach(Array(providerAccounts.enumerated()), id: \.offset) { _, account in
                    compactUsageBar(account)
                }
                Spacer(minLength: 2)
                HStack {
                    Text(formatCost(data.todayCost))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("combined today")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                Spacer()
                Text("No accounts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// The provider's tightest window, labelled with the provider's name.
    private func compactUsageBar(_ account: WidgetAccountData) -> some View {
        let level = UsageLevel(utilization: account.hasError ? nil : account.tightestWindow?.utilization)
        return VStack(spacing: 3) {
            HStack {
                Text(verbatim: account.displayProviderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(level.percentText)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(level.color(normal: .green))
            }
            LevelBar(level: level)
        }
    }
}

// MARK: - Medium Widget

private struct MediumWidgetView: View {
    let data: WidgetData

    private var providerAccounts: [WidgetAccountData] { data.providerAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                ProviderIconsHeader(accounts: providerAccounts, font: .caption.weight(.medium))
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // Main content: usage bars on left, activity on right
            HStack(spacing: 12) {
                // Left: each provider's tightest window
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(providerAccounts.enumerated()), id: \.offset) { _, account in
                        if let window = account.tightestWindow {
                            usageBar(
                                label: "\(account.displayProviderName) · \(window.label)",
                                utilization: account.hasError ? nil : window.utilization,
                                resetsAt: window.resetsAt
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)

                // Right: Activity stats
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    statRow(icon: "dollarsign.circle", label: "Cost", value: formatCost(data.todayCost), valueColor: .green)
                    Spacer(minLength: 4)
                    statRow(icon: "bubble.left.and.bubble.right", label: "Turns", value: "\(data.conversationTurns)")
                    Spacer(minLength: 4)
                    statRow(icon: "clock", label: "Active", value: data.activeCodingTime)
                    Spacer(minLength: 4)
                    statRow(icon: "doc.text", label: "Lines", value: "\(data.linesWritten)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func usageBar(label: String, utilization: Double?, resetsAt: Date?) -> some View {
        let level = UsageLevel(utilization: utilization)
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                ResetCountdown(date: resetsAt)
                Text(level.percentText)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(level.color(normal: .green))
            }
            LevelBar(level: level)
        }
    }

    private func statRow(icon: String, label: LocalizedStringKey, value: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Large Widget

private struct LargeWidgetView: View {
    let data: WidgetData

    private var visibleModels: [(name: String, count: Int)] {
        data.modelUsage
            .filter { $0.value > 0 }
            .sorted {
                $0.value == $1.value
                    ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                    : $0.value > $1.value
            }
            .prefix(4)
            .map { (name: $0.key, count: $0.value) }
    }

    /// Accounts grouped by provider, in the providers' display order.
    private var orderedAccounts: [WidgetAccountData] {
        let order = data.orderedProviders
        return data.accounts.enumerated().sorted { lhs, rhs in
            let left = lhs.element.provider.flatMap(order.firstIndex(of:)) ?? order.count
            let right = rhs.element.provider.flatMap(order.firstIndex(of:)) ?? order.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline)
                    .foregroundStyle(brandColor)
                    .widgetAccentable()
                Text("AccountDock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Today's activity + model usage
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    activityStat(icon: "bubble.left.and.bubble.right", value: "\(data.conversationTurns)", label: "Turns")
                    activityStat(icon: "clock", value: data.activeCodingTime, label: "Active")
                    activityStat(icon: "doc.text", value: "\(data.linesWritten)", label: "Lines")
                    activityStat(icon: "dollarsign.circle", value: formatCost(data.todayCost), label: "Cost", valueColor: .green)
                }

                if !visibleModels.isEmpty {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 0.5)
                        .padding(.horizontal, 8)

                    HStack(spacing: 0) {
                        ForEach(Array(visibleModels.enumerated()), id: \.offset) { index, model in
                            modelStat(
                                name: model.name,
                                count: model.count,
                                color: modelColor(index)
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .background(brandColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // Per-account cards — expand to fill remaining space
            ForEach(Array(orderedAccounts.enumerated()), id: \.offset) { _, account in
                accountCard(account)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, valueColor: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueColor)
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func modelStat(name: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? .primary : .quaternary)
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(count > 0 ? .tertiary : .quaternary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func modelColor(_ index: Int) -> Color {
        [brandColor, .purple, .blue, .green][index % 4]
    }

    private func accountCard(_ account: WidgetAccountData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Account header
            HStack(spacing: 6) {
                Image(systemName: account.displayIconName)
                    .font(.caption2)
                    .foregroundStyle(account.isActive ? brandColor : .secondary)
                Text(account.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if account.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule()
                                .stroke(Color.green, lineWidth: 1)
                        )
                }
                Spacer()
                if let sub = account.subscriptionType {
                    Text(sub)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(brandColor)
                }
            }

            if account.hasError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                ForEach(Array(account.displayWindows.enumerated()), id: \.offset) { _, window in
                    accountUsageBar(window)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(account.isActive ? brandColor.opacity(0.22) : Color.white.opacity(0.04))
                .strokeBorder(account.isActive ? brandColor.opacity(0.6) : Color.white.opacity(0.08), lineWidth: account.isActive ? 1.0 : 0.5)
        )
    }

    private func accountUsageBar(_ window: WidgetWindow) -> some View {
        let level = UsageLevel(utilization: window.utilization)
        return HStack(spacing: 6) {
            Text(LocalizedStringKey(window.label))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 76, alignment: .leading)
            LevelBar(level: level)
            ResetCountdown(date: window.resetsAt, font: .system(size: 9))
                .frame(width: 58, alignment: .trailing)
            Text(level.percentText)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(level.color(normal: .green))
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Circular (Rings) Widget

private struct CircleWidgetView: View {
    let data: WidgetData

    private var providerAccounts: [WidgetAccountData] { data.providerAccounts }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ProviderIconsHeader(accounts: providerAccounts)
                Spacer()
            }

            Spacer(minLength: 0)

            if !providerAccounts.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(providerAccounts.enumerated()), id: \.offset) { _, account in
                        let window = account.tightestWindow
                        ringStat(
                            label: account.displayProviderName,
                            resetsAt: window?.resetsAt,
                            level: UsageLevel(utilization: account.hasError ? nil : window?.utilization)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("No accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func ringStat(label: String, resetsAt: Date?, level: UsageLevel) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: level.fraction)
                    .stroke(level.color(normal: .green), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(level.percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .aspectRatio(1, contentMode: .fit)

            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ResetCountdown(date: resetsAt, font: .system(size: 9))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CircleWidgetEntryView: View {
    var entry: AccountDockEntry

    var body: some View {
        if let data = entry.data {
            CircleWidgetView(data: data)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 28))
                    .foregroundStyle(brandColor)
                Text("Open AccountDock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to load data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helpers

private func formatCost(_ cost: Double) -> String {
    UsageFormat.cost(cost)
}

// MARK: - Widget Definition

struct AccountDockWidget: Widget {
    let kind: String = "AccountDockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccountDockProvider()) { entry in
            AccountDockWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AccountDock")
        .description("Monitor your coding-agent accounts from one place.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AccountDockCircleWidget: Widget {
    let kind: String = "AccountDockCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccountDockProvider()) { entry in
            CircleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AccountDock Rings")
        .description("Each provider's tightest limit, shown together as progress rings.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle

@main
struct AccountDockWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        AccountDockWidget()
        AccountDockCircleWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    AccountDockWidget()
} timeline: {
    AccountDockEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    AccountDockWidget()
} timeline: {
    AccountDockEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    AccountDockWidget()
} timeline: {
    AccountDockEntry.placeholder
}
