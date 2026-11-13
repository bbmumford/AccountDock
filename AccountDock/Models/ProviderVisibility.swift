import Foundation

/// Which providers AccountDock shows, stored as one list of hidden
/// providers so every provider, current or added later, is shown until the
/// user hides it. Views read `storageKey` through `@AppStorage` and decode
/// it with `hidden(in:)`.
enum ProviderVisibility {
    static let storageKey = "hiddenProviders"

    static func hidden(in stored: String) -> Set<AIProviderType> {
        Set(stored.split(separator: ",").compactMap { AIProviderType(rawValue: String($0)) })
    }

    /// The hidden providers as stored now, for code without an
    /// `@AppStorage` binding: the menu bar and the widget projection.
    static func storedHidden(_ defaults: UserDefaults = .standard) -> Set<AIProviderType> {
        hidden(in: defaults.string(forKey: storageKey) ?? "")
    }

    static func encode(_ hidden: Set<AIProviderType>) -> String {
        hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func visibleProviders(in stored: String) -> [AIProviderType] {
        let hidden = hidden(in: stored)
        return AIProviderType.implementedProviders.filter { !hidden.contains($0) }
    }

    /// Settings saved with one show flag per provider.
    private static let flagKeys: [AIProviderType: String] = [
        .claudeCode: "showClaudeProvider", .codex: "showCodexProvider", .kimi: "showKimiProvider",
    ]

    /// Moves the per-provider show flags into the hidden list once.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: storageKey) == nil else { return }
        var hidden: Set<AIProviderType> = []
        for (provider, key) in flagKeys where defaults.object(forKey: key) as? Bool == false {
            hidden.insert(provider)
        }
        defaults.set(encode(hidden), forKey: storageKey)
    }
}
