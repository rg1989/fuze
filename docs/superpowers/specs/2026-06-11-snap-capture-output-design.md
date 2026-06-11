# Design: Drag-Snap Tiling, Capture Overlay Fixes, Premium Voice HUD, Capture Output Pipeline

Date: 2026-06-11
Status: approved-by-default (user requested uninterrupted execution; decisions below
use the conventions of the tile manager Fuse replaces — veto anything and it gets reworked)

## 1. Drag-to-edge window snapping with preview (Tiling)

Dragging any window to a screen edge shows a translucent preview of the tile the
window would occupy; releasing the mouse applies it.

**Zones** (cursor within 10 pt of a screen-frame edge):

| Where | Action |
|---|---|
| Left edge, middle 50 % | left half |
| Left edge, top 25 % / bottom 25 % | top-left / bottom-left quarter |
| Right edge (mirrored) | right half / quarters |
| Top edge, middle 50 % | maximize |
| Top edge, outer 25 % each side | top-left / top-right quarter |
| Bottom edge | nothing (Dock) |

**Components**
- `SnapZone.swift` — pure hit-testing: `(mouseLocation, screenFrame) -> TileAction?`.
  Unit-tested (`SnapZoneTests`).
- `SnapPreviewOverlay.swift` — borderless, mouse-transparent window; rounded
  translucent accent-tinted rect with border, animated frame changes.
- `SnapDragMonitor.swift` — global mouse monitors (`leftMouseDown/Dragged/Up`).
  A drag is treated as a *window* drag only when the AX window under the initial
  mouse-down moves with the cursor while keeping its size (rules out text
  selection and resizes). On mouse-up inside a zone, applies the tile action to
  that window on the screen under the cursor.
- `WindowMover.apply(_:to:on:)` — refactored overload so the monitor can target
  the dragged window + cursor screen instead of frontmost window + its screen.
- Settings: `tiling.snapDrag` (default true) toggle in Tiling tab. Monitor
  respects `tiling.enabled` and PauseManager.

## 2. Screen-recording selection overlay + REC controls (Capture)

HEAD already freezes the dim backdrop + clear selection hole through the armed and
recording phases (commits c4b3627/f2ccd34); the installed build predated them.
Changes on top:

- Armed **Ready / Start / Cancel** HUD is centered in the middle of the selection
  (was: bottom edge of selection; the user's installed build pinned it top-right).
- Recording **Stop** HUD stays just outside the selection (below, then above,
  then inside as fallbacks) — deliberately NOT centered, otherwise the controls
  would be recorded into the video.
- `RecHUD` view restyled to match the premium HUD language (dark glass, red glow).
- Placement stays a pure function (`RecHUD.hudOrigin`), tests updated.

## 3. Premium voice HUD (Voice)

`RecordingHUDView` redesigned, API (`show/flash/hide`) unchanged:
- Dark glass rounded container, gradient hairline border, soft shadow.
- Recording: pulsing red-orange gradient orb + animated equalizer bars.
- Transcribing: rotating angular-gradient ring + label.
- Message: warning glyph in the same container.
All animation is TimelineView/withAnimation driven; no timers in the model.

## 4. Capture output pipeline

- **Folders**: screenshots → `capture.screenshotFolderPath`
  (default `~/Pictures/Fuse Screenshots`); recordings → `capture.recordingFolderPath`
  (default `~/Movies/Fuse Recordings`). If the user had customized the legacy
  `capture.saveFolderPath`, both new settings seed from it once.
- **Menu**: "Open Screenshots Folder" and "Open Recordings Folder" status-menu
  items + new configurable shortcuts (`openScreenshotsFolder`,
  `openRecordingsFolder`) in the Capture settings tab.
- **Clipboard**: unchanged — capture is copied immediately after saving.
- **Preview window** (`CapturePreview.swift`), replaces auto-opening the editor
  (setting `capture.showPreviewAfter`, default true, replaces
  `capture.openEditorAfter`):
  - Image thumbnail or AVKit player, filename, two large buttons:
    **Delete (Esc)** and **Keep (Return)**, plus a secondary **Edit** button that
    opens the existing annotation editor / trimmer.
  - Keep → close; file + clipboard untouched.
  - Delete → file moved to Trash; system clipboard cleared if Fuse's copy is
    still the current item (changeCount guard); matching items purged from
    Fuse clipboard history (`ClipboardStore.deleteItems(containingRepresentation:)`
    matched on the file-URL representation).

## Verification

- Unit: `SnapZoneTests`, updated `RecHUDPlacementTests`, existing suite green.
- Build: Release build via `scripts/release.sh`, fresh DMG (the bug report was
  filed against a stale installed build).
