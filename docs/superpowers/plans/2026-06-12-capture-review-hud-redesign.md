# Capture Review Flow + HUD Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify all floating HUD pills (voice recording, transcribing, video capture controls) into one polished dark-glass design family; replace the post-capture Keep/Delete preview with an edit-in-place review window offering Delete / Delete & Copy / Save / Save & Copy; stop auto-copying captures to the clipboard; fix the video-capture HUD rendering underneath the dim backdrop.

**Architecture:** Shared HUD components (glow dot, equalizer bars, ring, capsule pill buttons) move into a new `Sources/Core/HUDControls.swift` consumed by both `RecordingHUD` (voice) and `RecHUD` (capture). A new `CaptureReviewWindowController` (in `Sources/Capture/CaptureReview.swift`) replaces `CapturePreviewWindowController`, embedding the existing image-editor canvas (screenshots) or a player + trim sliders (recordings) directly, with four explicit exit actions handled by `CaptureController`. Action semantics live in a pure `ReviewAction` enum so they are unit-testable.

**Tech Stack:** Swift 5.10, AppKit + SwiftUI, AVFoundation, XCTest, xcodegen-generated Xcode project (`project.yml`), macOS 14 target.

---

## Build & Test Commands (used throughout)

```bash
# After ADDING or DELETING any file, regenerate the Xcode project first:
xcodegen generate

# Build:
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5

# Run all tests:
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20

# Run one test class:
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/ReviewActionTests 2>&1 | tail -20
```

**CRITICAL — stale-build gotcha:** Fuse is an LSUIElement menu-bar app. Changes are NOT visible until you run `scripts/release.sh`, reinstall the app, and relaunch it. A Debug build alone does not update the running app. Manual verification happens only in Task 12.

---

## Design Decisions (already made — do not re-litigate)

1. **One HUD family.** Every floating pill = dark translucent glass capsule (`hudPillChrome()`), a fixed 24×24 leading indicator, a tracked italic shimmer label, white monospaced digits for timers, and capsule-shaped buttons (red gradient for primary actions, translucent "ghost" for secondary). Recording accents are red, transcribing accents orange (user preference: dark glass only, recording red — light/ivory pills were explicitly rejected).
2. **Recording and Transcribing pills get identical structure** so they read as siblings: `[indicator] [equalizer bars] [shimmer label]`. Recording = red glow dot + red bars + "RECORDING". Transcribing = orange ring + orange bars + "TRANSCRIBING".
3. **No auto-copy.** When the review window is enabled (`capture.showPreviewAfter`, default true), nothing touches the clipboard until the user picks a Copy action. The old `capture.copyToClipboard` toggle only applies in "silent mode" (review window disabled).
4. **Four review actions** (pure enum `ReviewAction`):
   - **Delete** (Esc): trash the file. Nothing copied.
   - **Delete & Copy**: capture lands on the clipboard, file does not stay in the captures folder. Screenshots → flattened PNG bytes on the clipboard, file trashed. Recordings → file moved (or trim-exported) to a temp staging file, that file URL copied, original trashed/gone (a URL to a trashed file would be useless, hence staging).
   - **Save** (⌘S): keep the file (annotations/trim baked in). Nothing copied.
   - **Save & Copy** (Return, primary/prominent button): keep the file (baked) AND copy (screenshots: PNG bytes + file URL; recordings: file URL).
   - Closing the window with the close button = keep the file as it was saved on disk, nothing copied, edits discarded.
5. **Edit-in-place.** The screenshot review window IS the editor (annotation toolbar + canvas always visible — no "Edit…" button). The recording review window IS the trimmer (player + start/end sliders). The separate `ImageEditorWindowController`, `VideoTrimmerWindowController`, and `CapturePreviewWindowController` are deleted.
6. **Z-order fix:** the capture `RecHUD` panel level is raised to `screenSaver + 1` (the region-picker dim overlay stays at `.screenSaver`), so Stop/Start/Cancel are always clearly above the dark backdrop.
7. **Out of scope — do not touch:** `RecHUD.hudOrigin` placement math (and `RecHUDPlacementTests`), `CaptureNames`, `RecordingService`/`RecordingStateMachine`, `VideoRemuxer`, `VoiceController` logic, the region-picker selection behavior.

## File Map

| File | Action | Responsibility after this plan |
|---|---|---|
| `Sources/Core/HUDControls.swift` | **Create** | Shared HUD pieces: `HUDGlowDot`, `HUDEqualizerBars`, `HUDTranscribeRing`, `HUDPillButtonStyle` |
| `Sources/Core/FuseTheme.swift` | Modify | Refined pill chrome (deeper glass, subtler hairline, softer shadow) |
| `Sources/Voice/RecordingHUD.swift` | Modify | Voice pill uses shared components, fixed height |
| `Sources/Capture/RecHUD.swift` | Modify | Capture pill rebuilt with shared components + pill buttons; panel level fix |
| `Sources/Capture/ReviewAction.swift` | **Create** | Pure 4-action enum |
| `Sources/Capture/VideoTrimmer.swift` | Modify | Shrinks to `TrimMath` only (+ new `isNoOp`) |
| `Sources/Capture/VideoExporter.swift` | **Create** | Passthrough trim export, in-place trim |
| `Sources/Capture/ImageEditorView.swift` | Modify | `ImageEditorPane` (toolbar + canvas, no output buttons); window controller deleted |
| `Sources/Capture/ImageEditorModel.swift` | No change | (annotation model stays as is) |
| `Sources/Capture/CaptureReview.swift` | **Create** | Review window: screenshot editor / video trimmer + 4-action bar |
| `Sources/Capture/CapturePreview.swift` | **Delete** | (replaced by CaptureReview) |
| `Sources/Capture/CaptureController.swift` | Modify | Pipeline without auto-copy; review-action side effects |
| `Sources/Capture/CaptureSettingsView.swift` | Modify | Updated toggles + footer copy |
| `Tests/FuseTests/ReviewActionTests.swift` | **Create** | Action semantics |
| `Tests/FuseTests/TrimRangeTests.swift` | Modify | `isNoOp` tests appended |
| `Tests/FuseTests/ImageEncodingTests.swift` | **Create** | Format-aware encoding magic bytes |
| `Tests/FuseTests/VideoExporterTests.swift` | **Create** | Extension → AVFileType mapping |

