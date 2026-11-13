import Foundation

/// Today's work across the providers AccountDock shows: the totals the
/// usage dashboard, the cost tab, the menu bar and the widget display, so
/// they always agree. Built by `make` from each provider's day
/// (`AppState.todaySummary` reads them from `providerCosts`).
struct TodaySummary {
    /// One provider's work today, from its local usage records.
    struct ProviderDay: Equatable {
        var cost: Double = 0
        var tokens = 0
        var turns = 0
        var linesChanged = 0
        var activeMinutes = 0
        /// Model responses (Claude Code: turns) by the model's recorded name.
        var modelActivity: [String: Int] = [:]

        var hasActivity: Bool { cost > 0 || tokens > 0 || turns > 0 }
    }

    /// Providers counted, in registry order: implemented and not hidden.
    let included: [AIProviderType]
    /// The counted providers' days, for those with activity today.
    let byProvider: [(provider: AIProviderType, day: ProviderDay)]
    let cost: Double
    let tokens: Int
    let turns: Int
    let linesChanged: Int
    let activeMinutes: Int

    /// The counted providers whose records report `metric`.
    func reporting(_ metric: ActivityMetric) -> [AIProviderType] {
        included.filter { $0.capabilities.activityMetrics.contains(metric) }
    }

    /// One provider's day, empty when it is not counted or did nothing.
    func day(for provider: AIProviderType) -> ProviderDay {
        byProvider.first { $0.provider == provider }?.day ?? ProviderDay()
    }

    /// Sums the days of every implemented provider not in `hidden`. Each
    /// metric counts only providers whose `activityMetrics` report it, so a
    /// provider whose records leave a metric at zero does not dilute it;
    /// tokens count for every provider.
    static func make(days: [AIProviderType: ProviderDay], hidden: Set<AIProviderType>) -> TodaySummary {
        let included = AIProviderType.implementedProviders.filter { !hidden.contains($0) }
        func total<T: AdditiveArithmetic>(_ metric: ActivityMetric?, _ value: (ProviderDay) -> T) -> T {
            included
                .filter { provider in metric.map { provider.capabilities.activityMetrics.contains($0) } ?? true }
                .reduce(T.zero) { $0 + value(days[$1] ?? ProviderDay()) }
        }
        return TodaySummary(
            included: included,
            byProvider: included.compactMap { provider in
                days[provider].flatMap { $0.hasActivity ? (provider, $0) : nil }
            },
            cost: total(.cost) { $0.cost },
            tokens: total(nil) { $0.tokens },
            turns: total(.turns) { $0.turns },
            linesChanged: total(.linesChanged) { $0.linesChanged },
            activeMinutes: total(.activeTime) { $0.activeMinutes }
        )
    }
}
