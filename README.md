# AccountDock

One dock for every local AI coding identity.

AccountDock is a native macOS menu-bar app for managing Claude Code and OpenAI
Codex accounts. It isolates credentials, switches the account consumed by each
CLI, and combines provider usage, activity, costs, and menu-bar modules.

## Highlights

- Add, rename, reauthenticate, remove, and switch Claude and Codex accounts.
- Managed Codex homes with atomic promotion to `~/.codex/auth.json`.
- Safe Codex switching that restarts associated app-servers and resumes
  captured CLI sessions against the selected account.
- Combined usage and API-equivalent cost history for both providers.
- Configurable menu-bar modules with bar or percentage usage displays.
- Provider-specific, session- and weekly-aware automatic account failover.
- Safe Claude credential switching that detects running Claude Code processes.
- Reset-aware recovery and a privacy-safe failover activity log.
- Seven-day cost history paging plus colour, density, width, and corner controls.
- Optional launch at login using macOS `SMAppService`.
- Read-only GitHub update checks with a copyable, checksum-verifying installer
  command. AccountDock never downloads or executes an update itself.

## Automatic failover

Settings → Failover configures Claude and Codex independently. AccountDock
never fails over from one provider to the other.

- Choose the account order for each provider and optionally loop through it.
- Set independent session and weekly thresholds for Claude subscriptions.
- Set the long-window quota threshold reported by Codex. This is normally seven
  days, while Free accounts can expose a 30-day quota; Codex does not expose a
  five-hour/session subscription window.
- Prefer the eligible account with the most remaining headroom.
- After the active account reaches a threshold, prefer a ladder account whose
  limits have reset, or hold briefly when the active limiting window is about
  to reset. A recovered account never pulls work away from a healthy account.
- Optionally keep reset windows warm. After a fresh provider response confirms
  a reset, AccountDock makes one minimal request against that account so the
  next countdown begins immediately. Claude uses a unique
  `--no-session-persistence` probe and removes matching residue; Codex uses
  `exec --ephemeral`. The probe never becomes a resumable user session.
- Adapt active-account polling from five minutes down to fifteen seconds as a
  configured limit approaches, without forcing a full refresh of every account.
- Back off exhausted accounts when no failover destination exists, following
  known reset and provider retry-after times instead of repeatedly polling.
- Preserve the last known reset information when a provider temporarily
  responds with a rate-limit error.
- Refresh inactive Claude OAuth credentials independently, including rotated
  refresh tokens, without replacing the credential used by active sessions.

When every configured account is exhausted, AccountDock selects the account
whose blocking limits become available first. A session-limited account is not
treated as ready while its weekly limit remains blocked. AccountDock prepares
that account, monitors it for restored capacity, and releases the tracked
Claude processes only after the provider confirms capacity.

### Safe Claude and Codex switching and session recovery

Claude Code processes keep the credential with which they were launched, so
changing the credential file alone does not move an already-running workload.
For manual switches, AccountDock offers **Switch Safely**, **Switch Without
Restart**, or **Cancel**. Automatic failover captures the running Claude Code
processes before switching credentials and requests a graceful termination
after the switch. It never force-kills them.

The installer adds AccountDock's own Claude lifecycle hooks without replacing
other configured hooks. They record privacy-scoped recovery metadata—session
identifier, working directory, lifecycle state, host type, and timestamp—under
`~/Library/Application Support/AccountDock/Sessions`. Prompt and transcript
content are never stored. A one-time copy of the pre-install Claude settings is
kept at `~/.claude/settings.json.accountdock-backup`.

It also configures `~/.codex/hooks.json` and every AccountDock-managed Codex
home using the lifecycle-hook format implemented by the `bbmumford/codex`
fork. Existing Codex hook groups are preserved and backed up once. Because
upstream Codex does not currently ship this interface, these hooks activate on
compatible builds and remain inert configuration on builds that do not support
them. A compatible Codex build may ask the user to review and trust a newly
installed user hook before its first run.

Recovery is host-neutral. AccountDock detects the recovery method rather than
assuming a particular harness: IDE-managed sessions are released to their host
for respawn, while standalone Claude CLI sessions are reopened in Terminal at
their original working directory with `claude --resume <session-id>`. Before
resuming, it checks that the same session is not already running.

