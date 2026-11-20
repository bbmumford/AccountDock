import XCTest
@testable import AccountDock

/// The menu-bar strip's provider groups (`MenuBarPresence`): a group shows
/// while the user keeps its provider on and one account can run the CLI,
/// and leaves otherwise without reading usage.
final class MenuBarPresenceTests: XCTestCase {
    private let order: [AIProviderType] = [.claudeCode, .codex, .kimi]
    private let modules: [MenuBarModule] = [.claudeSession, .codexWeekly, .kimiPercentages, .dailyCost]
    private let signedIn: (Account) -> Bool = { _ in false }

    private func kimi(_ plan: String?) -> Account {
        Account(email: "kimi@mail.example", displayName: "Kimi", provider: .kimi, subscriptionType: plan, isActive: true)
    }

    private func shown(_ accounts: [Account], hidden: Set<AIProviderType> = [],
                       needsSignIn: @escaping (Account) -> Bool = { _ in false }) -> [AIProviderType] {
        MenuBarPresence.shownProviders(order: order, modules: modules, hidden: hidden,
                                       accounts: accounts, needsSignIn: needsSignIn)
    }

    func testFreeOnlyKimiIsHiddenAndSettingsSaysWhy() {
        let accounts = [kimi("free")]
        XCTAssertEqual(MenuBarPresence.of(.kimi, hidden: [], accounts: accounts, needsSignIn: signedIn),
                       .noUsableAccount(.plan))
        XCTAssertFalse(shown(accounts).contains(.kimi))
        XCTAssertEqual(
            MenuBarPresence.notice(for: .kimi, modules: modules, hidden: [], accounts: accounts, needsSignIn: signedIn),
            "Hidden from the menu bar: no Kimi account's plan includes Kimi Code. It shows again when one does."
        )
    }

    func testKimiShowsAgainOnceAnAccountIsUpgradedOrAdded() {
        var free = kimi("free")
        XCTAssertFalse(shown([free]).contains(.kimi))

        free.profilePlan = "moderato"
        XCTAssertTrue(shown([free]).contains(.kimi))
        XCTAssertNil(MenuBarPresence.notice(for: .kimi, modules: modules, hidden: [], accounts: [free], needsSignIn: signedIn))

        let paid = Account(email: "paid@mail.example", displayName: "Paid", provider: .kimi, subscriptionType: "Moderato")
        XCTAssertTrue(shown([kimi("free"), paid]).contains(.kimi))
    }

    /// The windows' readings are no input: Codex accounts on paid plans,
    /// signed in, keep their group however full their windows are.
    func testCodexWithEveryWindowFullStaysShown() {
        let accounts = [
            Account(email: "a@mail.example", displayName: "A", provider: .codex, subscriptionType: "pro", isActive: true),
            Account(email: "b@mail.example", displayName: "B", provider: .codex, subscriptionType: "plus"),
        ]
        XCTAssertEqual(MenuBarPresence.of(.codex, hidden: [], accounts: accounts, needsSignIn: signedIn), .shown)
        XCTAssertEqual(shown(accounts), [.codex])
    }

    func testProviderTheUserTurnedOffIsHiddenRegardless() {
        let accounts = [
            Account(email: "c@mail.example", displayName: "C", subscriptionType: "max", isActive: true),
            Account(email: "k@mail.example", displayName: "K", provider: .kimi, subscriptionType: "Moderato"),
        ]
        XCTAssertEqual(shown(accounts), [.claudeCode, .kimi])
        XCTAssertEqual(shown(accounts, hidden: [.kimi]), [.claudeCode])
        XCTAssertEqual(MenuBarPresence.of(.kimi, hidden: [.kimi], accounts: accounts, needsSignIn: signedIn), .hiddenByUser)
        // The General toggle already says so; the notice is only for accounts.
        XCTAssertNil(MenuBarPresence.notice(for: .kimi, modules: modules, hidden: [.kimi], accounts: accounts, needsSignIn: signedIn))
        XCTAssertEqual(MenuBarPresence.turnedOffNotice(for: .kimi),
                       "Kimi is turned off in General → Providers, so its modules stay out of the menu bar.")
    }

