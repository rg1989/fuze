# Phase 9: Packaging & Final QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–8 complete.

**Goal:** A distributable, signed (and, if a Developer ID is available, notarized) `Fuse.app` in a DMG, plus a full cross-feature manual QA pass.

**Architecture:** Release build via `xcodebuild archive` driven by a single `scripts/release.sh`. Signing is parameterized: ad-hoc for personal use, Developer ID + notarization when credentials exist. Nested Mach-O binaries (the managed `yt-dlp` lives in Application Support, NOT inside the bundle, precisely so re-signing is never needed when it self-updates).

**Tech Stack:** xcodebuild, codesign, xcrun notarytool, hdiutil.

---

### Task 9.1: App icon

**Files:**
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/` (via script)
- Create: `scripts/make-icon.sh`
- Modify: `project.yml` (icon setting)

- [ ] **Step 1: HUMAN-VERIFY — source artwork.** Ask the human for a 1024×1024 PNG (`icon-1024.png` in repo root). If they don't have one, generate a placeholder:

```bash
# Renders the SF Symbol bolt onto a rounded dark background as a stand-in icon.
swift - <<'EOF'
import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 180, yRadius: 180).fill()
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .bold)
if let symbol = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = symbol.copy() as! NSImage
    tinted.lockFocus()
    NSColor.systemYellow.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = NSRect(x: (1024 - tinted.size.width)/2, y: (1024 - tinted.size.height)/2,
                   width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: r)
}
image.unlockFocus()
try! image.tiffRepresentation
    .flatMap { NSBitmapImageRep(data: $0) }!
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "icon-1024.png"))
EOF
ls -la icon-1024.png
```

- [ ] **Step 2: Write `scripts/make-icon.sh`**

```bash
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
```

- [ ] **Step 3: Generate the icon set and wire it into the build**

```bash
chmod +x scripts/make-icon.sh && ./scripts/make-icon.sh
```
Then in `project.yml`, inside `targets: → Fuse: → settings:` add a `base:` block (or extend the existing target-level settings):

```yaml
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

- [ ] **Step 4: Rebuild and verify**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -3
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Expected: `** BUILD SUCCEEDED **`. **HUMAN-VERIFY:** the new icon shows in Settings window's title bar / app switcher.

- [ ] **Step 5: Commit**

```bash
git add scripts/make-icon.sh Resources/Assets.xcassets project.yml icon-1024.png
git commit -m "feat: app icon and asset catalog"
```

---

### Task 9.2: Release script (archive → sign → DMG)

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1: Write `scripts/release.sh`**

```bash
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
```

- [ ] **Step 2: Run it (ad-hoc path)**

```bash
chmod +x scripts/release.sh && ./scripts/release.sh
```
Expected: `codesign OK` and `Built dist/Fuse-<date>.dmg`. Note: an ad-hoc DMG is for **this machine only**; Gatekeeper blocks it elsewhere.

- [ ] **Step 3: HUMAN-VERIFY — install from DMG.** Mount the DMG, drag Fuse to /Applications, launch it. macOS treats this as a NEW binary: every permission (Accessibility, Input Monitoring, Microphone) must be re-granted via the General tab. Confirm the app works from /Applications.

- [ ] **Step 4: Commit**

```bash
git add scripts/release.sh
git commit -m "feat: release script with optional notarization and DMG output"
```

- [ ] **Step 5 (optional, requires Apple Developer Program): notarized build.** Ask the human whether they have a Developer ID certificate. If yes:

```bash
# one-time credential setup
xcrun notarytool store-credentials fuse --apple-id <appleid> --team-id <TEAMID> --password <app-specific-password>
SIGN_ID="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=fuse ./scripts/release.sh
```
Expected: notarytool reports `status: Accepted`, stapler reports `The staple and validate action worked!`. If no Developer ID, skip — ad-hoc is fine for personal use.

---

### Task 9.3: Full cross-feature QA pass

**Files:** none (verification only)

- [ ] **Step 1: HUMAN-VERIFY — run this script with the human, from the /Applications install, all permissions granted:**

1. **Scroll:** trackpad scrolls naturally; external mouse wheel direction matches the Scroll tab settings; toggling "Reverse mouse" flips it live.
2. **Tiling:** in any app press ⌃⌥← / ⌃⌥→ / ⌃⌥↩ / ⌃⌥1–4 / ⌃⌥C / ⌃⌥N — window snaps correctly on every connected display.
3. **Clipboard:** copy a sentence in a browser, a file in Finder, and a screenshot region (⇧⌃⌘4); press ⇧⌘V in TextEdit; all three appear newest-first with previews; pick the text item → it pastes; original clipboard restored ~1 s later.
4. **Voice:** hold ⌃⌥Space in TextEdit, speak a sentence, release; HUD shows recording→transcribing; text appears at the cursor within a few seconds (base.en model).
5. **Downloader:** paste a video page URL into the Downloads window; metadata resolves; download completes into the configured folder; progress bar moved during download.
6. **Notifications:** create test notifications (e.g. ask someone to message you, or `osascript -e 'display notification "test" with title "QA"'` twice), press ⌃⌥⌫ — Notification Center empties without mouse use.
7. **Notes:** press ⌃⌥M — notes panel appears; create a note with a text block, a code block (copy button puts the code on the clipboard — and it shows up in the ⇧⌘V clipboard history), and an image block pasted from a screenshot; press ⌃⌥M to hide; press again — content persisted; "Copy as Markdown" produces fenced code.
8. **Pause switch:** menu-bar icon → "Pause Fuse" — icon dims; mouse-wheel reversal reverts to system behavior; ⌃⌥← does nothing; text copied in TextEdit while paused never appears in history, even after resuming. Resume restores everything.
9. **Coexistence banner:** with a known utility running (e.g. Rectangle or Maccy — or temporarily add `"com.apple.TextEdit"` to `ConflictDetector.knownConflicts` and open TextEdit, reverting afterwards), Settings → General shows the conflict banner with advice; quitting the app clears it within ~2 s.
10. **Privacy exclusions:** add Terminal in Settings → Clipboard → "Privacy — never record from"; copy text in Terminal → absent from ⇧⌘V history; remove Terminal → Terminal copies record again.
11. **Restart resilience:** quit Fuse, relaunch — all seven features work without reconfiguration; "Launch at login" survives a reboot if the human is willing to test it.

- [ ] **Step 2: Record results.** Append a `## QA <date>` section to `README.md` listing pass/fail per feature; file follow-up issues for any failure. Commit:

```bash
git add README.md
git commit -m "docs: record release QA results"
```

---

## Manual verification checklist (end of phase)

- [ ] DMG built and installed from /Applications.
- [ ] All 11 QA script items pass.
- [ ] (Optional) Notarization `Accepted` if Developer ID available.

## Risks & gotchas

- `codesign --deep` is deprecated-ish but acceptable here because all nested code is SPM-built frameworks; if Sparkle or helper tools are ever added, sign inside-out explicitly.
- Ad-hoc signed apps: TCC permissions reset on every re-sign — expected; Developer ID signing makes grants stable across updates (the real reason to get a certificate).
- WhisperKit models live in Application Support, not the bundle — DMG stays small (~30 MB) and models survive app updates.
