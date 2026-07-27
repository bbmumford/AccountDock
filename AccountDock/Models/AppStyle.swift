import SwiftUI

// MARK: - Design Tokens

enum AppStyle {
    // Layout
    static var cardCornerRadius: CGFloat {
        guard UserDefaults.standard.object(forKey: "cardCornerRadius") != nil else { return 7 }
        return CGFloat(UserDefaults.standard.double(forKey: "cardCornerRadius"))
    }
    static var cardPadding: CGFloat {
        switch UserDefaults.standard.string(forKey: "interfaceDensity") ?? "comfortable" {
        case "compact": return 8
        case "spacious": return 16
        default: return 12
        }
    }
    static var screenHorizontalPadding: CGFloat { cardPadding + 4 }

    // Shadow
    static var cardShadowColor: Color {
        Color.dockMidnight.opacity(UserDefaults.standard.bool(forKey: "disableCardShadows") ? 0 : 0.22)
    }
    static var cardShadowRadius: CGFloat { UserDefaults.standard.bool(forKey: "disableCardShadows") ? 0 : 5 }
    static var cardShadowY: CGFloat { UserDefaults.standard.bool(forKey: "disableCardShadows") ? 0 : 6 }

    // Badge
    static let badgeHPadding: CGFloat = 6
    static let badgeVPadding: CGFloat = 2

    // Progress Bar
    static let barCornerRadius: CGFloat = 3
    static let barHeight: CGFloat = 7

    // Colors
    static let buttonTextColor = Color(red: 0x42 / 255, green: 0x42 / 255, blue: 0x42 / 255)
}

// MARK: - Card Style Modifier

struct CardStyleModifier: ViewModifier {
    var fill: Color = .cardFill
    var border: Color = .cardBorder
    var hasShadow: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(AppStyle.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius)
                    .fill(fill)
                    .strokeBorder(border, lineWidth: 1)
                    .shadow(
                        color: hasShadow ? AppStyle.cardShadowColor : .clear,
                        radius: AppStyle.cardShadowRadius,
                        x: 0,
                        y: AppStyle.cardShadowY
                    )
            )
    }
}

extension View {
    /// Standard card style with fill, border, shadow, and content padding.
    func cardStyle(fill: Color = .cardFill, border: Color = .cardBorder, hasShadow: Bool = true) -> some View {
        modifier(CardStyleModifier(fill: fill, border: border, hasShadow: hasShadow))
    }

    /// Standard horizontal padding for sections within the popover.
    func sectionPadding() -> some View {
        padding(.horizontal, AppStyle.screenHorizontalPadding)
    }
}
