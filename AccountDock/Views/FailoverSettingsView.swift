import SwiftUI

struct FailoverSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared

    var body: some View {
        Form {
            Section {
                Text("Automatically rotate within each provider. Thresholds trigger a switch; they are not ceilings. Destination accounts remain usable until a provider-reported session or long window reaches 100%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AIProviderType.implementedProviders) { provider in
                providerSection(provider)
            }

            Section {
                Label(
                    "Account switching changes the credentials consumed by that provider's CLI. Providers are never crossed.",
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
                Picker("Failover switch method", selection: binding(provider, \.codexSwitchMode)) {
                    ForEach(CodexFailoverSwitchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help(codexSwitchModeHelp(policy.codexSwitchMode))
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
            Toggle("Keep reset windows warm", isOn: binding(provider, \.keepWindowsWarm))
                .help(
                    provider.capabilities.supportsSessionQuota
                        ? "For every managed account, after a confirmed session or weekly reset, send one minimal non-persistent request so its new countdown starts. Failover exclusions do not disable warming."
                        : "For every managed account, after a confirmed weekly reset, send one minimal ephemeral request so its new countdown starts. Failover exclusions do not disable warming."
                )

            Toggle("Suspend agents when all accounts are exhausted", isOn: binding(provider, \.suspendAgentsWhenExhausted))
                .help("Pauses running provider CLI processes without terminating them. AccountDock resumes those exact processes after capacity returns.")

            Toggle("Intelligent long-window balancing", isOn: binding(provider, \.intelligentBalancingEnabled))
                .help("Targets full usable quota across included accounts. Accounts resetting sooner are deliberately consumed more aggressively before their allowance clears, while exhausted session windows are always rejected.")
            if policy.intelligentBalancingEnabled {
                LabeledContent("Switch advantage") {
                    Stepper(
                        "\(Int(policy.balancingMinimumAdvantage)) points",
                        value: binding(provider, \.balancingMinimumAdvantage),
                        in: 2...25,
                        step: 1
                    )
                    .monospacedDigit()
                }
                .padding(.leading, 20)
                .help("Required reset-adjusted utilization advantage before AccountDock rebalances. Larger values reduce switching.")

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

                if provider == .codex && policy.codexSwitchMode == .safeRestart {
                    Label(
                        "Codex balancing waits in Switch Safely mode because healthy sessions have no limit error. Choose Switch Without Restart or Force Restart Sessions to rebalance proactively.",
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

    private func codexSwitchModeHelp(_ mode: CodexFailoverSwitchMode) -> String {
        switch mode {
        case .safeRestart:
            "Waits for a running session to receive a usage-limit error, then switches and resumes only affected sessions."
        case .forceRestart:
            "Acts immediately when the reported quota reaches the threshold, closes detected Codex Terminal sessions, and resumes them after switching."
        case .withoutRestart:
            "Acts immediately and signals running sessions to reload credentials. Requires the AccountDock Codex fork."
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
