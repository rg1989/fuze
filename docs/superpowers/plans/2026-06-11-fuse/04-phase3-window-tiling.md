# Phase 3: Window Tiling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** Rectangle-style keyboard window tiling: 11 global hotkeys (halves, quarters, maximize, center, move-to-next-display) that reposition the frontmost window of any app via the Accessibility API, with a configurable gap and a Tiling settings tab containing shortcut recorders.

**Architecture:** All new code lives in `Sources/Tiling/`. Two pure, fully unit-tested layers do every calculation: `TileGeometry` (action → target rect inside a screen's `visibleFrame`, gap-aware, all in Cocoa bottom-left-origin coordinates) and `ScreenCoords` (the Cocoa ↔ AX top-left-origin coordinate flip). One thin OS-integration layer, `WindowMover`, glues them to `AXElement` from Core (`Sources/Core/AX.swift`) — it is verified by HUMAN-VERIFY steps, never unit-tested. `TilingController` registers the 11 hotkeys via `KeyboardShortcuts.onKeyDown(for:)` using ONLY the existing `KeyboardShortcuts.Name` constants from `Sources/Core/HotkeyNames.swift`. Settings keys (master §6.4): `"tiling.enabled"` (Bool, default `true`), `"tiling.gap"` (Double, default `0`).

**Tech Stack:** Swift 5.10, AppKit (`NSScreen`, `NSWorkspace`), ApplicationServices via Core's `AXElement` wrapper, KeyboardShortcuts 2.x (hotkeys + `Recorder` SwiftUI view), SwiftUI (settings tab), XCTest.

---

### Task 3.0: Preflight — verify Phase 1 is complete and the tree is green

**Files:**
- None created or modified. Verification only.

- [x] **Step 1: Verify the Core files from Phase 1 exist**

```bash
ls -la /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core
```

Expected: the listing contains ALL of these five files (names exact):

```
AX.swift
HotkeyNames.swift
Log.swift
PasteService.swift
Permissions.swift
```

If any file is missing, STOP — Phase 1 is not complete. Do not proceed.

- [x] **Step 2: Verify the integration anchors exist**

```bash
grep -n "FUSE:CONTROLLER-PROPS" Sources/App/AppDelegate.swift
grep -n "FUSE:CONTROLLER-START" Sources/App/AppDelegate.swift
grep -n "FUSE:SETTINGS_TABS" Sources/App/SettingsRootView.swift
```

Expected: each grep prints exactly one matching line. If any anchor is missing, STOP — Phase 0 scaffold is broken; fix the anchor comments before continuing.

- [x] **Step 3: Verify the tiling hotkey constants exist in Core**

```bash
grep -c "tile" Sources/Core/HotkeyNames.swift
```

Expected: a number ≥ 11 (the file defines `.tileLeftHalf`, `.tileRightHalf`, `.tileTopHalf`, `.tileBottomHalf`, `.tileTopLeft`, `.tileTopRight`, `.tileBottomLeft`, `.tileBottomRight`, `.tileMaximize`, `.tileCenter`, `.tileNextDisplay`). This phase NEVER defines new `KeyboardShortcuts.Name` constants — it only consumes these.

- [x] **Step 4: Verify the build and the existing tests are green**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. If either is red, STOP and fix before starting Task 3.1 — never build a phase on a red tree.

No commit for this task (nothing changed).

---

### Task 3.1: TileAction + TileGeometry (pure logic, TDD)

`TileGeometry` converts a `TileAction` into a target window rect inside a screen's `visibleFrame`. ALL inputs and outputs are in Cocoa (bottom-left-origin) coordinates — the AX flip happens later, in `ScreenCoords`. The `gap` parameter is an inset in points applied between the window and the edges of `visibleFrame` AND between adjacent tiled windows: with gap `g`, a half-tile is `(width/2 − 1.5g)` wide because it gives up `g` at the outer edge and `g/2` of the shared inner seam (two windows each give up `g/2`, so the seam totals `g`).

**Files:**
- Create: `Sources/Tiling/TileAction.swift`
- Create: `Sources/Tiling/TileGeometry.swift`
- Test: `Tests/FuseTests/TileGeometryTests.swift`

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/TileGeometryTests.swift` with exactly this content**

The reference frame for all tests is `visibleFrame = (0, 0, 1600, 1000)`. Every expected rect below is exact; the helper compares each component with a tiny accuracy tolerance so CGFloat arithmetic can never cause flaky failures.

```swift
import XCTest
@testable import Fuse

final class TileGeometryTests: XCTestCase {
    private let vf = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let anySize = CGSize(width: 400, height: 300)

    private func frame(_ action: TileAction,
                       gap: CGFloat = 0,
                       size: CGSize? = nil,
                       in visibleFrame: CGRect? = nil) -> CGRect {
        TileGeometry.frame(for: action,
                           visibleFrame: visibleFrame ?? vf,
                           currentWindowSize: size ?? anySize,
                           gap: gap)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.0001, "origin.x", file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.0001, "origin.y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, "height", file: file, line: line)
    }

    // MARK: - Gap 0 (visibleFrame 0,0,1600,1000)

    func testLeftHalfGap0() {
        assertRect(frame(.leftHalf), CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testRightHalfGap0() {
        assertRect(frame(.rightHalf), CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testTopHalfGap0() {
        // Cocoa coordinates: the TOP half has the LARGER y origin.
        assertRect(frame(.topHalf), CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testBottomHalfGap0() {
        assertRect(frame(.bottomHalf), CGRect(x: 0, y: 0, width: 1600, height: 500))
    }

    func testTopLeftGap0() {
        assertRect(frame(.topLeft), CGRect(x: 0, y: 500, width: 800, height: 500))
    }

    func testTopRightGap0() {
        assertRect(frame(.topRight), CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testBottomLeftGap0() {
        assertRect(frame(.bottomLeft), CGRect(x: 0, y: 0, width: 800, height: 500))
    }

    func testBottomRightGap0() {
        assertRect(frame(.bottomRight), CGRect(x: 800, y: 0, width: 800, height: 500))
    }

    func testMaximizeGap0() {
        assertRect(frame(.maximize), CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    func testCenterKeepsSizeGap0() {
        // 400×300 window centered in 1600×1000 → origin ((1600-400)/2, (1000-300)/2).
        assertRect(frame(.center, size: CGSize(width: 400, height: 300)),
                   CGRect(x: 600, y: 350, width: 400, height: 300))
    }

    func testCenterClampsOversizedWindowGap0() {
        // 2000×1200 window cannot fit; it is clamped to the visible frame.
        assertRect(frame(.center, size: CGSize(width: 2000, height: 1200)),
                   CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    // MARK: - Gap 10 (visibleFrame 0,0,1600,1000)
    // Half tiles: width/height = side/2 − 1.5·gap. Outer edges inset by gap;
    // the seam between two adjacent tiles is exactly gap points wide.

    func testLeftHalfGap10() {
        assertRect(frame(.leftHalf, gap: 10), CGRect(x: 10, y: 10, width: 785, height: 980))
    }

    func testRightHalfGap10() {
        // Right tile starts at midline + gap/2: 800 + 5 = 805.
        assertRect(frame(.rightHalf, gap: 10), CGRect(x: 805, y: 10, width: 785, height: 980))
    }

    func testTopHalfGap10() {
        // Top tile starts at vertical midline + gap/2: 500 + 5 = 505.
        assertRect(frame(.topHalf, gap: 10), CGRect(x: 10, y: 505, width: 1580, height: 485))
    }

    func testBottomHalfGap10() {
        assertRect(frame(.bottomHalf, gap: 10), CGRect(x: 10, y: 10, width: 1580, height: 485))
    }

    func testTopLeftGap10() {
        assertRect(frame(.topLeft, gap: 10), CGRect(x: 10, y: 505, width: 785, height: 485))
    }

    func testTopRightGap10() {
        assertRect(frame(.topRight, gap: 10), CGRect(x: 805, y: 505, width: 785, height: 485))
    }

    func testBottomLeftGap10() {
        assertRect(frame(.bottomLeft, gap: 10), CGRect(x: 10, y: 10, width: 785, height: 485))
    }

    func testBottomRightGap10() {
        assertRect(frame(.bottomRight, gap: 10), CGRect(x: 805, y: 10, width: 785, height: 485))
    }

    func testMaximizeGap10() {
        assertRect(frame(.maximize, gap: 10), CGRect(x: 10, y: 10, width: 1580, height: 980))
    }

    func testHorizontalSeamIsExactlyGapWide() {
        let left = frame(.leftHalf, gap: 10)
        let right = frame(.rightHalf, gap: 10)
        XCTAssertEqual(right.minX - left.maxX, 10, accuracy: 0.0001)
    }

    func testCenterKeepsSizeGap10() {
        // A window that fits is centered identically regardless of gap.
        assertRect(frame(.center, gap: 10, size: CGSize(width: 400, height: 300)),
                   CGRect(x: 600, y: 350, width: 400, height: 300))
    }

    func testCenterClampsOversizedWindowGap10() {
        // Clamped to the gap-inset frame (1580×980), then centered → origin (10, 10).
        assertRect(frame(.center, gap: 10, size: CGSize(width: 2000, height: 1200)),
                   CGRect(x: 10, y: 10, width: 1580, height: 980))
    }

    // MARK: - nextDisplay geometry == center geometry
    // WindowMover handles screen selection for .nextDisplay; geometrically it is
    // "center on the given visibleFrame, keeping (clamped) size" — same as .center.

    func testNextDisplayGeometryMatchesCenter() {
        let size = CGSize(width: 640, height: 480)
        assertRect(frame(.nextDisplay, gap: 10, size: size),
                   frame(.center, gap: 10, size: size))
    }

    // MARK: - Non-zero-origin visibleFrame (secondary display / Dock offset)

    func testOffsetOriginVisibleFrame() {
        let offset = CGRect(x: 100, y: 50, width: 1600, height: 1000)
        assertRect(frame(.leftHalf, in: offset),
                   CGRect(x: 100, y: 50, width: 800, height: 1000))
        assertRect(frame(.topRight, in: offset),
                   CGRect(x: 900, y: 550, width: 800, height: 500))
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: **BUILD FAILS** with `cannot find 'TileGeometry' in scope` (and/or `cannot find type 'TileAction' in scope`). A compile failure is this step's "red". If instead you see `** TEST SUCCEEDED **`, something already defines these types — investigate before writing any implementation.

- [x] **Step 3: Create `Sources/Tiling/TileAction.swift` with exactly this content**

```swift
/// Every tiling operation Fuse can perform. String raw values exist solely
/// for readable log lines — never persist or switch on the raw value.
enum TileAction: String, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
    case center
    case nextDisplay
}
```

- [x] **Step 4: Create `Sources/Tiling/TileGeometry.swift` with exactly this content**

```swift
import CoreGraphics

/// Pure geometry: maps a TileAction to a target window frame inside a screen's
/// visible frame. ALL inputs and outputs are in Cocoa (bottom-left-origin)
/// coordinates. The AX top-left flip is ScreenCoords' job, never this file's.
///
/// `gap` is an inset in points applied between the window and the edges of
/// `visibleFrame` AND between adjacent tiled windows. A half tile therefore
/// measures `side/2 − 1.5·gap`: it gives up `gap` at the outer edge plus half
/// of the shared `gap`-wide seam in the middle.
enum TileGeometry {
    static func frame(for action: TileAction,
                      visibleFrame vf: CGRect,
                      currentWindowSize: CGSize,
                      gap: CGFloat) -> CGRect {
        let g = gap
        let halfW = vf.width / 2
        let halfH = vf.height / 2
        let fullW = vf.width - 2 * g       // full span, outer gaps only
        let fullH = vf.height - 2 * g
        let halfGapW = halfW - 1.5 * g     // half span, outer gap + half the seam
        let halfGapH = halfH - 1.5 * g
        let leftX = vf.minX + g
        let rightX = vf.minX + halfW + 0.5 * g
        let bottomY = vf.minY + g
        let topY = vf.minY + halfH + 0.5 * g   // Cocoa: top = larger y

        switch action {
        case .leftHalf:
            return CGRect(x: leftX, y: bottomY, width: halfGapW, height: fullH)
        case .rightHalf:
            return CGRect(x: rightX, y: bottomY, width: halfGapW, height: fullH)
        case .topHalf:
            return CGRect(x: leftX, y: topY, width: fullW, height: halfGapH)
        case .bottomHalf:
            return CGRect(x: leftX, y: bottomY, width: fullW, height: halfGapH)
        case .topLeft:
            return CGRect(x: leftX, y: topY, width: halfGapW, height: halfGapH)
        case .topRight:
            return CGRect(x: rightX, y: topY, width: halfGapW, height: halfGapH)
        case .bottomLeft:
            return CGRect(x: leftX, y: bottomY, width: halfGapW, height: halfGapH)
        case .bottomRight:
            return CGRect(x: rightX, y: bottomY, width: halfGapW, height: halfGapH)
        case .maximize:
            return CGRect(x: leftX, y: bottomY, width: fullW, height: fullH)
        case .center, .nextDisplay:
            // Keep the window's current size, clamped to the gap-inset frame,
            // centered in the visible frame. For .nextDisplay the CALLER
            // (WindowMover) passes the NEXT screen's visibleFrame; the
            // geometry is identical to .center by design.
            let clampedW = min(currentWindowSize.width, fullW)
            let clampedH = min(currentWindowSize.height, fullH)
            return CGRect(x: vf.minX + (vf.width - clampedW) / 2,
                          y: vf.minY + (vf.height - clampedH) / 2,
                          width: clampedW,
                          height: clampedH)
        }
    }
}
```

- [x] **Step 5: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, with all 26 `TileGeometryTests` methods passing alongside every pre-existing test. If any geometry assertion fails, fix `TileGeometry.swift` (the tests encode the contract; do not edit expected values).

- [x] **Step 6: Commit**

```bash
git add Sources/Tiling/TileAction.swift Sources/Tiling/TileGeometry.swift Tests/FuseTests/TileGeometryTests.swift
git commit -m "feat(tiling): TileAction and gap-aware TileGeometry with exhaustive tests"
```

---

### Task 3.2: ScreenCoords — the Cocoa ↔ AX coordinate flip (pure logic, TDD)

THE classic macOS tiling pitfall: `AXUIElement` window positions are in TOP-LEFT-origin global coordinates (y grows downward from the top-left corner of the primary display), while `NSScreen.frame` / `visibleFrame` are in Cocoa BOTTOM-LEFT-origin coordinates (y grows upward). The primary screen — `NSScreen.screens[0]` — has Cocoa origin (0, 0), and its frame HEIGHT is the constant that anchors the flip. Master plan §10 mandates that every conversion goes through this one tested helper; nothing in Fuse may flip coordinates ad hoc.

**Files:**
- Create: `Sources/Tiling/ScreenCoords.swift`
- Test: `Tests/FuseTests/ScreenCoordsTests.swift`

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/ScreenCoordsTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

final class ScreenCoordsTests: XCTestCase {
    /// cocoa → ax → cocoa must be the identity for ANY rect on ANY display.
    private func assertRoundTrip(_ rect: CGRect, primaryHeight: CGFloat,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: primaryHeight)
        let back = ScreenCoords.cocoaRect(axOrigin: ax, size: rect.size,
                                          primaryScreenHeight: primaryHeight)
        XCTAssertEqual(back.origin.x, rect.origin.x, accuracy: 0.0001, "x", file: file, line: line)
        XCTAssertEqual(back.origin.y, rect.origin.y, accuracy: 0.0001, "y", file: file, line: line)
        XCTAssertEqual(back.width, rect.width, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(back.height, rect.height, accuracy: 0.0001, "height", file: file, line: line)
    }

    func testFullscreenPrimaryRectHasAXOriginZero() {
        // A rect covering the whole 1920×1080 primary: Cocoa origin (0,0)
        // bottom-left ⇒ AX origin (0,0) top-left.
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, 0, accuracy: 0.0001)
        XCTAssertEqual(ax.y, 0, accuracy: 0.0001)
    }

    func testKnownConversionOnPrimary() {
        // Cocoa (100, 200, 800, 600) on a 1080-high primary:
        // AX y = 1080 − rect.maxY = 1080 − 800 = 280.
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, 100, accuracy: 0.0001)
        XCTAssertEqual(ax.y, 280, accuracy: 0.0001)
    }

    func testRoundTripOnPrimary() {
        assertRoundTrip(CGRect(x: 100, y: 200, width: 800, height: 600), primaryHeight: 1080)
        assertRoundTrip(CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
        assertRoundTrip(CGRect(x: 37.5, y: 12.25, width: 311, height: 247), primaryHeight: 1080)
    }

    func testRoundTripOnSecondaryDisplayAtNegativeX() {
        // Secondary display left of the primary: Cocoa x is negative.
        assertRoundTrip(CGRect(x: -1920, y: 200, width: 800, height: 600), primaryHeight: 1080)
    }

    func testRoundTripOnSecondaryDisplayAbovePrimary() {
        // Secondary display above the primary: Cocoa y exceeds primary height.
        assertRoundTrip(CGRect(x: -1920, y: 1200, width: 800, height: 600), primaryHeight: 1080)
    }

    func testAXOriginIsNegativeForRectAbovePrimaryTop() {
        // Cocoa maxY = 1200 + 600 = 1800 > 1080 ⇒ AX y = 1080 − 1800 = −720.
        // Windows above the primary's top edge have NEGATIVE AX y. Real.
        let rect = CGRect(x: -1920, y: 1200, width: 800, height: 600)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, -1920, accuracy: 0.0001)
        XCTAssertEqual(ax.y, -720, accuracy: 0.0001)
    }
}
```

- [x] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: **BUILD FAILS** with `cannot find 'ScreenCoords' in scope`. That compile failure is the "red".

- [x] **Step 3: Create `Sources/Tiling/ScreenCoords.swift` with exactly this content**

```swift
import CoreGraphics

/// The ONE place Fuse converts between Cocoa (bottom-left-origin, NSScreen)
/// and AX (top-left-origin, AXUIElement) global coordinates.
///
/// The flip is anchored by the primary screen's frame HEIGHT
/// (`NSScreen.screens[0].frame.height` — the primary always has Cocoa
/// origin (0,0)). Both functions are total and pure; rects on secondary
/// displays (negative x, y above the primary) convert correctly.
enum ScreenCoords {
    /// Cocoa rect → AX origin (the top-left corner of the window in AX space).
    static func axOrigin(ofCocoaRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX, y: primaryScreenHeight - rect.maxY)
    }

    /// AX origin + size → Cocoa rect.
    static func cocoaRect(axOrigin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: axOrigin.x,
               y: primaryScreenHeight - axOrigin.y - size.height,
               width: size.width,
               height: size.height)
    }
}
```

- [x] **Step 4: Run the tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, with all 6 `ScreenCoordsTests` methods passing alongside everything else.

- [x] **Step 5: Commit**

```bash
git add Sources/Tiling/ScreenCoords.swift Tests/FuseTests/ScreenCoordsTests.swift
git commit -m "feat(tiling): ScreenCoords for Cocoa/AX coordinate conversion with round-trip tests"
```

---

### Task 3.3: WindowMover — AX integration (no unit tests; verified by HUMAN-VERIFY in Task 3.4)

`WindowMover` is the only file in this phase that touches the OS: it finds the frontmost window (via Core's `AXElement`), picks the screen the window lives on, asks `TileGeometry` for the target Cocoa rect, flips it through `ScreenCoords`, and applies it. It cannot be unit-tested (requires GUI Accessibility grants and live windows), so this task ends at a green build; behavior is human-verified after the hotkeys are wired in Task 3.4.

Uses ONLY these Core APIs, by their exact Phase 1 signatures: `AXElement.application(pid:)`, `AXElement.focusedWindow`, `AXElement.position`, `AXElement.size`, `AXElement.setPosition(_:)`, `AXElement.setSize(_:)`, `PermissionsService.hasAccessibility`, `PermissionsService.promptForAccessibility()`, `Log.tiling`.

**Files:**
- Create: `Sources/Tiling/WindowMover.swift`

- [x] **Step 1: Create `Sources/Tiling/WindowMover.swift` with exactly this content**

```swift
import AppKit

/// Applies a TileAction to the frontmost window via the Accessibility API.
/// All geometry is computed by TileGeometry (Cocoa coordinates) and converted
/// to AX coordinates by ScreenCoords — this file never does its own math.
enum WindowMover {
    /// The focused window of the frontmost app, or nil if there is none
    /// (e.g. Finder with no windows, or Accessibility not granted).
    static func frontmostWindow() -> AXElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXElement.application(pid: app.processIdentifier).focusedWindow
    }

    /// The screen containing (most of) the window: convert the window's AX
    /// position/size to a Cocoa rect, then pick the NSScreen whose frame has
    /// the largest intersection area. Falls back to the main screen.
    static func screen(containing window: AXElement) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        guard let primary = NSScreen.screens.first,
              let axPosition = window.position,
              let axSize = window.size else { return fallback }
        let cocoa = ScreenCoords.cocoaRect(axOrigin: axPosition,
                                           size: axSize,
                                           primaryScreenHeight: primary.frame.height)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let overlap = candidate.frame.intersection(cocoa)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = candidate
            }
        }
        return best ?? fallback
    }

    /// Compute and apply the target frame for `action` on the frontmost window.
    static func apply(_ action: TileAction) {
        guard PermissionsService.hasAccessibility else {
            Log.tiling.warning("tile \(action.rawValue, privacy: .public): Accessibility not granted; prompting")
            PermissionsService.promptForAccessibility()
            return
        }
        guard let window = frontmostWindow() else {
            Log.tiling.warning("tile \(action.rawValue, privacy: .public): no focused window")
            return
        }
        guard let primary = NSScreen.screens.first else {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): no screens attached")
            return
        }
        let primaryHeight = primary.frame.height
        let currentSize = window.size ?? .zero
        let gap = CGFloat(UserDefaults.standard.double(forKey: "tiling.gap"))

        // For .nextDisplay: pick the NEXT screen in NSScreen.screens cyclically,
        // then center the window (size kept, clamped) on that screen. Geometrically
        // identical to .center on the next screen's visibleFrame.
        let targetScreen: NSScreen
        let geometryAction: TileAction
        if action == .nextDisplay {
            let screens = NSScreen.screens
            let current = screen(containing: window)
            let index = screens.firstIndex(of: current) ?? 0
            targetScreen = screens[(index + 1) % screens.count]
            geometryAction = .center
        } else {
            targetScreen = screen(containing: window)
            geometryAction = action
        }

        let cocoaFrame = TileGeometry.frame(for: geometryAction,
                                            visibleFrame: targetScreen.visibleFrame,
                                            currentWindowSize: currentSize,
                                            gap: gap)
        let axOrigin = ScreenCoords.axOrigin(ofCocoaRect: cocoaFrame,
                                             primaryScreenHeight: primaryHeight)

        // Clamp-resistant apply order: setPosition → setSize → setPosition.
        // Apps like Terminal snap their size to character-cell multiples; if the
        // size is set first the window can drift away from the target origin.
        // Re-asserting the position after the resize pins the corner.
        if !window.setPosition(axOrigin) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): first setPosition failed")
        }
        if !window.setSize(cocoaFrame.size) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): setSize failed")
        }
        if !window.setPosition(axOrigin) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): second setPosition failed")
        }
    }
}
```

- [x] **Step 2: Regenerate, build, and run the existing tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` (no new tests; this confirms nothing regressed).

