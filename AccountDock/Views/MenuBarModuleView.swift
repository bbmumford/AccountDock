import SwiftUI

/// Renders one configured menu-bar module in the iStats-style two-line layout:
/// a short uppercase label on top and either a horizontal bar (for utilization
/// percentages) or a value text (for absolute numbers / times) on the bottom.
struct MenuBarModuleView: View {
    let module: MenuBarModule
    let appState: AppState
    /// Tick value that recomputes reset countdowns and elapsed-time markers.
    /// Passed in (and ignored by other modules) so the parent timer can
    /// drive view updates without each module owning a timer.
    let tick: Date

    // Fixed row geometry so every module shares the same baseline grid: the
    // label row and the value/bar row line up across all modules regardless of
    // whether the bottom row is text (taller) or a bar (shorter).
    private let labelRowHeight: CGFloat = 9
    private let valueRowHeight: CGFloat = 13

    var body: some View {
        switch module.kind {
        case .provider(let provider, .percentages):
            combinedPercentageView(provider: provider)
        case .provider(let provider, let metric):
            if let window = metric.window {
                switch metric {
                case .sessionReset, .longReset:
                    resetCell(provider: provider, window: window)
                case .sessionPercent, .longPercent:
                    providerUsageView(provider: provider, window: window, presentation: .percentage)
                default:
                    providerUsageView(provider: provider, window: window, presentation: .bar)
                }
            }
        case .dailyCost:
            VStack(alignment: .center, spacing: 0) {
                Text(module.compactLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(height: labelRowHeight)

                Text(dailyCostText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(height: valueRowHeight)
            }
            .fixedSize()
        }
    }

    // MARK: - Data accessors

    private enum UsagePresentation { case bar, percentage }

    /// The active account's reading of one of `provider`'s windows.
    private func activeWindow(provider: AIProviderType, window: MenuBarModule.Window) -> UsageWindow? {
        guard let account = appState.activeAccount(for: provider),
              let usage = appState.accountUsage[account.id] else { return nil }
        switch window {
        case .session: return usage.fiveHour
        case .long: return usage.sevenDay
        }
    }

    @ViewBuilder
    private func combinedPercentageView(provider: AIProviderType) -> some View {
        let usage = appState.activeAccount(for: provider).flatMap { appState.accountUsage[$0.id] }
        let session = usage?.fiveHour?.utilization
        let longWindow = usage?.sevenDay?.utilization
        ZStack {
            // An account without a session window shows its long window alone.
            quotaRing(
                usage?.reportsNoSessionWindow == true ? longWindow : session,
                diameter: 20,
                lineWidth: 2.5,
                unavailable: (longWindow ?? 0) >= 100
            )
            if usage?.reportsNoSessionWindow != true {
                quotaRing(longWindow, diameter: 12, lineWidth: 2.5)
            }
        }
        .frame(width: 20, height: 20)
        .frame(height: 22)
        .fixedSize()
        .help(combinedPercentageHelp(provider: provider, session: session, longWindow: longWindow))
    }

    private func quotaRing(
        _ utilization: Double?,
        diameter: CGFloat,
        lineWidth: CGFloat,
        unavailable: Bool = false
    ) -> some View {
        ZStack {
            if unavailable {
                EvenDashedCircle(color: Color.primary.opacity(0.45), lineWidth: lineWidth)
            } else {
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
            }
            let level = UsageLevel(utilization: utilization)
            if level.isKnown, !unavailable {
                Circle()
                    .trim(from: 0, to: level.fraction)
                    .stroke(
                        level.color(normal: .green),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func combinedPercentageHelp(
        provider: AIProviderType,
        session: Double?,
        longWindow: Double?
    ) -> String {
        let sessionText = UsageLevel(utilization: session).percentText
        let longText = UsageLevel(utilization: longWindow).percentText
        return "\(provider.capabilities.sessionQuotaLabel): \(sessionText) · \(provider.capabilities.weeklyQuotaLabel): \(longText)"
    }

    private func providerUsageView(
        provider: AIProviderType,
        window: MenuBarModule.Window,
        presentation: UsagePresentation
    ) -> some View {
        let reading = activeWindow(provider: provider, window: window)
        let utilization = reading?.utilization
        _ = tick // the elapsed marker moves with the clock

        return Group {
            switch presentation {
            case .bar:
                UtilizationBar(utilization: utilization, markerPercent: reading?.elapsedPercent())
                    .frame(height: 22)
                    .padding(.horizontal, 2)
            case .percentage:
                HStack(spacing: 3) {
                    Image(systemName: window == .session ? "clock" : "calendar")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(UsageLevel(utilization: utilization).percentText)
                        .font(.system(size: 13.2, weight: .regular).monospacedDigit())
                }
                .frame(height: 22)
            }
        }
        .fixedSize()
    }

    private func resetText(provider: AIProviderType, window: MenuBarModule.Window) -> some View {
        _ = tick // the countdown moves with the clock
        let value = activeWindow(provider: provider, window: window)?.compactResetString
        return Text(value ?? "—")
            .font(.system(size: 13.2, weight: .regular).monospacedDigit())
            .foregroundStyle(.primary)
            .fixedSize()
    }

    private func resetCell(provider: AIProviderType, window: MenuBarModule.Window) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
            resetText(provider: provider, window: window)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .fixedSize()
    }

    private var dailyCostText: String {
        let cost = appState.combinedTodayCost
        guard cost > 0 else { return "—" }
        return String(format: "$%.2f", cost)
    }
}

/// A closed dashed ring made from equal angular segments. `StrokeStyle.dash`
/// measures linear dash lengths around a circle and leaves its remainder at
/// the path seam; explicit fractions keep the closing gap identical.
private struct EvenDashedCircle: View {
    let color: Color
    let lineWidth: CGFloat
    private let segmentCount = 10
    private let filledFraction = 0.50

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                let start = Double(index) / Double(segmentCount)
                let end = start + filledFraction / Double(segmentCount)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))
    }
}

/// Hollow rounded capsule with an inner filled pill whose width reflects
/// `utilization` (a 0–100 percentage, normalized to 0–1). Fill is monochrome
/// (adapts to the light/dark menu bar) until `UsageLevel` rates the window
/// high or critical, which colour it orange or red (clamped at 100% on
/// overage).
///
/// `markerPercent` (0–100, optional) draws a thin vertical "pace" tick at the
/// fraction of the rate-limit window already elapsed. Compare the fill to the
/// tick: fill past the tick = burning faster than the clock; behind = slower.
private struct UtilizationBar: View {
    /// 0–100 percentage (as returned by the usage API), or nil if unavailable.
    let utilization: Double?
    /// 0–100 time-elapsed percentage for the pace tick, or nil to hide it.
    var markerPercent: Double? = nil

    var trackWidth: CGFloat = 34
    var trackHeight: CGFloat = 10
    private let strokeWidth: CGFloat = 1
    private let innerInset: CGFloat = 1.5

    private var level: UsageLevel { UsageLevel(utilization: utilization) }

    private var clamped: Double { level.fraction }

    private var fillColor: Color { level.color(normal: .primary) }

    /// X offset (within the inset interior) of the pace tick, if shown.
    /// Suppressed when there's no usage data so a dashed "no data" bar can't
    /// sprout a stray tick.
    private var markerX: CGFloat? {
        guard utilization != nil, let m = markerPercent else { return nil }
        let frac = min(max(m / 100.0, 0), 1)
        return innerInset + (trackWidth - innerInset * 2) * frac
    }

    // A left-anchored inset Capsule fill and one optional vertical pace
    // tick, stacked without clip, compositingGroup or blend modifiers.
    var body: some View {
        ZStack(alignment: .leading) {
            // Track — hollow capsule outline.
            Capsule()
                .stroke(
                    Color.primary.opacity(utilization == nil ? 0.25 : 0.55),
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        dash: utilization == nil ? [2, 2] : []
                    )
                )
                .frame(width: trackWidth, height: trackHeight)

            // Fill — inset pill scaled to utilization. Omitted entirely when
            // no data so a missing value is visually distinct from 0%.
            if utilization != nil {
                Capsule()
                    .fill(fillColor)
                    .frame(
                        width: max(
                            0,
                            (trackWidth - innerInset * 2) * clamped
                        ),
                        height: trackHeight - innerInset * 2
                    )
                    .padding(.leading, innerInset)
            }

            // Pace tick — time elapsed in the window. Brand color so it stays
            // visible over both the monochrome fill and the empty track.
            if let x = markerX {
                Rectangle()
                    .fill(Color.brand)
                    .frame(width: 1.5, height: trackHeight - strokeWidth)
                    .offset(x: x - 0.75)
            }
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}
