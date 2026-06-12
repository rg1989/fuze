#!/bin/bash
# Usage:
#   ./scripts/release.sh                    # auto-detects an Apple Development cert, else ad-hoc
#   SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=fuse ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(date +%Y.%m.%d)
# Prefer a stable signing identity: with an Apple Development certificate the
# app's designated requirement survives rebuilds, so TCC permission grants
# (Accessibility, Input Monitoring, Screen Recording) stick across updates.
# Falls back to ad-hoc ("-") when no certificate is installed.
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
  SIGN_ID="${SIGN_ID:--}"
fi
echo "Signing as: $SIGN_ID"
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

# DMG — styled drag-to-Applications layout: dark background with an arrow,
# 128 px icons, fixed window size. Finder layout is applied to a read-write
# image first, then converted to the compressed final DMG.
DMG="$OUT/Fuse-$VERSION.dmg"
STAGE="$OUT/dmg-root"
RW_DMG="$OUT/Fuse-rw.dmg"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift "$STAGE/.background/background.png"

# Detach stale Fuse installer volumes from earlier opens/builds — a mounted
# "Fuse" volume would make this image mount as "Fuse 2", so Finder would
# style (and detach) the wrong disk.
for vol in /Volumes/Fuse /Volumes/Fuse\ *; do
  [ -d "$vol" ] && hdiutil detach "$vol" -force >/dev/null 2>&1 || true
done

hdiutil create -volname "Fuse" -srcfolder "$STAGE" -ov -format UDRW "$RW_DMG"
MOUNT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | tail -1)
if [ "$MOUNT" != "/Volumes/Fuse" ]; then
  echo "WARNING: unexpected mount point '$MOUNT'; skipping Finder styling"
else
# Finder scripting needs Automation permission; a denial must not kill the
# release — the DMG just ships with the default layout.
osascript <<'EOF' || echo "WARNING: Finder styling failed (Automation permission?); DMG keeps default layout"
tell application "Finder"
  tell disk "Fuse"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- window bounds {left, top, right, bottom}: 660×400 content
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    -- positions are icon centers in window coords (top-left origin)
    set position of item "Fuse.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
fi
sync
hdiutil detach "$MOUNT"
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG"
rm -f "$RW_DMG"
rm -rf "$STAGE"
echo "Built $DMG"
