# AccountDock Source Review

## Scope

This review covers CCSwitcher at `1f3b9c8` and CodexBar at `cc8da27`. AccountDock is a hard
fork of CCSwitcher. CodexBar remains a read-only reference checkout; none of its MIT-licensed
source has been copied wholesale.

## CCSwitcher

### Licensing constraint

The reviewed CCSwitcher revision does not contain a repository license. A local
working fork is technically possible, but public redistribution, publication,
or reuse beyond what copyright law otherwise permits needs explicit permission
from the CCSwitcher copyright holder. CodexBar is MIT-licensed, but its notice
must be retained if any of its source is copied. AccountDock currently adapts
the managed-home design rather than copying CodexBar source wholesale.

### Architecture

CCSwitcher is a compact macOS 14 SwiftUI menu-bar application generated from `project.yml`.
`AppState` is the central `@MainActor` store, `StatusItemController` bridges to AppKit, and the
views are a small SwiftUI layer. Claude credentials are read from the CLI-owned keychain entry
and account backups are stored by the app. Usage, activity and cost readers are separate services.

### Strengths

- The credential-switching flow verifies identity before backing up or accepting a switch.
- `project.yml` provides one reproducible source of project configuration.
- Parsers and menu-bar modules are separated well enough to evolve independently.
- The widget shares a narrow `WidgetData` model rather than importing the application state.
- File logging and passive credential diagnostics make account corruption diagnosable.

### Risks and debt

- `AppState` mixes orchestration, persistence, network refresh, widget projection and UI errors.
  Provider-specific coordinators should replace the growing set of provider branches.
- The source originally exposed `AIProviderType.codex` and `.gemini`, but all behavior was
  Claude-specific. That created a misleading extension seam rather than actual provider support.
- Claude backups have a file fallback in `~/.ccswitcher`; credentials should never fall back to
  plaintext storage. AccountDock should migrate remaining fallback data into Keychain.
- Several process runners synchronously drain pipes and then wait. Large subprocess output can
  deadlock unless output is drained concurrently.
- Account metadata lives in `UserDefaults` with no schema version. A versioned store and explicit
  migrations would make future provider changes safer.
- Most operations depend on concrete singletons, which makes credential and switching tests hard.
- UI strings are partly localized and partly inline English, so new provider surfaces need a
  deliberate localization pass.
- The repository contains no focused unit-test target for switching invariants.

## CodexBar

### Architecture

CodexBar is a much larger Swift 6 application split into `CodexBar`, `CodexBarCore`,
`CodexBarCLI`, and extensive tests. Providers are registered through a catalog and expose
provider-scoped settings, fetchers, menu descriptors and credential stores. The menu-bar
controller is decomposed across extensions, while settings use Observation-based state.

Codex multi-account support uses isolated managed `CODEX_HOME` directories. A login is performed
inside a new home, identity is derived from `auth.json`, and a selected account is promoted to
the system Codex home through a staged replacement. Workspace identity and reconciliation are
handled separately from email identity.

### Strengths

- Provider data is strongly siloed and provider capabilities are explicit.
- Codex account promotion is planned, prepared and executed in separate testable units.
- Managed-home deletion validates containment before removing anything.
- The parser/provider test suite is broad and avoids live Keychain prompts by default.
- Settings persistence, migrations and provider detection are separated.
- Process execution includes timeout, process-group termination and concurrent pipe capture.

### Risks and debt

- The application is very large for a menu-bar utility; controller behavior is spread over many
  extensions, increasing navigation cost and implicit coupling.
- `SettingsStore` and `StatusItemController` remain high-gravity types despite file-level splits.
- Many provider integrations amplify regression surface and release-validation cost.
- AppKit menu behavior is difficult to exercise in CI; model seams reduce but do not remove this.
- Copying CodexBar wholesale into CCSwitcher would import far more architecture and dependencies
  than AccountDock needs.

## AccountDock direction

AccountDock keeps CCSwitcher's smaller shell and adopts CodexBar's safest core idea: isolated
Codex homes with atomic promotion of `auth.json`. Provider-specific credentials remain siloed.
The current implementation adds Codex capture, login, switching, reauthentication and removal,
plus persisted appearance controls.

Recommended next steps:

1. Extract `ClaudeAccountCoordinator` and `CodexAccountCoordinator` from `AppState`.
2. Add an `AccountStore` with schema versioning and migrations from CCSwitcher defaults.
3. Replace the Codex process runner with bounded concurrent output capture and cancellation.
4. Add fixture-based tests for JWT identity parsing, path-containment checks and atomic promotion.
5. Port only Codex usage models/fetchers needed for the AccountDock dashboard.
6. Make every usage/menu module declare supported providers and render a provider selector.
7. Remove plaintext Claude credential fallback and add a one-time secure migration.
8. Localize every newly introduced AccountDock string.
