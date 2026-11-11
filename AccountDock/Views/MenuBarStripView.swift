import SwiftUI

private struct StripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The full content rendered inside the `NSStatusItem` button: provider groups
/// and every enabled module, laid out horizontally. Each module is a
/// two-line iStats-style cell. Hosted in an `NSHostingController` so it is free
/// of `MenuBarExtra`'s single-line / single-element label constraints.
///
/// The view reports its intrinsic width via `onWidth` so the controller can
/// keep `NSStatusItem.length` exactly matched — otherwise the status item
/// keeps a stale (too-narrow) width and clips the leading icon / trailing
/// module once real data widens the content.
struct MenuBarStripView: View {
    // Not @ObservedObject: in the NSStatusItem hosting context, ObservableObject
    // change delivery is unreliable (only @State / timer re-render the hosted
    // view). We poll on a short interval instead.
    let appState: AppState
    let config: MenuBarConfig
    let onWidth: (CGFloat) -> Void
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("accentPalette") private var accentPalette = "softWhite"
    @State private var tick = Date()
    // Polled refresh. ObservableObject change delivery is unreliable for a
    // SwiftUI view hosted in an NSStatusItem, so we re-read AppState/config on
    // a short interval (the pattern menu-bar monitors like iStats/Stats use).
    // This also keeps the reset countdowns current; they show whole minutes,
    // and each tick lays out the whole strip, so the interval stays well
    // under a minute without being shorter than the quota cycle needs.
    private let tickTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 13) {
            ForEach(visibleProviderOrder) { provider in
                providerGroup(provider)
            }

            ForEach(globalModules) { module in
                MenuBarModuleView(
                    module: module,
                    appState: appState,
                    showFullEmail: showFullEmail,
                    tick: tick
                )
            }
        }
        .padding(.horizontal, 6)
        .id(accentPalette)
        .frame(height: 22)
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: StripWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(StripWidthKey.self) { width in
            if width > 0 { onWidth(width) }
        }
        .onReceive(tickTimer) { date in
            tick = date
        }
    }

    private var visibleProviderOrder: [AIProviderType] {
        config.providerOrder.filter { provider in
            config.modules.contains { $0.provider == provider }
        }
    }

    private var globalModules: [MenuBarModule] {
        config.modules.filter { $0.provider == nil }
    }

    private func providerGroup(_ provider: AIProviderType) -> some View {
        HStack(spacing: 5) {
            Image(systemName: provider.iconName)
                .font(.system(size: 14.3, weight: .semibold))
                .overlay(alignment: .bottomTrailing) {
                    // Paused sessions: the strip is re-read on every tick.
                    if appState.routedStatus[provider] != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.blue)
                            .offset(x: 3, y: 3)
                    } else if appState.agentPauseStatus[provider] != nil {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                            .offset(x: 3, y: 3)
                    }
                }
            ForEach(config.modules.filter { $0.provider == provider }) { module in
                MenuBarModuleView(
                    module: module,
                    appState: appState,
                    showFullEmail: showFullEmail,
                    tick: tick
                )
            }
        }
        .padding(.horizontal, 2)
    }
}
