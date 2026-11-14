import SwiftUI

/// Reusable capsule badge for status indicators (subscription type, active state, etc.).
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.brandOnAccent)
            .padding(.horizontal, AppStyle.badgeHPadding)
            .padding(.vertical, AppStyle.badgeVPadding)
            .background(color, in: Capsule())
    }
}

extension Badge {
    /// One of an account's status badges (`AccountStatus.Badge`).
    init(_ badge: AccountStatus.Badge) {
        self.init(text: badge.text, color: badge.tone.color)
    }
}

extension AccountStatus.Tone {
    /// The colour an account status badge or notice is drawn in.
    var color: Color {
        switch self {
        case .accent: .brand
        case .attention: .orange
        case .caution: .yellow
        case .failure: .red
        }
    }
}
