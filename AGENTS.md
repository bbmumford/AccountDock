# AccountDock Agent Guidelines

**Rules**:
- `project.yml` is the ONLY source of truth. NEVER edit `.pbxproj` or `Info.plist` directly. Run `xcodegen generate` after changes.
- `AccountDock.xcodeproj` is disposable (git-ignored).

**App**: Native macOS menu-bar app for managing and switching Claude Code and
Codex accounts.
**Features**: Isolated provider credentials, combined usage/cost telemetry,
configurable menu-bar modules, launch at login, and read-only GitHub release
checks that present a user-reviewed installer command.

**Architecture & Files**:
- **Docs**: `ARCHITECTURE.md` (token flow), `BUILD_GUIDE.md`, `project.yml` (Xcode config).
- **Entry**: `AccountDockApp.swift` (MenuBarExtra, lifecycle), `AppState.swift` (@MainActor state).
- **Services**: 
  - `ClaudeService.swift`: Wraps `claude` CLI (auth/status).
  - `KeychainService.swift`: Manages OAuth tokens via `/usr/bin/security`.
  - `CodexService.swift`: Isolates managed Codex homes and reads native usage.
  - `UpdateChecker.swift`: Validates GitHub release metadata and constructs the
    safe installer command; it never executes updates.
  - `*Parser.swift`: Parses Claude and Codex local session data.
- **Models**: `Account.swift`, `*Data.swift` (usage/cost/activity).
- **Views**: `MainMenuView.swift` (dropdown), `SettingsView.swift` (native window), `HiddenWindowView.swift` (LSUIElement keepalive workaround).
