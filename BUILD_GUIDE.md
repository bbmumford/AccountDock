# AccountDock build and release guide

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 6)
- XcodeGen: `brew install xcodegen`

## Project

`project.yml` is the only source of project configuration. Generate the Xcode
project from it and never edit `AccountDock.xcodeproj` or the generated
`Info.plist` keys by hand; the project directory is git-ignored.

```bash
xcodegen generate
open AccountDock.xcodeproj
```

Targets:

| Target | Type | Notes |
| --- | --- | --- |
| `AccountDock` | application | The menu-bar app. Also compiles `AccountDockRouter/Core` and embeds the router and the widget. |
| `AccountDockRouter` | command-line tool | The local request router, copied into `AccountDock.app/Contents/MacOS`. |
| `AccountDockWidget` | app extension | WidgetKit widget. |
| `AccountDockTests` | unit tests | Hosted by the app. |

## Test

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AccountDockTests \
  CODE_SIGNING_ALLOWED=NO
```

The tests never touch real credentials, the Keychain or the network. Router
tests exercise `RouterLogic` directly. To run a router against a scratch
directory and port instead of the installed one, set
`ACCOUNTDOCK_ROUTER_DIRECTORY` and `ACCOUNTDOCK_ROUTER_PORT` before starting
`AccountDock.app/Contents/MacOS/AccountDockRouter`.

## Build a Release app

```bash
xcodebuild build \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AccountDockRelease \
  CODE_SIGNING_ALLOWED=NO
codesign --force --deep --sign - /tmp/AccountDockRelease/Build/Products/Release/AccountDock.app
```

An ad-hoc signature is enough to run locally, but macOS ties Keychain access
to the signature: each ad-hoc build is a new app to the Keychain, and until
**Always Allow** is clicked again the saved accounts cannot be read and only
the active account works. A local self-signed code-signing identity gives every
build the same signature, so the permission carries over:

```bash
codesign --force --deep --sign "AccountDock Local" /tmp/AccountDockRelease/Build/Products/Release/AccountDock.app
```

The identity is a certificate and key in the login keychain, created once with
`openssl` (a code-signing extended key usage) and `security import`. It never
leaves the Mac and is not trusted for distribution. After replacing an
installed copy, the app restarts the router on the new build within two
minutes.

## Screenshots

```bash
Tools/render_screenshots.sh [output-directory]   # default: docs/images
```

The script builds a Debug app, copies it under the bundle identifier
`app.accountdock.screenshots` and runs it with `ACCOUNTDOCK_SCREENSHOT_DIR`
set. `AccountDock/Debug/ScreenshotRenderer.swift` (Debug builds only) loads
sample accounts, renders each view off screen and exits. The separate bundle
identifier gives the render its own empty preferences, so it cannot change the
installed app's accounts, failover order or settings, and it refuses to run
under the production identifier.

## Versioning

Both the app and the widget read `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` from `project.yml`.

```bash
./scripts/release.sh patch
# or: ./scripts/release.sh 1.3.0
```

The script updates both targets, regenerates the project, creates a local
commit and a `v<version>` tag. It never pushes. Update
[RELEASE_NOTES.md](RELEASE_NOTES.md) and commit it before running it.

## GitHub Actions

`.github/workflows/ci-release.yml` has two jobs:

1. `test` runs for pull requests, `main`, tags and manual dispatch.
2. `release` runs only for a `v*` tag after the tests pass. It checks that the
   tag matches `MARKETING_VERSION`, builds an Installer package with
   `scripts/package/postinstall`, writes its SHA-256 digest and publishes the
   GitHub release.

The pipeline produces an unsigned development installer because no Apple
Developer signing identities or notarization credentials are configured.
Before public distribution, add Developer ID Application and Installer signing,
notarization, stapling and a Gatekeeper check to the release job.

Publishing is manual and separate:

```bash
git push origin main
git push origin v<version>
```

Do not push until redistribution rights are resolved and the push has been
approved.

## Installer and update safety

The app queries GitHub's latest-release API but never modifies itself. It
shows a command for the user to inspect and run, which:

1. creates a temporary directory;
2. downloads `AccountDock.pkg` over HTTPS;
3. checks it against `AccountDock.pkg.sha256`;
4. runs Apple's `installer`, which asks for administrator approval;
5. runs the package's `postinstall`, which adds AccountDock's Claude Code and
   Codex session hooks for the console user, keeping existing hook groups and
   one-time settings backups;
6. registers AccountDock as a login item.

The app installs the remaining hooks (status line, pause gate, Kimi Code) after
asking, and manages the router itself. A public release must also be Developer
ID signed and notarized.
