# Phase 10: Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–9 complete (the app is built and shipping; this phase adds a new feature on top).

**Goal:** Add "Capture" — a CleanShot-X-style screenshot and screen-recording tool. ⌃⌥S triggers the system's interactive crosshair capture (region or window); ⌃⌥R starts/stops a region screen recording with a floating REC HUD. Every capture is saved to a configurable folder with a timestamped name, automatically copied to the clipboard with `markInternal: false` so Fuse's own clipboard history records it (free synergy with Phase 4), and optionally opened in a built-in annotation editor (images: arrow/rect/ellipse/freehand/highlighter/text/crop) or a minimal trimmer (videos: two sliders + passthrough export).

**Architecture:** Capture drives `/usr/sbin/screencapture` via `Process` instead of reimplementing capture — the system engine gives us the crosshair UI, window snapping, ESC-to-cancel, and the `.mov` encoder for free, and the child process inherits Fuse's TCC identity so Screen Recording permission is attributed to Fuse. Pure logic is isolated and TDD'd: `CaptureNames` (timestamped filenames, Date injected), `CaptureGeometry` (drag-rect normalization + Cocoa→top-left coordinate flip for `screencapture -R`), `RecordingStateMachine` (idle → selectingRegion → recording → finishing transitions as a pure function), `AnnotationGeometry`/`AnnotationPaths` (arrow-head math, shared CGPath builder), and `TrimMath` (fraction sliders → `CMTimeRange?`). OS-integration shells around them — `ScreenshotService`, `RecordingService` + `RegionPicker` overlay + `RecHUD`, `CaptureController` (shared output pipeline + hotkeys + menu), editor/trimmer windows — are build-verified and human-verified. Integration with shared files happens ONLY at the §6.1 anchors in `AppDelegate.swift` and the `SettingsTab` enum in `SettingsRootView.swift` (the TabView anchor is retired; new tabs are enum cases now).

**Tech Stack:** `Process` + `/usr/sbin/screencapture` (capture engine), CoreGraphics (`CGPreflightScreenCaptureAccess`, `CGImage.cropping`), AppKit (borderless overlay window, REC HUD panel, editor windows, `NSSavePanel`/`NSOpenPanel`), SwiftUI (`Canvas`, `DragGesture`, settings form), AVKit/AVFoundation (`VideoPlayer`, `AVAssetExportSession` passthrough), KeyboardShortcuts (`.captureRegion`, `.toggleRecording`), XCTest. Core APIs consumed: `PasteService.write(_:markInternal:)`, `PermissionsService` (extended here with Screen Recording), `Log` (new `capture` category), `PauseManager` (no work needed — capture is hotkey-only, and `KeyboardShortcuts.isEnabled` already covers it; the status-menu items intentionally stay live while paused, matching the master plan §12 "explicit clicks are user intent" rule).

**One shared draw routine — honest scope note:** the live SwiftUI `Canvas` and the AppKit flattener cannot share a single stroke call (GraphicsContext vs NSGraphicsContext). They DO share all geometry: `AnnotationPaths.path(for:)` builds one `CGPath` per annotation, consumed by `Path(cgPath:)` in Canvas and `NSBezierPath(cgPath:)` in the flattener. Only two thin strokers (color/width/alpha application) and the text drawing exist twice. Keep it that way — do not try to unify the strokers.

**Naming note:** the Voice feature already owns `RecordingHUD` / `RecordingHUDModel` / `RecordingHUDView` (Sources/Voice/RecordingHUD.swift). The capture HUD is therefore named `RecHUD` / `RecHUDModel` / `RecHUDView`. Do not rename either side.

---

### Task 10.0: Preflight — verify the built app is green and the integration points exist

**Files:**
- None created or modified. Verification only.

- [x] **Step 1: Verify Core files and the Capture integration points exist**

```bash
ls /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core
grep -n "FUSE:CONTROLLER-PROPS\|FUSE:MENU-ITEMS\|FUSE:CONTROLLER-START" /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/AppDelegate.swift
grep -n "case general, scroll" /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/SettingsRootView.swift
grep -n "markInternal" /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core/PasteService.swift
```
Expected: `ls` lists (at least) `AX.swift HotkeyNames.swift Log.swift PasteService.swift PauseManager.swift Permissions.swift`; the AppDelegate grep prints three anchor lines; the SettingsRootView grep prints the `SettingsTab` case list line; the PasteService grep shows `markInternal: Bool = true` in the `write` signature. If anything is missing, STOP — the codebase is not in the expected Phase 0–9 state.

- [x] **Step 2: Verify the system capture engine supports what we need**

```bash
ls -l /usr/sbin/screencapture
screencapture -h 2>&1 | grep -E '^\s+-(i|o|v|R|V)' 
```
Expected: the binary exists, and the usage output documents `-i` (interactive), `-o` (no window shadow), `-v` (video recording), and `-R<x,y,w,h>` (capture screen rect). On the development machine (macOS 26.x) all four are present. If `-R` is missing or later proves not to combine with `-v` (Task 10.4 HUMAN-VERIFY), the fallback is full-screen recording (`screencapture -v <file>` without `-R`) — record that under `## Deviations` at the bottom of this file.

- [x] **Step 3: Verify the build is green**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [x] **Step 4: Verify the tests are green**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (150 tests as of Phase 9). If red, STOP and fix first — never build a feature on a red base.

---

### Task 10.1: Core integrations — hotkeys (TDD), Log category, Screen Recording permission

**Files:**
- Modify: `Sources/Core/HotkeyNames.swift`
- Modify: `Tests/FuseTests/HotkeyNamesTests.swift`
- Modify: `Sources/Core/Log.swift`
- Modify: `Sources/Core/Permissions.swift`
- Modify: `Sources/App/GeneralSettingsView.swift`

- [x] **Step 1: Write the failing test — extend the hotkey registry test**

In `Tests/FuseTests/HotkeyNamesTests.swift`, find this exact line inside the `all` array:

```swift
            .toggleNotesPanel,
```

Replace it with:

```swift
            .toggleNotesPanel,
            .captureRegion, .toggleRecording,
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `type 'KeyboardShortcuts.Name' has no member 'captureRegion'` (a compile failure is this step's "red").

- [x] **Step 3: Implement — add the two names to `Sources/Core/HotkeyNames.swift`**

Append the following inside the `extension KeyboardShortcuts.Name { ... }` block, directly after the `tileNextDisplay` line (before the closing brace):

```swift

    // Capture (Phase 10)
    static let captureRegion = Self("captureRegion", default: .init(.s, modifiers: [.control, .option]))
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.control, .option]))
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 5: Add the log category to `Sources/Core/Log.swift`**

Find this exact line:

```swift
    static let clipboard = Logger(subsystem: "com.rgv250cc.Fuse", category: "clipboard")
```

Replace it with:

```swift
    static let clipboard = Logger(subsystem: "com.rgv250cc.Fuse", category: "clipboard")
    static let capture = Logger(subsystem: "com.rgv250cc.Fuse", category: "capture")
```

- [x] **Step 6: Extend `Sources/Core/Permissions.swift` with Screen Recording**

Edit A — in `enum SettingsPane`, find:

```swift
    case microphone
```

Replace with:

```swift
    case microphone
    case screenRecording
```

Edit B — in the `urlString` switch, find:

```swift
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
```

Replace with:

```swift
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Edit C — in `enum PermissionsService`, find:

```swift
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
```

Replace with:

```swift
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Screen Recording (TCC kTCCServiceScreenCapture). Non-prompting check;
    /// promptForScreenRecording() triggers the one-shot system dialog.
    /// Both come from CoreGraphics (umbrella'd by ApplicationServices).
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func promptForScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
```

- [x] **Step 7: Add the Screen Recording row to `Sources/App/GeneralSettingsView.swift`**

Edit A — find:

```swift
    @State private var micStatus = PermissionsService.microphoneStatus
```

Replace with:

```swift
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var hasScreenRecording = PermissionsService.hasScreenRecording
```

Edit B — find the Microphone `permissionRow` call:

```swift
                permissionRow(
                    title: "Microphone",
                    detail: "Push-to-talk dictation",
                    granted: micStatus == .authorized,
                    pane: .microphone,
                    prompt: { PermissionsService.requestMicrophone { _ in } })
```

Replace with:

```swift
                permissionRow(
                    title: "Microphone",
                    detail: "Push-to-talk dictation",
                    granted: micStatus == .authorized,
                    pane: .microphone,
                    prompt: { PermissionsService.requestMicrophone { _ in } })
                permissionRow(
                    title: "Screen Recording",
                    detail: "Screenshots and screen recordings (Capture)",
                    granted: hasScreenRecording,
                    pane: .screenRecording,
                    prompt: PermissionsService.promptForScreenRecording)
```

Edit C — in the `.onReceive(refresh)` closure, find:

```swift
            micStatus = PermissionsService.microphoneStatus
```

Replace with:

```swift
            micStatus = PermissionsService.microphoneStatus
            hasScreenRecording = PermissionsService.hasScreenRecording
