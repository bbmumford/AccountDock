import XCTest
@testable import AccountDock

/// The account profile decides a Claude account's plan and tier: a
/// credential, `claude auth status` and a sign-in name the plan the token
/// was issued under, which an upgrade or a downgrade does not change.
final class ProfilePlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Claude token JSON naming `plan` and `tier`, as the Keychain holds it.
    private func token(plan: String, tier: String, access: String = "a") -> String {
        "{\"claudeAiOauth\":{\"accessToken\":\"\(access)\",\"refreshToken\":\"r\",\"subscriptionType\":\"\(plan)\",\"rateLimitTier\":\"\(tier)\"}}"
    }

    /// An account upgraded from Pro to Max 5x whose profile check answered.
    private func upgraded() -> Account {
        var account = Account(email: "upgraded@mail.example", displayName: "U", subscriptionType: "pro")
        account.rateLimitTier = "default_claude_ai"
        let profile = ClaudeService.liveSubscription(fromProfileJSON: [
            "account": ["email": "upgraded@mail.example", "has_claude_max": true],
            "organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"],
        ])
        let change = account.applyProfilePlan(profile.planType, inactive: profile.isInactive,
                                               tier: profile.rateLimitTier, checkedAt: now)
        XCTAssertEqual(change?.before, "Pro")
        XCTAssertEqual(change?.after, "Max")
        XCTAssertEqual(change?.detail, "pro:default_claude_ai -> max:default_claude_max_5x")
        return account
    }

    private func assertMax5x(_ account: Account, _ message: String, line: UInt = #line) {
        XCTAssertEqual(account.subscriptionType, "max", message, line: line)
        XCTAssertEqual(account.rateLimitTier, "default_claude_max_5x", message, line: line)
        XCTAssertEqual(account.planSize, 5, message, line: line)
        XCTAssertEqual(account.planHasSessionWindow, true, message, line: line)
        XCTAssertEqual(account.displaySubscriptionType, "Max", message, line: line)
    }

    func testAnUpgradedAccountStaysMax5xThroughItsTokensReads() {
        var account = upgraded()
        assertMax5x(account, "the profile's plan and tier")
        let issued = token(plan: "pro", tier: "default_claude_ai")
        // `readClaudeUsage` and `adoptLiveCredential` (`setRateLimitTier`).
        XCTAssertFalse(account.applyCredentialPlan(nil, tier: ClaudeService.rateLimitTier(from: issued)))
        // The re-authentication's sign-in.
        XCTAssertFalse(account.applyCredentialPlan(ClaudeIsolatedLogin.subscriptionType(of: issued),
                                                   tier: ClaudeService.rateLimitTier(from: issued)))
        assertMax5x(account, "a token issued under Pro changes nothing")
    }

    func testAnUpgradedAccountStaysMax5xThroughClaudeAuthStatus() {
        var account = upgraded()
        let status = AuthStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty",
                                email: account.email, orgId: nil, orgName: nil, subscriptionType: "pro")
        // `updateActiveAccount` and the switch.
        XCTAssertFalse(account.applyCredentialPlan(status.subscriptionType))
        assertMax5x(account, "auth status names the token's plan")
        XCTAssertEqual(ClaudeService.authStatus(of: account, identity: [:]).subscriptionType, "max",
                       "a switch's stand-in status carries the profile's plan")
    }

    func testAnUpgradedAccountStaysMax5xAfterARelaunch() throws {
        var saved = upgraded()
        // A store written while a token writer had overwritten the fields.
        saved.subscriptionType = "pro"
        saved.rateLimitTier = "default_claude_ai"
        let data = try JSONEncoder().encode([saved])
        var loaded = try XCTUnwrap(JSONDecoder().decode([Account].self, from: data).first)
        XCTAssertEqual(loaded.profilePlan, "max")
        XCTAssertEqual(loaded.profileRateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(loaded.profileCheckedAt, now)
        XCTAssertEqual(loaded.planSize, 5, "plan size reads the profile's tier first")
        loaded.adoptProfilePlan()
        assertMax5x(loaded, "the loaded account takes the profile's plan")
    }

    func testAnAccountSavedWithoutAProfileStillLoads() throws {
        let legacy = Data("""
        [{"id":"30D6F4DB-6642-4534-9BF0-237F24043F06","email":"old@mail.example","displayName":"O",
          "provider":"Claude Code","subscriptionType":"pro","isActive":false,"rateLimitTier":"default_claude_ai"}]
        """.utf8)
        var account = try XCTUnwrap(JSONDecoder().decode([Account].self, from: legacy).first)
        XCTAssertNil(account.profilePlan)
        XCTAssertNil(account.profileCheckedAt)
        account.adoptProfilePlan()
        XCTAssertEqual(account.subscriptionType, "pro")
        XCTAssertEqual(account.planSize, 1)
        // Until a profile answers, the credential's plan is the one known.
        XCTAssertTrue(account.applyCredentialPlan("max", tier: "default_claude_max_20x"))
        XCTAssertEqual(account.planSize, 20)
    }

    func testAnUpgradedAccountStaysMax5xAfterItsTokenIsRenewed() {
        var account = upgraded()
        // A renewal replaces the access token and keeps the plan fields the
        // token was issued with (`ClaudeService.refreshStoredToken`).
        let renewed = token(plan: "pro", tier: "default_claude_ai", access: "renewed")
        XCTAssertFalse(account.applyCredentialPlan(ClaudeIsolatedLogin.subscriptionType(of: renewed),
                                                   tier: ClaudeService.rateLimitTier(from: renewed)))
        assertMax5x(account, "the renewed token names the plan it was issued under")
        XCTAssertEqual(AppState.learnedPlan(account), TurnCostModel.LearnedPlan(plan: "max", tier: "default_claude_max_5x"),
                       "costs are learned against the profile's plan")
    }

    func testADowngradeTheProfileShowsIsApplied() {
        var account = upgraded()
        let downgraded = ClaudeService.liveSubscription(fromProfileJSON: [
            "account": ["email": "upgraded@mail.example"],
            "organization": ["organization_type": "claude_pro", "rate_limit_tier": "default_claude_ai"],
        ])
        let later = now.addingTimeInterval(3 * 60 * 60)
        let change = account.applyProfilePlan(downgraded.planType, inactive: downgraded.isInactive,
                                              tier: downgraded.rateLimitTier, checkedAt: later)
        XCTAssertEqual(change, Account.PlanChange(before: "Max", after: "Pro",
                                                  detail: "max:default_claude_max_5x -> pro:default_claude_ai"))
        XCTAssertEqual(account.subscriptionType, "pro")
        XCTAssertEqual(account.planSize, 1)
        XCTAssertEqual(account.profileCheckedAt, later)
        // A token issued under Max cannot bring the larger plan back.
        XCTAssertFalse(account.applyCredentialPlan("max", tier: "default_claude_max_5x"))
        XCTAssertEqual(account.planSize, 1)
        // The same answer again is no change.
        XCTAssertNil(account.applyProfilePlan("pro", inactive: false, tier: "default_claude_ai", checkedAt: later))
    }

    func testATierChangeWithinOnePlanNameSaysWhichTier() {
        var account = Account(email: "max@mail.example", displayName: "M", subscriptionType: "max")
        account.rateLimitTier = "default_claude_ai"
        let change = account.applyProfilePlan("max", inactive: false, tier: "default_claude_max_5x", checkedAt: now)
        XCTAssertEqual(change?.before, "Max (default_claude_ai)")
        XCTAssertEqual(change?.after, "Max (default_claude_max_5x)")
        XCTAssertEqual(account.planSize, 5)
    }

    func testAnEndedPlanTheProfileShowsMakesTheAccountUnavailable() {
        var account = upgraded()
        let change = account.applyProfilePlan(nil, inactive: true, tier: nil, checkedAt: now)
        XCTAssertEqual(change?.after, "Free")
        XCTAssertFalse(account.supportsProviderWorkloads)
        XCTAssertFalse(account.applyCredentialPlan("pro"), "the token's plan cannot revive an ended one")
        XCTAssertFalse(account.supportsProviderWorkloads)
    }

    func testAProfileRecordsTheAccountItDescribes() {
        let profile = ClaudeService.liveSubscription(fromProfileJSON: [
            "account": ["email": "Upgraded@Mail.example"],
            "organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"],
        ])
        XCTAssertEqual(profile.email, "Upgraded@Mail.example")
        XCTAssertTrue(upgraded().matches(email: profile.email))
        XCTAssertFalse(Account(email: "other@mail.example", displayName: "O").matches(email: profile.email))
    }

    func testTheProfileIsCheckedAgainEveryFewHoursAndOnTheUsersRefresh() {
        let interval = AppState.profileRecheckInterval
        XCTAssertLessThanOrEqual(interval, 6 * 60 * 60)
        XCTAssertTrue(AppState.planCheckDue(checkedAt: nil, attemptedAt: nil, forced: false, available: true, now: now),
                      "an account no profile has answered for is checked")
        XCTAssertFalse(AppState.planCheckDue(checkedAt: now.addingTimeInterval(-interval + 60), attemptedAt: nil,
                                                      forced: false, available: true, now: now))
        XCTAssertTrue(AppState.planCheckDue(checkedAt: now.addingTimeInterval(-interval), attemptedAt: nil,
                                                     forced: false, available: true, now: now))
        XCTAssertTrue(AppState.planCheckDue(checkedAt: now.addingTimeInterval(-60), attemptedAt: nil,
                                                     forced: true, available: true, now: now),
                      "the user's refresh checks every account")
        // A check that got no answer waits before it is tried again.
        XCTAssertFalse(AppState.planCheckDue(checkedAt: nil, attemptedAt: now.addingTimeInterval(-60),
                                                      forced: false, available: true, now: now))
        XCTAssertTrue(AppState.planCheckDue(checkedAt: nil,
                                                     attemptedAt: now.addingTimeInterval(-AppState.profileRetryInterval),
                                                     forced: false, available: true, now: now))
        // An answered check's own send time is older than its answer.
        XCTAssertFalse(AppState.planCheckDue(checkedAt: now.addingTimeInterval(-60), attemptedAt: now.addingTimeInterval(-61),
                                                      forced: false, available: true, now: now))
    }

    func testEveryProviderNamesWhereItStatesThePlan() {
        XCTAssertEqual(AIProviderType.claudeCode.capabilities.planAuthority?.source, .profileEndpoint)
        XCTAssertEqual(AIProviderType.kimi.capabilities.planAuthority?.source, .profileEndpoint)
        XCTAssertEqual(AIProviderType.codex.capabilities.planAuthority?.source, .usageReply,
                       "Codex's ID token outlives a plan change; its usage reply names the plan now")
    }

    func testAKimiPlanTheProfileShowsEndedReplacesTheStoredOne() throws {
        // A `/me` reply after the paid level ended.
        let reply = Data("""
        {"user_id":"u-1","nickname":"Personal","user_level_name":"Free","email":"kimi@mail.example"}
        """.utf8)
        let signedIn = try KimiService.profileIdentity(from: reply)
        XCTAssertEqual(signedIn.planType, "Free")
        var account = Account(email: "kimi@mail.example", displayName: "Personal", provider: .kimi, subscriptionType: "Ultra")
        let answer = ProviderPlanAnswer(plan: signedIn.planType, owner: signedIn.identifier, displayName: signedIn.displayName)
        XCTAssertTrue(account.matches(email: answer.owner))
        let change = account.applyProfilePlan(answer.plan, inactive: answer.inactive, tier: answer.tier, checkedAt: now)
        XCTAssertEqual(change, Account.PlanChange(before: "Ultra", after: "Free", detail: "Ultra -> Free"))
        XCTAssertEqual(account.subscriptionType, "Free")
        XCTAssertEqual(account.profileCheckedAt, now)
        // A re-authentication's identity from before the change cannot put it back.
        XCTAssertFalse(account.applyCredentialPlan("Ultra"))
        XCTAssertEqual(account.displaySubscriptionType, "Free")
        XCTAssertNil(account.planSize, "Kimi lists no plan sizes, so its cost is learned or plan-wide")
        XCTAssertFalse(account.supportsProviderWorkloads, "Kimi Code needs a paid Kimi membership")
        XCTAssertEqual(AppState.learnedPlan(account), TurnCostModel.LearnedPlan(plan: "Free", tier: nil))
    }

    func testAKimiProfileWithoutAnAddressNamesTheAccountByItsUserID() throws {
        let signedIn = try KimiService.profileIdentity(from: Data(#"{"user_id":"u-2","user_level_name":" "}"#.utf8))
        XCTAssertEqual(signedIn.identifier, "u-2")
        XCTAssertEqual(signedIn.displayName, "u-2")
        XCTAssertNil(signedIn.planType, "a blank level names no plan, so the one known stays")
    }

    func testAKimiUsageReplyIsReadWindowByWindow() throws {
        let full = try KimiService.usage(fromReply: Data("""
        {"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2027-01-15T10:00:00Z"},
                   "limit_month_total":{"used_ratio":0.4,"reset_time":"2027-02-01T00:00:00Z"},
                   "limit_month_code":{"used_ratio":0.6,"reset_time":"2027-02-01T00:00:00Z"}}}
        """.utf8))
        XCTAssertEqual(full.fiveHour?.utilization, 25)
        XCTAssertEqual(full.sevenDay?.utilization, 60)
        // A plan without the code window still reads.
        let partial = try KimiService.usage(fromReply: Data("""
        {"usages":{"limit_month_total":{"used_ratio":1.0,"reset_time":"2027-02-01T00:00:00Z"}}}
        """.utf8))
        XCTAssertNil(partial.fiveHour)
        XCTAssertEqual(partial.sevenDay?.utilization, 100)
        // A reply with no window says what it carried.
        XCTAssertThrowsError(try KimiService.usage(fromReply: Data(#"{"usages":{},"user":{"level":"free"}}"#.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("usages{}"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("user{level}"), error.localizedDescription)
        }
        XCTAssertThrowsError(try KimiService.usage(fromReply: Data(#"{"usages":{"limit_5h":{"reset_time":"x"}}}"#.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("used_ratio"), error.localizedDescription)
        }
    }

    func testACodexPlanItsUsageReplyNamesWinsOverItsIDToken() {
        var account = Account(email: "codex@mail.example", displayName: "C", provider: .codex, subscriptionType: "plus")
        let change = account.applyProfilePlan("pro", inactive: false, tier: nil, checkedAt: now)
        XCTAssertEqual(change?.after, "Pro")
        XCTAssertFalse(account.applyCredentialPlan("plus"), "the ID token's claim is the plan it was issued under")
        XCTAssertEqual(account.planHasSessionWindow, true)
        XCTAssertNil(account.applyProfilePlan("pro", inactive: false, tier: nil, checkedAt: now), "the same plan is no change")
    }
}
