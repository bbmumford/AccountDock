import Foundation

private let holdLog = FileLog("RequestHold")

/// Sends a provider CLI's model requests through the router's
/// `ProviderPassthrough`, so a pause holds them for as long as it lasts.
///
/// The CLI's base URL (`RequestHoldSupport`) is pointed at
/// `/__provider/<key>` while the provider pauses agents and the router runs;
/// its previous value is recorded in `Router/passthrough.json` as the
/// upstream the router forwards to, and is written back when either stops.
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
    /// config. The pause gate then lets a step go on at its own limit
    /// instead of refusing it, since the next request waits in the router.
    static func isActive(_ provider: AIProviderType) -> Bool {
        guard let hold = provider.capabilities.requestHold, let routed = routedURL(provider) else { return false }
        return TOMLHookConfig.value(at: settingsURL(hold), table: hold.table, key: hold.key) == routed
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
                if enabled.contains(provider), routerRunning, hold.keepsCredentialAtRouter {
                    if current != routed || entries[key] == nil {
                        let previous = current.flatMap { $0 == routed || $0.isEmpty ? nil : $0 }
                        let upstream = previous ?? entries[key]?.upstream ?? hold.defaultUpstream
                        entries[key] = ProviderPassthrough.Entry(upstream: upstream, sessionField: hold.sessionField)
                        // The upstream is recorded before the CLI is pointed
                        // at the router, which forwards to it.
                        try writeEntries(entries)
                    }
                    if current != routed {
                        try TOMLHookConfig.setValue(at: url, table: hold.table, key: hold.key, value: routed, comment: marker)
                        holdLog.info("\(provider.rawValue) model requests now go through the router; sessions started from now are held for whole pauses")
                    }
                } else if current == routed {
                    let upstream = entries[key]?.upstream ?? hold.defaultUpstream
                    try TOMLHookConfig.setValue(at: url, table: hold.table, key: hold.key, value: upstream, comment: nil)
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