- [x] **Step 3: Commit**

```bash
git add Sources/Tiling/WindowMover.swift
git commit -m "feat(tiling): WindowMover applies tile frames via AX with clamp-resistant ordering"
```

---

### Task 3.4: TilingController + AppDelegate wiring (hotkeys live)

`TilingController` registers all 11 hotkey handlers using `KeyboardShortcuts.onKeyDown(for:)` with the EXISTING `KeyboardShortcuts.Name` constants from `Sources/Core/HotkeyNames.swift` (`.tileLeftHalf`, `.tileRightHalf`, `.tileTopHalf`, `.tileBottomHalf`, `.tileTopLeft`, `.tileTopRight`, `.tileBottomLeft`, `.tileBottomRight`, `.tileMaximize`, `.tileCenter`, `.tileNextDisplay`). It NEVER defines new Name constants. Each handler re-reads `"tiling.enabled"` from UserDefaults (a cheap bool lookup) so toggling the setting takes effect instantly without re-registering anything.

**Files:**
- Create: `Sources/Tiling/TilingController.swift`
- Modify: `Sources/App/AppDelegate.swift` (two anchor insertions, shown exactly below)

- [x] **Step 1: Create `Sources/Tiling/TilingController.swift` with exactly this content**

```swift
import AppKit
import KeyboardShortcuts

/// Registers the 11 global tiling hotkeys and routes them to WindowMover.
/// Hotkey Name constants come EXCLUSIVELY from Core/HotkeyNames.swift.
final class TilingController {
    private static let shortcutMap: [(KeyboardShortcuts.Name, TileAction)] = [
        (.tileLeftHalf, .leftHalf),
        (.tileRightHalf, .rightHalf),
        (.tileTopHalf, .topHalf),
        (.tileBottomHalf, .bottomHalf),
        (.tileTopLeft, .topLeft),
        (.tileTopRight, .topRight),
        (.tileBottomLeft, .bottomLeft),
        (.tileBottomRight, .bottomRight),
        (.tileMaximize, .maximize),
        (.tileCenter, .center),
        (.tileNextDisplay, .nextDisplay),
    ]

    func start() {
        UserDefaults.standard.register(defaults: [
            "tiling.enabled": true,
            "tiling.gap": 0.0,
        ])
        for (name, action) in Self.shortcutMap {
            KeyboardShortcuts.onKeyDown(for: name) {
                // Re-checked on every keypress: toggling the setting takes
                // effect immediately, no re-registration needed.
                guard UserDefaults.standard.bool(forKey: "tiling.enabled") else { return }
                WindowMover.apply(action)
            }
        }
        Log.tiling.info("tiling started: \(Self.shortcutMap.count) shortcuts registered")
    }
}
```

