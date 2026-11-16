import SwiftUI

/// Names an icon-only control while the pointer rests on it, in a small
/// popover: its name in bold, then what it does. A `.help` tooltip appears
/// only after a long delay, and not at all while the menu's panel is not the
/// key window, so an icon such as the footer's Failover switch would be left
/// unexplained.
private struct HoverExplanation: ViewModifier {
    let title: String
    let detail: String
    @State private var hovering = false
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                pending?.cancel()
                if inside {
                    // A short pause, so passing over the icon on the way
                    // elsewhere opens nothing.
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled, hovering else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(width: 280, alignment: .leading)
            }
            .help(detail.isEmpty ? title : "\(title): \(detail)")
            .accessibilityHint(detail)
    }
}

extension View {
    /// Shows `title` and `detail` in a popover while the pointer rests on
    /// this control (`HoverExplanation`).
    func hoverExplanation(_ title: String, _ detail: String = "") -> some View {
        modifier(HoverExplanation(title: title, detail: detail))
    }
}