```

- [x] **Step 8: Build and run the full test suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [x] **Step 9: Commit**

```bash
git add Sources/Core/HotkeyNames.swift Tests/FuseTests/HotkeyNamesTests.swift Sources/Core/Log.swift Sources/Core/Permissions.swift Sources/App/GeneralSettingsView.swift
git commit -m "feat(capture): capture hotkeys, log category, screen-recording permission plumbing"
```

---

### Task 10.2: CaptureNames + CaptureGeometry — pure helpers (TDD)

**Files:**
- Create: `Sources/Capture/CaptureNames.swift`
- Create: `Sources/Capture/CaptureGeometry.swift`
- Test: `Tests/FuseTests/CaptureNamesTests.swift`
- Test: `Tests/FuseTests/RegionGeometryTests.swift` (created here; Task 10.4 appends the state-machine test class)

`CaptureNames.fileName(kind:date:timeZone:)` is the single source of capture filenames — Date and TimeZone are injected so the function is pure and deterministic under test (never call `Date()` or read `.current` inside; the default parameter values are the only place `.current` appears). `CaptureGeometry` holds the two rect helpers used by both the region picker and the editor: drag-in-any-direction normalization, and the Cocoa→top-left flip that `screencapture -R` requires (same convention as the tested `ScreenCoords` helper in Tiling: anchor on the primary screen's frame height).

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/CaptureNamesTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

final class CaptureNamesTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int,
                      _ h: Int, _ mi: Int, _ s: Int, tz: TimeZone) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: components)!
    }

    func testScreenshotName() {
        let tz = TimeZone(identifier: "Europe/Riga")!
        let d = date(2026, 6, 11, 17, 23, 45, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .screenshot, date: d, timeZone: tz),
                       "Fuse Shot 2026-06-11 at 17.23.45.png")
    }

    func testRecordingName() {
        let tz = TimeZone(identifier: "UTC")!
        let d = date(2026, 1, 2, 3, 4, 5, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .recording, date: d, timeZone: tz),
                       "Fuse Recording 2026-01-02 at 03.04.05.mov")
    }

    func testMidnightZeroPadding() {
        let tz = TimeZone(identifier: "UTC")!
        let d = date(2026, 12, 31, 0, 0, 0, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .screenshot, date: d, timeZone: tz),
                       "Fuse Shot 2026-12-31 at 00.00.00.png")
    }
}
```

- [x] **Step 2: Create `Tests/FuseTests/RegionGeometryTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

// Tests for the capture feature's pure geometry (this task) and the
// recording state machine (Task 10.4 appends its test class below).

final class RegionGeometryTests: XCTestCase {
    func testNormalizedRectDragDownRight() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 80))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragUpLeft() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 110, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragDownLeft() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 110, y: 20), to: CGPoint(x: 10, y: 80))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragUpRight() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 110, y: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectClick() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(r, CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    /// screencapture -R wants GLOBAL top-left-origin points; the overlay
    /// delivers Cocoa (bottom-left) coordinates. A Cocoa rect whose bottom
    /// edge is at y=200 on a 1000-pt-tall primary screen has its TOP edge
    /// 700 pt below the top of the screen.
    func testTopLeftRectFlip() {
        let cocoa = CGRect(x: 50, y: 200, width: 300, height: 100)
        let flipped = CaptureGeometry.topLeftRect(fromCocoaRect: cocoa, primaryScreenHeight: 1000)
        XCTAssertEqual(flipped, CGRect(x: 50, y: 700, width: 300, height: 100))
    }

    func testTopLeftRectFullScreenIsIdentityOrigin() {
        let cocoa = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let flipped = CaptureGeometry.topLeftRect(fromCocoaRect: cocoa, primaryScreenHeight: 1117)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 0, width: 1728, height: 1117))
    }
}
```

- [x] **Step 3: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'CaptureNames' in scope` and/or `cannot find 'CaptureGeometry' in scope`.

- [x] **Step 4: Implement — create `Sources/Capture/CaptureNames.swift` with exactly this content**

```swift
import Foundation

/// What kind of capture a file is. Drives both the filename and the
/// post-capture behavior (editor vs trimmer, png-vs-file-url clipboard).
enum CaptureKind {
    case screenshot
    case recording
}

/// Timestamped capture filenames — the ONE place these strings are built.
/// Pure: Date and TimeZone are injected; never call Date() in here.
enum CaptureNames {
    static func fileName(kind: CaptureKind, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: date)
        switch kind {
        case .screenshot: return "Fuse Shot \(stamp).png"
        case .recording: return "Fuse Recording \(stamp).mov"
        }
    }
}
```

- [x] **Step 5: Implement — create `Sources/Capture/CaptureGeometry.swift` with exactly this content**

```swift
import CoreGraphics

/// Pure rect helpers shared by the region picker and the image editor.
enum CaptureGeometry {
    /// Rect spanned by a drag in ANY direction (standard CGRect has negative
    /// width/height semantics we never want downstream).
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(b.x - a.x),
               height: abs(b.y - a.y))
    }

    /// Cocoa (bottom-left-origin) global rect → top-left-origin global rect,
    /// as `screencapture -R<x,y,w,h>` expects. Same flip convention as
    /// Tiling's ScreenCoords: anchored on the PRIMARY screen's frame height
    /// (NSScreen.screens[0] always has Cocoa origin (0,0)).
    static func topLeftRect(fromCocoaRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}
```

- [x] **Step 6: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, with all 3 `CaptureNamesTests` and 7 `RegionGeometryTests` listed as passed.

- [x] **Step 7: Commit**

```bash
git add Sources/Capture/CaptureNames.swift Sources/Capture/CaptureGeometry.swift Tests/FuseTests/CaptureNamesTests.swift Tests/FuseTests/RegionGeometryTests.swift
git commit -m "feat(capture): pure filename formatter and region geometry helpers"
```

---

### Task 10.3: RegionPicker — full-screen selection overlay (OS integration)

**Files:**
- Create: `Sources/Capture/RegionPicker.swift`

A borderless transparent window at `.screenSaver` level covering the screen that contains the mouse. Crosshair cursor; click-drag draws a selection rectangle punched out of a dimmed backdrop; releasing the drag confirms; Return with no drag means "record the entire screen"; ESC cancels. Cannot be unit-tested (needs a GUI session and key/mouse events) — compile-verify here, human-verify in Task 10.8. Results are delivered in **Cocoa global screen coordinates**; the consumer (RecordingService, Task 10.4) flips them for `screencapture -R`.

- [x] **Step 1: Create `Sources/Capture/RegionPicker.swift` with exactly this content**

```swift
import AppKit

/// Result of a region-selection session, in Cocoa (bottom-left-origin)
/// GLOBAL screen coordinates. RecordingService converts to top-left for
/// screencapture via CaptureGeometry.topLeftRect.
enum RegionPickResult: Equatable {
    case region(CGRect)
    case fullScreen
    case cancelled
}

