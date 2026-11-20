import Foundation

/// Whether a provider's group (its icon and its modules) appears in the
/// menu-bar strip. `MenuBarStripView` reads it on every tick, so a group
/// leaves the menu bar when no account can run the provider's CLI and
/// returns once one can: a plan upgraded, an account added or signed in
/// again. The Menu Bar preview applies the same rule, and both Settings
/// tabs show `notice` while it keeps a provider with enabled modules out of
/// the menu bar.
///
/// An account can run the CLI when its plan includes the workload and its
/// organisation allows it (`Account.workloadAvailability`, which carries a
/// refused CLI and a missing seat), and the provider has not rejected its
/// sign-in even after renewal (`AppState.needsSignIn`). Each of these is
/// stored state that only a provider's answer changes, never a reading that
/// failed, so a transient error does not take a group away. Usage is not
/// read: an account whose windows are full runs the CLI again once they
/// reset, and the group stays to show that.
///
/// An account failover excludes still counts: exclusion keeps failover from
/// choosing it, but the user can still switch to it or move a session onto
/// it (`SessionMoveRules`), so the CLI still runs on it.
enum MenuBarPresence: Equatable {
    case shown
    /// The user turned the provider off (`ProviderVisibility`).
    case hiddenByUser
    /// No account can run the provider's CLI, for the reason given.
    case noUsableAccount(Blocker)

    /// What stops a provider's accounts from running its CLI: one
    /// account's reason (`blocker(of:needsSignIn:)`), or the provider's
    /// when every account shares it, `.mixed` when they differ and
    /// `.noAccounts` when it has none.
    enum Blocker: Hashable {
        case noAccounts
        case organisation
        case plan
        case needsSignIn
        case mixed
    }

    /// Why the account cannot run its provider's CLI, nil when it can: the
    /// reasons a session move refuses an account for (`SessionMoveRules.blocker`
    /// with `Account.cliUnavailableReason`). An organisation's refusal and a
    /// plan without the workload come before a rejected sign-in, because
    /// signing in again lifts neither, and the notice names what the user
    /// has to change.
    static func blocker(of account: Account, needsSignIn: Bool) -> Blocker? {
        if account.cliAccessRefusedAt != nil || account.hasUnassignedSeat { return .organisation }
        if !account.supportsProviderWorkloads { return .plan }
        if needsSignIn { return .needsSignIn }
        return nil
    }

    /// The provider's presence given the user's hidden providers and every
    /// account AccountDock holds; `needsSignIn` is `AppState.needsSignIn`.
    static func of(
        _ provider: AIProviderType,
        hidden: Set<AIProviderType>,
        accounts: [Account],
        needsSignIn: (Account) -> Bool
    ) -> MenuBarPresence {
        if hidden.contains(provider) { return .hiddenByUser }
        let blockers = accounts.filter { $0.provider == provider }.map { blocker(of: $0, needsSignIn: needsSignIn($0)) }
        guard !blockers.isEmpty else { return .noUsableAccount(.noAccounts) }
        if blockers.contains(where: { $0 == nil }) { return .shown }
        let reasons = Set(blockers.compactMap { $0 })
        return .noUsableAccount(reasons.count == 1 ? reasons.first ?? .mixed : .mixed)
    }

    /// The providers whose groups the strip shows, in `order`: each has an
    /// enabled module in `modules` and is `.shown`.
    static func shownProviders(
        order: [AIProviderType],
        modules: [MenuBarModule],
        hidden: Set<AIProviderType>,
        accounts: [Account],
        needsSignIn: (Account) -> Bool
    ) -> [AIProviderType] {
        order.filter { provider in
            modules.contains { $0.provider == provider }
                && of(provider, hidden: hidden, accounts: accounts, needsSignIn: needsSignIn) == .shown
        }
    }

    /// What Settings says beside a provider whose enabled modules are kept
    /// out of the menu bar because no account can run its CLI; nil when
    /// the provider shows, the user turned it off, or it has no enabled
    /// module, since then nothing is missing for this reason.
    static func notice(
        for provider: AIProviderType,
        modules: [MenuBarModule],
        hidden: Set<AIProviderType>,
        accounts: [Account],
        needsSignIn: (Account) -> Bool
    ) -> String? {
        guard modules.contains(where: { $0.provider == provider }),
              case .noUsableAccount(let blocker) = of(provider, hidden: hidden, accounts: accounts, needsSignIn: needsSignIn)
        else { return nil }
        let name = provider.capabilities.displayName
        let workload = provider.capabilities.workloadName
        switch blocker {
        case .noAccounts:
            return "Hidden from the menu bar: no \(name) account has been added. It shows again when one is."
        case .plan:
            return "Hidden from the menu bar: no \(name) account's plan includes \(workload). It shows again when one does."
        case .organisation:
            return "Hidden from the menu bar: every \(name) account's organisation has disabled \(workload) for it or assigned it no seat. It shows again when one can use it."
        case .needsSignIn:
            return "Hidden from the menu bar: every \(name) account needs to sign in again. It shows again when one is signed in."
        case .mixed:
            return "Hidden from the menu bar: no \(name) account can run \(workload); each needs to sign in again, has a plan without it, or is stopped by its organisation. It shows again when one can."
        }
    }

    /// What the Menu Bar tab says beside a provider whose enabled modules
    /// are hidden because the user turned the provider off in General.
    static func turnedOffNotice(for provider: AIProviderType) -> String {
        "\(provider.capabilities.displayName) is turned off in General → Providers, so its modules stay out of the menu bar."
    }
}