---

### Task 1: Shared HUD components + chrome refinement

**Files:**
- Create: `Sources/Core/HUDControls.swift`
- Modify: `Sources/Core/FuseTheme.swift:49-68` (HUDPillChrome)

- [ ] **Step 1: Create `Sources/Core/HUDControls.swift`** with exactly this content:

```swift
import SwiftUI

/// Shared building blocks for every floating HUD pill (the voice
/// RecordingHUD and the capture RecHUD). One visual family: dark glass,
/// recording red / transcribe orange accents, shimmer labels, capsule
/// buttons. Every indicator renders in a fixed 24×24 slot so all pills
/// have identical height regardless of state.

/// Pulsing glow dot — the "live" indicator. `hollow` = armed, not yet
/// recording.
struct HUDGlowDot: View {
    var hollow = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 3.0)
            let gradient = LinearGradient(
                colors: [FuseTheme.recordingRedBright, FuseTheme.recordingRed],
                startPoint: .top, endPoint: .bottom)
            ZStack {
                Circle()
                    .fill(FuseTheme.recordingRed.opacity(hollow ? 0 : 0.25 + 0.25 * pulse))
                    .frame(width: 22, height: 22)
                    .blur(radius: 6)
                Group {
                    if hollow {
                        Circle().strokeBorder(gradient, lineWidth: 2.5)
                    } else {
                        Circle().fill(gradient)
                    }
                }
                .frame(width: 12, height: 12)
                .shadow(color: FuseTheme.recordingRed.opacity(0.5 + 0.3 * pulse),
                        radius: 4 + 4 * pulse)
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// Five animated equalizer bars, phase-shifted so they dance independently.
/// Color-parameterized: red while recording, orange while transcribing —
/// same structure in both pills so they read as one family.
struct HUDEqualizerBars: View {
    var bright: Color = FuseTheme.recordingRedBright
    var base: Color = FuseTheme.recordingRed

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    let phase = Double(index) * 0.9
                    let height = 5 + 13 * abs(sin(t * 2.7 + phase) * sin(t * 1.6 + phase * 1.4))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [bright, base],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height)
                }
            }
            .frame(width: 27, height: 24)
        }
    }
}

/// Rotating angular-gradient ring — the transcription spinner (deep orange).
struct HUDTranscribeRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [FuseTheme.transcribeOrange.opacity(0.0),
                                 FuseTheme.transcribeOrange,
                                 FuseTheme.transcribeOrangeDeep],
                        center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 17, height: 17)
                .rotationEffect(.radians(t * 2.6))
                .shadow(color: FuseTheme.transcribeOrange.opacity(0.5), radius: 5)
                .frame(width: 24, height: 24)
        }
    }
}

/// Capsule buttons that live INSIDE a HUD pill — replaces the stock macOS
/// bordered buttons that broke the dark-glass look.
/// `.hudRecordRed` = filled red gradient (Start / Stop).
/// `.hudGhost` = translucent white (Cancel).
struct HUDPillButtonStyle: ButtonStyle {
    enum Kind { case prominent(bright: Color, base: Color), ghost }
    var kind: Kind = .ghost

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 27)
            .background {
                Group {
                    switch kind {
                    case .prominent(let bright, let base):
                        Capsule().fill(LinearGradient(
                            colors: [bright, base],
                            startPoint: .top, endPoint: .bottom))
                    case .ghost:
                        Capsule().fill(Color.white.opacity(0.10))
                    }
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HUDPillButtonStyle {
    static var hudGhost: HUDPillButtonStyle { HUDPillButtonStyle(kind: .ghost) }
    static var hudRecordRed: HUDPillButtonStyle {
        HUDPillButtonStyle(kind: .prominent(bright: FuseTheme.recordingRedBright,
                                            base: FuseTheme.recordingRed))
    }
}
```

- [ ] **Step 2: Refine the pill chrome in `Sources/Core/FuseTheme.swift`.** Replace the body of `HUDPillChrome` (currently lines 49-68) with:

```swift
/// Shared dark-glass pill chrome for HUD content.
struct HUDPillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    HUDBlur()
                    Color.black.opacity(0.28)
                }
                .clipShape(Capsule())
            }
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }
}
```

(Deeper glass = the pill stays legible even when the dim recording backdrop sits behind it; the old 0.40-white top border read harsh and "plasticky".)

