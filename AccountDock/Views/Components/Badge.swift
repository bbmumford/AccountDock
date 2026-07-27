import SwiftUI

/// Reusable capsule badge for status indicators (subscription type, active state, etc.).
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, AppStyle.badgeHPadding)
            .padding(.vertical, AppStyle.badgeVPadding)
            .background(color, in: Capsule())
    }
}
