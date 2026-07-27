#!/bin/bash
set -euo pipefail

# AccountDock local release-preparation script.
# Updates the version, commits, and tags locally. It never pushes.
#
# Usage:
#   ./scripts/release.sh <version>
#   ./scripts/release.sh patch|minor|major
#
# Examples:
#   ./scripts/release.sh 1.3.0
#   ./scripts/release.sh patch    # 1.2.3 -> 1.2.4
#   ./scripts/release.sh minor    # 1.2.3 -> 1.3.0
#   ./scripts/release.sh major    # 1.2.3 -> 2.0.0

PROJECT_YML="project.yml"

# --- Helpers ---

die() { echo "ERROR: $1" >&2; exit 1; }

get_current_version() {
    grep 'MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*"\(.*\)".*/\1/'
}

get_current_build() {
    grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed 's/.*"\(.*\)".*/\1/'
}

bump_semver() {
    local current="$1" type="$2"
    IFS='.' read -r major minor patch <<< "$current"
    case "$type" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) die "Unknown bump type: $type" ;;
    esac
}

# --- Preflight checks ---

# Must be in repo root
[ -f "$PROJECT_YML" ] || die "Must be run from the project root (project.yml not found)"

# Must be on main branch
BRANCH=$(git branch --show-current)
[ "$BRANCH" = "main" ] || die "Must be on main branch (currently on '$BRANCH')"

# Must have clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Working tree is dirty. Commit or stash changes first."
fi

# Must have no untracked files in source directories
UNTRACKED=$(git ls-files --others --exclude-standard AccountDock/ AccountDockWidget/ Shared/ project.yml)
[ -z "$UNTRACKED" ] || die "Untracked source files found:\n$UNTRACKED"

# --- Determine version ---

CURRENT_VERSION=$(get_current_version)
CURRENT_BUILD=$(get_current_build)

if [ $# -ne 1 ]; then
    echo "Current: v${CURRENT_VERSION} (build ${CURRENT_BUILD})"
    echo ""
    echo "Usage: $0 <version|patch|minor|major>"
    exit 1
fi

INPUT="$1"

case "$INPUT" in
    patch|minor|major) NEW_VERSION=$(bump_semver "$CURRENT_VERSION" "$INPUT") ;;
    [0-9]*) NEW_VERSION="$INPUT" ;;
    *) die "Invalid argument: $INPUT (expected version number or patch/minor/major)" ;;
esac

NEW_BUILD=$((CURRENT_BUILD + 1))
TAG="v${NEW_VERSION}"

# --- Validate ---

echo "Release plan:"
echo "  Version:  ${CURRENT_VERSION} -> ${NEW_VERSION}"
echo "  Build:    ${CURRENT_BUILD} -> ${NEW_BUILD}"
echo "  Tag:      ${TAG}"
echo ""

# Check the tag does not already exist locally.
if git tag -l "$TAG" | grep -q .; then
    die "Tag $TAG already exists locally. Delete it first: git tag -d $TAG"
fi

read -p "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- Execute ---

# 1. Update MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml (all occurrences)
sed -i '' "s/MARKETING_VERSION: \"${CURRENT_VERSION}\"/MARKETING_VERSION: \"${NEW_VERSION}\"/g" "$PROJECT_YML"
sed -i '' "s/CURRENT_PROJECT_VERSION: \"${CURRENT_BUILD}\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/g" "$PROJECT_YML"

# 2. Regenerate Xcode project
xcodegen generate

# 3. Verify the update
VERIFY_VERSION=$(get_current_version)
VERIFY_BUILD=$(get_current_build)
[ "$VERIFY_VERSION" = "$NEW_VERSION" ] || die "Version update failed: expected $NEW_VERSION, got $VERIFY_VERSION"
[ "$VERIFY_BUILD" = "$NEW_BUILD" ] || die "Build update failed: expected $NEW_BUILD, got $VERIFY_BUILD"

# 4. Commit
git add "$PROJECT_YML"
git commit -m "chore: Bump to ${NEW_VERSION} (build ${NEW_BUILD})"

# 5. Create tag on this exact commit
git tag "$TAG"

echo ""
echo "Prepared ${TAG} (build ${NEW_BUILD}) locally."
echo "Nothing was pushed. Publish only with explicit approval:"
echo "  git push origin main"
echo "  git push origin ${TAG}"
