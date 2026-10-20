#!/bin/zsh
# Builds a Developer ID signed, notarized and stapled Cluvia.dmg.
#
#   DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=my-profile scripts/build-release.sh
#
# DEVELOPMENT_TEAM  Apple team ID owning the "Developer ID Application" certificate (required).
# NOTARY_PROFILE    Keychain profile created with `xcrun notarytool store-credentials` (required unless SKIP_NOTARIZE=1).
# SKIP_NOTARIZE=1   Sign and package only (local verification without notary credentials).
set -euo pipefail

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then : "${NOTARY_PROFILE:?set NOTARY_PROFILE (or SKIP_NOTARIZE=1)}"; fi

ROOT=${0:A:h:h}
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Cluvia.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Cluvia.app"
IDENTITY="Developer ID Application"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$ROOT"
xcodegen generate --quiet

echo "==> Archiving"
xcodebuild archive -project Cluvia.xcodeproj -scheme Cluvia -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/DerivedData" -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" | tail -1

echo "==> Exporting"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$BUILD/ExportOptions.plist" | tail -1
codesign --verify --deep --strict --verbose=1 "$APP"

notarize() {
  if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then echo "    (skipped notarization of ${1:t})"; return; fi
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$1"
}

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$BUILD/Cluvia.zip"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  xcrun notarytool submit "$BUILD/Cluvia.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "==> Building DMG"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$BUILD/Cluvia-$VERSION.dmg"
hdiutil create -volname "Cluvia $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"

echo "==> Verifying"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
fi
echo "Built $DMG"
