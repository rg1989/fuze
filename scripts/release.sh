#!/bin/bash
# Usage:
#   ./scripts/release.sh                    # ad-hoc signed DMG (personal use)
#   SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=fuse ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(date +%Y.%m.%d)
SIGN_ID="${SIGN_ID:--}"            # "-" = ad-hoc
OUT=dist
APP="$OUT/Fuse.app"

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate

xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Release \
  -derivedDataPath .build-release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

cp -R .build-release/Build/Products/Release/Fuse.app "$APP"

# Sign (hardened runtime only matters for notarized builds; harmless otherwise)
codesign --force --deep --options runtime \
  --entitlements Fuse.entitlements \
  --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP" && echo "codesign OK"

if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_ID" != "-" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/Fuse.zip"
  xcrun notarytool submit "$OUT/Fuse.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/Fuse.zip"
fi

# DMG
DMG="$OUT/Fuse-$VERSION.dmg"
mkdir -p "$OUT/dmg-root"
cp -R "$APP" "$OUT/dmg-root/"
ln -s /Applications "$OUT/dmg-root/Applications"
hdiutil create -volname "Fuse" -srcfolder "$OUT/dmg-root" -ov -format UDZO "$DMG"
rm -rf "$OUT/dmg-root"
echo "Built $DMG"
