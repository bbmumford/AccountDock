import SwiftUI
import UniformTypeIdentifiers

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var failoverStore = FailoverConfigStore.shared
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""
    @State private var pendingSwitchAccount: Account?
    @State private var pendingCodexProcesses: [RunningCodexProcess] = []
    @State private var showingCodexSwitchMethods = false
    @State private var draggedAccountID: UUID?
    @State private var draggedProvider: AIProviderType?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    if appState.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(providerOrder) { provider in
                            VStack(alignment: .leading, spacing: 8) {
                                providerHeader(provider)

                                ForEach(accounts(for: provider)) { account in
                                    accountRow(account)
                                }
                            }
                        }
                    }
                }
                .padding(16)

                addAccountButtons
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
            }
            .measureUsageContentHeight()
        }
        .alert("Choose \(pendingSwitchAccount?.provider.rawValue ?? "") switch method", isPresented: $showingCodexSwitchMethods) {
            Button("Force Restart Sessions", role: .destructive) {
                guard let account = pendingSwitchAccount else { return }
                let processes = pendingCodexProcesses
                clearPendingSwitch()
                Task {
                    await appState.switchTo(
                        account,
                        safelyRestartingCodex: processes,
                        closeCodexTerminalTabs: true
                    )
                }
            }
            Button("Switch Safely") {
                guard let account = pendingSwitchAccount else { return }
                let processes = pendingCodexProcesses
                clearPendingSwitch()
                Task {
                    await appState.switchTo(account, safelyRestartingCodex: processes)
                }
            }
            Button("Switch Without Restart") {
                guard let account = pendingSwitchAccount else { return }
                let processes = pendingCodexProcesses
                clearPendingSwitch()
                Task { await appState.switchTo(account, liveReloadingCodex: processes) }
            }
            Button("Cancel", role: .cancel) {
                clearPendingSwitch()
            }
        } message: {
            Text(codexProcessWarningMessage)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.textSecondary)

            Text("No Accounts")
                .font(.headline)

            Text("Add a \(AIProviderType.implementedNames(conjunction: "or")) account to get started.")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private var providerOrder: [AIProviderType] {
        var result: [AIProviderType] = []
        for account in appState.accounts where !result.contains(account.provider) {
            result.append(account.provider)
        }
        return result
    }

    private func accounts(for provider: AIProviderType) -> [Account] {
        appState.accounts.filter { $0.provider == provider }
    }

    private func providerHeader(_ provider: AIProviderType) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .frame(width: 14, height: 28)
                .contentShape(Rectangle())
                .onDrag {
                    draggedProvider = provider
                    return NSItemProvider(object: provider.rawValue as NSString)
                }

            Label(
                provider.capabilities.displayName,
                systemImage: provider.iconName
            )
            .font(.headline)
            .foregroundStyle(.brand)

            Spacer()
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: ProviderDisplayOrderDropDelegate(
                destination: provider,
                draggedProvider: $draggedProvider,
                move: appState.moveProvider(from:to:)
            )
        )
        .help("Drag to reorder provider groups")
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .frame(width: 14, height: 32)
                .contentShape(Rectangle())
                .onDrag {
                    draggedAccountID = account.id
                    return NSItemProvider(object: account.id.uuidString as NSString)
                }
                .help("Drag to reorder")

            // Provider icon
            Image(systemName: account.provider.iconName)
                .font(.title2)
                .foregroundStyle(account.isActive ? providerTint(account.provider) : .secondary)
                .frame(width: 32, height: 32)

            // Account info
            VStack(alignment: .leading, spacing: 2) {
                if editingAccountId == account.id {
                    HStack(spacing: 4) {
                        TextField("Custom label", text: $editingLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .onSubmit { commitLabelEdit(account) }

                        Button {
                            commitLabelEdit(account)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.brand)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingAccountId = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(account.effectiveDisplayName(obfuscated: !showFullEmail))
                            .font(.subheadline.weight(.medium))

                        Button {
                            editingLabel = account.customLabel ?? ""
                            editingAccountId = account.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit label")

                        if account.isActive {
                            Badge(text: String(localized: "Active", bundle: L10n.bundle), color: .brand)
                        }
                        if appState.needsSignIn(account) {
                            Badge(text: String(localized: "Needs sign-in", bundle: L10n.bundle), color: .orange)
                        }
                    }
                }

                AccountEmailLabel(email: account.email, alwaysVisible: showFullEmail)

                HStack(spacing: 8) {
                    if let sub = account.displaySubscriptionType {
                        Label(sub, systemImage: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                    }
                    Text(account.provider.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
                if let unavailable = account.providerUnavailableLabel {
                    Label(unavailable, systemImage: "nosign")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            // Actions
            if account.isActive {
                let locked = failoverStore.policy(for: account.provider).activeAccountLocked
                Button {
                    failoverStore.update(account.provider) { $0.activeAccountLocked.toggle() }
                } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open")
                        .foregroundStyle(locked ? providerTint(account.provider) : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(locked
                    ? "Locked: failover will not switch away from this account. Click to unlock."
                    : "Lock this account as the active one, so failover does not switch away from it.")
            }
            if !account.isActive && account.supportsProviderWorkloads {
                Button {
                    requestSwitch(to: account)
                } label: {
                    Text("Switch")
                        .foregroundStyle(.brandOnAccent)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(providerTint(account.provider))
                .help("Switch to this account")
            }

            Button {
                Task { await appState.reauthenticateAccount(account) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Re-authenticate (fix stale token)")
            .disabled(appState.isLoggingIn)

            Button {
                appState.removeAccount(account)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius)
                .fill(account.isActive ? .cardFillStrong : .clear)
                .strokeBorder(
                    account.isActive ? providerTint(account.provider).opacity(0.45) : .cardBorder,
                    lineWidth: 1
                )
                .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
        )
        .onDrop(
            of: [UTType.text],
            delegate: AccountDisplayOrderDropDelegate(
                destinationID: account.id,
                draggedAccountID: $draggedAccountID,
                move: appState.moveAccount(from:to:)
            )
        )
    }

    private func providerTint(_ provider: AIProviderType) -> Color {
        .brand
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        editingAccountId = nil
    }

    private func requestSwitch(to account: Account) {
        if account.provider.capabilities.supportsSelectableSwitchMode {
            pendingSwitchAccount = account
            pendingCodexProcesses = appState.runningCodexProcesses()
            showingCodexSwitchMethods = true
            return
        }
        // A provider without selectable switch methods switches in one action.
        Task { await appState.switchTo(account) }
    }

    private var codexProcessWarningMessage: String {
        guard !pendingCodexProcesses.isEmpty else {
            return "No running Codex sessions were detected. Choose how AccountDock should switch credentials; all Codex switch methods remain available."
        }
        let grouped = Dictionary(grouping: pendingCodexProcesses, by: \.label)
            .map { "\($0.value.count) \($0.key)" }
            .sorted()
            .joined(separator: ", ")
        return "\(grouped) may retain the current account. “Switch Safely” changes credentials and resumes captured sessions in new Terminal windows, leaving the original tabs open. “Force Restart Sessions” also closes those original Terminal tabs. IDE and ChatGPT integrations reconnect through their host."
    }

    private func clearPendingSwitch() {
        pendingSwitchAccount = nil
        pendingCodexProcesses = []
    }

    // MARK: - Add Account Buttons

    @ViewBuilder
    private var addAccountButtons: some View {
        if appState.isLoggingIn {
            // Logging in state
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser login...")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Text("Complete the login in your browser, then return here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                if let deadline = appState.loginDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                        Text("Times out in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Cancel login", role: .cancel) {
                    appState.cancelLogin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.cardFillStrong)
                    .strokeBorder(.cardBorder, lineWidth: 1)
                    .shadow(color: AppStyle.cardShadowColor, radius: AppStyle.cardShadowRadius, x: 0, y: AppStyle.cardShadowY)
            )
        } else {
            Menu {
                ForEach(AIProviderType.implementedProviders) { provider in
                    Menu {
                        Button("Login new account") {
                            Task { await appState.loginNewAccount(provider) }
                        }
                        .disabled(!appState.canLoginNewAccount(provider))
                        Button("Capture current account") {
                            Task { await appState.captureCurrentAccount(provider) }
                        }
                    } label: {
                        Label(provider.capabilities.displayName, systemImage: provider.iconName)
                    }
                }
            } label: {
                Label("Add Provider", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.large)
            .padding(8)
            .background(.cardFillStrong, in: RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius))
        }
    }
}

private struct AccountDisplayOrderDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var draggedAccountID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedAccountID, sourceID != destinationID else { return }
        move(sourceID, destinationID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedAccountID = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

private struct ProviderDisplayOrderDropDelegate: DropDelegate {
    let destination: AIProviderType
    @Binding var draggedProvider: AIProviderType?
    let move: (AIProviderType, AIProviderType) -> Void

    func dropEntered(info: DropInfo) {
        guard let source = draggedProvider, source != destination else { return }
        move(source, destination)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedProvider = nil
        return true
    }
}
