import CryptoKit
import Foundation

private let credentialLog = FileLog("Credentials")

/// The credential process every provider shares: renewing saved copies,
/// the renewal before every switch, what a rejected sign-in means, and
/// adopting a renewed live credential. Each provider's own storage and
/// endpoints are reached only through its `ProviderCredentialModule`.
extension AppState {
    /// The registration point of the providers' credential modules; nil
    /// for a provider AccountDock holds no credentials for.
    func credentialModule(for provider: AIProviderType) -> ProviderCredentialModule? {
        switch provider {
        case .claudeCode: ClaudeCredentialModule(keychain: keychain, service: claudeService)
        case .codex: CodexCredentialModule(service: codexService)
        case .kimi: KimiCredentialModule(service: kimiService)
        case .gemini: nil
        }
    }

    // MARK: - Names

    /// The account's name for events, alerts and logs, unique among the
    /// saved accounts of its provider.
    func messageName(_ account: Account) -> String {
        account.messageName(among: accounts)
    }

    // MARK: - Renewal

    /// Renews an account's saved credential without touching the one its
    /// provider's running sessions use. A rejection marks the account as
    /// needing sign-in; network and server failures do not.
    @discardableResult
    func renewSavedCredential(_ account: Account) async -> CredentialRenewal {
        guard let module = credentialModule(for: account.provider) else { return .unavailable }
        let outcome = await module.renewSavedCopy(account)
        switch outcome {
        case .renewed:
            clearNeedsSignIn(account)
            if slotCredentialAccounts.contains(account.id) { await reissueSlotCredential(for: account) }
        case .rejected: noteCredentialRejected(account)
        case .unavailable: break
        }
        return outcome
    }

    /// Confirms a switch destination's saved credential works before it
    /// becomes the CLI's credential: it is renewed before every switch,
    /// since only a renewal proves its refresh token still works; an
    /// unexpired access token says nothing about it, and sessions given a
    /// dead refresh token fail once their access token expires. A renewal
    /// that cannot be made for a network or server failure allows the
    /// switch while the access token lasts five more minutes. A check passed
    /// within the last minute is not repeated, because `evaluate` checks a
    /// destination before `performAutomaticSwitch` does. An account whose
    /// access token session slots hold is not renewed while that token lasts
    /// five more minutes: a renewal revokes the token, and every request its
    /// sessions make before their slots are rewritten is refused. Their use
    /// of it shows the account works, and its refresh token is the one
    /// AccountDock itself last rotated, since a slot holds no refresh token.
    func credentialIsUsable(_ account: Account) async -> Bool {
        guard let module = credentialModule(for: account.provider) else { return true }
        if let checked = credentialVerifiedAt[account.id], Date().timeIntervalSince(checked) < 60 { return true }
        switch module.hasSavedCopy(account) {
        case nil: return false
        case false?:
            quarantineCredentials(of: account, reason: "no stored credential")
            return false
        case true?: break
        }
        if slotCredentialAccounts.contains(account.id), !needsSignIn(account),
           module.savedCopyLasts(account, for: 5 * 60) {
            credentialVerifiedAt[account.id] = Date()
            return true
        }
        switch await renewSavedCredential(account) {
        case .renewed:
            credentialVerifiedAt[account.id] = Date()
            return true
        case .rejected:
            quarantineCredentials(of: account, reason: "its stored credential was rejected")
            return false
        case .unavailable:
            if module.savedCopyLasts(account, for: 5 * 60) { return true }
            switchFailureCooldown[account.id] = Date().addingTimeInterval(10 * 60)
            return false
        }
    }

    // MARK: - Needs sign-in

    /// Whether the provider rejected the sign-in AccountDock holds for the
    /// account: the live credential for the active account, the saved copy
    /// for any other. Such an account needs the user to sign in again; its
    /// usage readings are only the last ones taken, not a limit reached.
    func needsSignIn(_ account: Account) -> Bool {
        rejectedCredentialAccounts.contains(account.id)
    }

    /// Records that the provider rejected an account's sign-in, even after
    /// renewal. The account is left out of failover, and the user is told at
    /// once, because only they can sign it in again and its allowance is
    /// lost meanwhile.
    func noteCredentialRejected(_ account: Account) {
        guard !rejectedCredentialAccounts.contains(account.id) else { return }
        rejectedCredentialAccounts.insert(account.id)
        let name = messageName(account)
        failoverEvents.record(
            account.provider,
            account.isActive
                ? "\(name)'s sign-in was rejected; its sessions cannot continue until it is re-authenticated."
                : "\(name)'s saved sign-in was rejected; it is left out of failover until it is re-authenticated."
        )
        UserAlerts.shared.post(
            id: "credential-\(account.id.uuidString)",
            title: "\(name) needs to sign in again",
            body: "\(account.provider.capabilities.displayName) rejected this account's saved sign-in, so AccountDock cannot read or use it. Re-authenticate it in AccountDock → Accounts."
        )
    }

