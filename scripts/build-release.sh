#!/bin/zsh
# Builds Cluvia-<version>.dmg (plus a .sha256 file) in build/release.
#
#   DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=my-profile scripts/build-release.sh
#
# DEVELOPMENT_TEAM   Apple team ID owning the "Developer ID Application" certificate (unless UNSIGNED=1).
# Notarization, unless SKIP_NOTARIZE=1 or UNSIGNED=1, with either:
#   NOTARY_PROFILE   keychain profile created with `xcrun notarytool store-credentials`, or
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (used by CI).
# SKIP_NOTARIZE=1    Sign with Developer ID and package, without notarizing.
# UNSIGNED=1         No Developer ID: ad-hoc signed, not notarized. Gatekeeper will block it until the user allows it.
# BUILD_NUMBER       CFBundleVersion (defaults to the project's CURRENT_PROJECT_VERSION).
#
# The version (CFBundleShortVersionString) comes from MARKETING_VERSION in project.yml, which release-please bumps.
set -euo pipefail

UNSIGNED=${UNSIGNED:-0}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-0}
[[ "$UNSIGNED" == "1" ]] && SKIP_NOTARIZE=1
if [[ "$UNSIGNED" != "1" ]]; then : "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID (or UNSIGNED=1)}"; fi

notary_args=()
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    echo "set NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, or SKIP_NOTARIZE=1" >&2
    exit 1
  fi
fi

ROOT=${0:A:h:h}
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Cluvia.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Cluvia.app"
IDENTITY="Developer ID Application"
build_settings=()
[[ -n "${BUILD_NUMBER:-}" ]] && build_settings+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

rm -rf "$BUILD"
mkdir -p "$BUILD" "$EXPORT"
cd "$ROOT"
xcodegen generate --quiet

echo "==> Archiving"
if [[ "$UNSIGNED" == "1" ]]; then
  xcodebuild archive -project Cluvia.xcodeproj -scheme Cluvia -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/DerivedData" -skipPackagePluginValidation \
    "${build_settings[@]}" | tail -1
  cp -R "$ARCHIVE/Products/Applications/Cluvia.app" "$APP"
else
  xcodebuild archive -project Cluvia.xcodeproj -scheme Cluvia -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$BUILD/DerivedData" -skipPackagePluginValidation \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" "${build_settings[@]}" | tail -1

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
fi
codesign --verify --deep --strict --verbose=1 "$APP"

if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$APP" "$BUILD/Cluvia.zip"
  xcrun notarytool submit "$BUILD/Cluvia.zip" "${notary_args[@]}" --wait
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
if [[ "$UNSIGNED" != "1" ]]; then codesign --sign "$IDENTITY" --timestamp "$DMG"; fi
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  xcrun notarytool submit "$DMG" "${notary_args[@]}" --wait
  xcrun stapler staple "$DMG"
  echo "==> Verifying"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
fi
(cd "$BUILD" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "Built $DMG"