- [ ] **Step 3: Regenerate project and build**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/HUDControls.swift Sources/Core/FuseTheme.swift Fuse.xcodeproj
git commit -m "feat(theme): shared HUD components and refined dark-glass pill chrome"
```

---

### Task 2: Restyle the voice RecordingHUD with shared components

**Files:**
- Modify: `Sources/Voice/RecordingHUD.swift`

- [ ] **Step 1: Delete the private `GlowOrb`, `EqualizerBars`, and `TranscribeRing` structs** from `Sources/Voice/RecordingHUD.swift` (lines 17-81). They are superseded by `HUDGlowDot`, `HUDEqualizerBars`, `HUDTranscribeRing` in HUDControls.swift.

- [ ] **Step 2: Replace the `RecordingHUDView` body** (lines 86-119) with:

```swift
    var body: some View {
        HStack(spacing: 12) {
            switch model.display {
            case .hidden:
                EmptyView()
            case .recording:
                HUDGlowDot()
                HUDEqualizerBars()
                ShimmerText(text: "RECORDING",
                            base: FuseTheme.recordingRedBright,
                            highlight: FuseTheme.recordingRedShine)
            case .transcribing:
                HUDTranscribeRing()
                HUDEqualizerBars(bright: FuseTheme.transcribeOrangeShine,
                                 base: FuseTheme.transcribeOrange)
                ShimmerText(text: "TRANSCRIBING",
                            base: FuseTheme.transcribeOrange,
                            highlight: FuseTheme.transcribeOrangeShine)
            case .message(let text):
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(FuseTheme.transcribeOrange)
                    .shadow(color: FuseTheme.transcribeOrange.opacity(0.4), radius: 5)
                Text(text)
                    .font(FuseTheme.hudFont(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 27)   // identical pill height in every state
        .padding(.horizontal, 19)
        .padding(.vertical, 11)
        .hudPillChrome()
        .padding(24)   // room for the shadow inside the borderless panel
    }
```

(Both states now share the structure `[24pt indicator][equalizer bars][shimmer label]` — this is what makes the two pills finally read as the same UI.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Voice/RecordingHUD.swift
git commit -m "feat(voice): recording/transcribing pills share one structure and components"
```

---

### Task 3: Rebuild the capture RecHUD + z-order fix

**Files:**
- Modify: `Sources/Capture/RecHUD.swift`

Do NOT touch `hudOrigin` (lines 111-134) — `RecHUDPlacementTests` covers it.

- [ ] **Step 1: Delete the private `RecPulseDot` struct** (lines 13-36 of `Sources/Capture/RecHUD.swift`) — superseded by `HUDGlowDot`.

- [ ] **Step 2: Replace `RecHUDView`** (lines 38-81) with:

```swift
struct RecHUDView: View {
    @ObservedObject var model: RecHUDModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.mode {
            case .armed:
                HUDGlowDot(hollow: true)
                ShimmerText(text: "READY",
                            base: FuseTheme.recordingRedBright,
                            highlight: FuseTheme.recordingRedShine)
                Button { model.onStart?() } label: {
                    Label("Start", systemImage: "record.circle.fill")
                }
                .buttonStyle(.hudRecordRed)
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.onCancel?() }
                    .buttonStyle(.hudGhost)
                    .keyboardShortcut(.cancelAction)
            case .recording:
                HUDGlowDot()
                ShimmerText(text: "REC",
                            base: FuseTheme.recordingRedBright,
                            highlight: FuseTheme.recordingRedShine)
                Text(model.elapsedText)
                    .font(FuseTheme.hudFont(size: 14, weight: .semibold, italic: false))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                Button { model.onStop?() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.hudRecordRed)
            }
        }
        .frame(minHeight: 27)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .hudPillChrome()
        .padding(20)   // room for the shadow inside the borderless panel
    }
}
```

- [ ] **Step 3: Fix the z-order.** In `presentPanel()` (around line 162), the panel is created with `panel.level = .screenSaver` — the SAME level as the region-picker dim overlay, so the controls can end up underneath the backdrop. Change that line to:

```swift
            // One step ABOVE the region-picker overlay (.screenSaver), so the
            // Stop/Start/Cancel controls always render over the dim backdrop.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
```

Also add, right after the `panel.hidesOnDeactivate = false` line in the same creation block:

```swift
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

- [ ] **Step 4: Build and run placement tests**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/RecHUDPlacementTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **` (placement math untouched)

- [ ] **Step 5: Commit**

```bash
git add Sources/Capture/RecHUD.swift
git commit -m "feat(capture): REC HUD restyled to match voice pills; controls above dim backdrop"
```

---

### Task 4: ReviewAction enum (TDD)

**Files:**
- Create: `Tests/FuseTests/ReviewActionTests.swift`
- Create: `Sources/Capture/ReviewAction.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/FuseTests/ReviewActionTests.swift`:

```swift
import XCTest
@testable import Fuse

final class ReviewActionTests: XCTestCase {
    func testFourActionsExist() {
        XCTAssertEqual(ReviewAction.allCases.count, 4)
    }

    func testKeepsFile() {
        XCTAssertFalse(ReviewAction.delete.keepsFile)
        XCTAssertFalse(ReviewAction.deleteAndCopy.keepsFile)
        XCTAssertTrue(ReviewAction.save.keepsFile)
        XCTAssertTrue(ReviewAction.saveAndCopy.keepsFile)
    }

    func testCopiesToClipboard() {
        XCTAssertFalse(ReviewAction.delete.copiesToClipboard)
        XCTAssertTrue(ReviewAction.deleteAndCopy.copiesToClipboard)
        XCTAssertFalse(ReviewAction.save.copiesToClipboard)
        XCTAssertTrue(ReviewAction.saveAndCopy.copiesToClipboard)
    }

    func testTitles() {
        XCTAssertEqual(ReviewAction.delete.title, "Delete")
        XCTAssertEqual(ReviewAction.deleteAndCopy.title, "Delete & Copy")
        XCTAssertEqual(ReviewAction.save.title, "Save")
        XCTAssertEqual(ReviewAction.saveAndCopy.title, "Save & Copy")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/ReviewActionTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'ReviewAction' in scope`

- [ ] **Step 3: Implement.** Create `Sources/Capture/ReviewAction.swift`:

```swift
import Foundation

/// The four ways out of the post-capture review window. Pure data — the
/// side effects (trash, clipboard, trim export) live in CaptureController.
enum ReviewAction: String, CaseIterable {
    case delete, deleteAndCopy, save, saveAndCopy

    /// Does the capture file stay in the user's captures folder?
    var keepsFile: Bool {
        switch self {
        case .save, .saveAndCopy: return true
        case .delete, .deleteAndCopy: return false
        }
    }

    /// Does the capture land on the system clipboard?
    var copiesToClipboard: Bool {
        switch self {
        case .deleteAndCopy, .saveAndCopy: return true
        case .delete, .save: return false
        }
    }

    var title: String {
        switch self {
        case .delete: return "Delete"
        case .deleteAndCopy: return "Delete & Copy"
        case .save: return "Save"
        case .saveAndCopy: return "Save & Copy"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/ReviewActionTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Capture/ReviewAction.swift Tests/FuseTests/ReviewActionTests.swift Fuse.xcodeproj
git commit -m "feat(capture): ReviewAction enum for the four post-capture actions"
```

---

### Task 5: TrimMath.isNoOp (TDD)

**Files:**
- Modify: `Tests/FuseTests/TrimRangeTests.swift`
- Modify: `Sources/Capture/VideoTrimmer.swift:7-17` (TrimMath)

- [ ] **Step 1: Write the failing tests.** Append inside the `TrimRangeTests` class in `Tests/FuseTests/TrimRangeTests.swift`:

```swift
    func testFullRangeIsNoOp() {
        XCTAssertTrue(TrimMath.isNoOp(start: 0, end: 1))
    }

    func testNearFullRangeIsNoOp() {
        XCTAssertTrue(TrimMath.isNoOp(start: 0.0005, end: 0.9999))
    }

    func testTrimmedStartIsNotNoOp() {
        XCTAssertFalse(TrimMath.isNoOp(start: 0.1, end: 1))
    }

    func testTrimmedEndIsNotNoOp() {
        XCTAssertFalse(TrimMath.isNoOp(start: 0, end: 0.9))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/TrimRangeTests 2>&1 | tail -10`
Expected: FAIL — `type 'TrimMath' has no member 'isNoOp'`

- [ ] **Step 3: Implement.** Add inside `enum TrimMath` in `Sources/Capture/VideoTrimmer.swift`:

```swift
    /// True when the slider range is effectively the whole clip — Save can
    /// skip the export entirely.
    static func isNoOp(start: Double, end: Double, epsilon: Double = 0.001) -> Bool {
        start <= epsilon && end >= 1 - epsilon
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/TrimRangeTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Capture/VideoTrimmer.swift Tests/FuseTests/TrimRangeTests.swift
git commit -m "feat(capture): TrimMath.isNoOp detects full-range (no-trim) slider state"
```

---

### Task 6: Format-aware image encoding + dirty tracking in ImageEditorState (TDD)

**Files:**
- Create: `Tests/FuseTests/ImageEncodingTests.swift`
- Modify: `Sources/Capture/ImageEditorView.swift` (ImageEditorState)

This also fixes a latent bug: `save()` always wrote PNG data even when the capture file is `.jpg`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/FuseTests/ImageEncodingTests.swift`:

```swift
import AppKit
import XCTest
@testable import Fuse

final class ImageEncodingTests: XCTestCase {
    private func solidImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    func testPNGExtensionProducesPNGMagicBytes() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "png")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testJPGExtensionProducesJPEGMagicBytes() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "jpg")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(2)), [0xFF, 0xD8])
    }

    func testJPEGExtensionUppercaseAlsoJPEG() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "JPEG")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(2)), [0xFF, 0xD8])
    }

    func testUnknownExtensionFallsBackToPNG() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "webp")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/ImageEncodingTests 2>&1 | tail -10`
Expected: FAIL — `type 'ImageEditorState' has no member 'imageData'`

- [ ] **Step 3: Implement in `ImageEditorState`** (`Sources/Capture/ImageEditorView.swift`):

3a. Add two properties right below `@Published var textDraft = ""` (line 31):

```swift
    /// True once crop or pixelate has baked into the bitmap — edits that
    /// don't live in `annotations`.
    private(set) var pixelsDirty = false
