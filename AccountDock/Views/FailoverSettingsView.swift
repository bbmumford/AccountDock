import SwiftUI

struct FailoverSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared
    @AppStorage(ClaudeStatusLineTelemetry.preferenceKey) private var statusLineTelemetry = true
    @State private var routerError: String?
    @State private var routerBusy = false

    var body: some View {
        Form {
            Section {
                Text("Automatically rotate within each provider. A threshold starts a switch to an account that is below its thresholds on both the session and long window. When no such account exists, the active account keeps working up to the provider limit, then moves to the account with the most remaining capacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AIProviderType.implementedProviders) { provider in
                providerSection(provider)
            }

            Section {
                Label(
                    "Account switching changes the credentials consumed by that provider's CLI. Requests reach another provider only through the router's route target, and only while every account of the routed provider is exhausted.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: synchronizeOrders)
        .onChange(of: appState.accounts) { _, _ in synchronizeOrders() }
    }

    @ViewBuilder
    private func providerSection(_ provider: AIProviderType) -> some View {
        let policy = store.policy(for: provider)
        let providerAccounts = orderedAccounts(for: provider, policy: policy)
        let includedCount = providerAccounts.filter { !policy.excludedAccountIDs.contains($0.id) }.count

        Section {
            Toggle("Enable automatic failover", isOn: binding(provider, \.enabled))

            if provider.capabilities.supportsSessionQuota {
                thresholdRow(
                    title: "Session limit",
                    enabled: binding(provider, \.sessionEnabled),
                    threshold: binding(provider, \.sessionThreshold)
                )
            }

            thresholdRow(
                title: provider.capabilities.weeklyQuotaLabel,
                enabled: binding(provider, \.weeklyEnabled),
                threshold: binding(provider, \.weeklyThreshold)
            )

            if provider.capabilities.supportsSelectableSwitchMode {
                Picker("Failover switch method", selection: binding(provider, \.switchMethod)) {
                    ForEach(FailoverSwitchMethod.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help(switchMethodHelp(policy.switchMethod, provider: provider))
            }

            Toggle("Loop through accounts continuously", isOn: binding(provider, \.loops))
            Toggle("Prefer an account after its limit resets", isOn: binding(provider, \.resetAware))
            Toggle("Prefer the account with the most headroom", isOn: binding(provider, \.preferMostCapacity))
            Toggle("Wait for an imminent reset", isOn: binding(provider, \.waitForImminentReset))
            if policy.waitForImminentReset {
                LabeledContent("Reset grace period") {
                    Stepper(
                        "\(Int(policy.resetGraceMinutes)) min",
                        value: binding(provider, \.resetGraceMinutes),
                        in: 1...30,
                        step: 1
                    )
                    .monospacedDigit()
                }
                .padding(.leading, 20)
            }
            if provider.capabilities.supportsWindowWarming {
                Toggle("Keep reset windows warm", isOn: binding(provider, \.keepWindowsWarm))
                    .help(
                        "For every managed account, after a confirmed \(provider.capabilities.supportsSessionQuota ? "\(provider.capabilities.sessionQuotaLabel.lowercased()) or " : "")\(provider.capabilities.weeklyQuotaLabel.lowercased()) reset, send one minimal non-persistent request so its new countdown starts. Failover exclusions do not disable warming."
                    )
            }

            if provider.capabilities.liveUsageFeed == .statusLine {
                Toggle("Read live quota from \(provider.rawValue)'s status line", isOn: $statusLineTelemetry)
                    .help("Wraps the configured Claude Code status-line command so the 5-hour and weekly limits Claude Code receives with every response are recorded for AccountDock. The original status line keeps working unchanged. This removes most usage-endpoint requests, which is what Anthropic throttles.")
                    .onChange(of: statusLineTelemetry) { _, _ in
                        Task.detached(priority: .utility) { ClaudeStatusLineTelemetry.synchronize() }
                    }
            }

            Toggle("Pause sessions when all accounts are exhausted", isOn: binding(provider, \.suspendAgentsWhenExhausted))
                .help("When no other account can take the work, every session waits before its next request, shortly before the active account reaches its limit, so no request fails, and new turns wait at their start. Terminals stay usable, and sessions continue once a verified account has capacity.")

            if policy.suspendAgentsWhenExhausted, provider.capabilities.pauseGate != nil {
                if provider.capabilities.requestRouter != nil {
                    Toggle("Resume sessions as capacity allows", isOn: binding(provider, \.resumeAsCapacityAllows))
                        .padding(.leading, 20)
                        .help("Paused sessions continue a few at a time as accounts reset, each on an account where its forecast use fits before that account's window resets, instead of all at once on the first account that resets. A session's forecast is its average use in the hour before it paused, so one doing most of the work goes first and small ones fill what is left. A resumed session is paused again if its account nears its limit anyway.")
                }
                pauseControls(provider)
            }

            if provider.capabilities.requestRouter != nil {
                routingControls(provider, policy: policy)
            } else if provider.capabilities.requestHold?.bridgedProtocol != nil, !RouteTarget.available(for: provider).isEmpty {
                bridgeControls(provider, policy: policy)
            }

            Toggle("Intelligent long-window balancing", isOn: binding(provider, \.intelligentBalancingEnabled))
                .help("Spends included accounts in the order their allowances would otherwise expire: an account whose weekly or monthly limit resets sooner, or whose remaining allowance its 5-hour cap could no longer drain in time, is used first. Destinations must be below their thresholds on both windows.")
            if policy.intelligentBalancingEnabled {
                LabeledContent("Switch advantage") {
                    Stepper(
                        "\(Int(policy.balancingMinimumAdvantageHours)) h",
                        value: binding(provider, \.balancingMinimumAdvantageHours),
                        in: 1...72,
                        step: 1
                    )
                    .monospacedDigit()
                }
                .padding(.leading, 20)
                .help("How much sooner another account's remaining allowance must need to start being used, to be fully consumed before it resets, before AccountDock moves work to it. Larger values reduce switching.")

                LabeledContent("Minimum time on account") {
                    Stepper(
                        "\(Int(policy.balancingMinimumDwellMinutes)) min",
                        value: binding(provider, \.balancingMinimumDwellMinutes),
                        in: 5...180,
                        step: 5
                    )
                    .monospacedDigit()
                }
                .padding(.leading, 20)
                .help("Prevents oscillation after a balancing switch. Threshold failover still acts immediately.")

                if provider.capabilities.supportsSelectableSwitchMode && policy.switchMethod == .safeRestart {
                    Label(
                        "\(provider.capabilities.displayName) balancing waits in Switch Safely mode because healthy sessions have no limit error. Choose Switch Without Restart or Force Restart Sessions to rebalance proactively.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let status = appState.failoverStatus[provider] {
                Label(status, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Failover order")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if providerAccounts.isEmpty {
                    Text("Add at least two \(provider.rawValue) accounts to use failover.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(providerAccounts.enumerated()), id: \.element.id) { index, account in
                        HStack {
                            Toggle(
                                "Include \(account.effectiveDisplayName(obfuscated: false)) in failover",
                                isOn: accountIncludedBinding(provider, account.id)
                            )
                            .labelsHidden()
                            .help("Include this account in automatic failover")
                            Image(systemName: provider.iconName)
                                .foregroundStyle(
                                    policy.excludedAccountIDs.contains(account.id)
                                        ? Color.secondary
                                        : Color.brand
                                )
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.effectiveDisplayName(obfuscated: false))
                                    .lineLimit(1)
                                Text(account.displayEmail(obfuscated: true))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if account.isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                            if policy.excludedAccountIDs.contains(account.id) {
                                Text("EXCLUDED")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                move(provider, accountID: account.id, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            Button {
                                move(provider, accountID: account.id, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == providerAccounts.count - 1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Label(provider.rawValue, systemImage: provider.iconName)
        } footer: {
            if (policy.enabled || policy.intelligentBalancingEnabled) && includedCount < 2 {
                Text("Automatic switching needs at least two included accounts for this provider.")
            }
        }
    }

    private func switchMethodHelp(_ mode: FailoverSwitchMethod, provider: AIProviderType) -> String {
        switch mode {
        case .safeRestart:
            "Waits for a running session to receive a usage-limit error, then switches and resumes only affected sessions."
        case .forceRestart:
            "Acts immediately when the reported quota reaches the threshold, closes detected \(provider.capabilities.displayName) Terminal sessions, and resumes them after switching."
        case .withoutRestart:
            "Acts immediately and signals running sessions to reload credentials. Requires the AccountDock \(provider.capabilities.displayName) fork."
        }
    }

    private func thresholdRow(
        title: String,
        enabled: Binding<Bool>,
        threshold: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: enabled)
            HStack {
                Slider(value: threshold, in: 50...100, step: 1)
                    .disabled(!enabled.wrappedValue)
                Text("\(Int(threshold.wrappedValue))%")
                    .font(.body.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.leading, 20)
        }
    }

    /// Pausing on demand, so work can move onto accounts at or near their
    /// limits, or off one failover excludes, without a request reaching a
    /// limit first.
    @ViewBuilder
    private func pauseControls(_ provider: AIProviderType) -> some View {
        if let status = appState.agentPauseStatus[provider] {
            LabeledContent {
                Button("Resume now") {
                    Task { await appState.resumePausedAgentsNow(provider) }
                }
                .help("Let the paused sessions continue now. They may then reach the usage limit.")
            } label: {
                Label(
                    "\(status.manual ? "Paused by you" : "Paused at the limit") since \(status.since.formatted(date: .omitted, time: .shortened))",
                    systemImage: "pause.circle.fill"
                )
                .foregroundStyle(.orange)
            }
            .padding(.leading, 20)
        } else {
            LabeledContent {
                Button("Pause sessions now") { appState.pauseSessionsNow(provider) }
                    .help("Every session waits at its next tool call and new turns wait at their start. Use it before switching to an account at or near its limit. Sessions continue when you resume them or when an account in the failover order has capacity; an active account that failover excludes does not resume them.")
            } label: {
                Text("Hold sessions before switching accounts")
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
        }
    }

    /// Controls for a provider whose CLI reaches the router through a
    /// bridged request hold (`RequestHoldSupport.bridgedProtocol`): whether
    /// its requests go through the router at all, and the route target that
    /// serves them while every account is exhausted. Each change is applied
    /// by `AppState.applyBridgeSettings`, which installs or retires the
    /// router's agent and points the CLI's base URL there or back.
    @ViewBuilder
    private func bridgeControls(_ provider: AIProviderType, policy: ProviderFailoverPolicy) -> some View {
        let name = provider.capabilities.displayName
        let cli = provider.rawValue
        let targets = RouteTarget.available(for: provider)
        let hold = provider.capabilities.requestHold
        Toggle("Send \(cli) requests through AccountDock's router", isOn: Binding(
            get: { store.policy(for: provider).routeThroughBridge },
            set: { on in
                store.update(provider) {
                    $0.routeThroughBridge = on
                    if !on { $0.routeTarget = nil }
                }
                if !on { appState.routedStatus[provider] = nil }
                Task { await appState.applyBridgeSettings() }
            }
        ))
        .help("Lets another service serve \(cli)'s requests while every included \(name) account is exhausted. Once a service is chosen below, AccountDock sets \(hold?.key ?? "the base URL") in ~/\(hold?.settingsFile ?? "its config") to its local router, which forwards every request to \(name) unchanged until then. Turning this off restores the setting. Off by default.")
        if policy.routeThroughBridge {
            Picker("When every account is exhausted", selection: Binding(
                get: { store.policy(for: provider).routeTarget },
                set: { target in
                    store.update(provider) { $0.routeTarget = target }
                    if target == nil { appState.routedStatus[provider] = nil }
                    Task { await appState.applyBridgeSettings() }
                }
            )) {
                Text(policy.suspendAgentsWhenExhausted ? "Pause sessions" : "Do nothing").tag(String?.none)
                ForEach(targets) { target in
                    Text("Serve requests from \(target.displayName)").tag(Optional(target.id))
                }
            }
            .padding(.leading, 20)
            .help("While every included \(name) account is exhausted, the router rewrites \(cli)'s requests for the chosen service and its replies for \(cli), so sessions keep running; requests return to \(name) at each session's next turn once an account has capacity. A request \(name) refuses at the plan limit is served by the service instead of failing. \(name)'s own reasoning records and hosted tools, such as web search, are not carried over.")
            if let target = RouteTarget.named(policy.routeTarget) {
                Picker("\(target.displayName) model", selection: Binding(
                    get: { target.model(store.policy(for: provider).routeModel)?.id ?? target.defaultModel },
                    set: { model in
                        store.update(provider) { $0.routeModel = model }
                        appState.applyRouterState()
                    }
                )) {
                    ForEach(target.routableModels) { model in Text(model.label).tag(model.id) }
                }
                .padding(.leading, 20)
                Text(target.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                routeLimits(provider, target: target)
                Text("\(cli) sessions started before this was turned on reach \(name) directly until they are restarted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let routerError = appState.routerProblem {
            Text(routerError)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Controls for AccountDock's request router: a route target for when
    /// every account is exhausted, parallel accounts, and extra usage.
    @ViewBuilder
    private func routingControls(_ provider: AIProviderType, policy: ProviderFailoverPolicy) -> some View {
        let name = provider.capabilities.displayName
        let cli = provider.rawValue
        let targets = RouteTarget.available(for: provider)
        if !targets.isEmpty {
            Picker("When every account is exhausted", selection: routerBinding(provider, \.routeTarget)) {
                Text(policy.suspendAgentsWhenExhausted ? "Pause sessions" : "Do nothing").tag(String?.none)
                ForEach(targets) { target in
                    Text("Serve requests from \(target.displayName)").tag(Optional(target.id))
                }
            }
            .disabled(routerBusy)
            .help("\(cli) sends its requests through AccountDock's local router. While every included \(name) account is exhausted, the router serves them from the chosen service, so sessions keep running; requests return to \(name) at each session's next turn once an account has capacity. A request refused at the plan limit is served by the target instead of failing.")
            if let target = RouteTarget.named(policy.routeTarget) {
                Picker("\(target.displayName) model", selection: Binding(
                    get: { target.model(store.policy(for: provider).routeModel)?.id ?? target.defaultModel },
                    set: { model in store.update(provider) { $0.routeModel = model } }
                )) {
                    ForEach(target.routableModels) { model in Text(model.label).tag(model.id) }
                }
                .padding(.leading, 20)
                Text(target.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                routeLimits(provider, target: target)
            }
        }
        Toggle("Serve sessions from several accounts at once", isOn: routerBinding(provider, \.distributeSessions))
            .disabled(routerBusy)
            .help(provider.capabilities.sessionSlots != nil && policy.routeTarget == nil
                ? "Each \(cli) session started from a terminal opened afterwards runs on an account picked from those below their thresholds, so several accounts' 5-hour windows are used at the same time instead of one after another. A session keeps its account until it exits. Sessions started from an IDE or the desktop app, and those started before this was turned on, use the active account. Usage is read by polling each account."
                : "The router serves each \(cli) session from its own account, so several accounts' 5-hour windows are used at the same time instead of one after another. Each session keeps its account while it has room, which keeps its prompt cache; accounts below their thresholds take new sessions, those whose allowance must start being used soonest first. Usage is read from every response, so no extra requests are made.")
        if policy.distributeSessions {
            Toggle("Pace sessions to each account's 5-hour window", isOn: Binding(
                get: { store.policy(for: provider).paceSessions },
                set: { on in store.update(provider) { $0.paceSessions = on } }
            ))
            .padding(.leading, 20)
            .help(policy.usesRouter(for: provider)
                ? "New sessions go to the accounts with the most unused rate for the rest of their 5-hour window. A session keeps its account while its prompt cache lasts. When an account's sessions would reach its limit and stay there for longer than their cache lasts, some of them move to accounts that can carry them, at their next turn. Otherwise they stay; a session that reaches the limit with the reset at most five minutes away, before its cache expires, waits for it on its account. A session idle past its cache's lifetime is placed again at its next turn, as nothing is lost by moving it."
                : "New sessions go to the accounts with the most unused rate for the rest of their 5-hour window, in proportion to it. A session keeps its account until it exits.")
            let choices = provider.capabilities.sessionModelChoices
            if let first = choices.first {
                Toggle("When no account has allowance for a session's model, switch it to another model", isOn: Binding(
                    get: { store.policy(for: provider).noRoomModelFallback != nil },
                    set: { on in store.update(provider) { $0.noRoomModelFallback = on ? ($0.noRoomModelFallback ?? first.id) : nil } }
                ))
                .padding(.leading, 20)
                .help("A session whose model has its own weekly allowance, spent on every account, is refused until one resets. With this on, AccountDock types /model and the model below into the session's terminal once its turn has ended, when the session runs in agterm. Each switch, and each session it cannot reach, is recorded in the events.")
                if let fallback = policy.noRoomModelFallback {
                    Picker("Switch to", selection: Binding(
                        get: { fallback },
                        set: { model in store.update(provider) { $0.noRoomModelFallback = model } }
                    )) {
                        ForEach(choices) { choice in Text(choice.label).tag(choice.id) }
                    }
                    .padding(.leading, 40)
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }
        }
        if RequestRouterController.isInstalled() {
            Toggle("Keep prompt caches for an hour", isOn: Binding(
                get: { store.policy(for: provider).extendCacheLifetime },
                set: { on in store.update(provider) { $0.extendCacheLifetime = on } }
            ))
            .help("On a subscription \(cli) asks for the one-hour prompt cache for its main conversation, but for five minutes for subagents, workflow agents and background requests, and for every request while the account is on extra usage. A request among those that comes after a longer gap writes its whole context to the cache again. The router asks for the one-hour cache on every request to a Claude account, including those of sessions started before \(cli)'s own cache settings changed; only newly cached tokens cost more.")
            let ledger = appState.cacheExtension
            if ledger.saved > 0 || ledger.premium > 0 {
                Text("Last 7 days: about \(Self.windowPercent(ledger.saved, appState)) of a 5-hour window saved for \(Self.windowPercent(ledger.premium, appState)) more in cache writes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
        if policy.usesRouter(for: provider) {
            Text("\(cli) sessions started before the router was turned on reach \(name) directly until they are restarted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if provider.capabilities.supportsExtraUsage {
            Toggle("Use extra usage when every allowance is exhausted", isOn: Binding(
                get: { store.policy(for: provider).extraUsageMonthlyLimit != nil },
                set: { on in store.update(provider) { $0.extraUsageMonthlyLimit = on ? ($0.extraUsageMonthlyLimit ?? 50) : nil } }
            ))
            .help("Accounts with extra usage turned on with \(name) keep serving past their plan limit, only once every included account's allowance is exhausted, and only while that month's extra usage stays under the limit below.")
            if let limit = policy.extraUsageMonthlyLimit {
                LabeledContent("Monthly extra usage limit") {
                    Stepper("\(Int(limit))", value: Binding(
                        get: { store.policy(for: provider).extraUsageMonthlyLimit ?? limit },
                        set: { value in store.update(provider) { $0.extraUsageMonthlyLimit = value } }
                    ), in: 5...2_000, step: 5)
                    .monospacedDigit()
                }
                .padding(.leading, 20)
                .help("In each account's billing currency.")
            }
        }
        if let routerError = routerError ?? appState.routerProblem {
            Text(routerError)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// What the route target may take: sessions up to a context size, down
    /// to a share of its window kept for its own sessions, and only when it
    /// would carry the demand long enough to be worth the switch.
    @ViewBuilder
    private func routeLimits(_ provider: AIProviderType, target: RouteTarget) -> some View {
        let policy = store.policy(for: provider)
        let cap = policy.routeMaxContextTokens ?? target.defaultMaxContextTokens(model: policy.routeModel)
        LabeledContent("Route sessions up to") {
            Stepper("\(cap / 1_000)k tokens", value: Binding(
                get: { cap / 1_000 },
                set: { value in store.update(provider) { $0.routeMaxContextTokens = value * 1_000 } }
            ), in: 25...max(25, (target.model(policy.routeModel)?.contextTokens ?? 1_000_000) / 1_000), step: 25)
            .monospacedDigit()
        }
        .padding(.leading, 20)
        .help("A session with more context than this is paused until \(provider.capabilities.displayName) has capacity instead of being routed. Unless set, it is \(Int(RouteTarget.contextHeadroom * 100))% of the model's context window, which leaves room for \(target.displayName) counting the conversation with its own tokenizer. \(target.displayName) counts every routed token against its window, so routing starts only while it would carry the demand for the time set below.")
        LabeledContent("Keep for \(target.displayName) sessions") {
            Stepper("\(Int(policy.routeReservePercent))%", value: Binding(
                get: { store.policy(for: provider).routeReservePercent },
                set: { value in store.update(provider) { $0.routeReservePercent = value } }
            ), in: 0...90, step: 5)
            .monospacedDigit()
        }
        .padding(.leading, 20)
        .help("Routing stops before \(target.displayName)'s \(target.provider.capabilities.sessionQuotaLabel) window falls below this share, which stays for its own sessions.")
        LabeledContent("Route only if it lasts") {
            Stepper("\(Int(policy.routeMinimumMinutes)) min", value: Binding(
                get: { store.policy(for: provider).routeMinimumMinutes },
                set: { value in store.update(provider) { $0.routeMinimumMinutes = value } }
            ), in: 0...120, step: 5)
            .monospacedDigit()
        }
        .padding(.leading, 20)
        .help("Routing starts only when \(target.displayName) is expected to carry the busiest recent demand at least this long, from what routed tokens have cost its window so far.")
        if let verdict = appState.routeTargetVerdicts[target.id], !verdict.serves, let reason = verdict.reason {
            Label("Not routing now: \(reason).", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    /// Settings that need the router install it first and keep it only while
    /// at least one of them is on.
    /// Weighted tokens as a share of one 5-hour window at the learned ratio.
    private static func windowPercent(_ tokens: Double, _ appState: AppState) -> String {
        let percent = tokens / 1_000_000 * appState.turnCostModel.ratio
        return percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }

    private func routerBinding<Value: Equatable>(
        _ provider: AIProviderType,
        _ keyPath: WritableKeyPath<ProviderFailoverPolicy, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.policy(for: provider)[keyPath: keyPath] },
            set: { value in
                var next = store.policy(for: provider)
                next[keyPath: keyPath] = value
                let wanted = next.usesRouter(for: provider)
                let installed = RequestRouterController.isInstalled()
                routerError = nil
                guard wanted != installed else {
                    store.update(provider) { $0[keyPath: keyPath] = value }
                    appState.applyRouterState()
                    Task { await appState.maintainSessionSlots() }
                    return
                }
                routerBusy = true
                Task {
                    let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                        Result { wanted ? try RequestRouterController.install() : try RequestRouterController.removeFromClient() }
                    }.value
                    routerBusy = false
                    switch result {
                    case .success:
                        store.update(provider) { $0[keyPath: keyPath] = value }
                        if !wanted { appState.routedStatus[provider] = nil }
                        appState.routerCheckedAt = nil
                        await appState.maintainRouter()
                        await appState.maintainSessionSlots()
                    case .failure(let error):
                        routerError = error.localizedDescription
                    }
                }
            }
        )
    }

    private func binding<Value>(
        _ provider: AIProviderType,
        _ keyPath: WritableKeyPath<ProviderFailoverPolicy, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.policy(for: provider)[keyPath: keyPath] },
            set: { value in store.update(provider) { $0[keyPath: keyPath] = value } }
        )
    }

    private func accountIncludedBinding(
        _ provider: AIProviderType,
        _ accountID: UUID
    ) -> Binding<Bool> {
        Binding(
            get: { !store.policy(for: provider).excludedAccountIDs.contains(accountID) },
            set: { included in
                store.update(provider) { policy in
                    if included {
                        policy.excludedAccountIDs.remove(accountID)
                    } else {
                        policy.excludedAccountIDs.insert(accountID)
                    }
                }
            }
        )
    }

    private func orderedAccounts(
        for provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> [Account] {
        let providerAccounts = appState.accounts.filter { $0.provider == provider }
        let byID = Dictionary(uniqueKeysWithValues: providerAccounts.map { ($0.id, $0) })
        return policy.accountOrder.compactMap { byID[$0] }
            + providerAccounts.filter { !policy.accountOrder.contains($0.id) }
    }

    private func synchronizeOrders() {
        for provider in AIProviderType.implementedProviders {
            store.synchronizeOrder(
                provider: provider,
                accountIDs: appState.accounts.filter { $0.provider == provider }.map(\.id)
            )
        }
    }

    private func move(_ provider: AIProviderType, accountID: UUID, offset: Int) {
        store.update(provider) { policy in
            guard let index = policy.accountOrder.firstIndex(of: accountID) else { return }
            let destination = index + offset
            guard policy.accountOrder.indices.contains(destination) else { return }
            policy.accountOrder.swapAt(index, destination)
        }
    }
}
