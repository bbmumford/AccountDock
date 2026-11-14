import Foundation

/// What an account's card on the usage tab and its row in the account list
/// say about it: its badges, and the notices under its header. Decided in
/// one place (`make`) from the account and AppState's readings of it, and
/// kept in `AppState.accountStatuses`, which recomputes it whenever one of
/// those readings changes; `UsageDashboardView` and `AccountSwitcherView`
/// only draw it.
struct AccountStatus: Equatable {
    /// The colour a badge or notice is drawn in: the app's accent, orange
    /// for what the user should act on, yellow for an expired token, red for
    /// a failed reading.
    enum Tone: Equatable { case accent, attention, caution, failure }

    struct Badge: Equatable {
        var text: String
        var tone: Tone
    }

    /// One line under the header: a symbol, its words, and for a reading
    /// shown from before a failed one, when that reading was taken.
    struct Notice: Equatable {
        var symbol: String
        var text: String
        var tone: Tone
        var since: Date?
    }

    var isActive: Bool
    /// The provider rejected the sign-in AccountDock holds for the account
    /// (`AppState.needsSignIn`); its usage is the last reading.
    var needsSignIn: Bool
    /// The plan's name, when the account reports one.
    var plan: String?
    /// Why the plan cannot carry the provider's work, such as a free plan
    /// (`Account.providerUnavailableLabel`).
    var planUnavailable: String?
    /// What went wrong reading the account when there is no reading to
    /// show: the error, or an expired Keychain token.
    var readingProblem: Notice?
    /// The reading shown is from before a failed one.
    var staleReading: Notice?
    /// A provider whose credentials are files has none saved for the
    /// account.
    var needsCapture: Bool

    /// The card header's badge beside the account's name: Active.
    var cardTitleBadges: [Badge] {
        isActive ? [Badge(text: Self.activeText, tone: .accent)] : []
    }

    /// The card header's trailing badges: the plan, then why it cannot
    /// serve.
    var cardPlanBadges: [Badge] {
        [plan.map { Badge(text: $0, tone: .accent) }, planUnavailable.map { Badge(text: $0, tone: .attention) }]
            .compactMap { $0 }
    }

    /// The account list row's badges beside its name: Active, then Needs
    /// sign-in, which the card shows as its sign-in prompt instead.
    var listBadges: [Badge] {
        var badges = cardTitleBadges
        if needsSignIn { badges.append(Badge(text: String(localized: "Needs sign-in", bundle: L10n.bundle), tone: .attention)) }
        return badges
    }

    private static var activeText: String { String(localized: "Active", bundle: L10n.bundle) }

    /// The status of `account` from its reading (`hasReading`), the error of
    /// its last read (`error`) and whether its sign-in was rejected.
    static func make(_ account: Account, hasReading: Bool, error: AppState.UsageErrorState?,
                     signInRejected: Bool) -> AccountStatus {
        let unavailable = account.providerUnavailableLabel
        var problem: Notice?
        var stale: Notice?
        if hasReading {
            if let error, let cachedAt = error.cachedAt {
                stale = Notice(symbol: error.isRateLimited ? "timer" : "clock.arrow.circlepath", text: error.message,
                               tone: .attention, since: cachedAt)
            }
        } else if let error {
            let symbol = unavailable != nil
                ? "nosign" : (error.isRateLimited ? "timer" : (error.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
            problem = Notice(symbol: symbol, text: error.message, tone: error.isExpired ? .caution : .failure)
        } else if account.provider.capabilities.credentialStore == .keychain {
            problem = Notice(symbol: "exclamationmark.triangle",
                             text: String(localized: "Token expired. Switch to this account in \(account.provider.rawValue) to refresh.",
                                          bundle: L10n.bundle),
                             tone: .caution)
        }
        return AccountStatus(
            isActive: account.isActive, needsSignIn: signInRejected, plan: account.displaySubscriptionType,
            planUnavailable: unavailable, readingProblem: problem, staleReading: stale,
            needsCapture: account.provider.capabilities.credentialStore == .files && account.credentialLocation == nil
        )
    }
}