/// Borderless windows refuse key status by default; we need ESC/Return.
private final class RegionPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionPickerView: NSView {
    var onResult: ((RegionPickResult) -> Void)?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        let rect = CaptureGeometry.normalizedRect(from: a, to: b)
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let rect = selectionRect {
            // Punch a clear hole for the selection (window is non-opaque).
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.stroke()
        } else {
            let hint = "Drag to select a region   ·   Return records the entire screen   ·   Esc cancels"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width >= 8, rect.height >= 8,
              let window else {
            // Too small to be a deliberate selection — keep picking.
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }
        // View coords + window origin = Cocoa global screen coords
        // (the window's frame equals the screen's frame).
        let screenRect = CGRect(x: rect.minX + window.frame.minX,
                                y: rect.minY + window.frame.minY,
                                width: rect.width,
                                height: rect.height)
        onResult?(.region(screenRect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        // Esc
            onResult?(.cancelled)
        case 36, 76:    // Return / keypad Enter — entire screen
            onResult?(.fullScreen)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Presents the selection overlay on the screen containing the mouse.
/// Lifetime: owned by RecordingService; the window is retained until a
/// result is delivered, then torn down.
final class RegionPicker {
    private var window: RegionPickerWindow?

    var isPresenting: Bool { window != nil }

    func present(completion: @escaping (RegionPickResult) -> Void) {
        guard window == nil else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let window = RegionPickerWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        let view = RegionPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onResult = { [weak self] result in
            self?.dismiss()
            completion(result)
        }
        window.contentView = view
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
```

- [x] **Step 2: Regenerate, build, and run the regression suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **` (no new tests; the overlay needs a GUI and is verified in Task 10.8).

- [x] **Step 3: Commit**

```bash
git add Sources/Capture/RegionPicker.swift
git commit -m "feat(capture): full-screen region picker overlay"
```

---

### Task 10.4: RecordingStateMachine (TDD) + RecordingService + RecHUD

**Files:**
- Create: `Sources/Capture/RecordingService.swift` (state machine + service)
- Create: `Sources/Capture/RecHUD.swift`
- Modify (append): `Tests/FuseTests/RegionGeometryTests.swift`

The state machine is a pure transition function — `(Phase, Event) → (Phase, Action)` — fully TDD'd. Deliberate deviation from the original sketch ("recording(Process)"): the `Process` lives in `RecordingService`, NOT inside the phase enum, so the enum stays `Equatable` and trivially testable. `RecordingService` is the impure shell: it presents the `RegionPicker`, spawns `screencapture -v [-R x,y,w,h] <tmp>.mov`, stops it with `interrupt()` (SIGINT — screencapture finalizes the .mov on SIGINT), and hands the finished file to its `onFinished` callback (wired to `CaptureController` in Task 10.5). The HUD is named `RecHUD` because Voice already owns `RecordingHUD`.

- [x] **Step 1: Append the failing test class to `Tests/FuseTests/RegionGeometryTests.swift`** — add at the END of the file (after the closing brace of `RegionGeometryTests`), changing nothing above it:

```swift

final class RecordingStateMachineTests: XCTestCase {
    typealias SM = RecordingStateMachine

    private func assertTransition(_ phase: SM.Phase, _ event: SM.Event,
                                  becomes expectedPhase: SM.Phase,
                                  doing expectedAction: SM.Action,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let (next, action) = SM.transition(from: phase, on: event)
        XCTAssertEqual(next, expectedPhase, file: file, line: line)
        XCTAssertEqual(action, expectedAction, file: file, line: line)
    }

    func testToggleFromIdlePresentsPicker() {
        assertTransition(.idle, .toggle, becomes: .selectingRegion, doing: .presentRegionPicker)
    }

    func testRegionConfirmedStartsProcess() {
        assertTransition(.selectingRegion, .regionConfirmed, becomes: .recording, doing: .startProcess)
    }

    func testRegionCancelledReturnsToIdle() {
        assertTransition(.selectingRegion, .regionCancelled, becomes: .idle, doing: .none)
    }

    func testToggleWhileSelectingDismissesPicker() {
        assertTransition(.selectingRegion, .toggle, becomes: .idle, doing: .dismissRegionPicker)
    }

    func testToggleWhileRecordingStopsProcess() {
        assertTransition(.recording, .toggle, becomes: .finishing, doing: .stopProcess)
    }

    func testStopRequestWhileRecordingStopsProcess() {
        assertTransition(.recording, .stopRequested, becomes: .finishing, doing: .stopProcess)
    }

    func testProcessExitWhileFinishingFinalizes() {
        assertTransition(.finishing, .processExited, becomes: .idle, doing: .finalize)
    }

    func testUnexpectedProcessExitWhileRecordingStillFinalizes() {
        // screencapture died or was killed externally — recover, don't wedge.
        assertTransition(.recording, .processExited, becomes: .idle, doing: .finalize)
    }

    func testNoOps() {
        assertTransition(.idle, .processExited, becomes: .idle, doing: .none)
        assertTransition(.idle, .stopRequested, becomes: .idle, doing: .none)
        assertTransition(.finishing, .toggle, becomes: .finishing, doing: .none)
        assertTransition(.recording, .regionConfirmed, becomes: .recording, doing: .none)
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'RecordingStateMachine' in scope`.

- [x] **Step 3: Implement — create `Sources/Capture/RecordingService.swift` with exactly this content**

```swift
import AppKit

/// Pure recording lifecycle: a transition function from (phase, event) to
/// (next phase, side effect to perform). The Process handle deliberately
/// lives in RecordingService, not in the enum, so phases stay Equatable.
enum RecordingStateMachine {
    enum Phase: Equatable {
        case idle, selectingRegion, recording, finishing
    }

    enum Event: Equatable {
        case toggle           // hotkey or menu item
        case regionConfirmed  // picker delivered a region / fullScreen
        case regionCancelled  // picker Esc
        case stopRequested    // HUD Stop button
        case processExited    // screencapture terminated (any reason)
    }

    enum Action: Equatable {
        case presentRegionPicker
        case dismissRegionPicker
        case startProcess
        case stopProcess
        case finalize
        case none
    }

    static func transition(from phase: Phase, on event: Event) -> (phase: Phase, action: Action) {
        switch (phase, event) {
        case (.idle, .toggle):
            return (.selectingRegion, .presentRegionPicker)
        case (.selectingRegion, .regionConfirmed):
            return (.recording, .startProcess)
        case (.selectingRegion, .regionCancelled):
            return (.idle, .none)
        case (.selectingRegion, .toggle):
            return (.idle, .dismissRegionPicker)
        case (.recording, .toggle), (.recording, .stopRequested):
            return (.finishing, .stopProcess)
        case (.recording, .processExited):
            return (.idle, .finalize)   // crashed / killed externally — recover
        case (.finishing, .processExited):
            return (.idle, .finalize)
        default:
            return (phase, .none)
        }
    }
}

/// Owns the screen-recording flow: region picker → screencapture -v process
/// → SIGINT to stop → finished-file callback. Impure shell around the pure
/// state machine above. Main-thread only (all entry points are UI events;
/// the termination handler hops to main).
final class RecordingService {
    private(set) var phase: RecordingStateMachine.Phase = .idle
    private let picker = RegionPicker()
    private var process: Process?
    private var outputURL: URL?
    private var pendingRegion: CGRect?   // Cocoa coords; nil = entire screen

    /// Finished file (may not exist / be empty — consumer checks), or nil
    /// when nothing was recorded. Set by CaptureController.
    var onFinished: ((URL?) -> Void)?
    /// Phase observer for the HUD and the menu-item title.
    var onPhaseChange: ((RecordingStateMachine.Phase) -> Void)?

    var isRecording: Bool { phase == .recording || phase == .finishing }

    func toggle() { handle(.toggle) }
    func stop() { handle(.stopRequested) }

    private func handle(_ event: RecordingStateMachine.Event) {
        let (next, action) = RecordingStateMachine.transition(from: phase, on: event)
        phase = next
        onPhaseChange?(next)
        switch action {
        case .presentRegionPicker:
            picker.present { [weak self] result in
                guard let self else { return }
                switch result {
                case .cancelled:
                    self.handle(.regionCancelled)
                case .fullScreen:
                    self.pendingRegion = nil
                    self.handle(.regionConfirmed)
                case .region(let cocoaRect):
                    self.pendingRegion = cocoaRect
                    self.handle(.regionConfirmed)
                }
            }
        case .dismissRegionPicker:
            picker.dismiss()
        case .startProcess:
            startProcess()
        case .stopProcess:
            process?.interrupt()   // SIGINT — screencapture finalizes the .mov
        case .finalize:
            let url = outputURL
            process = nil
            outputURL = nil
            onFinished?(url)
        case .none:
            break
        }
    }

    private func startProcess() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuse-recording-\(UUID().uuidString).mov")
        outputURL = url
        var args = ["-v"]
        if let cocoaRect = pendingRegion {
            // screencapture -R wants GLOBAL points with TOP-LEFT origin.
            let primaryHeight = NSScreen.screens[0].frame.height
            let r = CaptureGeometry.topLeftRect(fromCocoaRect: cocoaRect,
                                                primaryScreenHeight: primaryHeight)
            args += ["-R", String(format: "%.0f,%.0f,%.0f,%.0f",
                                  r.minX, r.minY, r.width, r.height)]
        }
        args.append(url.path)
        pendingRegion = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handle(.processExited)
            }
        }
        do {
            try proc.run()
            process = proc
            Log.capture.info("recording started → \(url.path, privacy: .public)")
        } catch {
            Log.capture.error("screencapture -v failed to launch: \(error.localizedDescription, privacy: .public)")
            outputURL = nil
            handle(.processExited)   // → idle, finalize(nil)
        }
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, with all 9 `RecordingStateMachineTests` listed as passed.

- [x] **Step 5: Create `Sources/Capture/RecHUD.swift` with exactly this content** (named RecHUD — `RecordingHUD` belongs to Voice)

```swift
import AppKit
import SwiftUI

final class RecHUDModel: ObservableObject {
    @Published var elapsedText = "0:00"
    var onStop: (() -> Void)?
}

struct RecHUDView: View {
    @ObservedObject var model: RecHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(model.elapsedText)
                .font(.system(.body, design: .monospaced))
            Button("Stop") { model.onStop?() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Small floating REC indicator shown while a recording runs: red dot,
/// elapsed timer, Stop button. Non-activating panel pinned to the top-right
/// of the main screen (usually outside the recorded region — see gotchas).
final class RecHUD {
    private let model = RecHUDModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    func show() {
        startedAt = Date()
        model.elapsedText = "0:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let s = Int(Date().timeIntervalSince(startedAt))
            self.model.elapsedText = String(format: "%d:%02d", s / 60, s % 60)
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 170, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: RecHUDView(model: model))
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel?.setFrameOrigin(CGPoint(x: f.maxX - 200, y: f.maxY - 64))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        panel?.orderOut(nil)
    }
}
```

- [x] **Step 6: Regenerate, build, and run the full suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [x] **Step 7: Commit**

```bash
git add Sources/Capture/RecordingService.swift Sources/Capture/RecHUD.swift Tests/FuseTests/RegionGeometryTests.swift
git commit -m "feat(capture): recording state machine, screencapture -v service, REC HUD"
```

---

### Task 10.5: ScreenshotService + CaptureController with the shared output pipeline

**Files:**
- Create: `Sources/Capture/ScreenshotService.swift`
- Create: `Sources/Capture/CaptureController.swift`

`ScreenshotService` drives `screencapture -i -o <tmp>.png` (interactive: crosshair selection, spacebar toggles window mode, ESC cancels; `-o` drops the window shadow). When the process exits with a missing/empty tmpfile, the user pressed ESC — silently abort. `CaptureController` owns everything: both services, the HUD, hotkey registration, defaults registration, and the shared output pipeline (timestamped move → clipboard → editor → log). The "open editor" step temporarily opens captures with the system default app (`NSWorkspace.open`) — Tasks 10.6/10.7 replace the two branches with the built-in editor/trimmer; this keeps every task independently shippable without placeholders.

- [x] **Step 1: Create `Sources/Capture/ScreenshotService.swift` with exactly this content**

```swift
import AppKit

/// Drives the system's interactive screenshot engine:
/// `screencapture -i -o <tmp>.png`. The child process inherits Fuse's TCC
/// identity, so the Screen Recording permission prompt (first use) and the
/// grant are attributed to Fuse.
final class ScreenshotService {
    private var process: Process?

    var isRunning: Bool { process != nil }

    /// Calls back on the main queue with the temp PNG, or nil when the user
    /// cancelled with Esc (screencapture exits without writing the file).
    func captureInteractive(completion: @escaping (URL?) -> Void) {
        guard process == nil else { return }   // one interactive session at a time
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuse-shot-\(UUID().uuidString).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-o", tmp.path]
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.process = nil
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
                completion(size > 0 ? tmp : nil)   // missing/empty = Esc
            }
        }
        do {
            try proc.run()
            process = proc
        } catch {
            Log.capture.error("screencapture -i failed to launch: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }
}
```

- [x] **Step 2: Create `Sources/Capture/CaptureController.swift` with exactly this content**

```swift
import AppKit
import KeyboardShortcuts

/// Owns the Capture feature: screenshot + recording services, the REC HUD,
/// hotkeys, status-menu actions, and the shared output pipeline
/// (timestamped save → clipboard copy → editor/trimmer → log).
final class CaptureController {
    private let screenshots = ScreenshotService()
    private let recorder = RecordingService()
    private let hud = RecHUD()

    /// Set by AppDelegate so the title can swap with recording state.
    weak var recordingMenuItem: NSMenuItem?

    static let defaultSaveFolder = NSHomeDirectory() + "/Desktop"
    static let fileURLType = NSPasteboard.PasteboardType("public.file-url")

    func start() {
        UserDefaults.standard.register(defaults: [
            "capture.saveFolderPath": Self.defaultSaveFolder,
            "capture.copyToClipboard": true,
            "capture.openEditorAfter": true,
        ])

        recorder.onPhaseChange = { [weak self] phase in
            if phase == .recording {
                self?.hud.show()
            } else if phase == .idle {
                self?.hud.hide()
            }
            self?.refreshMenuTitle()
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.hud.hide()
            self.refreshMenuTitle()
            guard let url,
                  let size = (try? FileManager.default
                      .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                  size > 0
            else {
                Log.capture.info("recording produced no file; nothing to save")
                return
            }
            self.runOutputPipeline(tempURL: url, kind: .recording)
        }
        hud.onStop = { [weak self] in self?.recorder.stop() }

        // Hotkeys are automatically silenced by PauseManager via
        // KeyboardShortcuts.isEnabled — no pause handling needed here.
        KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in
            self?.captureRegion()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.recorder.toggle()
        }
    }

    // MARK: - Entry points (menu items target these)

    @objc func captureRegionFromMenu() { captureRegion() }
    @objc func toggleRecordingFromMenu() { recorder.toggle() }

    private func captureRegion() {
        guard !screenshots.isRunning else { return }
        screenshots.captureInteractive { [weak self] url in
            guard let self, let url else { return }   // nil = user pressed Esc
            self.runOutputPipeline(tempURL: url, kind: .screenshot)
        }
    }

    private func refreshMenuTitle() {
        recordingMenuItem?.title = recorder.isRecording ? "Stop Recording" : "Start Recording"
    }

    // MARK: - Shared output pipeline

    private func runOutputPipeline(tempURL: URL, kind: CaptureKind) {
        let defaults = UserDefaults.standard
        let folder = defaults.string(forKey: "capture.saveFolderPath") ?? Self.defaultSaveFolder
        let dest = URL(fileURLWithPath: folder)
            .appendingPathComponent(CaptureNames.fileName(kind: kind, date: Date()))
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            Log.capture.error("failed to move capture into place: \(error.localizedDescription, privacy: .public)")
            return
        }

        if defaults.bool(forKey: "capture.copyToClipboard") {
            copyToClipboard(dest, kind: kind)
        }
        if defaults.bool(forKey: "capture.openEditorAfter") {
            openInEditor(dest, kind: kind)
        }
        Log.capture.info("capture saved: \(dest.path, privacy: .public)")
    }

    private func copyToClipboard(_ url: URL, kind: CaptureKind) {
        let urlData = url.dataRepresentation
        switch kind {
        case .screenshot:
            guard let pngData = try? Data(contentsOf: url) else { return }
            // markInternal: false is LOAD-BEARING — Fuse's own clipboard
            // history must record this item (the watcher skips marked items).
            PasteService.write([[.png: pngData], [Self.fileURLType: urlData]],
                               markInternal: false)
        case .recording:
            PasteService.write([[Self.fileURLType: urlData]], markInternal: false)
        }
    }

    private func openInEditor(_ url: URL, kind: CaptureKind) {
        switch kind {
        case .screenshot:
            // Replaced in Task 10.6 with the built-in annotation editor.
            NSWorkspace.shared.open(url)
        case .recording:
            // Replaced in Task 10.7 with the built-in trimmer.
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [x] **Step 3: Regenerate, build, and run the regression suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [x] **Step 4: Commit**

```bash
git add Sources/Capture/ScreenshotService.swift Sources/Capture/CaptureController.swift
git commit -m "feat(capture): screenshot service and capture controller with shared output pipeline"
```

---

### Task 10.6: Image annotation editor — pure model (TDD) + SwiftUI editor + window

**Files:**
- Create: `Sources/Capture/ImageEditorModel.swift` (pure types + geometry + shared CGPath builder)
- Create: `Sources/Capture/ImageEditorView.swift` (ObservableObject state, SwiftUI view, window controller — window+view share this file)
- Modify: `Sources/Capture/CaptureController.swift` (wire the editor into the pipeline)
- Test: `Tests/FuseTests/AnnotationModelTests.swift`

Annotation coordinate space = image **point** space, top-left origin (matches SwiftUI Canvas). Flattening uses `NSImage(size:flipped: true)` so the drawing handler also gets a top-left-origin context — no ad-hoc flips anywhere. Crop flattens the current annotations into the image FIRST, then trims with `CGImage.cropping` and clears the annotation list (so annotations never need re-anchoring; Undo does not cross a crop — stated in the UI footer? No: stated here and in gotchas, the UI stays minimal).

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/AnnotationModelTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

final class AnnotationModelTests: XCTestCase {
    func testArrowHeadHorizontalArrow() {
        // Shaft (0,0)→(10,0), barbs of length 2 at ±30° off the shaft,
        // pointing back from the tip: x = 10 − 2·cos(30°), y = ±2·sin(30°).
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), length: 2)
        let expectedX = 10 - 2 * cos(CGFloat.pi / 6)   // ≈ 8.268
        XCTAssertEqual(left.x, expectedX, accuracy: 0.001)
        XCTAssertEqual(right.x, expectedX, accuracy: 0.001)
        XCTAssertEqual(abs(left.y), 1.0, accuracy: 0.001)    // 2·sin(30°) = 1
        XCTAssertEqual(abs(right.y), 1.0, accuracy: 0.001)
        XCTAssertEqual(left.y, -right.y, accuracy: 0.001)    // symmetric barbs
    }

    func testArrowHeadVerticalArrow() {
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 5, y: 20), to: CGPoint(x: 5, y: 0), length: 3)
        // Arrow points "up" in top-left space (decreasing y); barbs sit below
        // the tip, symmetric around x = 5.
        let expectedY = 3 * cos(CGFloat.pi / 6)   // ≈ 2.598
        XCTAssertEqual(left.y, expectedY, accuracy: 0.001)
        XCTAssertEqual(right.y, expectedY, accuracy: 0.001)
        XCTAssertEqual(left.x + right.x, 10, accuracy: 0.001)
        XCTAssertEqual(abs(left.x - 5), 1.5, accuracy: 0.001)   // 3·sin(30°)
    }

    func testArrowHeadDegenerateZeroLengthShaft() {
        // from == to: atan2(0,0) == 0 — must not crash; barbs land left of tip.
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 4, y: 4), to: CGPoint(x: 4, y: 4), length: 2)
        XCTAssertLessThan(left.x, 4)
        XCTAssertLessThan(right.x, 4)
    }

    func testAnnotationDefaults() {
        let a = Annotation(tool: .arrow)
        XCTAssertEqual(a.points, [])
        XCTAssertEqual(a.rect, .zero)
        XCTAssertEqual(a.text, "")
        XCTAssertEqual(a.color, .red)
        XCTAssertEqual(a.lineWidth, 4)
    }

    func testAllToolsBuildAPathWithoutCrashing() {
        for tool in AnnotationTool.allCases {
            var a = Annotation(tool: tool)
            a.points = [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)]
            a.rect = CGRect(x: 1, y: 1, width: 8, height: 8)
            a.text = "x"
            _ = AnnotationPaths.path(for: a)   // text yields an empty path
        }
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'AnnotationGeometry' in scope` (and friends).

- [x] **Step 3: Implement — create `Sources/Capture/ImageEditorModel.swift` with exactly this content**

```swift
import CoreGraphics
import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, freehand, highlighter, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        }
    }
}

/// Six preset colors stored as an enum (trivially Equatable/Codable-ready;
/// no NSColor in the model). The NSColor mapping lives in the view layer.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, black
    var id: String { rawValue }
}

/// One annotation, in image POINT coordinates with TOP-LEFT origin
/// (the SwiftUI Canvas space; the flattener uses a flipped context to match).
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var points: [CGPoint] = []   // freehand/highlighter vertices; arrow = [from, to]
    var rect: CGRect = .zero     // rectangle/ellipse bounds; text anchor = rect.origin
    var text: String = ""
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 4

