import Foundation

/// One configurable module rendered in the macOS menu bar: a metric of one
/// provider's active account, or the total daily cost.
///
/// Display style matches iStats / Stats: two-line stacked module with a short
/// uppercase label on top and either a bar (for percentages) or a value text
/// (for absolute numbers / times) on the bottom.
///
/// Stored by `rawValue`: the provider's `storageKey` followed by the metric,
/// such as `claudeSession` or `kimiMonthlyPercent`, so every provider,
/// including one added later, offers the metrics its capabilities allow.
struct MenuBarModule: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    /// What a provider module shows of the active account's windows.
    enum Metric: CaseIterable, Sendable {
        case sessionBar, longBar, sessionPercent, longPercent, percentages, sessionReset, longReset
        /// The tightest weekly limit scoped to one model, labelled with the
        /// model's name; offered where `reportsModelWeeklyLimits`.
        case modelLimit

        var window: Window? {
            switch self {
            case .sessionBar, .sessionPercent, .sessionReset: .session
            case .longBar, .longPercent, .longReset: .long
            case .percentages, .modelLimit: nil
            }
        }

        /// The suffix after the provider's storage key; `long` names the
        /// provider's long window.
        func storageSuffix(long: String) -> String {
            switch self {
            case .sessionBar: "Session"
            case .longBar: long
            case .sessionPercent: "SessionPercent"
            case .longPercent: "\(long)Percent"
            case .percentages: "Percentages"
            case .sessionReset: "SessionReset"
            case .longReset: "\(long)Reset"
            case .modelLimit: "ModelWeekly"
            }
        }
    }

    enum Window: Sendable { case session, long }

    enum Kind: Hashable, Sendable {
        case provider(AIProviderType, Metric)
        case dailyCost
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    static func provider(_ provider: AIProviderType, _ metric: Metric) -> MenuBarModule {
        MenuBarModule(.provider(provider, metric))
    }

    static let dailyCost = MenuBarModule(.dailyCost)

    init?(rawValue: String) {
        if rawValue == "dailyCost" { self.init(.dailyCost); return }
        for provider in AIProviderType.allCases {
            let capabilities = provider.capabilities
            guard rawValue.hasPrefix(capabilities.storageKey) else { continue }
            let suffix = String(rawValue.dropFirst(capabilities.storageKey.count))
            if let metric = Metric.allCases.first(where: { $0.storageSuffix(long: capabilities.longWindowStorageName) == suffix }) {
                self.init(.provider(provider, metric))
                return
            }
        }
        return nil
    }

    var rawValue: String {
        switch kind {
        case .provider(let provider, let metric):
            provider.capabilities.storageKey + metric.storageSuffix(long: provider.capabilities.longWindowStorageName)
        case .dailyCost: "dailyCost"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let module = MenuBarModule(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown module \(raw)"))
        }
        self = module
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var provider: AIProviderType? {
        if case .provider(let provider, _) = kind { return provider }
        return nil
    }

    var metric: Metric? {
        if case .provider(_, let metric) = kind { return metric }
        return nil
    }

    /// The modules offered in Settings, in the default order: bars and
    /// percentages provider by provider, then model limits, then reset
    /// countdowns window by window, then the total daily cost. A provider
    /// offers the metrics of the windows it reports, and the model limit
    /// where `reportsModelWeeklyLimits`.
    static var allCases: [MenuBarModule] {
        let providers = AIProviderType.implementedProviders
        func offered(_ provider: AIProviderType, _ metric: Metric) -> Bool {
            let capabilities = provider.capabilities
            if metric == .modelLimit { return capabilities.reportsModelWeeklyLimits }
            return metric.window != .session || capabilities.supportsSessionQuota
        }
        func block(_ metrics: [Metric]) -> [MenuBarModule] {
            providers.flatMap { provider in metrics.filter { offered(provider, $0) }.map { Self.provider(provider, $0) } }
        }
        let resets = [Metric.longReset, .sessionReset].flatMap { metric in
            providers.filter { offered($0, metric) }.map { Self.provider($0, metric) }
        }
        return block([.sessionBar, .longBar]) + block([.sessionPercent, .longPercent, .percentages])
            + block([.modelLimit]) + resets + [.dailyCost]
    }

    /// Short uppercase label shown on the top line of the module.
    var compactLabel: String {
        switch kind {
        case .provider(let provider, let metric):
            let capabilities = provider.capabilities
            switch metric {
            case .sessionBar, .sessionPercent: return capabilities.sessionShortLabel
            case .longBar, .longPercent: return capabilities.longShortLabel
            case .percentages: return "%"
            case .sessionReset: return capabilities.sessionShortLabel + "↻"
            case .longReset: return capabilities.longShortLabel + "↻"
            case .modelLimit: return "MODEL"
            }
        case .dailyCost: return "TOTAL"
        }
    }

    /// Human-readable name shown in the Settings reorder list.
    var localizedDisplayName: String {
        switch kind {
        case .provider(let provider, let metric):
            let capabilities = provider.capabilities
            let name = capabilities.displayName
            let session = "session (\(capabilities.sessionShortLabel.lowercased()))"
            let long = capabilities.longWindowStorageName.lowercased()
            switch metric {
            case .sessionBar: return "\(name) — \(session) usage"
            case .longBar: return "\(name) — \(long) usage"
            case .sessionPercent: return "\(name) — \(session) percentage"
            case .longPercent: return "\(name) — \(long) percentage"
            case .percentages: return "\(name) — session and \(long) percentages"
            case .sessionReset: return "\(name) — session reset"
            case .longReset: return "\(name) — \(long) reset"
            case .modelLimit: return "\(name) — model weekly limit"
            }
        case .dailyCost:
            return String(localized: "Total daily cost — all accounts and providers", bundle: L10n.bundle)
        }
    }
}

extension MenuBarModule {
    static let claudeSession = provider(.claudeCode, .sessionBar)
    static let claudeWeekly = provider(.claudeCode, .longBar)
    static let claudeSessionPercent = provider(.claudeCode, .sessionPercent)
    static let claudeWeeklyPercent = provider(.claudeCode, .longPercent)
    static let claudePercentages = provider(.claudeCode, .percentages)
    static let claudeSessionReset = provider(.claudeCode, .sessionReset)
    static let claudeWeeklyReset = provider(.claudeCode, .longReset)
    static let claudeModelWeekly = provider(.claudeCode, .modelLimit)
    static let codexSession = provider(.codex, .sessionBar)
    static let codexWeekly = provider(.codex, .longBar)
    static let codexSessionPercent = provider(.codex, .sessionPercent)
    static let codexWeeklyPercent = provider(.codex, .longPercent)
    static let codexPercentages = provider(.codex, .percentages)
    static let codexSessionReset = provider(.codex, .sessionReset)
    static let codexWeeklyReset = provider(.codex, .longReset)
    static let kimiSession = provider(.kimi, .sessionBar)
    static let kimiMonthly = provider(.kimi, .longBar)
    static let kimiSessionPercent = provider(.kimi, .sessionPercent)
    static let kimiMonthlyPercent = provider(.kimi, .longPercent)
    static let kimiPercentages = provider(.kimi, .percentages)
    static let kimiSessionReset = provider(.kimi, .sessionReset)
    static let kimiMonthlyReset = provider(.kimi, .longReset)
}

/// Persistence helpers for the user's chosen module ordering.
enum MenuBarModuleStore {
    static let storageKey = "menuBarModules"
    static let settingsNormalizedKey = "menuBarSettingsNormalized"
    static let combinedPercentagesNormalizedKey = "menuBarCombinedPercentagesNormalized"
    static let combinedPercentagesCorrectionKey = "menuBarCombinedPercentagesCorrection"

    /// Stored names of reset countdowns that name no provider. They decode
    /// to no module; `normalizedModules` replaces them with the provider
    /// countdowns of the same windows while `settingsNormalizedKey` is unset.
    private static let unscopedSessionReset = "sessionReset"
    private static let unscopedWeeklyReset = "weeklyReset"

    /// The modules shown when the stored list holds none.
    static let defaultModules: [MenuBarModule] = [.claudeSession, .claudeWeekly, .codexWeekly]

    /// Decode resiliently: a single unknown/renamed rawValue (e.g. from a
    /// newer build or hand-edited prefs) must NOT wipe the whole list. We
    /// decode as `[String]` and keep the values that map to a known case.
    static func decode(_ data: Data) -> [MenuBarModule] {
        storedNames(data).compactMap(MenuBarModule.init(rawValue:))
    }

    static func encode(_ modules: [MenuBarModule]) -> Data {
        (try? JSONEncoder().encode(modules)) ?? Data()
    }

    private static func storedNames(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Rewrites the stored module list as `normalizedModules` reads it,
    /// before `MenuBarConfig` loads it.
    static func normalizeSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        let splitCombined = defaults.bool(forKey: combinedPercentagesNormalizedKey)
            && !defaults.bool(forKey: combinedPercentagesCorrectionKey)
        let current = normalizedModules(
            stored: storedNames(defaults.data(forKey: storageKey) ?? Data()),
            replacingUnscopedResets: !defaults.bool(forKey: settingsNormalizedKey),
            splittingCombinedPercentages: splitCombined
        )
        if splitCombined {
            defaults.set(true, forKey: combinedPercentagesCorrectionKey)
        }
        defaults.set(encode(current), forKey: storageKey)
        defaults.set(true, forKey: settingsNormalizedKey)
    }

    /// The modules a stored name list stands for: its known modules once
    /// each, in order, or `defaultModules` when it has none.
    /// `replacingUnscopedResets` appends the provider countdowns an unscoped
    /// reset countdown stands for. `splittingCombinedPercentages` restores
    /// separate session and long-window percentages where the list holds a
    /// combined percentages module in their place, as
    /// `combinedPercentagesNormalizedKey` marks.
    static func normalizedModules(
        stored: [String],
        replacingUnscopedResets: Bool,
        splittingCombinedPercentages: Bool
    ) -> [MenuBarModule] {
        var current = stored.compactMap(MenuBarModule.init(rawValue:))
        let sessionReset = replacingUnscopedResets && stored.contains(unscopedSessionReset)
        let weeklyReset = replacingUnscopedResets && stored.contains(unscopedWeeklyReset)
        if current.isEmpty && !sessionReset && !weeklyReset {
            current = defaultModules
        }
        if sessionReset {
            current.append(.claudeSessionReset)
        }
        if weeklyReset {
            current.append(contentsOf: [.claudeWeeklyReset, .codexWeeklyReset])
        }
        if splittingCombinedPercentages {
            let separate = Dictionary(uniqueKeysWithValues: AIProviderType.implementedProviders.map {
                (MenuBarModule.provider($0, .percentages), [MenuBarModule.provider($0, .sessionPercent), .provider($0, .longPercent)])
            })
            current = current.flatMap { separate[$0] ?? [$0] }
        }
        var seen = Set<MenuBarModule>()
        return current.filter { seen.insert($0).inserted }
    }
}
