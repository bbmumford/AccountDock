import Foundation

/// One configurable module rendered in the macOS menu bar.
///
/// Display style matches iStats / Stats: two-line stacked module with a short
/// uppercase label on top and either a bar (for percentages) or a value text
/// (for absolute numbers / times) on the bottom.
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case claudeSession
    case claudeWeekly
    case claudeSessionPercent
    case claudeWeeklyPercent
    case claudeSessionReset
    case claudeWeeklyReset
    case codexSession
    case codexWeekly
    case codexSessionPercent
    case codexWeeklyPercent
    case codexSessionReset
    case codexWeeklyReset
    case kimiSession
    case kimiMonthly
    case kimiSessionPercent
    case kimiMonthlyPercent
    case kimiSessionReset
    case kimiMonthlyReset
    case claudeUsage
    case codexUsage
    case account
    case sessionBar
    case sessionBarPlain
    case weeklyBar
    case weeklyBarPlain
    case dailyCost
    case sessionReset
    case weeklyReset

    var id: String { rawValue }

    static var allCases: [MenuBarModule] {
        [
            .claudeSession, .claudeWeekly, .codexSession, .codexWeekly,
            .claudeSessionPercent, .claudeWeeklyPercent,
            .codexSessionPercent, .codexWeeklyPercent,
            .claudeWeeklyReset, .codexWeeklyReset,
            .claudeSessionReset, .codexSessionReset,
            .kimiSession, .kimiMonthly, .kimiSessionPercent, .kimiMonthlyPercent,
            .kimiSessionReset, .kimiMonthlyReset,
            .dailyCost
        ]
    }

    /// Short uppercase label shown on the top line of the module.
    var compactLabel: String {
        switch self {
        case .claudeSession:  return "5H"
        case .claudeWeekly:   return "7D"
        case .claudeSessionPercent: return "5H"
        case .claudeWeeklyPercent: return "7D"
        case .claudeSessionReset: return "5H↻"
        case .claudeWeeklyReset: return "7D↻"
        case .codexSession:   return "5H"
        case .codexWeekly:    return "7D"
        case .codexSessionPercent: return "5H"
        case .codexWeeklyPercent: return "7D"
        case .codexSessionReset: return "5H↻"
        case .codexWeeklyReset: return "7D↻"
        case .kimiSession: return "5H"
        case .kimiMonthly: return "MO"
        case .kimiSessionPercent: return "5H"
        case .kimiMonthlyPercent: return "MO"
        case .kimiSessionReset: return "5H↻"
        case .kimiMonthlyReset: return "MO↻"
        case .claudeUsage:    return "CLAUDE"
        case .codexUsage:     return "CODEX"
        case .account:         return "@"
        case .sessionBar:      return "5H"
        case .sessionBarPlain: return "5H"
        case .weeklyBar:       return "7D"
        case .weeklyBarPlain:  return "7D"
        case .dailyCost:       return "TOTAL"
        case .sessionReset:    return "5H↻"
        case .weeklyReset:     return "7D↻"
        }
    }

    /// Human-readable name shown in the Settings reorder list.
    var localizedDisplayName: String {
        switch self {
        case .claudeSession:  return String(localized: "Claude — session usage (5h)", bundle: L10n.bundle)
        case .claudeWeekly:   return String(localized: "Claude — weekly usage (7d)", bundle: L10n.bundle)
        case .claudeSessionPercent: return String(localized: "Claude — session percentage (5h)", bundle: L10n.bundle)
        case .claudeWeeklyPercent: return String(localized: "Claude — weekly percentage (7d)", bundle: L10n.bundle)
        case .claudeSessionReset: return String(localized: "Claude — session reset", bundle: L10n.bundle)
        case .claudeWeeklyReset: return String(localized: "Claude — weekly reset", bundle: L10n.bundle)
        case .codexSession:   return String(localized: "Codex — session usage (5h)", bundle: L10n.bundle)
        case .codexWeekly:    return String(localized: "Codex — weekly usage (7d)", bundle: L10n.bundle)
        case .codexSessionPercent: return String(localized: "Codex — session percentage (5h, when available)", bundle: L10n.bundle)
        case .codexWeeklyPercent: return String(localized: "Codex — weekly percentage (7d)", bundle: L10n.bundle)
        case .codexSessionReset: return String(localized: "Codex — session reset", bundle: L10n.bundle)
        case .codexWeeklyReset: return String(localized: "Codex — weekly reset", bundle: L10n.bundle)
        case .kimiSession: return "Kimi — session usage (5h)"
        case .kimiMonthly: return "Kimi — monthly usage"
        case .kimiSessionPercent: return "Kimi — session percentage (5h)"
        case .kimiMonthlyPercent: return "Kimi — monthly percentage"
        case .kimiSessionReset: return "Kimi — session reset"
        case .kimiMonthlyReset: return "Kimi — monthly reset"
        case .claudeUsage:    return String(localized: "Claude — session and weekly usage", bundle: L10n.bundle)
        case .codexUsage:     return String(localized: "Codex — session and weekly usage", bundle: L10n.bundle)
        case .account:         return String(localized: "Account name", bundle: L10n.bundle)
        case .sessionBar:      return String(localized: "Session — usage vs time (5h)", bundle: L10n.bundle)
        case .sessionBarPlain: return String(localized: "Session usage (5h)", bundle: L10n.bundle)
        case .weeklyBar:       return String(localized: "Weekly — usage vs time (7d)", bundle: L10n.bundle)
        case .weeklyBarPlain:  return String(localized: "Weekly usage (7d)", bundle: L10n.bundle)
        case .dailyCost:       return String(localized: "Total daily cost — all accounts and providers", bundle: L10n.bundle)
        case .sessionReset:    return String(localized: "Session reset countdown", bundle: L10n.bundle)
        case .weeklyReset:     return String(localized: "Weekly reset countdown", bundle: L10n.bundle)
        }
    }
}

