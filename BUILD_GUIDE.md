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

## Continuous integration

`.github/workflows/ci.yml` generates the project and runs the tests for every
push to `main`, every pull request and on manual dispatch. It builds nothing
for release.

## Publishing a release

Releases are built, signed and published from a Mac, so every release is
signed by the same identity and an in-app update keeps the installed app's
Keychain access and login item. Update [RELEASE_NOTES.md](RELEASE_NOTES.md)
with a `## <version>` section, commit it, then run:

```bash
./scripts/publish-release.sh patch   # or minor, major, or a version number
```

The script:

1. runs `scripts/release.sh` to set the version in `project.yml`, commit it
   and tag `v<version>` locally;
2. runs the tests and builds the Release app outside the source tree;
3. adds the installer's hook configurators to the app, then signs the widget
   extension and the app with `ACCOUNTDOCK_SIGNING_IDENTITY`, by default the
   "AccountDock Local" certificate in the login keychain;
4. writes `AccountDock.zip`, which the app updates from, and
   `AccountDock.pkg`, for a first install, each with a `.sha256` file;
5. asks, then pushes `main` and the tag and publishes the GitHub release with
   the version's release notes.

`--yes` skips both confirmations. `ACCOUNTDOCK_GH_USER` names the `gh`
account to publish as when it is not the active one; only that account then
answers git's credential requests for the push.

The releases are not Developer ID signed or notarized. Before distributing
beyond people who install with the README's command, add Developer ID
Application and Installer signing, notarization, stapling and a Gatekeeper
check to the script, and sign every release with the Developer ID from then
on: an update signed by a different identity is refused.

## Installer and update safety

The README's install command downloads `AccountDock.pkg` and its digest over
HTTPS, checks the digest, runs Apple's `installer`, which asks for
administrator approval, and adds the login item. The package's `postinstall`
adds AccountDock's Claude Code and Codex session hooks for the console user,
keeping existing hook groups and one-time settings backups. The app installs
the remaining hooks (status line, pause gate, Kimi Code) after asking, and
manages the router itself.

In-app updates (`UpdateChecker`, `UpdateInstaller`) install a release only
when:

1. its `AccountDock.zip` matches the release's published SHA-256;
2. the archive holds `app.accountdock.mac` at the release's version;
3. it satisfies the running app's designated requirement, which names the
   certificate that signed it. A copy signed ad hoc names only its own code
   hash, so it cannot vouch for an update and offers the install command
   instead.

A helper then waits for AccountDock to quit, moves the running copy to
`~/Library/Application Support/AccountDock/Updates/previous`, moves the update
into its place and opens it, putting the previous copy back if the move fails.
