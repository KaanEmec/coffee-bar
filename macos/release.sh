#!/bin/bash
# Builds a universal, Developer ID-signed CoffeeBar.app and zips it as build/CoffeeBar-macos.zip.
# Notarizes too when NOTARY_PROFILE names a `xcrun notarytool store-credentials` profile.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project CoffeeBar.xcodeproj -scheme CoffeeBar -configuration Release \
    -destination generic/platform=macOS -derivedDataPath build/DD ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp \
    clean build | grep -E "error:|\*\* BUILD" || true

app=build/DD/Build/Products/Release/CoffeeBar.app
codesign --verify --deep --strict "$app"
[[ "$(codesign -dv --verbose=2 "$app" 2>&1)" == *"Authority=Developer ID Application"* ]] || { echo "not Developer ID signed"; exit 1; }
[ -f "$app/Contents/Resources/AppIcon.icns" ] || { echo "app icon missing"; exit 1; }
lipo -archs "$app/Contents/MacOS/CoffeeBar"
lipo -archs "$app/Contents/MacOS/CoffeeBarHelper"

zip=build/CoffeeBar-macos.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip" && ditto -c -k --keepParent "$app" "$zip"
fi
shasum -a 256 "$zip"
