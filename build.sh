#!/bin/sh
# Builds build/JoyMouse.app. The previous app is only replaced once the compile succeeds.
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-"). A real identity keeps the
#                  Accessibility permission across rebuilds.
#   ARCHS          architectures (default: this Mac's). e.g. ARCHS="arm64 x86_64"
set -e
cd "$(dirname "$0")"
APP=build/JoyMouse.app
ARCHS=${ARCHS:-$(uname -m)}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
mkdir -p build
slices=""
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -framework AppKit -framework CoreBluetooth -framework IOBluetooth -framework ServiceManagement \
    Sources/*.swift -o "build/JoyMouse-$arch"
  slices="$slices build/JoyMouse-$arch"
done
lipo -create $slices -output build/JoyMouse.bin
rm -f $slices
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/JoyMouse.bin "$APP/Contents/MacOS/JoyMouse"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force -s - "$APP"
else
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
fi
echo "built $APP ($ARCHS)"