    init(id: UUID = UUID(), tool: AnnotationTool) {
        self.id = id
        self.tool = tool
    }
}

enum AnnotationGeometry {
    /// The two barb endpoints of an arrow head whose tip is at `to`,
    /// pointing back toward `from`, each `length` long, 30° off the shaft.
    static func arrowHeadPoints(from: CGPoint, to: CGPoint,
                                length: CGFloat) -> (CGPoint, CGPoint) {
        let back = atan2(to.y - from.y, to.x - from.x) + .pi
        let spread = CGFloat.pi / 6
        let left = CGPoint(x: to.x + length * cos(back - spread),
                           y: to.y + length * sin(back - spread))
        let right = CGPoint(x: to.x + length * cos(back + spread),
                            y: to.y + length * sin(back + spread))
        return (left, right)
    }
}

/// THE shared geometry between the live Canvas and the AppKit flattener:
/// one CGPath per annotation. Text is not a path — both renderers draw it
/// as an attributed string (the only intentionally duplicated rendering).
enum AnnotationPaths {
    static func path(for a: Annotation) -> CGPath {
        let path = CGMutablePath()
        switch a.tool {
        case .arrow:
            guard a.points.count >= 2 else { break }
            let from = a.points[0]
            let to = a.points[a.points.count - 1]
            path.move(to: from)
            path.addLine(to: to)
            let head = AnnotationGeometry.arrowHeadPoints(
                from: from, to: to, length: max(10, a.lineWidth * 3))
            path.move(to: head.0)
            path.addLine(to: to)
            path.addLine(to: head.1)
        case .rectangle:
            path.addRect(a.rect)
        case .ellipse:
            path.addEllipse(in: a.rect)
        case .freehand, .highlighter:
            guard let first = a.points.first else { break }
            path.move(to: first)
            for p in a.points.dropFirst() {
                path.addLine(to: p)
            }
        case .text:
            break   // drawn as a string by each renderer
        }
        return path
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, with all 5 `AnnotationModelTests` listed as passed.

- [x] **Step 5: Create `Sources/Capture/ImageEditorView.swift` with exactly this content** (state + view + window controller in one file)

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AnnotationColor {
    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .black: return .black
        }
    }
}

