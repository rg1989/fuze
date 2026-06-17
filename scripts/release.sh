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

# DMG — styled drag-to-Applications layout via dmgbuild (no Finder Automation).
DMG="$OUT/Fuse-$VERSION.dmg"
BG="$OUT/dmg-background.png"
swift scripts/dmg-background.swift "$BG"

if ! python3 -c "import dmgbuild" 2>/dev/null; then
  echo "Installing dmgbuild (one-time) for DMG layout…"
  python3 -m pip install --user dmgbuild
fi

for vol in /Volumes/Fuse /Volumes/Fuse\ *; do
  [ -d "$vol" ] && hdiutil detach "$vol" -force >/dev/null 2>&1 || true
done

APP_ABS="$(cd "$OUT" && pwd)/Fuse.app"
BG_ABS="$(cd "$(dirname "$BG")" && pwd)/$(basename "$BG")"
python3 -m dmgbuild -s scripts/dmg-settings.py \
  -Dapp="$APP_ABS" -Dbackground="$BG_ABS" \
  "Fuse" "$DMG"
rm -f "$BG"
echo "Built $DMG"
