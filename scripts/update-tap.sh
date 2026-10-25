#!/bin/bash
# Points the Homebrew tap (philipparndt/homebrew-ai-pause) at a published release.
#
# Usage: scripts/update-tap.sh <version> [sha256]
#        scripts/update-tap.sh --print <version> [sha256]   show the cask, change nothing
#
# The checksum is read from build/AI-Pause-<version>.zip.sha256 when not given.
set -euo pipefail

cd "$(dirname "$0")/.."

PRINT=""
if [ "${1:-}" = "--print" ]; then PRINT=1; shift; fi

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: update-tap.sh [--print] <version> [sha256]"; exit 2; }
VERSION="${VERSION#v}"
SHA="${2:-}"

REPO="${AI_PAUSE_REPO:-philipparndt/ai-pause}"
TAP="${AI_PAUSE_TAP:-philipparndt/homebrew-ai-pause}"
ZIP="build/AI-Pause-$VERSION.zip"

if [ -z "$SHA" ]; then
	test -f "$ZIP.sha256" || { echo "no $ZIP.sha256 and no checksum given"; exit 1; }
	SHA=$(awk '{print $1}' < "$ZIP.sha256")
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "not a sha256: $SHA"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CASK="$WORK/ai-pause.rb"

cat > "$CASK" <<RUBY
# typed: strict
# frozen_string_literal: true

cask "ai-pause" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/AI-Pause-#{version}.zip"
  name "AI Pause"
  desc "Menu bar app that pauses AI coding agents during calls and games"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "AI Pause.app"
  binary "#{appdir}/AI Pause.app/Contents/MacOS/ai-pause"

  uninstall launchctl: "de.philipparndt.ai-pause",
            quit:      "de.philipparndt.ai-pause",
            delete:    "~/Library/LaunchAgents/de.philipparndt.ai-pause.plist"

  zap trash: "~/.config/ai-pause"

  caveats <<~EOS
    Start AI Pause now and at every login:
      ai-pause install-login
  EOS
end
RUBY

if command -v brew >/dev/null; then
	echo "==> brew style"
	brew style "$CASK" || echo "    (style complained, not fatal)"
fi

if [ -n "$PRINT" ]; then
	cat "$CASK"
	exit 0
fi

command -v gh >/dev/null || { echo "gh is not installed: brew install gh"; exit 1; }

# The cask must describe the file GitHub actually serves.
PUBLISHED=$(gh release view "v$VERSION" --repo "$REPO" --json assets \
	--jq ".assets[] | select(.name == \"AI-Pause-$VERSION.zip\") | .digest // \"\"" 2>/dev/null || true)
if [ -z "$PUBLISHED" ]; then
	echo "no AI-Pause-$VERSION.zip published at v$VERSION in $REPO, publish the release first" >&2
	exit 1
fi
if [ "$PUBLISHED" != "null" ] && [ "$PUBLISHED" != "sha256:$SHA" ]; then
	echo "the published zip is not the one this cask pins:" >&2
	echo "  cask:      sha256:$SHA" >&2
	echo "  published: $PUBLISHED" >&2
	exit 1
fi

echo "==> Cloning $TAP"
gh repo clone "$TAP" "$WORK/tap" -- --quiet
mkdir -p "$WORK/tap/Casks"
cp "$CASK" "$WORK/tap/Casks/ai-pause.rb"

cd "$WORK/tap"
if [ -z "$(git status --porcelain -- Casks/ai-pause.rb)" ]; then
	echo "==> $TAP already points at $VERSION"
	exit 0
fi
git add Casks/ai-pause.rb
git commit -q -m "AI Pause $VERSION"
git push -q origin HEAD:main
echo "==> $TAP now installs AI Pause $VERSION"
echo "    brew install --cask philipparndt/ai-pause/ai-pause"