- [x] **Step 2: Wire the controller into `Sources/App/AppDelegate.swift` via the two anchors**

Edit 1 — find the line containing exactly `// FUSE:CONTROLLER-PROPS` and insert the property declaration immediately ABOVE it, so the file reads (other phases' properties may also be present above yours — leave them untouched):

```swift
    private var tilingController: TilingController!
    // FUSE:CONTROLLER-PROPS
```

Edit 2 — find the line containing exactly `// FUSE:CONTROLLER-START` (inside `applicationDidFinishLaunching`, after the XCTest guard that Phase 0 installed — do NOT move or remove that guard) and insert the construction + start immediately ABOVE it:

```swift
        tilingController = TilingController()
        tilingController.start()
        // FUSE:CONTROLLER-START
```

Do not reference line numbers; locate both anchors by their exact comment text. Make no other changes to AppDelegate.swift.

- [x] **Step 3: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. (The XCTest guard in AppDelegate prevents hotkey registration during test runs — windows must NOT move while tests execute.)

- [ ] **Step 4: HUMAN-VERIFY — tiling works end to end on the built-in display**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to perform ALL of the following and report each result:

1. Confirm Accessibility is granted (Fuse Settings → General → Accessibility row is green). If a previously green grant stopped working after a rebuild, this is the ad-hoc-signing TCC cache issue from master plan §10: remove Fuse from System Settings → Privacy & Security → Accessibility and re-add `.build/Build/Products/Debug/Fuse.app`.
2. If macOS's native window tiling claims the same keys (macOS 15+ / 26 binds ⌃⌥-arrow-style shortcuts in System Settings → Desktop & Dock → Windows), pressing the hotkey may trigger the SYSTEM's tiling instead of Fuse's. Disable the conflicting native shortcuts there (or plan to re-record Fuse's shortcuts in Task 3.5) before judging results.
3. Open **Safari** with one window. Press ⌃⌥← → window fills the LEFT half of the screen's visible area (not under the menu bar or Dock). Press ⌃⌥→ → right half. ⌃⌥↑ → top half. ⌃⌥↓ → bottom half.
4. Press ⌃⌥1 / ⌃⌥2 / ⌃⌥3 / ⌃⌥4 → top-left / top-right / bottom-left / bottom-right quarters respectively.
5. Press ⌃⌥↩ → window fills the entire visible frame. Press ⌃⌥C → window keeps its size and centers on screen.
6. Repeat step 3 in **Terminal**. Terminal snaps sizes to character cells — the window must still land flush at the target origin (the position→size→position ordering handles this); a few points of width/height slack is acceptable, drift of the top-left corner is not.
7. With two displays connected: focus a window and press ⌃⌥N → window centers on the other display; press again → it returns to the first (cyclic). With only one display: press ⌃⌥N → the window centers on the current screen and nothing crashes; note "single-display: nextDisplay skipped" in the result.
8. Watch logs during the above: `log stream --predicate 'subsystem == "com.rgv250cc.Fuse"' --level debug` should show the "tiling started: 11 shortcuts registered" line and no error lines during successful moves.

