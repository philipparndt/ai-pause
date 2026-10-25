#!/bin/bash
# Cuts a release: stamps the version, tags it, builds and notarizes from that tag, uploads
# the zip to GitHub and points the Homebrew tap at it.
#
# The upload comes last so a failed notarization never leaves an empty release behind.
#
# Usage: make release-publish VERSION=0.2.0
#
# Needs: a Developer ID certificate, a stored notarytool profile (see scripts/release.sh),
# release notes in docs/release-notes-<version>.md, and `gh` logged in.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: publish-release.sh <version>   e.g. 0.2.0"; exit 2; }
VERSION="${VERSION#v}"
TAG="v$VERSION"
ZIP="build/AI-Pause-$VERSION.zip"
NOTES_FILE="docs/release-notes-$VERSION.md"
REPO="${AI_PAUSE_REPO:-philipparndt/ai-pause}"

command -v gh >/dev/null || { echo "gh is not installed: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
	|| { echo "no Developer ID Application certificate in the keychain"; exit 1; }

# Everything that can stop the release is checked before the tag exists.
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "the working tree has changes, commit or stash them first"
	exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
	echo "$TAG already exists"
	exit 1
fi
[ -f "$NOTES_FILE" ] || { echo "no release notes at $NOTES_FILE, write them first" >&2; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "==> Releasing $TAG from $BRANCH"

if [ "$(cat VERSION)" != "$VERSION" ]; then
	echo "$VERSION" > VERSION
	git add VERSION
	git commit -q -m "Release $VERSION"
fi
git tag -a "$TAG" -m "AI Pause $VERSION"

make --no-print-directory release
test -f "$ZIP" || { echo "expected $ZIP and it is not there"; exit 1; }

git push origin "$BRANCH"
git push origin "$TAG"

NOTES=$(mktemp)
{
	cat "$NOTES_FILE"
	echo
	echo "### Install"
	echo
	echo "    brew install --cask philipparndt/ai-pause/ai-pause"
	echo
	echo "Signed with a Developer ID and notarized. Requires macOS 14.2 or newer, Apple silicon or Intel."
} > "$NOTES"

gh release create "$TAG" "$ZIP" "$ZIP.sha256" --repo "$REPO" --title "AI Pause $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

# After the release exists: the cask names a download that has to be there.
scripts/update-tap.sh "$VERSION"

echo "==> Published $TAG"
gh release view "$TAG" --repo "$REPO" --json url --jq .url
