#!/bin/bash
set -euo pipefail

# Builds, tests, signs, packages and publishes one AccountDock release from
# this Mac, so every release is signed by the same identity and an update
# keeps the installed app's Keychain access and login item.
#
# Usage:
#   ./scripts/publish-release.sh <version|patch|minor|major> [--yes]
#
# It runs ./scripts/release.sh to set the version and tag it, then:
#   1. runs the tests;
#   2. builds the Release app outside the source tree;
#   3. adds the installer's hook configurators and signs the app with
#      ACCOUNTDOCK_SIGNING_IDENTITY (default: the "AccountDock Local"
#      certificate in the login keychain);
#   4. writes AccountDock.zip for in-app updates and AccountDock.pkg for a
#      first install, each with a .sha256 file;
#   5. pushes main and the tag, and publishes the GitHub release with the
#      version's section of RELEASE_NOTES.md.
#
# ACCOUNTDOCK_GH_USER names the gh account to publish as when it is not the
# active one. Without --yes it asks before publishing.

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f project.yml ] || die "Run from the project root (project.yml not found)."
[ $# -ge 1 ] || die "Usage: $0 <version|patch|minor|major> [--yes]"
bump="$1"
assume_yes=false
[ "${2:-}" = "--yes" ] && assume_yes=true

command -v xcodegen >/dev/null || die "xcodegen is required (brew install xcodegen)."
command -v gh >/dev/null || die "gh is required (brew install gh)."

git_push=(git push)
if [ -n "${ACCOUNTDOCK_GH_USER:-}" ]; then
    GH_TOKEN="$(gh auth token --user "$ACCOUNTDOCK_GH_USER")" || die "gh has no login for $ACCOUNTDOCK_GH_USER."
    export GH_TOKEN
    # Only gh answers for GitHub, so the push uses this account rather than
    # one another credential helper holds.
    git_push=(git -c credential.helper= -c "credential.https://github.com.helper=!$(command -v gh) auth git-credential" push)
fi
repository="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
gh repo view "$repository" --json name >/dev/null 2>&1 || die "gh cannot reach $repository; sign in or set ACCOUNTDOCK_GH_USER."

identity="${ACCOUNTDOCK_SIGNING_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/"AccountDock Local"/ { split($1, a, " "); print a[2]; exit }')"
fi
[ -n "$identity" ] || die "No signing identity. Set ACCOUNTDOCK_SIGNING_IDENTITY to a codesigning identity's hash or name."

# 1. Version and tag (local only).
if $assume_yes; then
    ./scripts/release.sh "$bump" --yes
else
    ./scripts/release.sh "$bump"
fi
version="$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)"
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "Tag $tag was not created."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
derived="$work/DerivedData"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# 2. Test and build.
xcodegen generate --quiet
xcodebuild test -project AccountDock.xcodeproj -scheme AccountDock -destination 'platform=macOS' \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet || die "Tests failed; $tag is tagged locally only."
xcodebuild build -project AccountDock.xcodeproj -scheme AccountDock -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet
app="$work/AccountDock.app"
ditto "$derived/Build/Products/Release/AccountDock.app" "$app"

# 3. Installer configurators, then signing: anything added after signing
#    would break the signature the in-app updater checks.
cp scripts/configure-claude-hooks.js scripts/configure-codex-hooks.js "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/"*.sh
for appex in "$app"/Contents/Extensions/*.appex; do
    [ -d "$appex" ] && codesign --force --sign "$identity" "$appex"
done
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app" || die "The signed app does not verify."

# 4. Packages.
out="$work/release"
mkdir -p "$out"
ditto -c -k --keepParent "$app" "$out/AccountDock.zip"
chmod +x scripts/package/postinstall
pkgbuild --component "$app" --install-location /Applications --scripts scripts/package \
    --identifier app.accountdock.mac.pkg --version "$version" "$out/AccountDock.pkg" >/dev/null
(cd "$out" && for file in AccountDock.zip AccountDock.pkg; do shasum -a 256 "$file" > "$file.sha256"; done)

notes="$work/notes.md"
awk -v v="## $version" '$0 == v { found = 1; next } found && /^## / { exit } found { print }' RELEASE_NOTES.md > "$notes"
[ -s "$notes" ] || echo "AccountDock $version" > "$notes"

echo ""
echo "Ready to publish $tag to $repository:"
ls -l "$out" | awk 'NR > 1 { print "  " $NF " (" $5 " bytes)" }'
if ! $assume_yes; then
    read -r -p "Push main and $tag, and publish the release? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Not published. $tag stays local."; exit 0; }
fi

# 5. Publish.
"${git_push[@]}" origin main "$tag"
gh release create "$tag" "$out"/AccountDock.zip "$out"/AccountDock.zip.sha256 \
    "$out"/AccountDock.pkg "$out"/AccountDock.pkg.sha256 \
    --repo "$repository" --title "AccountDock $tag" --notes-file "$notes" --verify-tag
echo "Published $tag."
