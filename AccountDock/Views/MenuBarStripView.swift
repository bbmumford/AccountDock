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
    @AppStorage("accentPalette") private var accentPalette = "softWhite"
    @AppStorage(ProviderVisibility.storageKey) private var hiddenProviders = ""
    @State private var tick = Date()
    // Polled refresh. ObservableObject change delivery is unreliable for a
    // SwiftUI view hosted in an NSStatusItem, so we re-read AppState/config on
    // a short interval (the pattern menu-bar monitors like iStats/Stats use).
    // This also keeps the reset countdowns current; they show whole minutes,
    // and each tick lays out the whole strip, so the interval stays well
    // under a minute without being shorter than the quota cycle needs.
    private let tickTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        let providers = visibleProviderOrder
        let modules = globalModules
        HStack(spacing: 13) {
            ForEach(providers) { provider in
                providerGroup(provider)
            }

            ForEach(modules) { module in
                MenuBarModuleView(
                    module: module,
                    appState: appState,
                    tick: tick
                )
            }

            // With every group hidden and no global module, the mark keeps
            // the status item wide enough to click, since its popover is
            // the only way into AccountDock and its Settings.
            if providers.isEmpty && modules.isEmpty {
                AccountDockMenuBarMark()
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

    /// The provider groups the strip shows (`MenuBarPresence`): re-read on
    /// every tick, so a group leaves and returns as accounts change.
    private var visibleProviderOrder: [AIProviderType] {
        MenuBarPresence.shownProviders(
            order: config.providerOrder,
            modules: config.modules,
            hidden: ProviderVisibility.hidden(in: hiddenProviders),
            accounts: appState.accounts,
            needsSignIn: { appState.needsSignIn($0) }
        )
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
                    tick: tick
                )
            }
        }
        .padding(.horizontal, 2)
    }
}
