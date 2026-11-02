#!/bin/bash
# Renders the README screenshots in docs/images from sample accounts.
#
# A Debug build is copied and re-identified as app.accountdock.screenshots, so
# the render runs with its own empty preferences and never touches the
# installed AccountDock's accounts, failover order or settings.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/docs/images}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$root"
xcodegen generate --quiet
xcodebuild build \
  -project AccountDock.xcodeproj \
  -scheme AccountDock \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$work/build" \
  CODE_SIGNING_ALLOWED=NO -quiet

app="$work/AccountDock Screenshots.app"
cp -R "$work/build/Build/Products/Debug/AccountDock.app" "$app"
rm -rf "$app/Contents/PlugIns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.accountdock.screenshots" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app" >/dev/null

mkdir -p "$output"
ACCOUNTDOCK_SCREENSHOT_DIR="$output" "$app/Contents/MacOS/AccountDock"
defaults delete app.accountdock.screenshots >/dev/null 2>&1 || true
echo "Screenshots written to $output"
ls -1 "$output"