    /// Ends the needs-sign-in state once the account's credential worked.
    func clearNeedsSignIn(_ account: Account) {
        if rejectedCredentialAccounts.contains(account.id) { rejectedCredentialAccounts.remove(account.id) }
    }

    func quarantineCredentials(of account: Account, reason: String) {
        let alreadyQuarantined = credentialQuarantine[account.id].map { $0 > Date() } ?? false
        credentialQuarantine[account.id] = Date().addingTimeInterval(6 * 60 * 60)
        guard !alreadyQuarantined else { return }
        failoverEvents.record(
            account.provider,
            "\(messageName(account)) is excluded from automatic switching until it is re-authenticated: \(reason)"
        )
    }

    // MARK: - Live credential owner

    /// The account the provider's live credential belongs to, or nil when
    /// the credential changed since its owner was last read.
    func liveCredentialOwner(_ provider: AIProviderType) -> UUID? {
        guard let known = liveCredentialOwners[provider],
              let credential = credentialModule(for: provider)?.liveCredential?.read(),
              Self.credentialDigest(credential) == known.digest else { return nil }
        return known.account
    }

    /// Records that the live credential now in place belongs to `account`,
    /// after AccountDock installed or captured it.
    func noteLiveCredentialOwner(_ provider: AIProviderType, account: UUID) {
        guard let credential = credentialModule(for: provider)?.liveCredential?.read() else { return }
        liveCredentialOwners[provider] = (Self.credentialDigest(credential), account)
    }

    // MARK: - Moving running sessions

    /// Moves the provider's running sessions onto the live credential at
    /// their next request, and stops counting `previous` as consumed by
    /// them. Each session then rebuilds its prompt cache on the new account.
    /// Nothing happens for a provider whose sessions share no live credential.
    func moveRunningSessions(_ provider: AIProviderType, from previous: UUID? = nil) {
        guard let live = credentialModule(for: provider)?.liveCredential else { return }
        live.signalRunningSessions()
        if let previous { lastSwitchedAway[previous] = nil }
        sessionsLeftOn[provider] = nil
        credentialLog.info("\(provider.rawValue): running sessions signalled to use the live credential")
    }

    /// Whether a switch for `reason` moves running sessions at once. Leaving
    /// an account at its limit or without the workload does, because it
    /// would refuse them. A threshold or balancing switch leaves them to use
    /// what remains there, and `moveSessionsOffLimitedAccounts` moves them
    /// when it runs out.
    nonisolated static func switchMovesRunningSessions(_ reason: FailoverPlan.SwitchReason) -> Bool {
        switch reason {
        case .exhausted, .workloadUnavailable: true
        case .threshold, .balance: false
        }
    }

    /// Moves sessions left on an earlier account once that account reaches
    /// its limit. Called from `runQuotaCycle`. An account is forgotten after
    /// a session window, when its sessions have ended or the window reset.
    func moveSessionsOffLimitedAccounts(now: Date = Date()) {
        for (provider, ids) in sessionsLeftOn {
            let planner = FailoverPlanner(settings: plannerSettings(provider))
            for id in ids {
                guard let account = accounts.first(where: { $0.id == id }),
                      let away = lastSwitchedAway[id],
                      now.timeIntervalSince(away) < FailoverPlanner.sessionWindow else {
                    sessionsLeftOn[provider]?.remove(id)
                    continue
                }
                var state = quotaState(for: account, now: now)
                let refused = state.refusedAtLimit
                state.credentialsUsable = true
                state.resetUnverified = false
                state.refusedAtLimit = false
                if refused || planner.tier(state, now: now) == .exhausted {
                    failoverEvents.record(provider, "\(messageName(account)) reached its limit; the sessions still on it move to the active account at their next request.")
                    moveRunningSessions(provider, from: id)
                    break
                }
            }
        }
    }

    // MARK: - Live credentials

    /// Keeps the saved copies in step with each provider's live credential,
    /// for providers whose running sessions share one and renew it in place,
    /// including sessions still running on an account switched away from:
    /// they keep that account's credential, and renewing it revokes the copy
    /// AccountDock saved, which would otherwise be rejected at the next
    /// switch back.
    ///
    /// When a live credential changes, its owner is asked of the provider
    /// and the credential is saved as that account's copy. A credential of
    /// an account other than the active one is then replaced by the active
    /// account's saved copy, so new sessions start on the account failover
    /// chose; never while the CLI is signed in as another account, as after
    /// a sign-in made outside AccountDock. Called from `runQuotaCycle`;
    /// reads each live credential at most every two minutes and asks the
    /// provider only when it changed.
    func adoptRenewedCredentials(now: Date = Date()) async {
        guard !isLoading, !isLoggingIn else { return }
        for provider in AIProviderType.implementedProviders {
            guard let live = credentialModule(for: provider)?.liveCredential,
                  let active = activeAccount(for: provider) else { continue }
            if let checked = liveCredentialCheckedAt[provider], now.timeIntervalSince(checked) < 2 * 60 { continue }
            liveCredentialCheckedAt[provider] = now
            await adoptLiveCredential(live, provider: provider, active: active)
        }
    }

