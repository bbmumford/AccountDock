import SwiftUI

struct FailoverSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FailoverConfigStore.shared

    var body: some View {
        Form {
            Section {
                Text("Automatically rotate to another account from the same provider when the active subscription reaches a configured limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            providerSection(.claudeCode)
            providerSection(.codex)

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

        Section {
            Toggle("Enable automatic failover", isOn: binding(provider, \.enabled))

            if provider == .claudeCode {
                thresholdRow(
                    title: "Session limit",
                    enabled: binding(provider, \.sessionEnabled),
                    threshold: binding(provider, \.sessionThreshold)
                )
            } else {
                LabeledContent("Session limit") {
                    Text("Not reported by Codex")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            thresholdRow(
                title: "Weekly limit",
                enabled: binding(provider, \.weeklyEnabled),
                threshold: binding(provider, \.weeklyThreshold)
            )

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
                            Image(systemName: provider.iconName)
                                .foregroundStyle(.brand)
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
            if policy.enabled && providerAccounts.count < 2 {
                Text("Failover needs at least two managed accounts for this provider.")
            }
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
        for provider in [AIProviderType.claudeCode, .codex] {
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
