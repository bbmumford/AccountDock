import SwiftUI

/// A switch's icon in its three states (`AppState.ToggleState`): filled in
/// the brand colour when on, its outline or slashed form in grey when off,
/// and the plain form in the brand colour when some providers have it on and
/// some off.
struct SwitchGlyph: View {
    let on: String
    let off: String
    let mixed: String
    let state: AppState.ToggleState

    var body: some View {
        switch state {
        case .on: Image(systemName: on).foregroundStyle(.brand)
        case .off: Image(systemName: off).foregroundStyle(.secondary)
        case .mixed: Image(systemName: mixed).foregroundStyle(.brand)
        }
    }

    static func failover(_ state: AppState.ToggleState) -> SwitchGlyph {
        SwitchGlyph(on: "arrow.triangle.2.circlepath.circle.fill", off: "arrow.triangle.2.circlepath.circle",
                    mixed: "arrow.triangle.2.circlepath", state: state)
    }

    static func balancing(_ state: AppState.ToggleState) -> SwitchGlyph {
        SwitchGlyph(on: "square.stack.3d.up.fill", off: "square.stack.3d.up.slash", mixed: "square.stack.3d.up",
                    state: state)
    }
}

/// The menu footer's Failover and Balancing switches, left of Refresh,
/// Settings and Quit: each sets its setting for every provider it covers
/// at once (`AppState.setActiveAccountMovement`,
/// `AppState.setSessionBalancing`), shows on, off or mixed, and lists each
/// provider's state in its tooltip.
struct FooterSwitches: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared

    var body: some View {
        let failoverProviders = appState.failoverToggleProviders
        let failover = AppState.toggleState(failoverProviders.map { store.policy(for: $0).movesActiveAccountAutomatically })
        let balancingProviders = appState.balancingToggleProviders
        let balancing = AppState.toggleState(balancingProviders.map { store.policy(for: $0).distributeSessions })

        Button {
            appState.setActiveAccountMovement(AppState.toggleTarget(failover), for: failoverProviders, from: "the menu")
        } label: {
            SwitchGlyph.failover(failover)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Failover: \(summary(failoverProviders) { store.policy(for: $0).movesActiveAccountAutomatically }). On, failover and weekly balancing move the active account at a threshold or its limit, and early to use weekly allowances before they reset; off, it stays where you put it. Click to turn it \(AppState.toggleTarget(failover) ? "on" : "off") for every provider.")
        .accessibilityLabel("Failover")
        .accessibilityValue(text(failover))

        if !balancingProviders.isEmpty {
            Button {
                Task {
                    await appState.setSessionBalancing(AppState.toggleTarget(balancing), for: balancingProviders,
                                                       from: "the menu")
                }
            } label: {
                SwitchGlyph.balancing(balancing)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Session balancing: \(summary(balancingProviders) { store.policy(for: $0).distributeSessions }). On, sessions run in slots of their own on several accounts and move between them one at a time; off, new sessions use the shared sign-in. Pacing and Rebalance automatically keep their settings. Click to turn it \(AppState.toggleTarget(balancing) ? "on" : "off") for every provider.")
            .accessibilityLabel("Session balancing")
            .accessibilityValue(text(balancing))
        }
    }

    private func summary(_ providers: [AIProviderType], _ isOn: (AIProviderType) -> Bool) -> String {
        AppState.toggleSummary(providers.map { (name: $0.capabilities.displayName, on: isOn($0)) })
    }

    private func text(_ state: AppState.ToggleState) -> String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .mixed: "On for some providers"
        }
    }
}