Record the human's answers before proceeding. If any step fails, STOP and debug before committing.

- [x] **Step 5: Commit**

```bash
git add Sources/Tiling/TilingController.swift Sources/App/AppDelegate.swift
git commit -m "feat(tiling): register 11 tiling hotkeys via TilingController"
```

---

### Task 3.5: TilingSettingsView + settings tab wiring

A SwiftUI settings tab: enable toggle (`"tiling.enabled"`), gap slider 0–24 pt (`"tiling.gap"`), one `KeyboardShortcuts.Recorder` row per action (recorders bind to the SAME Name constants the controller listens on, so re-recording takes effect immediately — KeyboardShortcuts persists shortcuts internally per Name), and a red callout when Accessibility is missing.

**Files:**
- Create: `Sources/Tiling/TilingSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (one anchor insertion, shown exactly below)

- [x] **Step 1: Create `Sources/Tiling/TilingSettingsView.swift` with exactly this content**

```swift
import KeyboardShortcuts
import SwiftUI

struct TilingSettingsView: View {
    @AppStorage("tiling.enabled") private var tilingEnabled = true
    @AppStorage("tiling.gap") private var gap = 0.0
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.red)
                            Text("Fuse cannot move other apps' windows without it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForAccessibility()
                            PermissionsService.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }
            Section {
                Toggle("Enable window tiling", isOn: $tilingEnabled)
                HStack {
                    Slider(value: $gap, in: 0...24, step: 1) {
                        Text("Window gap")
                    }
                    Text("\(Int(gap)) pt")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Gap is applied at screen edges and between adjacent tiled windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Halves") {
                KeyboardShortcuts.Recorder("Left half", name: .tileLeftHalf)
                KeyboardShortcuts.Recorder("Right half", name: .tileRightHalf)
                KeyboardShortcuts.Recorder("Top half", name: .tileTopHalf)
                KeyboardShortcuts.Recorder("Bottom half", name: .tileBottomHalf)
            }
            Section("Quarters") {
                KeyboardShortcuts.Recorder("Top left", name: .tileTopLeft)
                KeyboardShortcuts.Recorder("Top right", name: .tileTopRight)
                KeyboardShortcuts.Recorder("Bottom left", name: .tileBottomLeft)
                KeyboardShortcuts.Recorder("Bottom right", name: .tileBottomRight)
            }
            Section("Other") {
                KeyboardShortcuts.Recorder("Maximize", name: .tileMaximize)
                KeyboardShortcuts.Recorder("Center", name: .tileCenter)
                KeyboardShortcuts.Recorder("Next display", name: .tileNextDisplay)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
        }
    }
}
```

- [x] **Step 2: Wire the tab into `Sources/App/SettingsRootView.swift` via the anchor**

Find the line containing exactly `// FUSE:SETTINGS_TABS` and insert the tab entry immediately ABOVE it, so the file reads (other phases' tabs may also be present above yours — leave them untouched):

