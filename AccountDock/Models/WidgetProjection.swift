import Foundation

/// Builds the widget's `WidgetData` from the app's accounts, readings and
/// today's totals, with every label, icon and window decided here from the
/// providers' capabilities; the widget target cannot read
/// `ProviderCapabilities`, so it renders exactly this. Called by
/// `AppState.updateWidgetData`.
enum WidgetProjection {
    /// An account's windows in display order: the session window, the long
    /// window, then each model's own weekly limit. A window the reading does
    /// not carry is left out, so an account without a session window has
    /// one window fewer.
    static func windows(_ usage: UsageAPIResponse?, provider: AIProviderType) -> [WidgetWindow] {
        guard let usage else { return [] }
        let capabilities = provider.capabilities
        var windows: [WidgetWindow] = []
        if let session = usage.fiveHour {
            windows.append(WidgetWindow(label: capabilities.sessionQuotaLabel,
                                        utilization: session.utilization, resetsAt: session.resetsAtDate))
        }
        if let long = usage.sevenDay {
            windows.append(WidgetWindow(label: capabilities.longWindowLabel(for: long),
                                        utilization: long.utilization, resetsAt: long.resetsAtDate))
        }
        for limit in usage.modelWeeklyLimits {
            windows.append(WidgetWindow(label: "\(limit.model) weekly", utilization: limit.percent,
                                        resetsAt: limit.resetsAt.flatMap(UsageWindow.parseProviderDate)))
        }
        return windows
    }

    /// One account as the widget shows it. `errorMessage` is the reason its
    /// usage could not be read; it marks an error only when there is no
    /// earlier reading to show.
    static func account(
        _ account: Account,
        usage: UsageAPIResponse?,
        errorMessage: String?,
        obfuscated: Bool
    ) -> WidgetAccountData {
        let capabilities = account.provider.capabilities
        return WidgetAccountData(
            provider: account.provider.rawValue,
            providerName: capabilities.displayName,
            iconName: capabilities.iconName,
            email: account.displayEmail(obfuscated: obfuscated),
            displayName: account.effectiveDisplayName(obfuscated: obfuscated),
            subscriptionType: account.displaySubscriptionType,
            isActive: account.isActive,
            windows: windows(usage, provider: account.provider),
            hasError: errorMessage != nil && usage == nil,
            errorMessage: errorMessage
        )
    }

    /// The widget's whole file. Accounts of providers `summary` does not
    /// count (hidden or not implemented) are left out; providers are
    /// ordered as their accounts first appear, the order Accounts shows.
    static func make(
        accounts: [Account],
        usage: [UUID: UsageAPIResponse],
        errorMessages: [UUID: String],
        summary: TodaySummary,
        obfuscated: Bool,
        now: Date
    ) -> WidgetData {
        let shown = accounts.filter { summary.included.contains($0.provider) }
        var order: [AIProviderType] = []
        for account in shown where !order.contains(account.provider) {
            order.append(account.provider)
        }
        var models: [String: Int] = [:]
        for entry in summary.byProvider {
            for (model, count) in entry.day.modelActivity where count > 0 {
                models[entry.provider.displayModelName(model), default: 0] += count
            }
        }
        return WidgetData(
            providerOrder: order.map(\.rawValue),
            accounts: shown.map {
                account($0, usage: usage[$0.id], errorMessage: errorMessages[$0.id], obfuscated: obfuscated)
            },
            todayCost: summary.cost,
            conversationTurns: summary.turns,
            activeCodingTime: ActivityStats(activeCodingMinutes: summary.activeMinutes).activeCodingTimeString,
            linesWritten: summary.linesChanged,
            modelUsage: models,
            lastUpdated: now
        )
    }
}
