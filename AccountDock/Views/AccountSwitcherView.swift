import SwiftUI

/// Lists all configured accounts with switching and management.
struct AccountSwitcherView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var editingAccountId: UUID?
    @State private var editingLabel = ""
    @State private var pendingSwitchAccount: Account?
    @State private var pendingClaudeProcesses: [RunningClaudeProcess] = []
    @State private var showingClaudeProcessWarning = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    if appState.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.accounts) { account in
                            accountRow(account)
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
        .alert("Claude sessions are still running", isPresented: $showingClaudeProcessWarning) {
            Button("Switch Safely") {
                guard let account = pendingSwitchAccount else { return }
                let processes = pendingClaudeProcesses
                clearPendingSwitch()
                Task {
                    await appState.switchTo(account, safelyRestarting: processes)
                }
            }
            Button("Switch Without Restart") {
                guard let account = pendingSwitchAccount else { return }
                clearPendingSwitch()
                Task { await appState.switchTo(account) }
            }
            Button("Cancel", role: .cancel) {
                clearPendingSwitch()
            }
        } message: {
            Text(processWarningMessage)
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

            Text("Add a Claude Code or Codex account to get started.")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Account Row

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
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
                    }
                }

                Text(account.displayEmail(obfuscated: !showFullEmail))
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

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
            }

            Spacer()

            // Actions
            if !account.isActive {
                Button {
                    requestSwitch(to: account)
                } label: {
                    Text("Switch")
                        .foregroundStyle(.brandOnAccent)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(providerTint(account.provider))
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
    }

    private func providerTint(_ provider: AIProviderType) -> Color {
        .brand
    }

    private func commitLabelEdit(_ account: Account) {
        appState.updateAccountLabel(account, label: editingLabel)
        editingAccountId = nil
    }

    private func requestSwitch(to account: Account) {
        guard account.provider == .claudeCode else {
            Task { await appState.switchTo(account) }
            return
        }
        let processes = appState.runningClaudeProcesses()
        guard !processes.isEmpty else {
            Task { await appState.switchTo(account) }
            return
        }
        pendingSwitchAccount = account
        pendingClaudeProcesses = processes
        showingClaudeProcessWarning = true
    }

    private var processWarningMessage: String {
        let grouped = Dictionary(grouping: pendingClaudeProcesses, by: \.label)
            .map { "\($0.value.count) \($0.key)" }
            .sorted()
            .joined(separator: ", ")
        return "\(grouped) will keep using their existing account. “Switch Safely” changes the account, then gracefully closes only these Claude processes. Reopen terminal sessions afterward; IDE integrations may restart automatically."
    }

    private func clearPendingSwitch() {
        pendingSwitchAccount = nil
        pendingClaudeProcesses = []
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
            HStack(spacing: 8) {
                Menu {
                    Button("Login new Claude account") {
                        Task { await appState.loginNewAccount() }
                    }
                    Button("Capture current Claude account") {
                        Task { await appState.addAccount() }
                    }
                } label: {
                    Label("Add Claude", systemImage: AIProviderType.claudeCode.iconName)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button("Login new Codex account") {
                        Task { await appState.loginNewCodexAccount() }
                    }
                    .disabled(!appState.codexAvailable)
                    Button("Capture current Codex account") {
                        Task { await appState.addCurrentCodexAccount() }
                    }
                } label: {
                    Label("Add Codex", systemImage: AIProviderType.codex.iconName)
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)
            }
            .controlSize(.large)
            .padding(8)
            .background(.cardFillStrong, in: RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius))
        }
    }
}