```swift
            TilingSettingsView()
                .tabItem { Label("Tiling", systemImage: "rectangle.split.2x1") }
            // FUSE:SETTINGS_TABS
```

Locate the anchor by its exact comment text, never by line number. Make no other changes to SettingsRootView.swift.

- [x] **Step 3: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — settings tab drives behavior live**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to perform ALL of the following and report each result:

1. Open Fuse Settings → a "Tiling" tab exists with the rectangle icon, showing the toggle, the gap slider, and 11 shortcut recorder rows grouped as Halves / Quarters / Other.
2. Set the gap slider to **10 pt**. In Safari press ⌃⌥← then ⌃⌥2 (top right): both windows sit visibly inset ~10 pt from the screen edges, and when both halves are tiled side by side (Safari left, Terminal right) the seam between them is ~10 pt. Set the gap back to 0 → tiles are flush again. No app restart needed.
3. Turn "Enable window tiling" OFF → pressing ⌃⌥← does nothing. Turn it back ON → tiling works again immediately.
4. Click the "Left half" recorder, record a different shortcut (e.g. ⌃⌥⇧L), and press the NEW shortcut → window tiles left immediately, no restart. Press the recorder's clear button (×) and re-record the original ⌃⌥← afterwards.
5. Revoke Accessibility for Fuse (System Settings → Privacy & Security → Accessibility → toggle Fuse off). Within ~2 seconds the Tiling tab shows the red "Accessibility permission required" callout. Press ⌃⌥← → the system Accessibility prompt appears (or nothing happens beyond a log line); Fuse must NOT crash. Re-grant Accessibility; the callout disappears and tiling works again. If tiling stays broken after re-granting, apply the §10 TCC fix (remove + re-add the app in the Accessibility list).

