import Foundation

/// How a cost or a token count is written wherever AccountDock shows one:
/// the usage dashboard, the cost tab, the menu bar and the widget.
enum UsageFormat {
    /// "$12.34". A cost above zero but under a cent reads "<$0.01" so it is
    /// not mistaken for none. `wholeDollars` writes "$12" for columns too
    /// narrow for cents.
    static func cost(_ amount: Double, wholeDollars: Bool = false) -> String {
        if wholeDollars { return String(format: "$%.0f", amount) }
        if amount > 0 && amount < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", amount)
    }

    /// "950", "12.3K", "4.5M", "1.2B".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