```

3b. Set the flag: add `pixelsDirty = true` as the LAST line of `applyCrop()` (after `cropMode = false`) and as the LAST line of `applyPixelate(in:)` (after `image = NSImage(cgImage: outCG, size: image.size)`).

3c. Add a pristine check right below the new `pixelsDirty` property:

```swift
    /// Nothing to bake — Save can leave the file on disk untouched.
    var isPristine: Bool { annotations.isEmpty && inProgress == nil && !pixelsDirty }
```

3d. Replace the existing `static func pngData(of:)` (lines 203-207) with a format-aware encoder:

```swift
    /// Encodes for the given file extension: jpg/jpeg → JPEG (0.9), anything
    /// else → PNG. The capture file's own extension decides — never write
    /// PNG bytes into a .jpg file.
    static func imageData(of image: NSImage, forPathExtension ext: String) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if ["jpg", "jpeg"].contains(ext.lowercased()) {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// PNG of the flattened image — what Copy actions put on the clipboard.
    func clipboardImageData() -> Data? {
        Self.imageData(of: flattened(), forPathExtension: "png")
    }
```

3e. Update the three existing callers of `pngData` inside the same file:
- `copyFlattened()`: change `Self.pngData(of: flattened())` → `clipboardImageData()` body, i.e. replace the whole method with:

```swift
    func copyFlattened() {
        guard let data = clipboardImageData() else { return }
        // markInternal: false — clipboard history records the edited image too.
        PasteService.write([[.png: data]], markInternal: false)
    }
```

- `save()`: replace with:

```swift
    func save() {
        guard let data = Self.imageData(of: flattened(),
                                        forPathExtension: fileURL.pathExtension) else { return }
        do {
            try data.write(to: fileURL)
            Log.capture.info("editor saved over \(self.fileURL.path, privacy: .public)")
        } catch {
            Log.capture.error("editor save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
```

- `saveAs()`: change its first line to `guard let data = Self.imageData(of: flattened(), forPathExtension: "png") else { return }` (this method is deleted in Task 10 anyway; this just keeps the build green).

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/ImageEncodingTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Capture/ImageEditorView.swift Tests/FuseTests/ImageEncodingTests.swift Fuse.xcodeproj
git commit -m "feat(capture): format-aware image encoding + pristine tracking in editor state"
```

---

### Task 7: Extract ImageEditorPane (editor without output buttons)

**Files:**
- Modify: `Sources/Capture/ImageEditorView.swift` (the `ImageEditorView` struct, lines 241-368)

The review window needs the toolbar + canvas WITHOUT Copy/Save/Save As… (those become the four action buttons). Keep the build green by making the old `ImageEditorView` a thin wrapper — it is deleted in Task 10.

- [ ] **Step 1: Rename and trim.** In `Sources/Capture/ImageEditorView.swift`:

1a. Rename `struct ImageEditorView: View` to `struct ImageEditorPane: View` (keep `@ObservedObject var state` and `@FocusState` as they are).

1b. In its `toolbar` view, DELETE these three trailing buttons (keep the `Spacer()`):

```swift
            Button("Copy") { state.copyFlattened() }
            Button("Save") { state.save() }
            Button("Save As…") { state.saveAs() }
```

1c. Remove the `.frame(minWidth: 680, minHeight: 440)` from the pane's `body` (sizing now belongs to the window that embeds the pane).

1d. Add a temporary wrapper directly below the pane struct so `ImageEditorWindowController` still compiles (deleted in Task 10):

```swift
/// Transitional wrapper — removed when the standalone editor window goes
/// away in favor of the capture review window.
struct ImageEditorView: View {
    @ObservedObject var state: ImageEditorState
    var body: some View {
        ImageEditorPane(state: state)
            .frame(minWidth: 680, minHeight: 440)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Capture/ImageEditorView.swift
git commit -m "refactor(capture): extract ImageEditorPane (toolbar+canvas, no output buttons)"
```

---

### Task 8: VideoExporter (TDD on the pure part)

**Files:**
- Create: `Tests/FuseTests/VideoExporterTests.swift`
- Create: `Sources/Capture/VideoExporter.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/FuseTests/VideoExporterTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import Fuse

final class VideoExporterTests: XCTestCase {
    func testFileTypeMapping() {
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "mp4"), .mp4)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "MP4"), .mp4)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "mov"), .mov)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: ""), .mov)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/VideoExporterTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'VideoExporter' in scope`

- [ ] **Step 3: Implement.** Create `Sources/Capture/VideoExporter.swift`:

```swift
import AVFoundation

/// Trim export for finished recordings: passthrough preset (same streams,
/// no re-encode, fast — same approach as VideoRemuxer), output container
/// matched to the destination's extension.
enum VideoExporter {
    static func fileType(forPathExtension ext: String) -> AVFileType {
        ext.lowercased() == "mp4" ? .mp4 : .mov
    }

    /// Exports `range` of the movie at `source` to `destination`
    /// (overwriting it). Calls back on the main queue with success.
    static func exportTrimmed(source: URL, range: CMTimeRange, to destination: URL,
                              completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(false)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = fileType(forPathExtension: destination.pathExtension)
        session.timeRange = range
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status != .completed {
                    Log.capture.error("trim export failed: \(String(describing: session.error), privacy: .public)")
                }
                completion(session.status == .completed)
            }
        }
    }

    /// Trims the movie at `url` IN PLACE: exports the range to a hidden
    /// sibling temp file, then atomically replaces `url`. The export can't
    /// write onto the file it is reading, hence the two-step.
    static func trimInPlace(url: URL, range: CMTimeRange,
                            completion: @escaping (Bool) -> Void) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".fuse-trim-\(UUID().uuidString).\(url.pathExtension)")
        exportTrimmed(source: url, range: range, to: tmp) { ok in
            guard ok else {
                completion(false)
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                completion(true)
            } catch {
                Log.capture.error("trim replace failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: tmp)
                completion(false)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test -only-testing:FuseTests/VideoExporterTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Capture/VideoExporter.swift Tests/FuseTests/VideoExporterTests.swift Fuse.xcodeproj
git commit -m "feat(capture): VideoExporter — passthrough trim export and in-place trim"
```

---

### Task 9: The CaptureReview window

**Files:**
- Create: `Sources/Capture/CaptureReview.swift`

This file is purely additive (nothing references it yet) — the wiring happens in Task 10.

- [ ] **Step 1: Create `Sources/Capture/CaptureReview.swift`** with exactly this content:

```swift
import AppKit
import AVKit
import CoreMedia
import SwiftUI

/// Callback box so CaptureController can wire the action handler AFTER the
/// window (and the SwiftUI views referencing this object) exist — same
/// pattern as the old CapturePreviewActions / RecHUDModel.
final class ReviewActionRelay: ObservableObject {
    var onAction: ((ReviewAction) -> Void)?
}

/// Trim state for the recording review: player + fractional start/end.
final class VideoReviewState: ObservableObject {
    let fileURL: URL
    let player: AVPlayer
    @Published var start: Double = 0
    @Published var end: Double = 1
    @Published var durationSeconds: Double = 0

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

    /// nil when the sliders are at (effectively) full range or the range is
    /// invalid — Save skips the export entirely.
    var pendingTrim: CMTimeRange? {
        guard durationSeconds > 0,
              !TrimMath.isNoOp(start: start, end: end) else { return nil }
        return TrimMath.trimRange(start: start, end: end, duration: durationSeconds)
    }
}

/// The four-way exit row shown at the bottom of both review windows.
/// `shortcutsEnabled: false` while a text annotation is being typed, so
/// Return/Esc go to the text field instead of firing actions.
struct ReviewActionBar: View {
    var shortcutsEnabled = true
    var onAction: (ReviewAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { onAction(.delete) } label: {
                Label(ReviewAction.delete.title, systemImage: "trash")
            }
            .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.escape) : nil)

            Button { onAction(.deleteAndCopy) } label: {
                Label(ReviewAction.deleteAndCopy.title, systemImage: "trash.square")
            }

            Spacer()

            Text("Return = Save & Copy · Esc = Delete")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button { onAction(.save) } label: {
                Label(ReviewAction.save.title, systemImage: "internaldrive")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button { onAction(.saveAndCopy) } label: {
                Label(ReviewAction.saveAndCopy.title, systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return) : nil)
        }
        .controlSize(.large)
    }
}

/// Screenshot review = the annotation editor with the action bar under it.
/// No "Edit…" step: draw, crop, pixelate immediately, then pick an exit.
struct ScreenshotReviewView: View {
    @ObservedObject var state: ImageEditorState
    var onAction: (ReviewAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ImageEditorPane(state: state)
            Divider()
            ReviewActionBar(shortcutsEnabled: state.pendingText == nil,
                            onAction: onAction)
                .padding(12)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

/// Recording review = player + trim sliders with the action bar under it.
struct VideoReviewView: View {
    @ObservedObject var state: VideoReviewState
    var onAction: (ReviewAction) -> Void

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
            ReviewActionBar(onAction: onAction)
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { state.player.play() }
    }

    private func timeLabel(_ fraction: Double) -> String {
        let s = Int(fraction * state.durationSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Floating window shown after every capture (when enabled). Owns the
/// window + per-kind edit state; the action side effects live in
/// CaptureController.
final class CaptureReviewWindowController {
    private let window: NSWindow
    private let relay: ReviewActionRelay
    private var closeObserver: NSObjectProtocol?
    /// Set for screenshots — exposes annotations/crop to CaptureController.
    let imageState: ImageEditorState?
    /// Set for recordings — exposes the pending trim range.
    let videoState: VideoReviewState?

    var onAction: ((ReviewAction) -> Void)? {
        get { relay.onAction }
        set { relay.onAction = newValue }
    }
    var onClose: (() -> Void)?

    /// nil when a screenshot file can't be read — nothing to review (the
    /// file is already saved on disk; the pipeline just skips the window).
    init?(fileURL: URL, kind: CaptureKind) {
        let relay = ReviewActionRelay()
        self.relay = relay
        let hosting: NSView
        switch kind {
        case .screenshot:
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            let state = ImageEditorState(image: image, fileURL: fileURL)
            imageState = state
            videoState = nil
            hosting = NSHostingView(rootView: ScreenshotReviewView(state: state) {
                relay.onAction?($0)
            })
        case .recording:
            let state = VideoReviewState(fileURL: fileURL)
            imageState = nil
            videoState = state
            hosting = NSHostingView(rootView: VideoReviewView(state: state) {
                relay.onAction?($0)
            })
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.videoState?.player.pause()
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

    func close() {
        window.close()
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Capture/CaptureReview.swift Fuse.xcodeproj
git commit -m "feat(capture): review window — edit-in-place editor/trimmer with four exit actions"
```

---

### Task 10: Rewire CaptureController; delete the old preview/editor/trimmer windows

**Files:**
- Modify: `Sources/Capture/CaptureController.swift`
- Delete: `Sources/Capture/CapturePreview.swift`
- Modify: `Sources/Capture/ImageEditorView.swift` (remove wrapper + window controller + dead methods)
- Modify: `Sources/Capture/VideoTrimmer.swift` (keep only TrimMath)

- [ ] **Step 1: Rewire `CaptureController.swift`.**

1a. Replace the three window arrays (lines 11-13):

```swift
    private var imageEditors: [ImageEditorWindowController] = []
    private var videoTrimmers: [VideoTrimmerWindowController] = []
    private var previews: [CapturePreviewWindowController] = []
```

with:

```swift
    private var reviews: [CaptureReviewWindowController] = []
```

1b. Replace the clipboard/preview section of `runOutputPipeline` (the lines from `var clipboardChangeCount: Int?` through the `showPreview(...)` call) with:

```swift
        // The review window owns all clipboard decisions now — nothing is
        // copied until the user picks a Copy action. Auto-copy only applies
        // in silent mode (review window disabled).
        if defaults.bool(forKey: "capture.showPreviewAfter") {
            showReview(for: dest, kind: kind)
        } else if defaults.bool(forKey: "capture.copyToClipboard") {
            copyToClipboard(dest, kind: kind)
        }
```

1c. Replace `showPreview(for:kind:clipboardChangeCount:)` and `discardCapture(at:kind:clipboardChangeCount:)` entirely (lines 164-213) with:

```swift
    // MARK: - Post-capture review (Delete / Delete & Copy / Save / Save & Copy)

    private func showReview(for url: URL, kind: CaptureKind) {
        guard let review = CaptureReviewWindowController(fileURL: url, kind: kind) else {
            return   // unreadable screenshot — already saved; nothing to review
        }
        review.onAction = { [weak self, weak review] action in
            guard let self, let review else { return }
            self.perform(action, on: url, kind: kind, review: review)
        }
        review.onClose = { [weak self, weak review] in
            self?.reviews.removeAll { $0 === review }
        }
        reviews.append(review)
        review.show()
    }

    private func perform(_ action: ReviewAction, on url: URL, kind: CaptureKind,
                         review: CaptureReviewWindowController) {
        switch kind {
        case .screenshot:
            performScreenshotAction(action, on: url, state: review.imageState)
            review.close()
        case .recording:
            performRecordingAction(action, on: url, state: review.videoState,
                                   review: review)
        }
    }

    private func performScreenshotAction(_ action: ReviewAction, on url: URL,
                                         state: ImageEditorState?) {
        // Bake annotations/crop BEFORE copying so a copied file URL points
        // at the final pixels.
        if action.keepsFile, let state, !state.isPristine {
            state.save()
        }
        if action.copiesToClipboard, let state,
           let data = state.clipboardImageData() {
            var items: [[NSPasteboard.PasteboardType: Data]] = [[.png: data]]
            if action.keepsFile {
                items.append([Self.fileURLType: url.dataRepresentation])
            }
            // markInternal: false is LOAD-BEARING — Fuse's own clipboard
            // history must record this item (the watcher skips marked items).
            PasteService.write(items, markInternal: false)
        }
        if !action.keepsFile {
            trashCapture(at: url)
        }
    }

    private func performRecordingAction(_ action: ReviewAction, on url: URL,
                                        state: VideoReviewState?,
                                        review: CaptureReviewWindowController) {
        state?.player.pause()
        let trim = state?.pendingTrim

        func finish(copying fileURL: URL?) {
            if action.copiesToClipboard, let fileURL {
                PasteService.write([[Self.fileURLType: fileURL.dataRepresentation]],
                                   markInternal: false)
            }
            review.close()
        }

        if action.keepsFile {
            if let trim {
                VideoExporter.trimInPlace(url: url, range: trim) { _ in
                    finish(copying: url)   // trim failure still keeps the original
                }
            } else {
                finish(copying: url)
            }
            return
        }

        // Delete variants.
        guard action.copiesToClipboard else {
            trashCapture(at: url)
            finish(copying: nil)
            return
        }
        // Delete & Copy: a clipboard file URL must stay readable, so the
        // clip is staged in the temp directory (the OS cleans it up later)
        // instead of the recordings folder.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuse-clip-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: staged)
        if let trim {
            VideoExporter.exportTrimmed(source: url, range: trim, to: staged) { [weak self] ok in
                self?.trashCapture(at: url)
                finish(copying: ok ? staged : nil)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: url, to: staged)
                finish(copying: staged)
            } catch {
                Log.capture.error("failed to stage clip for clipboard: \(error.localizedDescription, privacy: .public)")
                finish(copying: nil)
            }
        }
    }

    private func trashCapture(at url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Log.capture.info("capture discarded to Trash: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.capture.error("failed to trash capture: \(error.localizedDescription, privacy: .public)")
        }
    }
```

1d. Delete the whole `openInEditor(_:kind:)` method (lines 232-252). Keep `copyToClipboard(_:kind:)` (still used by silent mode) and keep `Self.fileURLType`.

- [ ] **Step 2: Delete the replaced windows.**

2a. Delete the file `Sources/Capture/CapturePreview.swift` (`git rm Sources/Capture/CapturePreview.swift`).

2b. In `Sources/Capture/ImageEditorView.swift`: delete the transitional `struct ImageEditorView` wrapper (added in Task 7), the `final class ImageEditorWindowController` (whole class at the bottom of the file), and the now-unused `copyFlattened()` and `saveAs()` methods from `ImageEditorState`. Keep `save()`, `flattened()`, `clipboardImageData()`, `imageData(of:forPathExtension:)`, `isPristine`, `pixelsDirty`.

2c. In `Sources/Capture/VideoTrimmer.swift`: delete `final class VideoTrimmerState`, `struct VideoTrimmerView`, and `final class VideoTrimmerWindowController`. The file keeps ONLY the imports it still needs (`import CoreMedia`) and `enum TrimMath` (with `trimRange` and `isNoOp`). Update the header comment to: `/// Pure slider math shared by the recording review window.`

- [ ] **Step 3: Regenerate, build, run the FULL test suite**

Run: `xcodegen generate && xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` — all suites including the pre-existing ones (TrimRangeTests still compiles because TrimMath survived).

- [ ] **Step 4: Commit**

```bash
git add -A Sources/Capture Fuse.xcodeproj
git commit -m "feat(capture): four-action review flow replaces Keep/Delete preview; no auto-copy"
```

---

### Task 11: Settings copy update

**Files:**
- Modify: `Sources/Capture/CaptureSettingsView.swift:57-65`

- [ ] **Step 1: Update the toggles and footer.** Replace:

```swift
                Toggle("Copy capture to clipboard", isOn: $copyToClipboard)
                Toggle("Show preview after capture", isOn: $showPreviewAfter)
```

with:

```swift
                Toggle("Show review window after capture", isOn: $showPreviewAfter)
                Toggle("Auto-copy to clipboard (only when review is off)",
                       isOn: $copyToClipboard)
                    .disabled(showPreviewAfter)
```

and replace the footer `Text(...)` content with:

```swift
                Text("The review window lets you annotate screenshots and trim recordings, then choose Delete, Delete & Copy, Save, or Save & Copy (Return = Save & Copy, Esc = Delete, ⌘S = Save). Nothing is copied to the clipboard unless you pick a Copy action. With the review window off, captures save silently — enable auto-copy to also place them on the clipboard.")
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Capture/CaptureSettingsView.swift
git commit -m "feat(capture): settings copy for the review-window flow"
```

---

### Task 12: Full verification + release build + manual QA

- [ ] **Step 1: Full test suite**

Run: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Release build + reinstall + relaunch** (REQUIRED — the running LSUIElement app does not pick up changes otherwise):

```bash
scripts/release.sh
```

Then reinstall the produced app (follow whatever install step `release.sh` prints / copies into `dist/`), quit the running Fuse from the menu bar, and launch the new build.

- [ ] **Step 3: Manual QA checklist** (report each item pass/fail):

1. **Voice pills**: trigger voice recording → dark glass pill: red glow dot + red equalizer bars + shimmering "RECORDING". Release → same-shaped pill: orange ring + orange bars + shimmering "TRANSCRIBING". Both pills the same height, same chrome.
2. **Capture armed HUD**: start a recording (hotkey) and drag a region → pill shows hollow red dot + "READY" + red capsule **Start** + ghost **Cancel** (no stock macOS buttons anywhere).
3. **Backdrop z-order**: click Start → the recording pill (red dot, "REC", timer, red capsule **Stop**) is clearly ABOVE the dim backdrop, not muddied underneath it.
4. **Screenshot review**: capture a region → clipboard does NOT change (paste in another app to confirm) → review window opens with annotation toolbar + canvas immediately usable. Draw an arrow, then **Save & Copy** → file in `~/Pictures/Fuse Screenshots` contains the arrow, pasting yields the annotated image.
5. **Screenshot Delete**: capture → **Delete** (or Esc) → file in Trash, clipboard untouched.
6. **Screenshot Delete & Copy**: capture, draw something → **Delete & Copy** → file in Trash, pasting yields the annotated image.
7. **Recording review**: record a short clip → review window opens with player + start/end sliders + the same four buttons. Trim to a sub-range → **Save** → saved file in `~/Movies/Fuse Recordings` has the shorter duration; clipboard untouched.
8. **Recording Save & Copy**: record → **Save & Copy** without trimming → file kept, pasting in Finder produces the movie file.
9. **Recording Delete & Copy**: record → **Delete & Copy** → recordings folder does not keep the file, pasting in Finder still produces a playable movie (staged temp file).
10. **Window close button** on either review window → file stays as saved, nothing copied.
11. **Silent mode**: Settings → Capture → turn "Show review window" off, auto-copy on → capture → file saved + clipboard updated, no window. Turn the review window back on afterwards.
12. **Text annotation Return-safety**: in the screenshot review, choose the text tool, click the canvas, type a word — pressing Return commits the text and does NOT trigger Save & Copy; a second Return (with no text field open) does.

- [ ] **Step 4: Final commit if QA fixes were needed; otherwise done.**

---

## Self-Review Notes (already applied)

- `TrimRangeTests` keeps compiling after Task 10 because `TrimMath` (with `isNoOp`) survives in `VideoTrimmer.swift`.
- `RecHUDPlacementTests` is untouched: Tasks 3 changes only the view + panel level, never `hudOrigin`.
- `ImageEditorState.imageData` is introduced in Task 6 and consumed in Tasks 9/10 under the same name/signature.
- `ReviewAction` flags drive `performScreenshotAction`/`performRecordingAction`; titles are reused by `ReviewActionBar` labels.
- Every new file (`HUDControls.swift`, `ReviewAction.swift`, `VideoExporter.swift`, `CaptureReview.swift`, two test files) is followed by `xcodegen generate` before building.