Record the human's answers before proceeding. If any step fails, STOP and debug before committing.

- [x] **Step 5: Commit**

```bash
git add Sources/Tiling/TilingSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(tiling): settings tab with enable toggle, gap slider, and shortcut recorders"
```

---

## Manual verification checklist (end of phase)

- [ ] **HUMAN-VERIFY** All four halves (⌃⌥← → ↑ ↓) and all four quarters (⌃⌥1–4) tile Safari correctly on the built-in display; windows respect the menu bar and Dock (visibleFrame, not full frame).
- [ ] **HUMAN-VERIFY** Maximize (⌃⌥↩) and Center (⌃⌥C) work; Center keeps the window's size and clamps oversized windows to the screen.
- [ ] **HUMAN-VERIFY** Terminal tiles flush at the target corner despite character-cell size snapping (left half then right half: no top-left drift).
- [ ] **HUMAN-VERIFY** ⌃⌥N round-trips a window across two displays (cyclic), or — single-display machine — centers in place without crashing (note the skip).
- [ ] **HUMAN-VERIFY** Gap = 10 pt visibly insets tiles from screen edges and leaves a ~10 pt seam between adjacent tiles; gap = 0 restores flush tiling; changes apply without restart.
- [ ] **HUMAN-VERIFY** Re-recording a shortcut in the Tiling tab takes effect immediately; the "Enable window tiling" toggle gates all 11 hotkeys instantly.
- [ ] **HUMAN-VERIFY** With Accessibility revoked, a tiling hotkey produces the system permission prompt (never a crash), and the Tiling tab shows the red callout within ~2 s.
- [x] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (includes 26 TileGeometryTests + 6 ScreenCoordsTests).
- [x] `git log --oneline | head -6` shows the five Phase 3 commits on top (TileGeometry, ScreenCoords, WindowMover, TilingController, settings tab).

