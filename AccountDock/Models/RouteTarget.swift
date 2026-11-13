import Foundation

/// A service the routed provider's requests can be served by while every
/// one of its accounts is exhausted.
///
/// A target is backed by the accounts of one AccountDock provider, which
/// supply its credential and its remaining capacity. A provider offers a
/// target through `ProviderCapabilities.routeTarget`, and its credential
/// through `AppState.accessCredential`; the router itself needs no change.
struct RouteTarget: Identifiable, Equatable, Sendable {
    struct Model: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        /// The model's context window, in its own tokens.
        let contextTokens: Int
    }

    /// The context a model needs to be routed to: a session moved to it
    /// mid-work carries its whole conversation, and the routed provider's
    /// sessions run with a 1M-token context.
    static let minimumModelContext = 1_000_000
    /// Share of a model's window a routed request may fill. The router
    /// measures context in the routed provider's tokens, which the target
    /// counts with its own tokenizer.
    static let contextHeadroom = 0.9

    let id: String
    let displayName: String
    let baseURL: String
    let auth: RouterBackend.Auth
    let models: [Model]
    let defaultModel: String
    let provider: AIProviderType
    /// The request protocol the service accepts; it serves providers whose
    /// CLI the router speaks this protocol for.
    var clientProtocol: RouterProtocol = .anthropicMessages
    /// Whether the service rejects thinking blocks it did not sign itself.
    let validatesThinkingSignatures: Bool
    /// Whether the service keeps server-side conversations (`thread`) and
    /// understands deferred tools; the router adapts requests for one that
    /// does not.
    let acceptsMessageThreads: Bool
    let acceptsDeferredTools: Bool
    /// Window percent per million routed tokens until the target's own
    /// readings measure it.
    let defaultPercentPerMillion: Double
    let note: String

    var tokenFile: String { "target-\(id)" }

    /// The models requests may be routed to: those holding
    /// `minimumModelContext`.
    var routableModels: [Model] { models.filter { $0.contextTokens >= Self.minimumModelContext } }

    /// The routable model `id` names, or the default one.
    func model(_ id: String?) -> Model? {
        routableModels.first { $0.id == id } ?? routableModels.first { $0.id == defaultModel } ?? routableModels.first
    }

    /// Context above which a session is not routed to `model`, unless the
    /// user sets another limit.
    func defaultMaxContextTokens(model id: String?) -> Int {
        Int(Double(model(id)?.contextTokens ?? 0) * Self.contextHeadroom)
    }

    func backend(model: String?, maxContextTokens: Int?) -> RouterBackend {
        RouterBackend(
            id: id,
            displayName: displayName,
            baseURL: baseURL,
            auth: auth,
            tokenFile: tokenFile,
            model: self.model(model)?.id ?? defaultModel,
            validatesThinkingSignatures: validatesThinkingSignatures,
            reportsUnifiedUsage: false,
            acceptsMessageThreads: acceptsMessageThreads,
            acceptsDeferredTools: acceptsDeferredTools,
            maxContextTokens: maxContextTokens ?? defaultMaxContextTokens(model: model)
        )
    }

    static let kimi = RouteTarget(
        id: "kimi",
        displayName: "Kimi",
        baseURL: "https://api.kimi.ai/coding/",
        auth: .bearer,
        models: [
            .init(id: "k3", label: "K3", contextTokens: 1_048_576),
            .init(id: "k3.1-pro", label: "K3.1 Pro", contextTokens: 1_048_576),
            .init(id: "k3.1-pro-highspeed", label: "K3.1 Pro, high speed (2× usage)", contextTokens: 1_048_576),
            .init(id: "k3-256k", label: "K3 (256k context)", contextTokens: 262_144),
            .init(id: "kimi-for-coding", label: "Kimi for Coding (K2.8 preview)", contextTokens: 1_048_576),
            .init(id: "kimi-for-coding-highspeed", label: "Kimi for Coding, high speed", contextTokens: 262_144),
        ],
        defaultModel: "k3",
        provider: .kimi,
        clientProtocol: .anthropicMessages,
        validatesThinkingSignatures: false,
        acceptsMessageThreads: false,
        acceptsDeferredTools: false,
        // Measured: a routed burst of 23 million tokens used one 5-hour window.
        defaultPercentPerMillion: 4.2,
        note: "Uses the active Kimi account's login. Kimi counts every routed token against its 5-hour window: one request with a 300k-token conversation uses about 1% of it."
    )

    static var all: [RouteTarget] {
        AIProviderType.implementedProviders.compactMap { $0.capabilities.routeTarget }
    }

    /// Models a session's transcript names when the router served it from a
    /// target of `provider`; their usage belongs to that provider.
    static func routedModels(for provider: AIProviderType) -> Set<String> {
        Set(all.filter { $0.provider == provider }.flatMap { $0.models.map(\.id) + [$0.defaultModel] })
    }

    /// Every model a route target serves, for leaving routed requests out of
    /// the routed-from provider's own usage.
    static var allRoutedModels: Set<String> { Set(all.flatMap { routedModels(for: $0.provider) }) }

    static func named(_ id: String?) -> RouteTarget? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Targets for routing `provider`'s requests: other providers' services
    /// that accept the protocol the router serves `provider` with, or the one
    /// it bridges the provider's requests to
    /// (`RequestHoldSupport.bridgedProtocol`), and offer a model holding
    /// `minimumModelContext`.
    static func available(for provider: AIProviderType) -> [RouteTarget] {
        let capabilities = provider.capabilities
        guard let served = capabilities.requestRouter?.clientProtocol ?? capabilities.requestHold?.bridgedProtocol else { return [] }
        return all.filter { $0.provider != provider && $0.clientProtocol == served && !$0.routableModels.isEmpty }
    }
}
