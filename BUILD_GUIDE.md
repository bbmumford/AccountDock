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
   tag matches `MARKETING_VERSION`, signs the app, builds a signed Installer
   package, notarizes and staples it, generates SHA-256, and creates the
   GitHub release.

Configure these repository secrets before publishing:

- `APPLICATION_CERTIFICATE_BASE64`
- `INSTALLER_CERTIFICATE_BASE64`
- `CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_INSTALLER`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

The certificate values are base64-encoded `.p12` files. Use the exact identity
strings shown by `security find-identity -v`.

Publishing is intentionally manual and separate:

```bash
git push origin main
git push origin v1.0.0
```

Do not run those commands until the repository exists, secrets are configured,
redistribution rights are resolved, and explicit push approval has been given.

## Update safety model

The app queries GitHub's latest-release API but does not self-modify. It only
shows a command for the user to inspect and run. That command:

1. creates a temporary directory;
2. downloads `AccountDock.pkg` over HTTPS;
3. compares it with `AccountDock.pkg.sha256`;
4. checks the Installer signature with `pkgutil`;
5. asks Gatekeeper to assess the package with `spctl`;
6. invokes Apple's `installer`, which requests administrator authorization.

This keeps privileged installation explicit and leaves verification visible.
