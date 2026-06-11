#!/bin/bash
# Builds AppIcon.appiconset from icon-1024.png using sips.
set -euo pipefail
SRC="icon-1024.png"
DEST="Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$DEST"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size "$SRC" --out "$DEST/icon_${size}.png" >/dev/null
done
cat > "$DEST/Contents.json" <<'JSON'
{
  "images": [
    {"size": "16x16",   "idiom": "mac", "scale": "1x", "filename": "icon_16.png"},
    {"size": "16x16",   "idiom": "mac", "scale": "2x", "filename": "icon_32.png"},
    {"size": "32x32",   "idiom": "mac", "scale": "1x", "filename": "icon_32.png"},
    {"size": "32x32",   "idiom": "mac", "scale": "2x", "filename": "icon_64.png"},
    {"size": "128x128", "idiom": "mac", "scale": "1x", "filename": "icon_128.png"},
    {"size": "128x128", "idiom": "mac", "scale": "2x", "filename": "icon_256.png"},
    {"size": "256x256", "idiom": "mac", "scale": "1x", "filename": "icon_256.png"},
    {"size": "256x256", "idiom": "mac", "scale": "2x", "filename": "icon_512.png"},
    {"size": "512x512", "idiom": "mac", "scale": "1x", "filename": "icon_512.png"},
    {"size": "512x512", "idiom": "mac", "scale": "2x", "filename": "icon_1024.png"}
  ],
  "info": {"version": 1, "author": "xcode"}
}
JSON
cat > "Resources/Assets.xcassets/Contents.json" <<'JSON'
{"info": {"version": 1, "author": "xcode"}}
JSON
echo "Icon set written to $DEST"
