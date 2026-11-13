import Foundation

private let holdLog = FileLog("RequestHold")

/// Sends a provider CLI's model requests through the router's
/// `ProviderPassthrough`, so a pause holds them for as long as it lasts.
///
/// The CLI's base URL (`RequestHoldSupport`) is pointed at
/// `/__provider/<key>` while the provider pauses agents and the router runs;
/// its previous value is recorded in `Router/passthrough.json` as the
/// upstream the router forwards to, and is written back when either stops.
/// A CLI whose hold is bridged (`RequestHoldSupport.bridgedProtocol`) is
/// pointed there instead while its policy routes it through the bridge
/// (`ProviderFailoverPolicy.usesBridge(for:)`) and the router's agent is
/// installed, whatever its pause setting.
/// A CLI reads the setting when it starts, so sessions started earlier keep
/// their old endpoint, and those started while it was set keep reaching the
/// router until they end, which keeps the router from being retired as idle.
enum ProviderRequestHold {
    static let marker = "# accountdock-router"

    static var providers: [AIProviderType] {
        AIProviderType.implementedProviders.filter { $0.capabilities.requestHold != nil && $0.capabilities.pauseGate != nil }
    }

    private static func settingsURL(_ hold: RequestHoldSupport) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(hold.settingsFile)
    }

    static func routedURL(_ provider: AIProviderType) -> String? {
        provider.capabilities.pauseGate.map { ProviderPassthrough.baseURL(key: $0.key) }
    }

    /// Whether the CLI's requests go through the router now, read from its
    /// config; `AppState.routeToTarget` routes a bridged provider only then.
    static func pointsAtRouter(_ provider: AIProviderType) -> Bool {
        guard let hold = provider.capabilities.requestHold, let routed = routedURL(provider) else { return false }
        return TOMLHookConfig.value(at: settingsURL(hold), table: hold.table, key: hold.key) == routed
    }

    /// Whether the router holds the CLI's requests for a pause now. The
    /// pause gate then lets a step go on at its own limit instead of
    /// refusing it, since the next request waits in the router.
    static func isActive(_ provider: AIProviderType) -> Bool {
        provider.capabilities.requestHold?.holdsPausedRequests == true && pointsAtRouter(provider)
    }

    /// Whether `provider`'s CLI is to be pointed at the router: never when
    /// it would lose its credential there; a bridged hold while `policy`
    /// routes the provider through the bridge and the router's agent is
    /// installed; any other while the provider pauses agents and the routed
    /// provider's router runs.
    static func wantsRouter(_ provider: AIProviderType, pausing: Set<AIProviderType>, routerRunning: Bool,
                            policy: ProviderFailoverPolicy, agentInstalled: Bool) -> Bool {
        guard let hold = provider.capabilities.requestHold, hold.keepsCredentialAtRouter else { return false }
        if hold.bridgedProtocol != nil { return policy.usesBridge(for: provider) && agentInstalled }
        return pausing.contains(provider) && routerRunning
    }

    /// Points each provider's CLI at the router while `enabled` contains it,
    /// the router runs and the CLI keeps its credential there, and restores
    /// the recorded endpoint otherwise.
    static func synchronize(enabledFor enabled: Set<AIProviderType>, routerRunning: Bool) {
        var entries = ProviderPassthrough.entries()
        for provider in providers {
            guard let hold = provider.capabilities.requestHold, let key = provider.capabilities.pauseGate?.key,
                  let routed = routedURL(provider) else { continue }
            let url = settingsURL(hold)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let current = TOMLHookConfig.value(at: url, table: hold.table, key: hold.key)
            do {
                if wantsRouter(provider, pausing: enabled, routerRunning: routerRunning,
                               policy: FailoverConfigStore.storedPolicy(for: provider),
                               agentInstalled: RequestRouterController.agentInstalled) {
                    if current != routed || entries[key] == nil {
                        let previous = current.flatMap { $0 == routed || $0.isEmpty ? nil : $0 }
                        let upstream = previous ?? entries[key]?.upstream ?? hold.defaultUpstream
                        entries[key] = ProviderPassthrough.Entry(upstream: upstream, sessionField: hold.sessionField,
                                                                 holdsRequests: hold.holdsPausedRequests)
                        // The upstream is recorded before the CLI is pointed
                        // at the router, which forwards to it.
                        try writeEntries(entries)
                    }
                    if current != routed {
                        try TOMLHookConfig.setValue(at: url, table: hold.table, key: hold.key, value: routed, comment: marker)
                        holdLog.info("\(provider.rawValue) model requests now go through the router, for sessions started from now")
                    }
                } else if current == routed {
                    let upstream = entries[key]?.upstream ?? hold.defaultUpstream
                    if hold.keyAbsentByDefault, upstream == hold.defaultUpstream {
                        try TOMLHookConfig.removeValue(at: url, table: hold.table, key: hold.key)
                    } else {
                        try TOMLHookConfig.setValue(at: url, table: hold.table, key: hold.key, value: upstream, comment: nil)
                    }
                    holdLog.info("\(provider.rawValue) model requests go to \(upstream) again")
                }
            } catch {
                holdLog.warning("\(provider.rawValue) request hold update failed: \(error.localizedDescription)")
            }
        }
    }

    private static func writeEntries(_ entries: [String: ProviderPassthrough.Entry]) throws {
        try FileManager.default.createDirectory(at: ProviderPassthrough.entriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RouterConfig.encoder().encode(entries).write(to: ProviderPassthrough.entriesURL, options: .atomic)
    }
}
