# AccountDock Agent Guidelines

**Rules**:
- `project.yml` is the ONLY source of truth. NEVER edit `.pbxproj` or `Info.plist` directly. Run `xcodegen generate` after changes.
- `AccountDock.xcodeproj` is disposable (git-ignored).
- Run the test suite after every change (command in `BUILD_GUIDE.md`).
- Never write to the live Claude credential (`Claude Code-credentials`) in a test or experiment without first saving a copy of it.
- Screenshots come from `Tools/render_screenshots.sh` and sample data only, never from real accounts.

**App**: Native macOS menu-bar app (Swift 6, SwiftUI, macOS 14+) that manages
and switches Claude Code, Codex and Kimi Code accounts.
**Features**: Isolated provider credentials, combined usage/cost telemetry,
automatic per-provider failover with learned planning, a session pause gate, a
local request router for Claude Code, configurable menu-bar modules, and
read-only GitHub release checks.

**Docs**: `README.md` (features), `ARCHITECTURE.md` (design, credentials,
failover maths, router, hooks, files), `BUILD_GUIDE.md` (build, test,
screenshots, release), `RELEASE_NOTES.md`.

**Architecture & Files**:
- **Entry**: `AccountDockApp.swift` (scenes, lifecycle), `AppState.swift` (@MainActor state) with extensions `AppState+Failover.swift`, `AppState+Router.swift`, `AppState+Learning.swift`.
- **Models**:
  - `ProviderCapabilities.swift`: one declaration per provider; shared code reads it.
  - `FailoverPlanner.swift`: pure account-selection logic; `QuotaSimulator.swift`, `QuotaTrend.swift`, `UsageLearning.swift` feed it.
  - `FailoverConfig.swift`: per-provider policy and its store.
  - `RouteTarget.swift`: services Claude Code requests can be routed to.
  - `Account.swift`, `*Data.swift`: accounts, usage, costs, activity.
- **Services**:
  - `ClaudeService.swift`, `CodexService.swift`, `KimiService.swift`: provider authentication, usage and switching.
  - `KeychainService.swift`: live Claude slot via `/usr/bin/security`; account backups via the Security framework.
  - `AgentPauseGate.swift`, `AgentHookInstaller.swift`, `TOMLHookConfig.swift`, `AgentSessions.swift`, `SessionResumeShortcut.swift`: hooks, session records, the pause gate and its resume shortcut.
  - `RequestRouterController.swift`: installs, updates and retires the router; pushes state and credentials.
  - `UpdateChecker.swift`: validates GitHub release metadata; never executes updates.
  - `*Parser.swift`, `UsageDatabase.swift`, `UsageIndex.swift`: local session, cost and activity data.
- **Router**: `AccountDockRouter/Core/RouterCore.swift` (pure logic, shared with the app), `AccountDockRouter/Server/` (HTTP server and launchd entry).
- **Views**: `MainMenuView.swift` (popover), `UsageDashboardView.swift`, `CostDetailView.swift`, `AccountSwitcherView.swift`, `SettingsView.swift`, `FailoverSettingsView.swift`, `MenuBarStripView.swift` (status item), `HiddenWindowView.swift` (keepalive for the Settings window).
- **Debug only**: `Debug/ScreenshotRenderer.swift` renders README images from sample data.
