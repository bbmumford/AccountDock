import XCTest
@testable import AccountDock

final class AccountModelTests: XCTestCase {
    func testPlanNameComesFromThePlanAndTier() {
        var account = Account(email: "a@mail.example", displayName: "A", subscriptionType: "max")
        XCTAssertEqual(account.displaySubscriptionType, "Max")
        account.rateLimitTier = "default_claude_max_20x"
        XCTAssertEqual(account.displaySubscriptionType, "Ultra")
        account.rateLimitTier = "default_claude_max_5x"
        XCTAssertEqual(account.displaySubscriptionType, "Max")
        // A team seat on the same tier is not an individual plan.
        account.subscriptionType = "team"
        XCTAssertEqual(account.displaySubscriptionType, "Team")
    }

    func testMessageNameAddsTheEmailOnlyWhenAnotherAccountSharesTheName() {
        let work = Account(email: "work@mail.example", displayName: "Org", customLabel: "Work")
        let system = Account(email: "system@mail.example", displayName: "Org", customLabel: "Work")
        let personal = Account(email: "me@mail.example", displayName: "Org", customLabel: "Personal")
        let sameNameOtherProvider = Account(email: "x@mail.example", displayName: "Org", provider: .codex, customLabel: "Personal")
        let all = [work, system, personal, sameNameOtherProvider]
        XCTAssertEqual(work.messageName(among: all), "Work (\(work.obfuscatedEmail))")
        XCTAssertEqual(system.messageName(among: all), "Work (\(system.obfuscatedEmail))")
        XCTAssertNotEqual(work.messageName(among: all), system.messageName(among: all))
        XCTAssertEqual(personal.messageName(among: all), "Personal")
    }

    func testMessageNameUsesTheFullEmailWhenTheObfuscatedFormsCollide() {
        let first = Account(email: "brandon.a@mail.example", displayName: "Org", customLabel: "Team")
        let second = Account(email: "brandon.b@mail.example", displayName: "Org", customLabel: "Team")
        XCTAssertEqual(first.obfuscatedEmail, second.obfuscatedEmail)
        XCTAssertEqual(first.messageName(among: [first, second]), "Team (brandon.a@mail.example)")
    }

    func testProviderRegistryDefinesImplementedProvidersAndQuotaCapabilities() {
        XCTAssertEqual(AIProviderType.implementedProviders, [.claudeCode, .codex, .kimi])
        XCTAssertTrue(AIProviderType.claudeCode.capabilities.supportsSessionQuota)
        XCTAssertTrue(AIProviderType.codex.capabilities.supportsSessionQuota)
        XCTAssertEqual(AIProviderType.codex.capabilities.sessionQuotaMode, .whenPresent)
        XCTAssertEqual(AIProviderType.codex.capabilities.pricingPrefixes.first, "openai/")
        XCTAssertEqual(AIProviderType.kimi.capabilities.weeklyQuotaLabel, "Monthly limit")
        XCTAssertEqual(AIProviderType.kimi.capabilities.sessionQuotaLabel, "5-hour")
    }