/// Persistence helpers for the user's chosen module ordering.
enum MenuBarModuleStore {
    static let storageKey = "menuBarModules"
    static let settingsNormalizedKey = "menuBarSettingsNormalized"
    static let legacyShowAccountNameKey = "showAccountName"

    /// Decode resiliently: a single unknown/renamed rawValue (e.g. from a
    /// newer build or hand-edited prefs) must NOT wipe the whole list. We
    /// decode as `[String]` and keep the values that map to a known case.
    static func decode(_ data: Data) -> [MenuBarModule] {
        guard let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap(MenuBarModule.init(rawValue:))
    }

    static func encode(_ modules: [MenuBarModule]) -> Data {
        (try? JSONEncoder().encode(modules)) ?? Data()
    }

    /// Normalizes preferences written by earlier local builds while preserving
    /// the user's ordering and enabled modules.
    static func normalizeSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: settingsNormalizedKey) else { return }

        var current = decode(defaults.data(forKey: storageKey) ?? Data())
        if current.isEmpty {
            current = [.claudeSession, .claudeWeekly, .codexWeekly]
        }

        if current.contains(.sessionReset) {
            current.append(.claudeSessionReset)
        }
        if current.contains(.weeklyReset) {
            current.append(contentsOf: [.claudeWeeklyReset, .codexWeeklyReset])
        }

        let obsolete: Set<MenuBarModule> = [
            .account, .claudeUsage, .codexUsage,
            .sessionBar, .sessionBarPlain, .weeklyBar, .weeklyBarPlain,
            .sessionReset, .weeklyReset
        ]
        var seen = Set<MenuBarModule>()
        current = current.filter { !obsolete.contains($0) && seen.insert($0).inserted }
        defaults.set(encode(current), forKey: storageKey)
        defaults.set(true, forKey: settingsNormalizedKey)
    }
}

extension MenuBarModule {
    var provider: AIProviderType? {
        switch self {
        case .claudeSession, .claudeWeekly, .claudeSessionPercent, .claudeWeeklyPercent,
             .claudeSessionReset, .claudeWeeklyReset:
            return .claudeCode
        case .codexSession, .codexWeekly, .codexSessionPercent, .codexWeeklyPercent,
             .codexSessionReset, .codexWeeklyReset:
            return .codex
        case .kimiSession, .kimiMonthly, .kimiSessionPercent, .kimiMonthlyPercent,
             .kimiSessionReset, .kimiMonthlyReset:
            return .kimi
        default:
            return nil
        }
    }
}