Codex hooks additionally associate captured sessions with their persistent
app-server and owning host. Codex automatic failover has three selectable
switch methods:

- **Switch Safely** arms when the provider reports that the quota threshold was
  reached, but waits for a running session to record an actual usage-limit
  error. It then restarts and resumes only affected sessions; unaffected
  sessions reload the promoted credential in place.
- **Force Restart Sessions** acts immediately from the provider-reported quota
  threshold. It closes every detected Codex Terminal session, switches the
  credential, and reopens each recoverable session with
  `codex resume <session-id>`.
- **Switch Without Restart** acts immediately and signals compatible running
  Codex processes to reload the promoted credential in place.

Standalone sessions are reopened in their original working directory; VS Code
and ChatGPT integrations reconnect through their host.

- A confirmed **Force Restart Codex Sessions** action in Codex CLI settings
  closes detected Codex Terminal sessions and reopens every recoverable session
  with `codex resume <session-id>`. Sessions without a captured ID are reported
  instead of being silently replaced.
  The same action is available directly in the Codex account-switch warning.

- Cost records are resolved within their provider before model matching.
  Codex records retain their reasoning-effort tier, use an effort-specific
  pricing entry when one exists, and otherwise price the recorded reasoning
  tokens as output tokens at that provider model's published rate.
Settings → Failover Log records switches, exhausted-account waits, reset
selection, recovery release, and failures. Entries obfuscate account identity,
are capped at 500, and are stored locally at
`~/Library/Logs/AccountDock-failover.json`. The log can be cleared from the app.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer for development
- XcodeGen (`brew install xcodegen`)

## Install

Because the repository is private, sign in once with `gh auth login`, then run:

```bash
install_dir="$(mktemp -d)" && gh release download --repo bbmumford/AccountDock --pattern 'AccountDock.pkg*' --dir "$install_dir" --clobber && (cd "$install_dir" && shasum -a 256 -c AccountDock.pkg.sha256) && sudo installer -pkg "$install_dir/AccountDock.pkg" -target / && osascript -e 'tell application "System Events" to if not (exists login item "AccountDock") then make login item at end with properties {name:"AccountDock", path:"/Applications/AccountDock.app", hidden:false}' && rm -rf "$install_dir" && open -a AccountDock
```

The command downloads the release, verifies its SHA-256 checksum, installs it
in `/Applications`, merges AccountDock's lifecycle hooks into the current
user's Claude settings, adds AccountDock to Login Items, and opens it.

## Build and test

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AccountDockDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Open [AccountDock.xcodeproj](AccountDock.xcodeproj) for local development.
`project.yml` is the source of truth; regenerate the project after changing it.

## Updates and releases

AccountDock checks `bbmumford/AccountDock` for the latest GitHub release. A
release contains:

- `AccountDock.pkg` — macOS Installer package.
- `AccountDock.pkg.sha256` — SHA-256 digest generated by CI.

When a newer semantic version is available, Settings → About offers a safe
install command. The command downloads over HTTPS, checks SHA-256, asks for
administrator approval through `/usr/sbin/installer`, and enables startup.

The workflow in `.github/workflows/ci-release.yml` tests every change and
publishes releases only for `v*` tags. The current private development release
is not Developer ID signed or notarized; add Apple signing and notarization
before public distribution. See [BUILD_GUIDE.md](BUILD_GUIDE.md).

`scripts/release.sh` prepares a version commit and tag locally. It deliberately
does not push anything.

## Source layout

- `AccountDock/` — app models, services, and SwiftUI views.
- `AccountDockWidget/` — WidgetKit extension.
- `AccountDockTests/` — unit tests.
- `Shared/` — widget projection shared by both targets.
- `project.yml` — XcodeGen project definition and version source.

## Upstream attribution

AccountDock began as a hard fork of
[XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher) and was
informed by the account-isolation and telemetry approaches in
[steipete/CodexBar](https://github.com/steipete/CodexBar).

The reviewed CCSwitcher revision did not contain a repository license. Public
redistribution requires permission from its copyright holder. Archived
upstream documentation is retained under `docs/upstream/`.
