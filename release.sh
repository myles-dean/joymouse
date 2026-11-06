#!/bin/sh
# Universal, Developer ID signed, notarized and stapled build → build/JoyMouse-<version>.zip
#
# One-time setup (stores your notary credentials in the keychain as profile "notary"):
#   xcrun notarytool store-credentials notary --apple-id <you@example.com> --team-id <TEAMID>
# (it asks for an app-specific password from appleid.apple.com).
#
#   SIGN_IDENTITY  default: the first "Developer ID Application" identity in your keychain
#   NOTARY_PROFILE default: notary
set -e
cd "$(dirname "$0")"
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
NOTARY_PROFILE=${NOTARY_PROFILE:-notary}
[ -n "$SIGN_IDENTITY" ] || { echo "no Developer ID Application identity found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="build/JoyMouse-$VERSION.zip"

ARCHS="arm64 x86_64" SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh
codesign --verify --strict --verbose=2 build/JoyMouse.app

rm -f "$ZIP"
ditto -c -k --keepParent build/JoyMouse.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/JoyMouse.app
rm -f "$ZIP"
ditto -c -k --keepParent build/JoyMouse.app "$ZIP"
spctl --assess --type execute --verbose build/JoyMouse.app
echo "release: $ZIP"
