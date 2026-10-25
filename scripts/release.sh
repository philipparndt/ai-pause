#!/bin/bash
# Signs, notarizes and zips build/AI Pause.app for other machines.
#
# Run through `make release`, which builds the universal app first.
#
# Needs a "Developer ID Application" certificate in the keychain and a stored notarytool
# profile (NOTARY_PROFILE, default "notarytool"). On a machine without one, once:
#
#   xcrun notarytool store-credentials notarytool \
#       --apple-id <Apple ID> --team-id <team id> --password <app-specific password>
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/AI Pause.app"
PROFILE="${NOTARY_PROFILE:-notarytool}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

test -d "$APP" || { echo "no $APP, run make release"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/AI-Pause-$VERSION.zip"
BIN="$APP/Contents/MacOS/ai-pause"

# The download is the one build whose processor isn't known in advance.
for wanted in arm64 x86_64; do
	lipo -archs "$BIN" | grep -qw "$wanted" || { echo "refusing to release: $BIN lacks $wanted, run make release" >&2; exit 1; }
done

echo "==> Signing with: $IDENTITY"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
	|| { echo "Stopping: not signed with a Developer ID, Apple would reject this."; exit 1; }

# Stapled so the app doesn't have to ask Apple on first launch.
echo "==> Notarizing (waits for Apple)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Making $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper:"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

shasum -a 256 "$ZIP" | sed "s#build/##" > "$ZIP.sha256"
echo "==> Done: $ZIP"
