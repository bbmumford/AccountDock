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
/// at once (`AppState.setActiveAccountMovement`, which sets "Move the active
/// account automatically" and "Failover: switch at a threshold or the
/// limit" together, and `AppState.setSessionBalancing`), shows on, off or
/// mixed, and lists each provider's state in its tooltip.
struct FooterSwitches: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared

    var body: some View {
        let failoverProviders = appState.failoverToggleProviders
        let failover = AppState.toggleState(failoverProviders.map { AppState.failoverIsOn(store.policy(for: $0)) })
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
        .hoverExplanation(
            "Failover — \(text(failover).lowercased())",
            "On, the active account moves to an account with room at a threshold or its limit, and for weekly balancing: "
                + "Move the active account automatically and Failover: switch at a threshold or the limit, together. "
                + "\(summary(failoverProviders) { AppState.failoverIsOn(store.policy(for: $0)) }). "
                + (failover == .on ? "Click to keep each provider's active account where it is." : "Click to turn both on for every provider.")
        )
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
            .hoverExplanation(
                "Session balancing — \(text(balancing).lowercased())",
                "Runs sessions in slots of their own on several accounts and moves them between accounts one at a time. "
                    + "\(summary(balancingProviders) { store.policy(for: $0).distributeSessions }). "
                    + (balancing == .on ? "Click to turn it off; your pacing and rebalance settings are kept." : "Click to turn it on for every provider.")
            )
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

/// One provider's Failover switch, beside its Rebalance icon on the
/// Sessions page and the usage tab: its "Move the active account
/// automatically" and "Failover: switch at a threshold or the limit"
/// together (`AppState.setActiveAccountMovement`), which the footer's switch
/// also sets.
struct ProviderFailoverSwitch: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared
    let provider: AIProviderType
    /// Where the switch is, for the event.
    let place: String

    var body: some View {
        let on = AppState.failoverIsOn(store.policy(for: provider))
        let name = provider.capabilities.displayName
        Button {
            appState.setActiveAccountMovement(!on, for: [provider], from: place)
        } label: {
            SwitchGlyph.failover(on ? .on : .off)
        }
        .hoverExplanation(
            "Failover for \(name) — \(on ? "on" : "off")",
            on ? "The active account moves to an account with room at a threshold or its limit, and for weekly balancing (Move the active account automatically and Failover: switch at a threshold or the limit, both on). Click to keep it where it is."
               : "The active account stays where it is; session balancing still moves sessions. Click to turn on Move the active account automatically and Failover: switch at a threshold or the limit, so it moves to an account with room."
        )
        .accessibilityLabel("Failover for \(name)")
        .accessibilityValue(on ? "On" : "Off")
    }
}
