import SwiftUI

/// An account email in small secondary text. It stays masked unless the user
/// chose to always show full addresses, and is revealed only while the
/// pointer is over it.
struct AccountEmailLabel: View {
    let email: String
    let alwaysVisible: Bool
    @State private var isHovering = false

    var body: some View {
        let revealed = alwaysVisible || isHovering
        HStack(spacing: 4) {
            Text(revealed ? email : email.obfuscatedEmail())
                .font(.caption2)
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !alwaysVisible {
                Image(systemName: isHovering ? "eye" : "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(isHovering ? "Email shown" : "Email hidden")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

extension Account {
    /// The name shown above the email: the user's label, otherwise the
    /// provider-reported name when it differs from the email.
    func headerTitle(obfuscated: Bool) -> String {
        if let label = customLabel, !label.isEmpty { return label }
        if displayName.caseInsensitiveCompare(email) == .orderedSame {
            let plan = displaySubscriptionType.map { " \($0)" } ?? ""
            return "\(provider.capabilities.displayName)\(plan)"
        }
        return obfuscated ? obfuscatedDisplayName : displayName
    }
}