    func testAccountsThatOnlyNeedSignInAreHiddenUntilOneIsSignedIn() {
        let first = Account(email: "a@mail.example", displayName: "A", provider: .codex, subscriptionType: "pro", isActive: true)
        let second = Account(email: "b@mail.example", displayName: "B", provider: .codex, subscriptionType: "plus")
        var rejected: Set<UUID> = [first.id, second.id]
        let accounts = [first, second]
        XCTAssertEqual(MenuBarPresence.of(.codex, hidden: [], accounts: accounts, needsSignIn: { rejected.contains($0.id) }),
                       .noUsableAccount(.needsSignIn))
        XCTAssertEqual(shown(accounts, needsSignIn: { rejected.contains($0.id) }), [])
        XCTAssertEqual(
            MenuBarPresence.notice(for: .codex, modules: modules, hidden: [], accounts: accounts,
                                   needsSignIn: { rejected.contains($0.id) }),
            "Hidden from the menu bar: every Codex account needs to sign in again. It shows again when one is signed in."
        )

        rejected.remove(second.id)
        XCTAssertEqual(shown(accounts, needsSignIn: { rejected.contains($0.id) }), [.codex])
    }

    func testOrganisationRefusalAndMissingSeatHide() {
        var refused = Account(email: "r@mail.example", displayName: "R", subscriptionType: "team", isActive: true)
        refused.cliAccessRefusedAt = Date(timeIntervalSince1970: 1_000)
        let noSeat = Account(email: "s@mail.example", displayName: "S",
                             subscriptionType: "team" + Account.unassignedSeatSuffix)
        XCTAssertEqual(MenuBarPresence.of(.claudeCode, hidden: [], accounts: [refused, noSeat], needsSignIn: signedIn),
                       .noUsableAccount(.organisation))
        XCTAssertEqual(MenuBarPresence.of(.claudeCode, hidden: [], accounts: [refused, kimi("free")], needsSignIn: signedIn),
                       .noUsableAccount(.organisation))
    }

    func testDifferentReasonsAndNoAccountsAreNamed() {
        let free = Account(email: "f@mail.example", displayName: "F", provider: .codex, subscriptionType: "free")
        let rejected = Account(email: "r@mail.example", displayName: "R", provider: .codex, subscriptionType: "pro")
        XCTAssertEqual(MenuBarPresence.of(.codex, hidden: [], accounts: [free, rejected],
                                          needsSignIn: { $0.id == rejected.id }),
                       .noUsableAccount(.mixed))
        XCTAssertEqual(MenuBarPresence.of(.kimi, hidden: [], accounts: [free], needsSignIn: signedIn),
                       .noUsableAccount(.noAccounts))
        XCTAssertEqual(
            MenuBarPresence.notice(for: .kimi, modules: modules, hidden: [], accounts: [], needsSignIn: signedIn),
            "Hidden from the menu bar: no Kimi account has been added. It shows again when one is."
        )
    }

    /// A plan nothing has named yet is not a reason to hide: the group stays
    /// until a plan authority names a plan without the workload.
    func testUnknownPlanShows() {
        XCTAssertEqual(MenuBarPresence.of(.kimi, hidden: [], accounts: [kimi(nil)], needsSignIn: signedIn), .shown)
    }

    func testOnlyProvidersWithEnabledModulesShowAndNoticesNeedOne() {
        let accounts = [kimi("free")]
        XCTAssertNil(MenuBarPresence.notice(for: .kimi, modules: [.claudeSession], hidden: [],
                                            accounts: accounts, needsSignIn: signedIn))
        let claude = Account(email: "c@mail.example", displayName: "C", subscriptionType: "max", isActive: true)
        XCTAssertEqual(MenuBarPresence.shownProviders(order: order, modules: [.claudeSession], hidden: [],
                                                      accounts: [claude, kimi("Moderato")], needsSignIn: signedIn),
                       [.claudeCode])
    }

    func testUnavailableLabelNamesTheWorkload() {
        XCTAssertEqual(AIProviderType.kimi.capabilities.unavailableLabel, "Kimi Code unavailable")
        XCTAssertEqual(AIProviderType.codex.capabilities.unavailableLabel, "Codex unavailable")
        XCTAssertEqual(AIProviderType.claudeCode.capabilities.unavailableLabel, "Claude Code unavailable")
    }
}
