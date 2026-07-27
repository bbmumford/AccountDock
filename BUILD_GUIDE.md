# AccountDock build and release guide

## Local development

Requirements: macOS 14+, Xcode 16+, and XcodeGen.

```bash
brew install xcodegen
xcodegen generate
open AccountDock.xcodeproj
```

Run the test suite without signing:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AccountDockTests \
  CODE_SIGNING_ALLOWED=NO
```

Build a local Release app:

```bash
xcodebuild build \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AccountDockRelease \
  CODE_SIGNING_ALLOWED=NO
```

`project.yml` is authoritative. Do not hand-edit generated project settings.

## Versioning

The fresh project baseline is marketing version `1.0.0`, build `1`. Both app
and widget read the same values from `project.yml`.

Prepare a later release locally:

```bash
./scripts/release.sh patch
# or: ./scripts/release.sh 1.1.0
```

The script updates both targets, regenerates the project, creates a local
commit, and creates a `v<version>` tag. It never pushes.

## GitHub Actions

`.github/workflows/ci-release.yml` has two jobs:

1. `test` runs for pull requests, `main`, tags, and manual dispatch.
2. `release` runs only for a `v*` tag after tests pass. It verifies that the
   tag matches `MARKETING_VERSION`, builds a macOS Installer package, generates
   its SHA-256 digest, and creates the GitHub release.

The current pipeline creates an unsigned development installer because the
repository has no Apple Developer signing identities or notarization
credentials configured. Before public distribution, extend the release job
with Developer ID Application and Installer signing, Apple notarization,
stapling, and Gatekeeper verification.

Publishing is intentionally manual and separate:

```bash
git push origin main
git push origin v1.0.0
```

Do not run those commands until the repository exists, redistribution rights
are resolved, and explicit push approval has been given.

## Update safety model

The app queries GitHub's latest-release API but does not self-modify. It only
shows a command for the user to inspect and run. That command:

1. creates a temporary directory;
2. downloads `AccountDock.pkg` over HTTPS;
3. compares it with `AccountDock.pkg.sha256`;
4. invokes Apple's `installer`, which requests administrator authorization;
5. registers AccountDock as a macOS login item.

This keeps privileged installation explicit and leaves checksum verification
visible. A public release must additionally be Developer ID signed and
notarized.
