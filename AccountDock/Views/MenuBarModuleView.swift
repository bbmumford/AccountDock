import SwiftUI

/// Renders one configured menu-bar module in the iStats-style two-line layout:
/// a short uppercase label on top and either a horizontal bar (for utilization
/// percentages) or a value text (for absolute numbers / times) on the bottom.
struct MenuBarModuleView: View {
    let module: MenuBarModule
    let appState: AppState
    let showFullEmail: Bool
    /// Tick value that recomputes reset countdowns once a minute.
    /// Passed in (and ignored by non-countdown modules) so the parent timer
    /// can drive view updates without each module owning a timer.
    let tick: Date

    // Fixed row geometry so every module shares the same baseline grid: the
    // label row and the value/bar row line up across all modules regardless of
    // whether the bottom row is text (taller) or a bar (shorter).
    private let labelRowHeight: CGFloat = 9
    private let valueRowHeight: CGFloat = 13

    var body: some View {
        if let scopedUsage {
            providerUsageView(
                provider: scopedUsage.provider,
                window: scopedUsage.window,
                presentation: scopedUsage.presentation
            )
        } else if module == .claudeSessionReset {
            resetCell(provider: .claudeCode, window: .session)
        } else if module == .claudeWeeklyReset {
            resetCell(provider: .claudeCode, window: .weekly)
        } else if module == .codexSessionReset {
            resetCell(provider: .codex, window: .session)
        } else if module == .codexWeeklyReset {
            resetCell(provider: .codex, window: .weekly)
        } else if module == .kimiSessionReset {
            resetCell(provider: .kimi, window: .session)
        } else if module == .kimiMonthlyReset {
            resetCell(provider: .kimi, window: .weekly)
        } else if module == .account {
            // Account is shown as a single line (no label) — the name is
            // self-identifying and the `@` label added noise. No height frame:
            // wrapping the Text in a fixed-height frame truncated it.
            Text(accountText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()
        } else {
            VStack(alignment: .center, spacing: 0) {
                Text(module.compactLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.2)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(height: labelRowHeight)

                valueRow
                    .frame(height: valueRowHeight)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var valueRow: some View {
        switch module {
        case .claudeSession, .claudeWeekly, .claudeSessionPercent, .claudeWeeklyPercent,
             .codexSession, .codexWeekly, .codexSessionPercent, .codexWeeklyPercent,
             .kimiSession, .kimiMonthly, .kimiSessionPercent, .kimiMonthlyPercent,
             .claudeUsage, .codexUsage:
            EmptyView()

        case .claudeSessionReset:
            resetText(provider: .claudeCode, window: .session)
        case .claudeWeeklyReset:
            resetText(provider: .claudeCode, window: .weekly)
        case .codexSessionReset:
            resetText(provider: .codex, window: .session)
        case .codexWeeklyReset:
            resetText(provider: .codex, window: .weekly)
        case .kimiSessionReset:
            resetText(provider: .kimi, window: .session)
        case .kimiMonthlyReset:
            resetText(provider: .kimi, window: .weekly)

        case .account:
            Text(accountText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionBar:
            UtilizationBar(utilization: sessionUtilization, markerPercent: sessionTimeElapsed)

        case .weeklyBar:
            UtilizationBar(utilization: weeklyUtilization, markerPercent: weeklyTimeElapsed)

        case .sessionBarPlain:
            UtilizationBar(utilization: sessionUtilization)

        case .weeklyBarPlain:
            UtilizationBar(utilization: weeklyUtilization)

        case .dailyCost:
            Text(dailyCostText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .sessionReset:
            Text(sessionResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()

        case .weeklyReset:
            Text(weeklyResetText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    // MARK: - Data accessors

    private enum UsageWindow { case session, weekly }
    private enum UsagePresentation { case bar, percentage }

    private var scopedUsage: (
        provider: AIProviderType,
        window: UsageWindow,
        presentation: UsagePresentation
    )? {
        switch module {
        case .claudeSession: return (.claudeCode, .session, .bar)
        case .claudeWeekly: return (.claudeCode, .weekly, .bar)
        case .claudeSessionPercent: return (.claudeCode, .session, .percentage)
        case .claudeWeeklyPercent: return (.claudeCode, .weekly, .percentage)
        case .codexSession: return (.codex, .session, .bar)
        case .codexWeekly: return (.codex, .weekly, .bar)
        case .codexSessionPercent: return (.codex, .session, .percentage)
        case .codexWeeklyPercent: return (.codex, .weekly, .percentage)
        case .kimiSession: return (.kimi, .session, .bar)
        case .kimiMonthly: return (.kimi, .weekly, .bar)
        case .kimiSessionPercent: return (.kimi, .session, .percentage)
        case .kimiMonthlyPercent: return (.kimi, .weekly, .percentage)
        default: return nil
        }
    }

    private func providerUsageView(
        provider: AIProviderType,
        window: UsageWindow,
        presentation: UsagePresentation
    ) -> some View {
        let account = appState.activeAccount(for: provider)
        let utilization: Double? = account.flatMap {
            switch window {
            case .session: return appState.accountUsage[$0.id]?.fiveHour?.utilization
            case .weekly: return appState.accountUsage[$0.id]?.sevenDay?.utilization
            }
        }

        return Group {
            switch presentation {
            case .bar:
                UtilizationBar(utilization: utilization)
                    .frame(height: 22)
                    .padding(.horizontal, 2)
            case .percentage:
                HStack(spacing: 3) {
                    Image(systemName: window == .session ? "clock" : "calendar")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(utilization.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 13.2, weight: .regular).monospacedDigit())
                }
                .frame(height: 22)
            }
        }
        .fixedSize()
    }

    private func resetText(provider: AIProviderType, window: UsageWindow) -> some View {
        let account = appState.activeAccount(for: provider)
        let value: String? = account.flatMap {
            switch window {
            case .session: return appState.accountUsage[$0.id]?.fiveHour?.compactResetString
            case .weekly: return appState.accountUsage[$0.id]?.sevenDay?.compactResetString
            }
        }
        return Text(value ?? "—")
            .font(.system(size: 13.2, weight: .regular).monospacedDigit())
            .foregroundStyle(.primary)
            .fixedSize()
    }

    private func resetCell(provider: AIProviderType, window: UsageWindow) -> some View {
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

    private var accountText: String {
        guard let account = appState.activeAccount else { return "—" }
        let name = account.effectiveDisplayName(obfuscated: !showFullEmail)
        return name.isEmpty ? "—" : name
    }

    private var sessionUtilization: Double? {
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.fiveHour?.utilization
    }

    private var weeklyUtilization: Double? {
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.sevenDay?.utilization
    }

    private var sessionTimeElapsed: Double? {
        _ = tick // recompute as the window progresses
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.fiveHour?
            .elapsedPercent(windowSeconds: RateLimitWindow.fiveHourSeconds)
    }

    private var weeklyTimeElapsed: Double? {
        _ = tick
        guard let id = appState.activeAccount?.id else { return nil }
        return appState.accountUsage[id]?.sevenDay?
            .elapsedPercent(windowSeconds: RateLimitWindow.sevenDaySeconds)
    }

    private var dailyCostText: String {
        let cost = appState.combinedTodayCost
        guard cost > 0 else { return "—" }
        return String(format: "$%.2f", cost)
    }

    private var sessionResetText: String {
        // `tick` is read so SwiftUI recomputes on each timer fire.
        _ = tick
        guard let id = appState.activeAccount?.id,
              let s = appState.accountUsage[id]?.fiveHour?.compactResetString else {
            return "—"
        }
        return s
    }

    private var weeklyResetText: String {
        _ = tick
        guard let id = appState.activeAccount?.id,
              let s = appState.accountUsage[id]?.sevenDay?.compactResetString else {
            return "—"
        }
        return s
    }
}

/// Hollow rounded capsule with an inner filled pill whose width reflects
/// `utilization` (a 0–100 percentage, normalized to 0–1). Fill is monochrome
/// (adapts to the light/dark menu bar), turning red above 90% (and staying red
/// on overage, clamped at 100%).
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

    private var clamped: Double { min(max((utilization ?? 0) / 100.0, 0), 1) }

    private var fillColor: Color {
        guard let u = utilization, u > 90 else { return .primary }
        return .red
    }

    /// X offset (within the inset interior) of the pace tick, if shown.
    /// Suppressed when there's no usage data so a dashed "no data" bar can't
    /// sprout a stray tick.
    private var markerX: CGFloat? {
        guard utilization != nil, let m = markerPercent else { return nil }
        let frac = min(max(m / 100.0, 0), 1)
        return innerInset + (trackWidth - innerInset * 2) * frac
    }

    // Restored verbatim from the original (commit b012f0d): a left-anchored
    // inset Capsule fill. Plus one optional vertical pace tick. No clip /
    // compositingGroup / blend — those are what broke it.
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
