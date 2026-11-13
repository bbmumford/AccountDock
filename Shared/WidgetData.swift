import Foundation

/// One quota window of an account, as the widget shows it.
struct WidgetWindow: Codable, Equatable {
    /// The window's name, such as "Session", "Monthly limit" or "Fable weekly".
    let label: String
    /// Percent used; nil when unknown, which the widget shows as "—".
    let utilization: Double?
    /// When the window resets; the widget counts down to it live.
    let resetsAt: Date?
}

struct WidgetAccountData: Codable {
    /// The provider's identity, which groups accounts by provider.
    let provider: String?
    /// The provider's name as shown, such as "Kimi".
    let providerName: String?
    /// SF Symbol name of the provider's icon.
    let iconName: String?
    let email: String          // pre-obfuscated
    let displayName: String    // pre-obfuscated
    let subscriptionType: String?
    let isActive: Bool
    /// The account's quota windows in display order.
    let windows: [WidgetWindow]?
    let hasError: Bool
    let errorMessage: String?

    /// The readings of a file without `windows`, which carries one session
    /// and one weekly reading per account; read by `displayWindows`.
    let sessionUtilization: Double?
    let weeklyUtilization: Double?

    init(
        provider: String?,
        providerName: String?,
        iconName: String?,
        email: String,
        displayName: String,
        subscriptionType: String?,
        isActive: Bool,
        windows: [WidgetWindow],
        hasError: Bool,
        errorMessage: String?
    ) {
        self.provider = provider
        self.providerName = providerName
        self.iconName = iconName
        self.email = email
        self.displayName = displayName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.windows = windows
        self.hasError = hasError
        self.errorMessage = errorMessage
        self.sessionUtilization = nil
        self.weeklyUtilization = nil
    }

    /// The windows to show: `windows`, or the session and weekly readings
    /// of a file without them.
    var displayWindows: [WidgetWindow] {
        if let windows { return windows }
        return [
            sessionUtilization.map { WidgetWindow(label: "Session", utilization: $0, resetsAt: nil) },
            WidgetWindow(label: "Weekly", utilization: weeklyUtilization, resetsAt: nil),
        ].compactMap { $0 }
    }

    /// The window with the least room left, which limits the account first;
    /// the first window when none has a reading.
    var tightestWindow: WidgetWindow? {
        let windows = displayWindows
        return windows.filter { $0.utilization != nil }
            .max { ($0.utilization ?? 0) < ($1.utilization ?? 0) } ?? windows.first
    }

    var displayProviderName: String { providerName ?? provider ?? "" }

    /// `iconName`, or a generic account symbol when the file names none.
    var displayIconName: String { iconName ?? "person.crop.circle" }
}

/// Data shared between the main app and widget via direct file in the widget's sandbox container.
///
/// The main app (non-sandboxed) writes a JSON file into the widget extension's container directory.
/// The widget (sandboxed) reads from its own Application Support, which maps to the same path.
///
/// The file is a finished presentation: `WidgetProjection` in the app fills
/// in every label, icon and window from the providers' capabilities, so the
/// widget renders what it is given and names no provider itself. Fields a
/// file of the one-session-one-weekly shape lacks are optional, so such a
/// file still loads.
struct WidgetData: Codable {
    /// Provider identities in display order.
    let providerOrder: [String]?
    let accounts: [WidgetAccountData]
    let todayCost: Double
    let conversationTurns: Int
    let activeCodingTime: String
    let linesWritten: Int
    let modelUsage: [String: Int]
    let lastUpdated: Date

    /// Providers in display order: `providerOrder`, or the order accounts
    /// first name them.
    var orderedProviders: [String] {
        if let providerOrder { return providerOrder }
        var order: [String] = []
        for account in accounts {
            if let provider = account.provider, !order.contains(provider) { order.append(provider) }
        }
        return order
    }

    /// One account per provider, in display order: its active account, or
    /// its first.
    var providerAccounts: [WidgetAccountData] {
        orderedProviders.compactMap { provider in
            accounts.first { $0.provider == provider && $0.isActive }
                ?? accounts.first { $0.provider == provider }
        }
    }

    // Team-ID-prefixed App Group. macOS Sequoia (15+) prompts for App
    // Management on `group.<bundle-id>` style identifiers; the
    // `<TEAMID>.<bundle-id>` form is auto-authorized for Developer-ID-signed
    // apps without a provisioning profile and avoids the prompt entirely.
    private static let appGroupID = "584KQTRF3B.app.accountdock"
    private static let fileName = "widget-data.json"

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Load from the shared App Group container.
    static func load() -> WidgetData? {
        guard let containerURL = sharedContainerURL else { return nil }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    /// Save to the shared App Group container.
    func save() {
        guard let containerURL = Self.sharedContainerURL else { return }
        let fileURL = containerURL.appendingPathComponent(Self.fileName)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