/// Editor session state + the impure actions (flatten, crop, copy, save).
final class ImageEditorState: ObservableObject {
    @Published var image: NSImage
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow
    @Published var color: AnnotationColor = .red
    @Published var lineWidth: CGFloat = 4
    @Published var inProgress: Annotation?
    @Published var cropMode = false
    @Published var cropRect: CGRect?
    @Published var pendingText: CGPoint?
    @Published var textDraft = ""

    let fileURL: URL

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
    }

    // MARK: - Gesture handling (image point coords, top-left origin)

    func dragChanged(start: CGPoint, current: CGPoint) {
        if cropMode {
            cropRect = CaptureGeometry.normalizedRect(from: start, to: current)
            return
        }
        switch tool {
        case .text:
            break   // text places on dragEnded (a click)
        case .arrow:
            var a = inProgress ?? newAnnotation()
            a.points = [start, current]
            inProgress = a
        case .rectangle, .ellipse:
            var a = inProgress ?? newAnnotation()
            a.rect = CaptureGeometry.normalizedRect(from: start, to: current)
            inProgress = a
        case .freehand, .highlighter:
            var a = inProgress ?? newAnnotation()
            if a.points.isEmpty { a.points.append(start) }
            a.points.append(current)
            inProgress = a
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        if cropMode { return }   // crop rect persists until "Apply Crop"
        if tool == .text {
            pendingText = end
            textDraft = ""
            return
        }
        dragChanged(start: start, current: end)
        if let a = inProgress {
            annotations.append(a)
            inProgress = nil
        }
    }

    func commitText() {
        defer {
            pendingText = nil
            textDraft = ""
        }
        guard let anchor = pendingText, !textDraft.isEmpty else { return }
        var a = newAnnotation()
        a.tool = .text
        a.text = textDraft
        a.rect = CGRect(origin: anchor, size: .zero)
        annotations.append(a)
    }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast() }
    }

    private func newAnnotation() -> Annotation {
        var a = Annotation(tool: tool)
        a.color = color
        a.lineWidth = lineWidth
        return a
    }

    // MARK: - Flatten / crop / output

    /// Renders base image + all annotations into one NSImage. flipped: true
    /// gives the handler a TOP-LEFT-origin context, matching the Canvas, so
    /// annotation coordinates are used verbatim — no ad-hoc flips.
    func flattened() -> NSImage {
        let size = image.size
        let base = image
        let annotations = self.annotations
        return NSImage(size: size, flipped: true) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            for a in annotations {
                Self.drawWithAppKit(a)
            }
            return true
        }
    }

    /// AppKit stroker — thin twin of the Canvas stroker in ImageEditorView.
    /// Both consume AnnotationPaths.path(for:); only stroke application and
    /// text drawing are duplicated (GraphicsContext vs NSGraphicsContext).
    static func drawWithAppKit(_ a: Annotation) {
        if a.tool == .text {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: a.color.nsColor,
            ]
            a.text.draw(at: a.rect.origin, withAttributes: attrs)
            return
        }
        let path = NSBezierPath(cgPath: AnnotationPaths.path(for: a))
        path.lineWidth = a.tool == .highlighter ? a.lineWidth * 4 : a.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let color = a.tool == .highlighter
            ? a.color.nsColor.withAlphaComponent(0.4)
            : a.color.nsColor
        color.setStroke()
        path.stroke()
    }

    /// Flatten current annotations into the image, then trim. Annotations
    /// are cleared (they are now part of the pixels) — Undo does not cross
    /// a crop, by design.
    func applyCrop() {
        guard let cropRect, cropRect.width >= 1, cropRect.height >= 1 else { return }
        let flat = flattened()
        guard let cg = flat.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // CGImage pixel space is top-left origin, same as our annotation
        // space — only the point→pixel scale differs (Retina backing).
        let scaleX = CGFloat(cg.width) / flat.size.width
        let scaleY = CGFloat(cg.height) / flat.size.height
        let pixelRect = CGRect(x: cropRect.minX * scaleX,
                               y: cropRect.minY * scaleY,
                               width: cropRect.width * scaleX,
                               height: cropRect.height * scaleY)
        guard let cropped = cg.cropping(to: pixelRect.integral) else { return }
        image = NSImage(cgImage: cropped, size: cropRect.size)
        annotations = []
        inProgress = nil
        self.cropRect = nil
        cropMode = false
    }

    static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func copyFlattened() {
        guard let data = Self.pngData(of: flattened()) else { return }
        // markInternal: false — clipboard history records the edited image too.
        PasteService.write([[.png: data]], markInternal: false)
    }

    func save() {
        guard let data = Self.pngData(of: flattened()) else { return }
        do {
            try data.write(to: fileURL)
            Log.capture.info("editor saved over \(self.fileURL.path, privacy: .public)")
        } catch {
            Log.capture.error("editor save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveAs() {
        guard let data = Self.pngData(of: flattened()) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.directoryURL = fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            Log.capture.info("editor saved as \(url.path, privacy: .public)")
        } catch {
            Log.capture.error("editor save-as failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct ImageEditorView: View {
    @ObservedObject var state: ImageEditorState
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                canvasStack
                    .frame(width: state.image.size.width,
                           height: state.image.size.height)
                    .padding(12)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $state.tool) {
                ForEach(AnnotationTool.allCases) { tool in
                    Image(systemName: tool.symbolName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            HStack(spacing: 5) {
                ForEach(AnnotationColor.allCases) { color in
                    Button {
                        state.color = color
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(
                                Color.primary.opacity(state.color == color ? 0.8 : 0),
                                lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Width", selection: $state.lineWidth) {
                Text("2").tag(CGFloat(2))
                Text("4").tag(CGFloat(4))
                Text("6").tag(CGFloat(6))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
            Button("Undo") { state.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(state.annotations.isEmpty)
            Toggle("Crop", isOn: $state.cropMode)
                .toggleStyle(.button)
            if state.cropMode {
                Button("Apply Crop") { state.applyCrop() }
                    .disabled(state.cropRect == nil)
            }
            Spacer()
            Button("Copy") { state.copyFlattened() }
            Button("Save") { state.save() }
            Button("Save As…") { state.saveAs() }
        }
        .padding(10)
    }

    private var canvasStack: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: state.image)
                .resizable()
                .frame(width: state.image.size.width,
                       height: state.image.size.height)
            Canvas { context, _ in
                for a in state.annotations { draw(a, in: &context) }
                if let a = state.inProgress { draw(a, in: &context) }
                if state.cropMode, let crop = state.cropRect {
                    context.stroke(Path(crop), with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .gesture(dragGesture)
            if let anchor = state.pendingText {
                TextField("Text", text: $state.textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($textFieldFocused)
                    .offset(x: anchor.x, y: anchor.y)
                    .onSubmit { state.commitText() }
                    .onAppear { textFieldFocused = true }
            }
        }
    }

    /// Canvas stroker — thin twin of ImageEditorState.drawWithAppKit.
    private func draw(_ a: Annotation, in context: inout GraphicsContext) {
        if a.tool == .text {
            context.draw(
                Text(a.text)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(nsColor: a.color.nsColor)),
                at: a.rect.origin, anchor: .topLeading)
            return
        }
        let path = Path(AnnotationPaths.path(for: a))
        let opacity = a.tool == .highlighter ? 0.4 : 1.0
        let width = a.tool == .highlighter ? a.lineWidth * 4 : a.lineWidth
        context.stroke(
            path,
            with: .color(Color(nsColor: a.color.nsColor).opacity(opacity)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                state.dragChanged(start: value.startLocation, current: value.location)
            }
            .onEnded { value in
                state.dragEnded(start: value.startLocation, end: value.location)
            }
    }
}

/// Plain NSWindow hosting the editor. Retained by CaptureController until
/// the window closes (multiple editors may be open at once).
final class ImageEditorWindowController {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    var onClose: (() -> Void)?

    init?(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        let state = ImageEditorState(image: image, fileURL: fileURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: min(image.size.width + 48, 1200),
                                height: min(image.size.height + 110, 800)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.contentView = NSHostingView(rootView: ImageEditorView(state: state))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
```

- [x] **Step 6: Wire the editor into the pipeline — edit `Sources/Capture/CaptureController.swift`**

Edit A — find:

```swift
    private let hud = RecHUD()
```

Replace with:

```swift
    private let hud = RecHUD()
    private var imageEditors: [ImageEditorWindowController] = []
```

Edit B — find:

```swift
        case .screenshot:
            // Replaced in Task 10.6 with the built-in annotation editor.
            NSWorkspace.shared.open(url)
```

Replace with:

```swift
        case .screenshot:
            guard let editor = ImageEditorWindowController(fileURL: url) else {
                NSWorkspace.shared.open(url)   // unreadable PNG — fall back
                return
            }
            editor.onClose = { [weak self, weak editor] in
                self?.imageEditors.removeAll { $0 === editor }
            }
            imageEditors.append(editor)
            editor.show()
```

- [x] **Step 7: Regenerate, build, and run the full suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [x] **Step 8: Commit**

```bash
git add Sources/Capture/ImageEditorModel.swift Sources/Capture/ImageEditorView.swift Sources/Capture/CaptureController.swift Tests/FuseTests/AnnotationModelTests.swift
git commit -m "feat(capture): image annotation editor with shared-path renderers and crop"
```

---

### Task 10.7: Video trimmer — TrimMath (TDD) + AVKit player window

**Files:**
- Create: `Sources/Capture/VideoTrimmer.swift` (TrimMath + state + view + window controller)
- Modify: `Sources/Capture/CaptureController.swift` (wire the trimmer into the pipeline)
- Test: `Tests/FuseTests/TrimRangeTests.swift`

Minimal by design: AVKit `VideoPlayer` + two fraction sliders (start/end of duration) + "Export Trimmed" via `AVAssetExportSession` passthrough (no re-encode, fast and lossless). No timeline thumbnails in v1. The exported file lands next to the original as `"<name> trimmed.mov"`, its file-URL is copied to the clipboard (`markInternal: false`), and it is revealed in Finder.

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/TrimRangeTests.swift` with exactly this content**

```swift
import CoreMedia
import XCTest
@testable import Fuse

final class TrimRangeTests: XCTestCase {
    func testFullRange() {
        let r = TrimMath.trimRange(start: 0, end: 1, duration: 10)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 10, accuracy: 0.001)
    }

    func testInteriorRange() {
        let r = TrimMath.trimRange(start: 0.25, end: 0.75, duration: 8)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 6, accuracy: 0.001)
        XCTAssertEqual(r!.duration.seconds, 4, accuracy: 0.001)
    }

    func testEndEqualToStartIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0.5, end: 0.5, duration: 10))
    }

    func testEndBeforeStartIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0.8, end: 0.2, duration: 10))
    }

    func testNonPositiveDurationIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0, end: 1, duration: 0))
        XCTAssertNil(TrimMath.trimRange(start: 0, end: 1, duration: -3))
    }

    func testOutOfBoundsFractionsAreClamped() {
        let r = TrimMath.trimRange(start: -0.5, end: 1.5, duration: 4)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 4, accuracy: 0.001)
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'TrimMath' in scope`.

- [x] **Step 3: Implement — create `Sources/Capture/VideoTrimmer.swift` with exactly this content**

```swift
import AVKit
import AppKit
import SwiftUI

/// Pure slider math: fractional start/end (0…1) of a clip → CMTimeRange.
/// nil when duration is non-positive or the clamped range is empty.
enum TrimMath {
    static func trimRange(start: Double, end: Double, duration: Double) -> CMTimeRange? {
        guard duration > 0 else { return nil }
        let s = min(max(start, 0), 1)
        let e = min(max(end, 0), 1)
        guard e > s else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: s * duration, preferredTimescale: 600),
            end: CMTime(seconds: e * duration, preferredTimescale: 600))
    }
}

final class VideoTrimmerState: ObservableObject {
    let fileURL: URL
    let player: AVPlayer
    @Published var start: Double = 0
    @Published var end: Double = 1
    @Published var durationSeconds: Double = 0
    @Published var exporting = false
    @Published var statusMessage = ""

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.player = AVPlayer(url: fileURL)
        Task { @MainActor in
            let asset = AVURLAsset(url: fileURL)
            if let duration = try? await asset.load(.duration) {
                self.durationSeconds = duration.seconds
            }
        }
    }

    var exportDisabled: Bool {
        exporting || TrimMath.trimRange(start: start, end: end,
                                        duration: durationSeconds) == nil
    }

    func exportTrimmed() {
        guard let range = TrimMath.trimRange(start: start, end: end,
                                             duration: durationSeconds) else { return }
        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            statusMessage = "Export session unavailable"
            return
        }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let outURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(base) trimmed.mov")
        try? FileManager.default.removeItem(at: outURL)
        session.outputURL = outURL
        session.outputFileType = .mov
        session.timeRange = range
        exporting = true
        statusMessage = "Exporting…"
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                if session.status == .completed {
                    self.statusMessage = "Saved \(outURL.lastPathComponent)"
                    PasteService.write(
                        [[CaptureController.fileURLType: outURL.dataRepresentation]],
                        markInternal: false)
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                    Log.capture.info("trimmed export saved: \(outURL.path, privacy: .public)")
                } else {
                    let reason = session.error?.localizedDescription ?? "unknown error"
                    self.statusMessage = "Export failed: \(reason)"
                    Log.capture.error("trim export failed: \(reason, privacy: .public)")
                }
            }
        }
    }
}

struct VideoTrimmerView: View {
    @ObservedObject var state: VideoTrimmerState

    var body: some View {
        VStack(spacing: 12) {
            VideoPlayer(player: state.player)
                .frame(minWidth: 560, minHeight: 320)
            HStack(spacing: 8) {
                Text(timeLabel(state.start)).monospacedDigit()
                Slider(value: $state.start, in: 0...1) { Text("Start") }
                Slider(value: $state.end, in: 0...1) { Text("End") }
                Text(timeLabel(state.end)).monospacedDigit()
            }
            HStack {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export Trimmed") { state.exportTrimmed() }
                    .disabled(state.exportDisabled)
            }
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 420)
    }

    private func timeLabel(_ fraction: Double) -> String {
        let s = Int(fraction * state.durationSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Plain NSWindow hosting the trimmer. Retained by CaptureController until
/// the window closes.
final class VideoTrimmerWindowController {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    var onClose: (() -> Void)?

    init(fileURL: URL) {
        let state = VideoTrimmerState(fileURL: fileURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.contentView = NSHostingView(rootView: VideoTrimmerView(state: state))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, with all 6 `TrimRangeTests` listed as passed. Note: `exportAsynchronously` is deprecated on macOS 15+ in favor of async `export(to:as:)` — the deployment target is 14.0, so a deprecation **warning** is expected and acceptable. If it surfaces as an **error** (library drift), switch to the async API minimally and record it under `## Deviations`.

- [x] **Step 5: Wire the trimmer into the pipeline — edit `Sources/Capture/CaptureController.swift`**

Edit A — find:

```swift
    private var imageEditors: [ImageEditorWindowController] = []
```

Replace with:

```swift
    private var imageEditors: [ImageEditorWindowController] = []
    private var videoTrimmers: [VideoTrimmerWindowController] = []
```

Edit B — find:

```swift
        case .recording:
            // Replaced in Task 10.7 with the built-in trimmer.
            NSWorkspace.shared.open(url)
```

Replace with:

```swift
        case .recording:
            let trimmer = VideoTrimmerWindowController(fileURL: url)
            trimmer.onClose = { [weak self, weak trimmer] in
                self?.videoTrimmers.removeAll { $0 === trimmer }
            }
            videoTrimmers.append(trimmer)
            trimmer.show()
```

- [x] **Step 6: Regenerate, build, and run the full suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [x] **Step 7: Commit**

```bash
git add Sources/Capture/VideoTrimmer.swift Sources/Capture/CaptureController.swift Tests/FuseTests/TrimRangeTests.swift
git commit -m "feat(capture): video trimmer with passthrough export and tested trim math"
```

---

### Task 10.8: Settings tab + AppDelegate wiring + end-to-end HUMAN-VERIFY

**Files:**
- Create: `Sources/Capture/CaptureSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (enum case + content row + minWidth bump)
- Modify: `Sources/App/AppDelegate.swift` (three anchor inserts)

- [x] **Step 1: Create `Sources/Capture/CaptureSettingsView.swift` with exactly this content**

```swift
import AppKit
import KeyboardShortcuts
import SwiftUI

struct CaptureSettingsView: View {
    @AppStorage("capture.saveFolderPath") private var saveFolderPath = CaptureController.defaultSaveFolder
    @AppStorage("capture.copyToClipboard") private var copyToClipboard = true
    @AppStorage("capture.openEditorAfter") private var openEditorAfter = true

    @State private var hasScreenRecording = PermissionsService.hasScreenRecording
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasScreenRecording {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording permission required")
                                .foregroundStyle(.red)
                            Text("Screenshots and recordings need Screen Recording access. macOS also shows its own prompt on the first capture; relaunch Fuse after granting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForScreenRecording()
                            PermissionsService.openSystemSettings(pane: .screenRecording)
                        }
                    }
                }
            }
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture region:", name: .captureRegion)
                KeyboardShortcuts.Recorder("Start/stop recording:", name: .toggleRecording)
            }
            Section("Output") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Save to folder")
                        Text(saveFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                Toggle("Copy capture to clipboard", isOn: $copyToClipboard)
                Toggle("Open editor after capture", isOn: $openEditorAfter)
            }
            Section {
                Text("Copied captures land in Fuse's clipboard history automatically — every screenshot and recording shows up in the paste picker (⇧⌘V).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasScreenRecording = PermissionsService.hasScreenRecording
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path
        }
    }
}
```

- [x] **Step 2: Add the Capture tab to `Sources/App/SettingsRootView.swift`** (this file uses a `SettingsTab` enum, NOT the retired TabView anchor — four edits)

Edit A — find:

```swift
    case general, scroll, tiling, clipboard, voice, downloads, notifications, notes
```

Replace with:

```swift
    case general, scroll, tiling, clipboard, voice, capture, downloads, notifications, notes
```

Edit B — in the `title` switch, find:

```swift
        case .voice: return "Voice"
```

Replace with:

```swift
        case .voice: return "Voice"
        case .capture: return "Capture"
```

Edit C — in the `icon` switch, find:

```swift
        case .voice: return "mic"
```

Replace with:

```swift
        case .voice: return "mic"
        case .capture: return "camera.viewfinder"
```

Edit D — in the `content` switch, find:

```swift
        case .voice: VoiceSettingsView()
```

Replace with:

```swift
        case .voice: VoiceSettingsView()
        case .capture: CaptureSettingsView()
```

Edit E — nine 84-pt tab buttons need more width than the current minimum (9 × 84 + spacing ≈ 772). Find:

```swift
        .frame(minWidth: 720, minHeight: 560)
```

Replace with:

```swift
        .frame(minWidth: 800, minHeight: 560)
```

- [x] **Step 3: Wire the controller into `Sources/App/AppDelegate.swift`** (three anchor inserts; insert ABOVE each anchor, the anchor lines stay verbatim)

Edit A — find this exact line (4-space indentation):

```swift
    // FUSE:CONTROLLER-PROPS
```

Replace with:

```swift
    private var captureController: CaptureController!
    private var captureRegionMenuItem: NSMenuItem!
    private var recordingMenuItem: NSMenuItem!
    // FUSE:CONTROLLER-PROPS
```

Edit B — find this exact line (8-space indentation):

```swift
        // FUSE:MENU-ITEMS
```

Replace with:

```swift
        captureRegionMenuItem = NSMenuItem(
            title: "Capture Region",
            action: #selector(CaptureController.captureRegionFromMenu),
            keyEquivalent: "")
        menu.addItem(captureRegionMenuItem)
        recordingMenuItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(CaptureController.toggleRecordingFromMenu),
            keyEquivalent: "")
        menu.addItem(recordingMenuItem)
        // FUSE:MENU-ITEMS
```

Edit C — find this exact line (8-space indentation):

```swift
        // FUSE:CONTROLLER-START
```

Replace with:

```swift
        captureController = CaptureController()
        captureController.recordingMenuItem = recordingMenuItem
        captureController.start()
        captureRegionMenuItem.target = captureController
        recordingMenuItem.target = captureController
        // FUSE:CONTROLLER-START
```

- [x] **Step 4: Regenerate, build, and run the full suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Launch the app**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

- [ ] **Step 6: HUMAN-VERIFY — permission, tab, and screenshot flow**

Ask the human to perform ALL of the following and report each result:
1. Settings → confirm a **Capture** tab (camera.viewfinder icon) sits between Voice and Downloads, all nine tabs are visible without an overflow chevron, and the General tab shows a **Screen Recording** permission row.
2. Press ⌃⌥S. The FIRST time, macOS should show the Screen Recording permission prompt **attributed to Fuse** — grant it, then quit and relaunch Fuse (TCC requires a relaunch for screen capture). If the crosshair appears immediately, permission was already granted.
3. Press ⌃⌥S again, drag a region. Confirm: (a) the PNG lands in the configured save folder as `Fuse Shot <timestamp>.png`; (b) ⌘V pastes the image into Preview/Notes; (c) the shot appears in the clipboard-history paste picker (⇧⌘V); (d) the annotation editor window opens automatically.
4. Press ⌃⌥S and hit **Esc** — confirm nothing is saved, copied, or opened (silent cancel), and the next ⌃⌥S still works.
5. Press ⌃⌥S and tap **spacebar** — window-selection mode; click a window — confirm a shadow-free window shot goes through the same pipeline.

Record the answers before continuing. If permission was granted but captures fail after a rebuild, suspect the §10 TCC ad-hoc-signing gotcha FIRST (remove and re-add Fuse in Privacy & Security → Screen Recording, relaunch).

- [ ] **Step 7: HUMAN-VERIFY — editor**

With an editor window open from a fresh ⌃⌥S capture, ask the human to:
1. Draw an **arrow** (head renders at the drag end), a **rectangle**, an **ellipse**, a **freehand** squiggle, and a **highlighter** stroke (wide, translucent) — dragging in every direction works.
2. Pick the **text** tool, click on the image, type "Hello", press Enter — bold colored text lands at the click point.
3. Press ⌘Z twice — the last two annotations disappear in order.
4. Toggle **Crop**, drag a region, click **Apply Crop** — image trims to the region with annotations baked in.
5. Click **Copy**, paste into Preview (⌘N from clipboard) — annotations are flattened into the pasted image; the edited image also appears in the clipboard history.
6. Click **Save** — the file in the save folder now contains the annotations. **Save As…** writes a second PNG where chosen.

- [ ] **Step 8: HUMAN-VERIFY — recording flow**

Ask the human to:
1. Press ⌃⌥R. The dimmed overlay appears with crosshair cursor and the hint text. Press **Esc** — overlay vanishes, nothing recorded.
2. Press ⌃⌥R, drag a region, release. The REC HUD (red dot + timer) appears top-right and the status menu item now reads **Stop Recording**. Record ~10 seconds of visible motion, then press ⌃⌥R again (or click the HUD's **Stop**, or the menu item). Confirm: (a) the HUD disappears; (b) `Fuse Recording <timestamp>.mov` lands in the save folder and **plays back correctly in QuickTime** (SIGINT finalized the file); (c) the file-URL is in the clipboard history; (d) the trimmer window opens. **If the .mov shows the entire screen instead of the dragged region, `-R` does not combine with `-v` on this macOS — apply the fallback (drop `-R`, record full screen) and write it under `## Deviations`.**
3. Press ⌃⌥R, press **Return** without dragging — full-screen recording starts; stop it; the .mov covers the whole screen.
4. In the trimmer: scrub the player, set start ≈ 25% and end ≈ 75%, click **Export Trimmed**. Confirm `<name> trimmed.mov` appears next to the original, is revealed in Finder, plays only the middle section, and its file-URL is in the clipboard history.
5. **Pause switch:** menu-bar icon → "Pause Fuse" → ⌃⌥S and ⌃⌥R do nothing; the menu's "Capture Region" still works (explicit clicks are user intent, master plan §12). Resume — hotkeys work again.

Record all answers. Debug aid: `log stream --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "capture"' --level debug`.

- [x] **Step 9: Commit**

```bash
git add Sources/Capture/CaptureSettingsView.swift Sources/App/SettingsRootView.swift Sources/App/AppDelegate.swift
git commit -m "feat(capture): settings tab and app wiring for capture hotkeys and menu items"
```

---

### Task 10.9 (OPTIONAL — skip if any earlier task overran): Pixelate tool in the editor

**Files:**
- Modify: `Sources/Capture/ImageEditorModel.swift`
- Modify: `Sources/Capture/ImageEditorView.swift`

CIPixellate over a dragged region, composited into the base image. Like crop, this is **destructive**: the pixelation is baked into `image` immediately (it must hide the underlying pixels permanently, so it can never be a strokeable annotation) and ⌘Z does not undo it. Skip this entire task without guilt if behind schedule — nothing depends on it.

- [x] **Step 1: Add the tool case to `Sources/Capture/ImageEditorModel.swift`**

Edit A — find:

```swift
    case arrow, rectangle, ellipse, freehand, highlighter, text
```

Replace with:

```swift
    case arrow, rectangle, ellipse, freehand, highlighter, text, pixelate
```

Edit B — in `symbolName`, find:

```swift
        case .text: return "textformat"
```

Replace with:

```swift
        case .text: return "textformat"
        case .pixelate: return "squareshape.split.3x3"
```

Edit C — in `AnnotationPaths.path(for:)`, find:

```swift
        case .text:
            break   // drawn as a string by each renderer
```

Replace with:

```swift
        case .text, .pixelate:
            break   // text is drawn as a string; pixelate is baked into the image
```

- [x] **Step 2: Add the drag preview and the CIPixellate application to `Sources/Capture/ImageEditorView.swift`**

Edit A — at the top of the file, find:

```swift
import UniformTypeIdentifiers
```

Replace with:

```swift
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
```

Edit B — in `ImageEditorState`, find:

```swift
    @Published var pendingText: CGPoint?
```

Replace with:

```swift
    @Published var pendingText: CGPoint?
    @Published var pixelatePreview: CGRect?
```

Edit C — in `dragChanged(start:current:)`, find:

```swift
        switch tool {
        case .text:
            break   // text places on dragEnded (a click)
```

Replace with:

```swift
        switch tool {
        case .text:
            break   // text places on dragEnded (a click)
        case .pixelate:
            pixelatePreview = CaptureGeometry.normalizedRect(from: start, to: current)
```

Edit D — in `dragEnded(start:end:)`, find:

```swift
        if tool == .text {
            pendingText = end
            textDraft = ""
            return
        }
```

Replace with:

```swift
        if tool == .text {
            pendingText = end
            textDraft = ""
            return
        }
        if tool == .pixelate {
            let region = CaptureGeometry.normalizedRect(from: start, to: end)
            pixelatePreview = nil
            applyPixelate(in: region)
            return
        }
```

Edit E — add this method to `ImageEditorState`, directly after the `applyCrop()` method:

```swift
    /// Bake a pixelated version of `rect` (image points, top-left origin)
    /// into the base image. Destructive — not undoable, like crop.
    func applyPixelate(in rect: CGRect) {
        guard rect.width >= 2, rect.height >= 2,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let scaleX = CGFloat(cg.width) / image.size.width
        let scaleY = CGFloat(cg.height) / image.size.height
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter.pixellate()
        filter.inputImage = ci
        filter.scale = Float(16 * max(scaleX, 1))
        filter.center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        guard let pixelated = filter.outputImage else { return }
        // CoreImage is BOTTOM-LEFT origin; our rect is top-left — flip Y.
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: CGFloat(cg.height) - rect.maxY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY)
        let composited = pixelated.cropped(to: pixelRect).composited(over: ci)
        let context = CIContext()
        guard let outCG = context.createCGImage(composited, from: ci.extent) else { return }
        image = NSImage(cgImage: outCG, size: image.size)
    }
```

Edit F — in `ImageEditorView`'s `Canvas` closure, find:

```swift
                if state.cropMode, let crop = state.cropRect {
                    context.stroke(Path(crop), with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
```

Replace with:

```swift
                if state.cropMode, let crop = state.cropRect {
                    context.stroke(Path(crop), with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let preview = state.pixelatePreview {
                    context.stroke(Path(preview), with: .color(.gray),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
```

- [x] **Step 3: Regenerate, build, and run the full suite** (the `testAllToolsBuildAPathWithoutCrashing` test from Task 10.6 automatically covers the new case via `CaseIterable`)

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — pixelate**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
⌃⌥S → capture a region containing readable text → in the editor pick the pixelate tool (3×3 grid icon) → drag over the text → on release the region becomes mosaic blocks and the text is unreadable; Copy/Save include the pixelation.

- [x] **Step 5: Commit**

```bash
git add Sources/Capture/ImageEditorModel.swift Sources/Capture/ImageEditorView.swift
git commit -m "feat(capture): pixelate tool via CIPixellate region compositing"
```

---

### Task 10.10: Update the master plan

**Files:**
- Modify: `docs/superpowers/plans/2026-06-11-fuse/00-MASTER.md`

- [x] **Step 1: Add the Capture row to the §1 feature table** — find the Notes row:

```markdown
| 7 | Quick-capture notes panel: hotkey-toggled, block-based (text / code / image / link), per-block copy, Markdown export | Heynote / Apple Quick Note | 8 | `09-phase8-notes.md` |
```

Insert directly AFTER it (before the Packaging row):

```markdown
| 8 | Capture: hotkey screenshots + screen recordings → clipboard + history, annotation editor, video trimmer | CleanShot X | 10 | `11-phase10-capture.md` |
```

- [x] **Step 2: Add the two hotkeys to the §6.3 table** — find the `.toggleNotesPanel` row and insert directly after it:

```markdown
| `.captureRegion` | ⌃⌥S | interactive screenshot (region/window) → save + clipboard + editor |
| `.toggleRecording` | ⌃⌥R | start (region picker) / stop screen recording |
```

- [x] **Step 3: Add the three settings keys to the §6.4 table** — find the `core.didRunBefore` row and insert directly BEFORE it:

```markdown
| `capture.saveFolderPath` | String | `NSHomeDirectory() + "/Desktop"` |
| `capture.copyToClipboard` | Bool | true |
| `capture.openEditorAfter` | Bool | true |
```

- [x] **Step 4: Add `Sources/Capture/` to the §5 tree** — find the line:

```
│   ├── Notes/                           # Phase 8
```

Replace with:

```
│   ├── Notes/                           # Phase 8
│   ├── Capture/                         # Phase 10
```

- [x] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-06-11-fuse/00-MASTER.md
git commit -m "docs(capture): record phase 10 in the master plan contracts"
```

---

## Manual verification checklist

- [ ] **HUMAN-VERIFY** Capture tab visible (camera.viewfinder, between Voice and Downloads); all nine tabs fit with no overflow; General tab shows the Screen Recording row (Task 10.8 Step 6.1).
- [ ] **HUMAN-VERIFY** First ⌃⌥S triggers the Screen Recording permission prompt attributed to **Fuse**; capture works after grant + relaunch (Task 10.8 Step 6.2).
- [ ] **HUMAN-VERIFY** ⌃⌥S region shot → file in save folder + ⌘V pastes it + appears in clipboard-history picker + editor opens (Task 10.8 Step 6.3).
- [ ] **HUMAN-VERIFY** Esc during interactive capture cancels silently — no file, no clipboard write, no editor (Task 10.8 Step 6.4).
- [ ] **HUMAN-VERIFY** Editor: arrow/rect/ellipse/freehand/highlighter in all drag directions; text on Enter; ⌘Z; crop; Copy flattens; Save/Save As (Task 10.8 Step 7).
- [ ] **HUMAN-VERIFY** ⌃⌥R → overlay → drag region → REC HUD with running timer → stop via hotkey/HUD/menu → playable .mov in folder, file-URL in clipboard history, trimmer opens (Task 10.8 Step 8.2).
- [ ] **HUMAN-VERIFY** Return with no drag records the entire screen (Task 10.8 Step 8.3).
- [ ] **HUMAN-VERIFY** Trimmer exports `<name> trimmed.mov` containing only the selected range; revealed in Finder (Task 10.8 Step 8.4).
- [ ] **HUMAN-VERIFY** Pause Fuse silences ⌃⌥S and ⌃⌥R; menu "Capture Region" still works; resume restores hotkeys (Task 10.8 Step 8.5).
- [ ] **HUMAN-VERIFY** (only if Task 10.9 ran) pixelate drag renders unreadable mosaic, included in Copy/Save.
- [x] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (30 new tests: 3 CaptureNamesTests + 7 RegionGeometryTests + 9 RecordingStateMachineTests + 5 AnnotationModelTests + 6 TrimRangeTests, plus the extended HotkeyNamesTests).
- [x] `git log --oneline | head -12` shows the Phase 10 commits (core plumbing, pure helpers, region picker, recording service, controller, editor, trimmer, settings/wiring, master-plan docs; pixelate if run).
- [x] `git status` clean; `ls Sources/Capture` shows: `CaptureController.swift CaptureGeometry.swift CaptureNames.swift CaptureSettingsView.swift ImageEditorModel.swift ImageEditorView.swift RecHUD.swift RecordingService.swift RegionPicker.swift ScreenshotService.swift VideoTrimmer.swift`.

## Risks & gotchas

- **TCC + Screen Recording + ad-hoc signing (master plan §10 — this WILL bite, twice).** Screen Recording grants are cached by code signature AND require an app relaunch to take effect. After any rebuild, a previously granted permission can silently die while System Settings still shows it granted: `screencapture` then writes nothing (screenshots look like Esc-cancels) or records a black/empty movie. Fix: remove Fuse from Privacy & Security → Screen Recording, re-add `.build/Build/Products/Debug/Fuse.app`, relaunch. Suspect this FIRST when captures stop producing files.
- **Permission attribution depends on inheritance.** `screencapture` runs as a child of Fuse and inherits its TCC identity — the prompt and the grant belong to Fuse. If a future refactor launches it via a shell or login-item helper, attribution breaks. Keep `Process.executableURL` pointing straight at `/usr/sbin/screencapture`.
- **`-v` + `-R` combination is the one externally-owned contract.** It works on the development machine (verified in Task 10.0 Step 2), but Apple does not document the pairing's stability across versions. The HUMAN-VERIFY in Task 10.8 Step 8.2 explicitly checks the recorded region; the sanctioned fallback (full-screen `-v`, Deviation note) is one argument removal in `RecordingService.startProcess()`.
- **SIGINT is the contract for finalizing recordings.** `interrupt()` sends SIGINT, which `screencapture` traps to finish writing the .mov. NEVER "upgrade" it to `terminate()` (SIGTERM) or `kill -9` — both can leave an unplayable file. The state machine only finalizes after `processExited`, so the file is complete when the pipeline runs.
- **Esc-cancel detection is file-based, on purpose.** `screencapture -i` exits 0 whether the user captured or cancelled; the ONLY reliable signal is whether the tmpfile exists with size > 0. Do not switch to exit-code checking.
- **Coordinate flips: three spaces are in play.** RegionPicker emits Cocoa (bottom-left) global coords; `screencapture -R` wants top-left global coords (`CaptureGeometry.topLeftRect`, unit-tested — never flip inline); editor annotations live in image-point top-left space matching both SwiftUI Canvas and the `flipped: true` flatten context; CoreImage (pixelate) is bottom-left again. Every conversion in this plan is explicit and commented — keep it that way.
- **The clipboard-history synergy hinges on `markInternal: false`.** Phase 4's watcher skips pasteboard items carrying the Fuse-internal marker. Captures and editor copies must NOT carry it (they are user content, not transient paste plumbing). If captures stop appearing in the picker, check this flag before anything else. Conversely, while Fuse is *paused* the clipboard watcher swallows changes — a capture taken from the still-live menu item during pause will be copied but not recorded in history. Expected, not a bug.
- **Two strokers exist by design.** `AnnotationPaths` is the single geometry source; the Canvas stroker and `drawWithAppKit` are deliberately thin duplicates because `GraphicsContext` and `NSGraphicsContext` cannot share stroke calls. Resist unifying them with a rendering abstraction — that's more code than the duplication.
- **Crop and pixelate are destructive; ⌘Z is annotation-only.** Crop flattens annotations into pixels first (so nothing needs re-anchoring) and clears the annotation list; pixelate composites immediately. This is the v1 contract — do not half-implement an image-level undo stack.
- **`NSImage(size:flipped:drawingHandler:)` + `respectFlipped: true` is the flatten contract.** It gives a top-left-origin context so annotation coordinates are used verbatim. If text or shapes render mirrored, someone removed one of these two flags.
- **Retina scale lives only at the CGImage boundary.** Annotations and crop rects are in points; the point→pixel scale (`cg.width / size.width`) is applied only inside `applyCrop`/`applyPixelate`. A 2x screenshot cropped without scaling silently produces a quarter-size result — the scale lines are load-bearing.
- **The REC HUD can appear inside the recorded region.** It floats top-right of the main screen; a region drawn there records the HUD. Acceptable v1 limitation (CleanShot has the same failure mode with its own UI) — do not add "move the HUD out of the region" logic now.
- **`exportAsynchronously` deprecation.** Deprecated from macOS 15 in favor of async `export(to:as:)`; with deployment target 14.0 it compiles with a warning. If a future SDK hard-errors, migrate minimally and record the Deviation.
- **One interactive session at a time.** `ScreenshotService` ignores ⌃⌥S while a `screencapture -i` is already up, and the recording state machine no-ops events that don't apply (e.g. stop while idle). Mashing hotkeys must never spawn parallel `screencapture` processes.
- **Unretained-callback rule does not apply here, but lifetime still matters.** All `Process.terminationHandler` closures capture `self` weakly and hop to the main queue; `CaptureController` must stay retained by AppDelegate for the whole app lifetime (Task 10.8 Edit A) or in-flight captures lose their callbacks.
- **Settings window width.** Nine tabs at 84 pt need ≥ 772 pt; Task 10.8 Edit E bumps `minWidth` to 800. If a tenth tab ever lands, bump again or shrink the per-tab width — the custom tab bar intentionally never collapses into an overflow menu.

## Deviations

(Recorded by the implementing model — see master plan §9 rule 6.)

- **Task 10.0 Step 4 baseline count:** the suite was 153 tests green (not the "150 as of Phase 9" the plan expected) — the post-Phase-9 clipboard-visuals commit (934dd3e) added 3 tests before this phase started. No action needed; final count is 183.
- **Task 10.10 Step 4 tree-glyph drift:** the master plan §5 tree had `│   └── Notes/` (last entry, `└──`), not the `│   ├── Notes/` the plan quoted. Adapted minimally: Notes changed to `├──` and `│   └── Capture/                         # Phase 10` added as the new last entry.
- **HUMAN-VERIFY steps not executed:** Task 10.8 Steps 5–8, Task 10.9 Step 4, and the entire Manual verification checklist were skipped per the agent execution rules (no app launches, no interactive `screencapture`). They remain unticked for a human to perform — including the `-v -R` region-recording check whose sanctioned fallback (drop `-R`) was NOT needed at build time but is unverified at runtime.