    private func adoptLiveCredential(_ live: LiveCredentialModule, provider: AIProviderType, active: Account) async {
        guard let credential = live.read() else { return }
        let digest = Self.credentialDigest(credential)
        guard digest != liveCredentialDigests[provider] else { return }
        let owner: CredentialOwner
        do {
            owner = try await live.owner(of: credential)
        } catch LiveCredentialError.rejected {
            // A rejected credential names no account; the active account's
            // usage read renews it through the CLI.
            liveCredentialDigests[provider] = digest
            return
        } catch {
            return
        }
        // Read again, so a credential renewed during the request is not
        // overwritten by the older one.
        guard live.read() == credential else { return }
        liveCredentialDigests[provider] = digest
        guard let account = Self.owningAccount(
            owner,
            among: accounts.filter { $0.provider == provider },
            providerAccountID: { live.providerAccountID(ofSavedCopy: $0) }
        ) else {
            credentialLog.warning("\(provider.rawValue)'s live credential belongs to no saved account; left in place")
            return
        }
        setRateLimitTier(live.rateLimitTier(of: credential), for: account.id)
        let liveWasActives = liveCredentialOwners[provider]?.account == active.id
        liveCredentialOwners[provider] = (digest, account.id)
        let action = Self.liveCredentialAction(
            ownerID: account.id,
            activeID: active.id,
            signedInAsActive: live.signedInEmail()?.caseInsensitiveCompare(active.email) == .orderedSame,
            activeCopyIsCurrent: live.savedCopy(active) == credential,
            liveWasActives: liveWasActives
        )
        switch action {
        case .none:
            return
        case .saveActiveCopy:
            _ = live.save(credential, asCopyOf: active)
        case .makeOwnerActive:
            if live.savedCopy(account) != credential { _ = live.save(credential, asCopyOf: account) }
            for index in accounts.indices where accounts[index].provider == provider {
                accounts[index].isActive = accounts[index].id == account.id
            }
            if activeAccount?.provider == provider { activeAccount = accounts.first { $0.id == account.id } }
            saveAccounts(refreshWidget: true)
            let restored = live.restoreSignedInIdentity(of: account)
            failoverEvents.record(provider, "\(messageName(account))'s sign-in is the one in use, so it is the active account; a session on \(messageName(active)) had rewritten the signed-in identity\(restored ? ", which is restored" : "").")
        case .adopt(let restoreActive):
            guard live.save(credential, asCopyOf: account) else { return }
            clearNeedsSignIn(account)
            credentialQuarantine[account.id] = nil
            failoverEvents.record(provider, "Saved \(messageName(account))'s renewed sign-in, written by one of its running sessions.")
            guard restoreActive else { return }
            guard live.install(savedCopyOf: active), let installed = live.read() else {
                failoverEvents.record(provider, "New sessions start on \(messageName(account)): \(messageName(active))'s saved sign-in could not be restored.")
                return
            }
            liveCredentialDigests[provider] = Self.credentialDigest(installed)
            liveCredentialOwners[provider] = (Self.credentialDigest(installed), active.id)
            live.signalRunningSessions()
            failoverEvents.record(provider, "Restored \(messageName(active))'s sign-in for new sessions.")
        }
    }

    /// The saved account a live credential's owner is: matched by the
    /// provider's account identifier, then by email.
    nonisolated static func owningAccount(
        _ owner: CredentialOwner,
        among accounts: [Account],
        providerAccountID: (Account) -> String?
    ) -> Account? {
        if let id = owner.providerAccountID, let match = accounts.first(where: { providerAccountID($0) == id }) {
            return match
        }
        guard let email = owner.email else { return nil }
        return accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    enum LiveCredentialAction: Equatable {
        case none
        /// The active account's sessions renewed its credential.
        case saveActiveCopy
        /// The live credential is another account's and AccountDock never
        /// saw the active account's own credential live: only the signed-in
        /// identity named the active account, as when a session on another
        /// account rewrote it. The owner is the active account.
        case makeOwnerActive
        /// Another account's sessions renewed its credential into the live
        /// slot; it is saved as that account's copy, and the active
        /// account's copy is put back when `restoreActive`.
        case adopt(restoreActive: Bool)
    }

    /// What a changed live credential calls for. The active account's copy
    /// is saved only while the CLI is signed in as it, and the live slot is
    /// only written back while it is, so a sign-in made outside AccountDock
    /// is never undone.
    nonisolated static func liveCredentialAction(
        ownerID: UUID,
        activeID: UUID,
        signedInAsActive: Bool,
        activeCopyIsCurrent: Bool,
        liveWasActives: Bool = true
    ) -> LiveCredentialAction {
        if ownerID == activeID {
            return signedInAsActive && !activeCopyIsCurrent ? .saveActiveCopy : .none
        }
        guard liveWasActives else { return .makeOwnerActive }
        return .adopt(restoreActive: signedInAsActive)
    }

    /// A digest that tells credentials apart without keeping them.
    nonisolated static func credentialDigest(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