## Risks & gotchas

- **macOS 26 native tiling shortcut conflicts.** macOS's built-in window tiling (System Settings → Desktop & Dock → Windows) claims ⌃⌥-arrow-style shortcuts on modern macOS. If a Fuse hotkey appears dead or triggers the system's tiling animation instead, instruct the human to disable the conflicting native keyboard shortcuts there, or re-record Fuse's shortcuts to non-conflicting combos in the Tiling tab. Do not burn time debugging Fuse before ruling this out.
- **TCC caches grants by code signature (master §10).** With ad-hoc signing, a rebuilt Fuse binary can silently lose Accessibility while System Settings still shows it granted — `AXIsProcessTrusted()` returns false and every `setPosition`/`setSize` fails. Fix: remove Fuse from the Accessibility list and re-add `.build/Build/Products/Debug/Fuse.app`. Suspect this FIRST whenever AX calls mysteriously fail.
- **AX is top-left origin; NSScreen is bottom-left (master §10).** Every conversion must go through `ScreenCoords` — never flip ad hoc in WindowMover, the settings view, or future phases. Windows on a display above the primary legitimately have negative AX y; treat negative coordinates as valid, not as errors.
- **Apps clamp window sizes.** Terminal (character cells), some Electron apps (min sizes), and apps with fixed aspect ratios will not accept the exact requested size. The position→size→position ordering keeps the origin pinned; the final size may differ by a few points. This is expected — never loop retrying `setSize`.
- **`visibleFrame` vs `frame`.** Tiling must use `NSScreen.visibleFrame` (excludes menu bar and Dock). The ONLY use of `frame` is the primary screen's `frame.height` as the flip anchor in coordinate conversion, plus screen-containment intersection tests. Mixing them up shoves windows under the Dock.
- **Single-display `.nextDisplay`.** With one screen, `(index + 1) % 1 == 0` re-centers on the same display — harmless by design, but the two-display HUMAN-VERIFY genuinely requires two displays; record a skip note otherwise.
- **`KeyboardShortcuts.Recorder` label API drift.** The plan uses the 2.x SwiftUI initializer `KeyboardShortcuts.Recorder("Left half", name: .tileLeftHalf)`. If the pinned package version renames the initializer, check `.build/SourcePackages/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift` and adjust the call sites minimally, recording the change under `## Deviations` per master §9.
- **Hosted tests must never move windows.** The XCTest guard at the top of `applicationDidFinishLaunching` (Phase 0) prevents `TilingController.start()` from running during `xcodebuild test`. Never insert controller-start code outside that guard.

## Deviations

- **Task 3.0 Step 1 path:** the plan's `ls` command points at the main checkout (`/Users/rgv250cc/Documents/Projects/Fuse/Sources/Core`); per worktree-isolation rules the verification was performed against the same path in this worktree (`Fuse-worktrees/phase3-tiling/Sources/Core`). All five required files (plus PauseManager.swift, ConflictDetector.swift) present.
- **TileGeometryTests count:** Task 3.1 Step 5 expects "all 26 TileGeometryTests methods", but the plan's verbatim test file defines 25 test methods. The file was created exactly as written and all 25 pass; the prose count is off by one. No code change.
- **HUMAN-VERIFY steps skipped:** executed in a headless agent session with no human at the GUI — Task 3.4 Step 4, Task 3.5 Step 4, and the seven end-of-phase HUMAN-VERIFY checklist items remain unticked and must be verified by a human before release.
- No API drift encountered: `KeyboardShortcuts.onKeyDown(for:)` and `KeyboardShortcuts.Recorder(_:name:)` compiled as written against the pinned 2.x package; all Core APIs matched their Phase 1 signatures exactly.
