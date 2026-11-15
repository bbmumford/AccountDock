import XCTest
@testable import AccountDock

/// Behavior shared across providers is driven by `ProviderCapabilities`, so
/// these pin what each registered provider offers to the generic pipelines.
final class ProviderCapabilitiesTests: XCTestCase {
    func testTheRouterServesTheProviderWithARequestRouter() {
        XCTAssertEqual(AIProviderType.routedProvider, .claudeCode)
        XCTAssertEqual(RouteTarget.all.map(\.id), ["kimi"])
        XCTAssertEqual(RouteTarget.available(for: .claudeCode).map(\.id), ["kimi"])
        XCTAssertEqual(RouteTarget.available(for: .codex).map(\.id), ["kimi", "claude"], "served through the Responses bridge")
        XCTAssertTrue(RouteTarget.available(for: .kimi).isEmpty)
    }

    func testHookComponentsFollowCapabilities() {
        let components = Set(AgentHookInstaller.Component.all.map(\.id))
        XCTAssertEqual(components, [
            "Claude Code.lifecycle", "Claude Code.liveUsageFeed", "Claude Code.pauseGate", "Claude Code.router",
            "Codex.lifecycle", "Codex.pauseGate",
            "Kimi.lifecycle", "Kimi.pauseGate",
        ])
    }

    func testEveryImplementedProviderWarmsWindowsAndPausesSessions() {
        for provider in AIProviderType.implementedProviders {
            XCTAssertTrue(provider.capabilities.supportsWindowWarming, provider.rawValue)
            XCTAssertNotNil(provider.capabilities.pauseGate, provider.rawValue)
            XCTAssertNotNil(provider.capabilities.lifecycleHooks, provider.rawValue)
            XCTAssertNotNil(provider.capabilities.cliExecutableName, provider.rawValue)
            XCTAssertTrue(ProviderFailoverPolicy.defaults(for: provider).keepWindowsWarm, provider.rawValue)
        }
    }

    func testASwitchMethodSavedForCodexStillDecodes() throws {
        let stored = #"{"codexSwitchMode":"withoutRestart"}"#.data(using: .utf8)!
        let policy = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: stored)
        XCTAssertEqual(policy.switchMethod, .withoutRestart)
        let reencoded = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(reencoded.switchMethod, .withoutRestart)
    }

    func testProviderVisibilityMovesTheShowFlags() {
        let defaults = UserDefaults(suiteName: "ProviderCapabilitiesTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: "showCodexProvider")
        defaults.set(true, forKey: "showKimiProvider")
        ProviderVisibility.migrate(defaults)
        let stored = defaults.string(forKey: ProviderVisibility.storageKey) ?? ""
        XCTAssertEqual(ProviderVisibility.hidden(in: stored), [.codex])
        XCTAssertEqual(ProviderVisibility.visibleProviders(in: stored), [.claudeCode, .kimi])
    }

    func testKimiModelAliasesArePriced() {
        XCTAssertEqual(AIProviderType.kimi.capabilities.pricingAliases["k3"], "moonshot/kimi-k3")
        XCTAssertEqual(AIProviderType.codex.displayModelName("gpt-5.5-codex"), "GPT 5.5 Codex")
        XCTAssertEqual(AIProviderType.kimi.displayModelName("k3"), "Kimi k3")
    }

    /// One CLI settings tab serves every provider from what its
    /// capabilities declare.
    func testTheCLISettingsTabIsDrivenByCapabilities() throws {
        let claude = try XCTUnwrap(AIProviderType.claudeCode.capabilities.cliSettings)
        XCTAssertEqual(claude.executable, AIProviderType.claudeCode.capabilities.cliExecutableName)
        XCTAssertEqual(claude.preferenceKey, kClaudeBinaryPathPreferenceKey)
        XCTAssertNotNil(claude.installedVersion)
        XCTAssertNotNil(claude.latestVersion)
        XCTAssertNil(claude.recovery)
        XCTAssertNil(claude.isolationNote)

        let codex = try XCTUnwrap(AIProviderType.codex.capabilities.cliSettings)
        XCTAssertEqual(codex.executable, AIProviderType.codex.capabilities.cliExecutableName)
        XCTAssertEqual(codex.preferenceKey, "codexBinaryPathPreference")
        XCTAssertNil(codex.installedVersion, "Codex's version is not read")
        XCTAssertNotNil(codex.isolationNote)
        XCTAssertEqual(codex.recovery?.confirmButton, "Force Restart")

        XCTAssertNil(AIProviderType.kimi.capabilities.cliSettings, "Kimi's tab says where its accounts are managed")
    }
}
