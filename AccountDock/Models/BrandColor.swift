import SwiftUI
import AppKit

extension Color {
    /// AccountDock's independent blue identity colour.
    static var brand: Color {
        switch UserDefaults.standard.string(forKey: "accentPalette") ?? "softWhite" {
        case "signal": return Color(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0)
        case "ember": return Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0)
        case "ocean": return Color(red: 0.12, green: 0.48, blue: 0.92)
        case "violet": return Color(red: 0.49, green: 0.25, blue: 0.93)
        case "forest": return Color(red: 0.12, green: 0.62, blue: 0.38)
        case "rose": return Color(red: 0.88, green: 0.23, blue: 0.45)
        case "graphite": return Color(red: 0.35, green: 0.38, blue: 0.43)
        case "softWhite":
            return adaptive(
                light: Color(red: 0.52, green: 0.50, blue: 0.46),
                dark: Color(red: 0.91, green: 0.90, blue: 0.86)
            )
        default:
            return adaptive(
                light: Color(red: 0.52, green: 0.50, blue: 0.46),
                dark: Color(red: 0.91, green: 0.90, blue: 0.86)
            )
        }
    }

    /// Foreground used for text and symbols placed directly on a solid brand
    /// fill. The Default palette uses the adaptive window surface to create a cut-out
    /// effect; saturated palettes use white.
    static var brandOnAccent: Color {
        (UserDefaults.standard.string(forKey: "accentPalette") ?? "softWhite") == "softWhite"
            ? Color(nsColor: .windowBackgroundColor)
            : .white
    }

    static let dockViolet = Color(red: 0.49, green: 0.25, blue: 0.93)
    static let dockCoral = Color(red: 0.95, green: 0.42, blue: 0.32)
    static let dockMidnight = Color(red: 0.025, green: 0.047, blue: 0.12)
    static let dockInk = Color(red: 0.055, green: 0.082, blue: 0.17)

    /// Creates a color that automatically adapts between light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    // MARK: - Card

    /// Standard card fill.
    static let cardFill = adaptive(light: Color.white.opacity(0.20), dark: Color.black.opacity(0.21))
    /// Emphasized card fill (e.g. active account row).
    static let cardFillStrong = adaptive(light: Color.white.opacity(0.25), dark: Color.black.opacity(0.28))
    /// Standard card border.
    static let cardBorder = adaptive(light: Color.white.opacity(0.40), dark: Color.white.opacity(0.20))

    // MARK: - Tab Bar

    /// Tab bar background fill.
    static let tabFill = adaptive(light: Color.white.opacity(0.15), dark: Color.black.opacity(0.21))
    /// Tab bar border.
    static let tabBorder = adaptive(light: Color.white.opacity(0.40), dark: Color.white.opacity(0.20))

    // MARK: - Text

    /// Primary text color for cards and tab selected state.
    static let textPrimary = adaptive(light: Color.primary, dark: Color.white)
    /// Secondary text color for card labels and tab unselected state.
    static let textSecondary = adaptive(light: Color.secondary, dark: Color.white.opacity(0.55))

    // MARK: - Subtle Backgrounds

    /// Subtle brand tint for banners and badges.
    static let subtleBrand = adaptive(light: brand.opacity(0.12), dark: brand.opacity(0.28))
    /// Progress bar track.
    static let progressTrack = adaptive(light: Color.gray.opacity(0.18), dark: Color.white.opacity(0.15))
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
    static var brandOnAccent: Color { .brandOnAccent }
    static var cardFill: Color { .cardFill }
    static var cardFillStrong: Color { .cardFillStrong }
    static var cardBorder: Color { .cardBorder }
    static var tabFill: Color { .tabFill }
    static var tabBorder: Color { .tabBorder }
    static var textPrimary: Color { .textPrimary }
    static var textSecondary: Color { .textSecondary }
    static var subtleBrand: Color { .subtleBrand }
    static var progressTrack: Color { .progressTrack }
}
