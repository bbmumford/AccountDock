import Foundation

/// Two switches outside Settings: **Failover**, the providers' "Move the
/// active account automatically" (`ProviderFailoverPolicy.activeAccountLocked`,
/// inverted) and "Failover: switch at a threshold or the limit"
/// (`enabled`) together (`withFailover`), so failover on means the active
/// account moves to an account with room; and **Balancing**, session
/// balancing, which is "Serve sessions from several accounts at once"
/// (`distributeSessions`). Session balancing's
/// other settings (pacing, rebalancing automatically, resuming sessions left
/// waiting) act only while `distributeSessions` is on, and the switch leaves
/// them as they are, so turning it on again restores what the provider had.
/// The menu's footer sets either for every provider at once; the provider
/// headings beside Rebalance set Failover for one. Both change the stored
/// policy the Settings toggles change, through the same steps.
extension AppState {
    /// What a switch over several providers shows.
    enum ToggleState: Equatable {
        case on, off
        /// Some providers have it on and some off.
        case mixed
    }

    /// `values`, one per provider, as one switch's state; off with none.
    nonisolated static func toggleState(_ values: [Bool]) -> ToggleState {
        guard let first = values.first else { return .off }
        return values.allSatisfy { $0 == first } ? (first ? .on : .off) : .mixed
    }

    /// What clicking a switch in `state` sets every provider to: off when
    /// all are on, on otherwise, so a mixed switch turns them all on.
    nonisolated static func toggleTarget(_ state: ToggleState) -> Bool {
        state != .on
    }

    /// Each provider's state for a switch's tooltip: "Claude Code on · Codex
    /// off · Kimi Code off".
    nonisolated static func toggleSummary(_ entries: [(name: String, on: Bool)]) -> String {
        entries.map { "\($0.name) \($0.on ? "on" : "off")" }.joined(separator: " · ")
    }

    /// `policy` with session balancing on or off: `distributeSessions`
    /// alone, so its other settings are kept for when it is on again.
    nonisolated static func withSessionBalancing(_ policy: ProviderFailoverPolicy, on: Bool) -> ProviderFailoverPolicy {
        var next = policy
        next.distributeSessions = on
        return next
    }

    /// The event for a switch turned on or off for `providers` from
    /// `place`: "Failover turned off from the menu for Claude Code, Codex
    /// and Kimi Code."
    nonisolated static func toggleEvent(_ setting: String, on: Bool, providers: [String], from place: String) -> String {
        let names: String
        switch providers.count {
        case 0: names = "no provider"
        case 1: names = providers[0]
        default: names = providers.dropLast().joined(separator: ", ") + " and " + providers[providers.count - 1]
        }
        return "\(setting) turned \(on ? "on" : "off") from \(place) for \(names)."
    }

    /// The providers the Failover switch covers: every implemented one with
    /// an account, or every implemented one while none has.
    var failoverToggleProviders: [AIProviderType] {
        let used = AIProviderType.implementedProviders.filter { provider in accounts.contains { $0.provider == provider } }
        return used.isEmpty ? AIProviderType.implementedProviders : used
    }

    /// The providers the Balancing switch covers: those of
    /// `failoverToggleProviders` whose sessions can be served from several
    /// accounts, in slots of their own or through the router.
    var balancingToggleProviders: [AIProviderType] {
        failoverToggleProviders.filter { $0.capabilities.sessionIsolation != nil || $0.capabilities.requestRouter != nil }
    }

    /// `policy` with failover on or off as the Failover switches set it:
    /// "Move the active account automatically" and "Failover: switch at a
    /// threshold or the limit" (`enabled`) together, so failover on means
    /// the active account moves to an account with room.
    nonisolated static func withFailover(_ policy: ProviderFailoverPolicy, on: Bool) -> ProviderFailoverPolicy {
        var next = policy
        next.movesActiveAccountAutomatically = on
        next.enabled = on
        return next
    }

    /// Whether the Failover switches show `policy` on: both settings
    /// `withFailover` sets are on.
    nonisolated static func failoverIsOn(_ policy: ProviderFailoverPolicy) -> Bool {
        policy.movesActiveAccountAutomatically && policy.enabled
    }

    /// Turns failover on or off for each of `providers` (`withFailover`),
    /// as the Settings toggles "Move the active account automatically" and
    /// "Failover: switch at a threshold or the limit" do together, and
    /// records it once for each provider changed.
    func setActiveAccountMovement(_ on: Bool, for providers: [AIProviderType], from place: String) {
        let changed = providers.filter { Self.withFailover(failoverConfig.policy(for: $0), on: on) != failoverConfig.policy(for: $0) }
        guard !changed.isEmpty else { return }
        for provider in changed {
            failoverConfig.update(provider) { $0 = Self.withFailover($0, on: on) }
        }
        let event = Self.toggleEvent("Failover", on: on, providers: changed.map(\.capabilities.displayName), from: place)
        for provider in changed { failoverEvents.record(provider, event) }
    }

    /// Turns session balancing on or off for each of `providers` as
    /// Settings' "Serve sessions from several accounts at once" does: for
    /// the routed provider, the router is installed or retired when the
    /// change needs it, and the change is kept only once that has worked;
    /// then the router's state and the slots follow. Records it once for
    /// each provider changed.
    func setSessionBalancing(_ on: Bool, for providers: [AIProviderType], from place: String) async {
        var changed: [AIProviderType] = []
        for provider in providers where failoverConfig.policy(for: provider).distributeSessions != on {
            let next = Self.withSessionBalancing(failoverConfig.policy(for: provider), on: on)
            if provider.capabilities.requestRouter != nil {
                let wanted = next.usesRouter(for: provider)
                if wanted != RequestRouterController.isInstalled() {
                    let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                        Result { wanted ? try RequestRouterController.install() : try RequestRouterController.removeFromClient() }
                    }.value
                    if case .failure(let error) = result {
                        failoverEvents.record(provider, "Session balancing was not turned \(on ? "on" : "off") from \(place): \(error.localizedDescription)")
                        continue
                    }
                    failoverConfig.update(provider) { $0 = Self.withSessionBalancing($0, on: on) }
                    if !wanted { routedStatus[provider] = nil }
                    routerCheckedAt = nil
                    await maintainRouter()
                    changed.append(provider)
                    continue
                }
            }
            failoverConfig.update(provider) { $0 = Self.withSessionBalancing($0, on: on) }
            changed.append(provider)
        }
        guard !changed.isEmpty else { return }
        applyRouterState()
        await maintainSessionSlots()
        let event = Self.toggleEvent("Session balancing", on: on, providers: changed.map(\.capabilities.displayName), from: place)
        for provider in changed { failoverEvents.record(provider, event) }
    }
}
