import SwiftUI

struct AccountDockMark: View {
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: "arrow.left.arrow.right.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.brand)
        .frame(width: size, height: size)
        .accessibilityLabel("AccountDock")
    }
}

/// A crisp template-style mark that remains legible at macOS menu-bar size.
struct AccountDockMenuBarMark: View {
    var body: some View {
        AccountDockMark(size: 15)
            .frame(width: 17, height: 17)
    }
}

struct AccountDockBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [.dockMidnight, .dockInk, .dockMidnight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.97, blue: 1.0),
                        Color(red: 0.97, green: 0.95, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Circle()
                .fill(Color.brand.opacity(colorScheme == .dark ? 0.10 : 0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: -150, y: -260)

            Circle()
                .fill(Color.brand.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: 170, y: 250)
        }
        .ignoresSafeArea()
    }
}