    func testFreeTierEligibilityIsProviderCapabilityDriven() {
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .claudeCode, subscriptionType: "free"))
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .codex, subscriptionType: "free"))
        // Kimi Code is part of Kimi's paid memberships; its profile names the plan "Free".
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .kimi, subscriptionType: "Free"))
        XCTAssertTrue(Account.supportsProviderWorkloads(provider: .kimi, subscriptionType: "Ultra"))
        XCTAssertTrue(Account.supportsProviderWorkloads(provider: .gemini, subscriptionType: "free"))
    }

    func testFreeCodexAccountIsNotAWorkloadDestination() {
        let account = Account(
            email: "free@example.com",
            displayName: "Free",
            provider: .codex,
            subscriptionType: "free"
        )
        XCTAssertFalse(account.supportsProviderWorkloads)
        XCTAssertEqual(account.providerUnavailableLabel, "Codex unavailable")
        XCTAssertFalse(Account.supportsProviderWorkloads(provider: .codex, subscriptionType: "FREE"))
    }

    func testPaidCodexAccountRemainsAWorkloadDestination() {
        let account = Account(
            email: "plus@example.com",
            displayName: "Plus",
            provider: .codex,
            subscriptionType: "plus"
        )
        XCTAssertTrue(account.supportsProviderWorkloads)
        XCTAssertNil(account.providerUnavailableLabel)
    }

    func testFreeClaudeAccountIsNotAClaudeCodeDestination() {
        let account = Account(
            email: "free@example.com",
            displayName: "Free",
            provider: .claudeCode,
            subscriptionType: "free"
        )
        XCTAssertFalse(account.supportsProviderWorkloads)
        XCTAssertEqual(account.providerUnavailableLabel, "Claude Code unavailable")
    }

    func testUnusedUnstartedWindowRequiresConfirmedZeroAndNoReset() {
        XCTAssertTrue(UsageWindow(utilization: 0, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(UsageWindow(utilization: nil, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(UsageWindow(utilization: 1, resetsAt: nil).isUnusedUnstartedWindow)
        XCTAssertFalse(
            UsageWindow(
                utilization: 0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
            ).isUnusedUnstartedWindow
        )
    }

    func testLegacyAccountDecodesWithoutCredentialLocation() throws {
        let data = """
        {
          "id": "51437F9A-812D-4CAC-A322-3CB743182CB0",
          "email": "legacy@example.com",
          "displayName": "Legacy",
          "provider": "Claude Code",
          "isActive": true
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(account.email, "legacy@example.com")
        XCTAssertNil(account.credentialLocation)
    }

    func testProvidersMaintainIndependentActiveState() {
        let claude = Account(email: "claude@example.com", displayName: "Claude", isActive: true)
        let codex = Account(
            email: "codex@example.com",
            displayName: "Codex",
            provider: .codex,
            isActive: true,
            credentialLocation: "/managed/codex"
        )

        XCTAssertTrue(claude.isActive)
        XCTAssertTrue(codex.isActive)
        XCTAssertNotEqual(claude.provider, codex.provider)
    }

    func testMenuBarCatalogUsesProductDefaultOrder() {
        XCTAssertEqual(MenuBarModule.allCases, [
            .claudeSession, .claudeWeekly, .codexSession, .codexWeekly, .kimiSession, .kimiMonthly,
            .claudeSessionPercent, .claudeWeeklyPercent, .claudePercentages,
            .codexSessionPercent, .codexWeeklyPercent, .codexPercentages,
            .kimiSessionPercent, .kimiMonthlyPercent, .kimiPercentages,
            .claudeModelWeekly,
            .claudeWeeklyReset, .codexWeeklyReset, .kimiMonthlyReset,
            .claudeSessionReset, .codexSessionReset, .kimiSessionReset,
            .dailyCost
        ])
    }

    func testStoredMenuBarModuleNamesRoundTrip() {
        let stored = [
            "claudeSession", "claudeWeekly", "claudeSessionPercent", "claudeWeeklyPercent", "claudePercentages",
            "claudeSessionReset", "claudeWeeklyReset", "codexSession", "codexWeekly", "codexSessionPercent",
            "codexWeeklyPercent", "codexPercentages", "codexSessionReset", "codexWeeklyReset", "kimiSession",
            "kimiMonthly", "kimiSessionPercent", "kimiMonthlyPercent", "kimiPercentages", "kimiSessionReset",
            "kimiMonthlyReset", "dailyCost", "claudeModelWeekly",
        ]
        for name in stored {
            XCTAssertEqual(MenuBarModule(rawValue: name)?.rawValue, name, name)
        }
        XCTAssertEqual(MenuBarModule(rawValue: "kimiMonthlyReset"), .provider(.kimi, .longReset))
        XCTAssertNil(MenuBarModule(rawValue: "kimiWeekly"))
        let data = MenuBarModuleStore.encode([.claudeSession, .kimiMonthlyPercent, .dailyCost])
        XCTAssertEqual(MenuBarModuleStore.decode(data), [.claudeSession, .kimiMonthlyPercent, .dailyCost])
    }

    func testStoredModuleNamesWithoutAProviderAreDroppedOrReplaced() {
        let stored = ["claudeUsage", "account", "sessionBar", "codexWeekly", "sessionReset", "weeklyReset"]
        XCTAssertNil(MenuBarModule(rawValue: "sessionReset"))
        XCTAssertEqual(
            MenuBarModuleStore.normalizedModules(stored: stored, replacingUnscopedResets: true, splittingCombinedPercentages: false),
            [.codexWeekly, .claudeSessionReset, .claudeWeeklyReset, .codexWeeklyReset]
        )
        XCTAssertEqual(
            MenuBarModuleStore.normalizedModules(stored: stored, replacingUnscopedResets: false, splittingCombinedPercentages: false),
            [.codexWeekly]
        )
        XCTAssertEqual(
            MenuBarModuleStore.normalizedModules(stored: ["account"], replacingUnscopedResets: true, splittingCombinedPercentages: false),
            MenuBarModuleStore.defaultModules
        )
        XCTAssertEqual(
            MenuBarModuleStore.normalizedModules(stored: ["sessionReset"], replacingUnscopedResets: true, splittingCombinedPercentages: false),
            [.claudeSessionReset]
        )
        XCTAssertEqual(
            MenuBarModuleStore.normalizedModules(stored: ["kimiPercentages", "dailyCost", "kimiSessionPercent"],
                                                 replacingUnscopedResets: false, splittingCombinedPercentages: true),
            [.kimiSessionPercent, .kimiMonthlyPercent, .dailyCost]
        )
    }

    func testModelLimitModuleIsOfferedOnlyWhereReadingsCarryModelLimitsAndIsOffByDefault() {
        let offered = MenuBarModule.allCases.filter { $0.metric == .modelLimit }
        XCTAssertEqual(offered.compactMap(\.provider),
                       AIProviderType.implementedProviders.filter { $0.capabilities.reportsModelWeeklyLimits })
        XCTAssertFalse(MenuBarModuleStore.defaultModules.contains { $0.metric == .modelLimit })
        XCTAssertEqual(MenuBarModule.claudeModelWeekly.rawValue, "claudeModelWeekly")
    }

    func testTheModelLimitModuleShowsTheTightestUnexpiredModelLimit() throws {
        let json = """
        {"seven_day": {"utilization": 30, "resets_at": null},
         "limits": [
           {"kind": "weekly_scoped", "percent": 91, "resets_at": "2001-01-01T00:00:00+00:00",
            "scope": {"model": {"display_name": "Old"}}},
           {"kind": "weekly_scoped", "percent": 64, "resets_at": "2099-10-22T13:00:00+00:00",
            "scope": {"model": {"display_name": "Fable"}}},
           {"kind": "weekly_scoped", "percent": 20, "resets_at": null,
            "scope": {"model": {"display_name": "Sonnet"}}}
         ]}
        """
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.tightestModelWeeklyLimit()?.model, "Fable")
        let none = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(#"{"seven_day": {"utilization": 1}}"#.utf8))
        XCTAssertNil(none.tightestModelWeeklyLimit())
    }

    func testElapsedMarkerNeedsTheWindowsOwnLength() {
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let elapsed = UsageWindow(utilization: 10, resetsAt: reset, windowSeconds: 4 * 3600).elapsedPercent(at: now)
        XCTAssertEqual(elapsed ?? -1, 75, accuracy: 0.5)
        XCTAssertNil(UsageWindow(utilization: 10, resetsAt: reset).elapsedPercent(at: now))
        XCTAssertNil(UsageWindow(utilization: 10, resetsAt: nil, windowSeconds: 3600).elapsedPercent(at: now))
    }

    func testCachedUsageClearsAfterKnownResetPasses() {
        let now = Date()
        let usage = UsageAPIResponse(
            fiveHour: UsageWindow(
                utilization: 100,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
            ),
            sevenDay: UsageWindow(
                utilization: 72,
                resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let effective = usage.expiringPassedResets(at: now)

        XCTAssertEqual(effective.fiveHour?.utilization, 0)
        XCTAssertNil(effective.fiveHour?.resetsAt)
        XCTAssertEqual(effective.sevenDay?.utilization, 72)
        XCTAssertNotNil(effective.sevenDay?.resetsAt)
    }

    func testCachedUsageReportsItsNextFutureReset() throws {
        let now = Date()
        let sessionReset = now.addingTimeInterval(300)
        let weeklyReset = now.addingTimeInterval(600)
        let usage = UsageAPIResponse(
            fiveHour: UsageWindow(
                utilization: 40,
                resetsAt: ISO8601DateFormatter().string(from: sessionReset)
            ),
            sevenDay: UsageWindow(
                utilization: 80,
                resetsAt: ISO8601DateFormatter().string(from: weeklyReset)
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let nextReset = try XCTUnwrap(usage.nextResetDate)
        XCTAssertEqual(nextReset.timeIntervalSince1970,
                       sessionReset.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testSuccessfulWarmupPinsMovingPlaceholderAndLaterPollPreservesIt() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let placeholder = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 0, resetsAt: nil, windowSeconds: 604_800),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        let pinned = placeholder.pinningWarmupCountdowns(
            session: false,
            weekly: true,
            startedAt: startedAt
        )
        XCTAssertEqual(
            try XCTUnwrap(pinned.sevenDay?.resetsAtDate).timeIntervalSince1970,
            startedAt.addingTimeInterval(604_800).timeIntervalSince1970,
            accuracy: 1
        )

        let preserved = placeholder.preservingEstablishedCountdowns(from: pinned)
        XCTAssertEqual(preserved.sevenDay?.resetsAt, pinned.sevenDay?.resetsAt)
    }

    func testRealProviderCountdownReplacesPinnedCountdown() {
        let pinned = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(
                utilization: 0,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(500)),
                windowSeconds: 604_800
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )
        let provider = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(
                utilization: 1,
                resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(400)),
                windowSeconds: 604_800
            ),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: nil
        )

        XCTAssertEqual(
            provider.preservingEstablishedCountdowns(from: pinned).sevenDay?.resetsAt,
            provider.sevenDay?.resetsAt
        )
    }

    /// An account's badges and notices are decided once, from its reading,
    /// its last read's error and its sign-in; the views only draw them.
    func testAccountStatusIsDecidedInOnePlace() {
        let active = Account(email: "a@mail.example", displayName: "A", subscriptionType: "max", isActive: true)
        let fresh = AccountStatus.make(active, hasReading: true, error: nil, signInRejected: false)
        XCTAssertEqual(fresh.cardTitleBadges.map(\.tone), [.accent])
        XCTAssertEqual(fresh.cardPlanBadges.map(\.text), [active.displaySubscriptionType].compactMap { $0 })
        XCTAssertEqual(fresh.listBadges.count, 1)
        XCTAssertNil(fresh.readingProblem)
        XCTAssertNil(fresh.staleReading)
        XCTAssertFalse(fresh.needsCapture, "a Keychain account has no credential files to capture")

        let cachedAt = Date(timeIntervalSinceReferenceDate: 1000)
        let limited = AppState.UsageErrorState(isExpired: false, isRateLimited: true, message: "Rate limited", cachedAt: cachedAt)
        let stale = AccountStatus.make(active, hasReading: true, error: limited, signInRejected: true)
        XCTAssertTrue(stale.needsSignIn)
        XCTAssertEqual(stale.listBadges.map(\.tone), [.accent, .attention], "the list shows Needs sign-in beside Active")
        XCTAssertEqual(stale.staleReading, AccountStatus.Notice(symbol: "timer", text: "Rate limited", tone: .attention, since: cachedAt))
        XCTAssertNil(stale.readingProblem, "a reading is shown, so its failure is only a notice under it")

        let other = Account(email: "b@mail.example", displayName: "B")
        XCTAssertEqual(AccountStatus.make(other, hasReading: false, error: nil, signInRejected: false).readingProblem?.tone,
                       .caution, "a Keychain account without a reading has an expired token")
        let failed = AppState.UsageErrorState(isExpired: false, isRateLimited: false, message: "Failed")
        XCTAssertEqual(AccountStatus.make(other, hasReading: false, error: failed, signInRejected: false).readingProblem,
                       AccountStatus.Notice(symbol: "xmark.circle", text: "Failed", tone: .failure))

        let inactive = Account(email: "c@mail.example", displayName: "C", provider: .codex, subscriptionType: "inactive")
        let expired = AppState.UsageErrorState(isExpired: true, isRateLimited: false, message: "Expired")
        let unavailable = AccountStatus.make(inactive, hasReading: false, error: expired, signInRejected: false)
        XCTAssertNotNil(unavailable.planUnavailable)
        XCTAssertEqual(unavailable.cardPlanBadges.last?.tone, .attention)
        XCTAssertEqual(unavailable.readingProblem?.symbol, "nosign", "a plan that cannot serve explains the failed reading")
        XCTAssertEqual(unavailable.readingProblem?.tone, .caution)
        XCTAssertEqual(unavailable.needsCapture, AIProviderType.codex.capabilities.credentialStore == .files)
        XCTAssertNil(AccountStatus.make(inactive, hasReading: false, error: nil, signInRejected: false).readingProblem
                        .flatMap { AIProviderType.codex.capabilities.credentialStore == .keychain ? nil : $0 })
    }

    /// The neutral reading keeps every window, percent, reset and length of
    /// the reply it came from, and gives the same reply back.
    func testAUsageReadingConvertsBothWays() throws {
        let json = #"""
        {"five_hour":{"utilization":42,"resets_at":"2026-11-15T12:00:00.000Z","window_seconds":18000},
         "seven_day":{"utilization":10.5,"resets_at":"2026-11-20T01:00:00Z"},
         "seven_day_opus":{"utilization":3,"resets_at":null},
         "extra_usage":null}
        """#
        let response = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
        let reading = UsageReading(response)
        XCTAssertEqual(reading.windows.map(\.kind), [.session, .long, .model])
        XCTAssertEqual(reading.session?.percent, 42)
        XCTAssertEqual(reading.session?.length, 18000)
        XCTAssertEqual(reading.session?.resetsAt, response.fiveHour?.resetsAtDate)
        XCTAssertEqual(reading.long?.percent, 10.5)
        XCTAssertNil(reading.windows.last?.resetsAt)

        let back = reading.response
        XCTAssertEqual(back.fiveHour?.utilization, 42)
        XCTAssertEqual(back.fiveHour?.windowSeconds, 18000)
        XCTAssertEqual(back.fiveHour?.resetsAtDate, response.fiveHour?.resetsAtDate)
        XCTAssertEqual(back.sevenDay?.resetsAtDate, response.sevenDay?.resetsAtDate)
        XCTAssertEqual(back.sevenDayOpus?.utilization, 3)
        XCTAssertNil(back.sevenDaySonnet)
    }

    /// A usage snapshot saved in the reply's form loads, converted, and a
    /// snapshot saved now holds the neutral reading and loads the same.
    func testASavedUsageSnapshotOfTheOldFormLoads() throws {
        let stored = #"""
        {"usage":{"five_hour":{"utilization":42,"resets_at":"2026-11-15T12:00:00.000Z"},
                  "seven_day":{"utilization":10,"resets_at":"2026-11-20T01:00:00Z","window_seconds":604800}},
         "updatedAt":785000000,"wholeAt":785000100,"wholeLongUtilization":10,"resetUnverified":true}
        """#
        let old = try JSONDecoder().decode(PersistedUsageSnapshot.self, from: Data(stored.utf8))
        XCTAssertEqual(old.usage.fiveHour?.utilization, 42)
        XCTAssertEqual(old.usage.sevenDay?.windowSeconds, 604800)
        XCTAssertEqual(old.usage.sevenDay?.resetsAtDate, UsageWindow.parseProviderDate("2026-11-20T01:00:00Z"))
        XCTAssertEqual(old.updatedAt, Date(timeIntervalSinceReferenceDate: 785000000))
        XCTAssertEqual(old.wholeAt, Date(timeIntervalSinceReferenceDate: 785000100))
        XCTAssertEqual(old.wholeLongUtilization, 10)
        XCTAssertEqual(old.resetUnverified, true)

        let saved = try JSONEncoder().encode(old)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(object["reading"], "a snapshot is saved as the neutral reading")
        XCTAssertNil(object["usage"])
        let reloaded = try JSONDecoder().decode(PersistedUsageSnapshot.self, from: saved)
        XCTAssertEqual(reloaded.reading.windows, old.reading.windows)
        XCTAssertEqual(reloaded.resetUnverified, true)
    }

    // MARK: - An organisation refusing the CLI

    /// What Claude Code shows, and the reply behind it, when a team admin
    /// turned off the account's subscription access.
    private let organisationRefusal = "API Error: Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"
    private let organisationReply = #"{"type":"error","error":{"type":"oauth_org_not_allowed","message":"Your organization has disabled Claude subscription access for Claude Code"}}"#

    func testTheOrganisationsRefusalIsKnownByItsWordsAndItsErrorType() {
        XCTAssertTrue(ClaudeService.refusesCLIAccess(organisationRefusal))
        XCTAssertTrue(ClaudeService.refusesCLIAccess(organisationReply))
        XCTAssertTrue(ClaudeService.refusesCLIAccess(
            "Usage request failed: warm-up request exited 1: \(organisationRefusal)"), "the probe's failure carries the CLI's words")
        XCTAssertFalse(ClaudeService.refusesCLIAccess("API Error: Rate limit reached"))
        XCTAssertFalse(ClaudeService.refusesCLIAccess(#"{"type":"error","error":{"type":"permission_error"}}"#))
    }

    func testAnAccountItsOrganisationRefusesCannotServeTheCLI() throws {
        var account = Account(email: "bowens@example.com", displayName: "Bowens", provider: .claudeCode,
                              orgName: "Bowens", subscriptionType: "team")
        XCTAssertTrue(account.supportsProviderWorkloads)
        XCTAssertNil(account.cliUnavailableReason)
        XCTAssertNil(account.cliAccessNotice)

        let refusedAt = Date(timeIntervalSince1970: 1_800_000_000)
        account.cliAccessRefusedAt = refusedAt
        XCTAssertFalse(account.supportsProviderWorkloads, "no session is placed, warmed or moved there")
        XCTAssertEqual(account.providerUnavailableLabel, "Claude Code disabled by organisation")
        XCTAssertEqual(account.cliUnavailableReason, "its organisation has disabled Claude Code subscription access")
        XCTAssertEqual(SessionMoveRules.blocker(needsSignIn: false, cannotServe: account.cliUnavailableReason),
                       "its organisation has disabled Claude Code subscription access", "a move by hand is refused with the reason")
        let notice = try XCTUnwrap(account.cliAccessNotice)
        XCTAssertTrue(notice.hasPrefix("Organisation has disabled Claude Code subscription access."))
        XCTAssertTrue(notice.contains("seat or licence"), "a removed seat or licence is the usual cause")

        let status = AccountStatus.make(account, hasReading: false,
                                        error: AppState.UsageErrorState(isExpired: true, isRateLimited: false,
                                                                        message: notice, cachedAt: nil),
                                        signInRejected: false)
        XCTAssertEqual(status.accessNotice?.text, notice)
        XCTAssertEqual(status.accessNotice?.since, refusedAt)
        XCTAssertNil(status.readingProblem, "the card says it once")
        XCTAssertEqual(status.cardPlanBadges.last?.text, "Claude Code disabled by organisation")

        // The mark is kept with the account, and an account saved before it loads without one.
        let saved = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(saved.cliAccessRefusedAt, refusedAt)
        var plain = account
        plain.cliAccessRefusedAt = nil
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        object["cliAccessRefusedAt"] = nil
        let old = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.cliAccessRefusedAt)
        XCTAssertTrue(old.supportsProviderWorkloads)
    }

    func testARefusalMarksTheAccountOnlyWhileRecentAndItIsCheckedAgainDaily() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AppState.cliAccessRefusalCounts(at: now.addingTimeInterval(-60), clearedAt: nil, now: now))
        XCTAssertFalse(AppState.cliAccessRefusalCounts(at: now.addingTimeInterval(-3 * 3600), clearedAt: nil, now: now),
                       "a refusal read back from an old transcript says nothing now")
        XCTAssertFalse(AppState.cliAccessRefusalCounts(at: now.addingTimeInterval(-120), clearedAt: now.addingTimeInterval(-60), now: now),
                       "a refusal from before the account served again")

        let refused = now.addingTimeInterval(-3600)
        XCTAssertFalse(AppState.cliAccessRecheckDue(refusedAt: nil, retryAt: nil, forced: true, now: now))
        XCTAssertFalse(AppState.cliAccessRecheckDue(refusedAt: refused, retryAt: nil, forced: false, now: now))
        XCTAssertTrue(AppState.cliAccessRecheckDue(refusedAt: refused, retryAt: nil, forced: true, now: now),
                      "the user's refresh checks it at once")
        XCTAssertTrue(AppState.cliAccessRecheckDue(refusedAt: now.addingTimeInterval(-25 * 3600), retryAt: nil, forced: false, now: now))
        XCTAssertFalse(AppState.cliAccessRecheckDue(refusedAt: refused, retryAt: now.addingTimeInterval(600), forced: false, now: now))
        XCTAssertTrue(AppState.cliAccessRecheckDue(refusedAt: refused, retryAt: now.addingTimeInterval(-1), forced: false, now: now),
                      "a re-check that failed on the network is tried again within the hour")
    }
}
