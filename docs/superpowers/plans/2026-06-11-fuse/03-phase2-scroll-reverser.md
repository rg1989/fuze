# Phase 2: Scroll Direction Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** Replace Scroll Reverser: reverse scroll direction independently per device class — "natural" scrolling on the trackpad/Magic Mouse while a classic mouse wheel scrolls the traditional way (or any other combination). A session-wide modifying `CGEventTap` intercepts every scroll-wheel event, classifies it as continuous (trackpad & Magic Mouse) or line-based (classic wheel), and negates its delta fields according to four user settings. Direction math is a pure, fully unit-tested function; only the thin tap wrapper is OS-integration code verified by a human.

**Architecture:** Four new files in `Sources/ScrollControl/`, layered so the testable surface is maximal. `ScrollSettings` is an immutable snapshot of the four `scroll.*` UserDefaults values. `ScrollTransformer.transform(_:source:settings:)` is a pure function from `(deltas, device class, settings)` to either rewritten deltas or `nil` (= pass through) — this is the TDD centerpiece. `ScrollEventTapController` (in `ScrollEventTap.swift`) owns the `CGEventTap` on the main run loop, keeps a cached `ScrollSettings` snapshot so the hot path never touches UserDefaults, waits for Accessibility permission with a 5-second retry timer, and re-enables the tap when the OS disables it. `ScrollSettingsView` is a SwiftUI Form bound via `@AppStorage`. Integration with shared files happens ONLY at the master-plan §6.1 anchors in `AppDelegate.swift` and `SettingsRootView.swift`. No hotkeys are needed for this feature.

**Tech Stack:** CoreGraphics `CGEventTap` (via AppKit), Foundation `UserDefaults`/`Timer`/`NotificationCenter`, SwiftUI `@AppStorage`, XCTest. Core APIs consumed: `PermissionsService.hasAccessibility`, `PermissionsService.promptForAccessibility()`, `PermissionsService.openSystemSettings(pane:)`, `Log.scroll` (all from Phase 1).

**Known limitation (state it, don't fight it):** macOS reports trackpads AND Magic Mice as *continuous* scroll devices; classic wheels as *line-based*. Without per-device IOKit identification (explicitly out of scope for v1), Fuse treats trackpad + Magic Mouse as one class controlled by the "trackpad" toggle. The settings UI says so.

---

### Task 2.0: Preflight — verify Phases 0–1 are in place

**Files:**
- None created or modified. Verification only.

- [ ] **Step 1: Verify Phase 1 Core files exist**

```bash
ls /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core
```
Expected output contains all five files (order may differ): `AX.swift`, `HotkeyNames.swift`, `Log.swift`, `PasteService.swift`, `Permissions.swift`. If any are missing, STOP — Phase 1 is not complete. Do not proceed.

- [ ] **Step 2: Verify the integration anchors exist**

```bash
grep -n "FUSE:CONTROLLER-PROPS\|FUSE:CONTROLLER-START" /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/AppDelegate.swift
grep -n "FUSE:SETTINGS_TABS" /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/SettingsRootView.swift
```
Expected: the first command prints two lines (one per anchor), the second prints one line. If any anchor is missing, STOP and restore it from the Phase 0 plan before continuing.

- [ ] **Step 3: Verify the build is green**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the tests are green**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`. If red, STOP and fix Phase 0/1 first — never build a feature on a red base.

---

### Task 2.1: ScrollSettings — snapshot of the four scroll preferences (TDD)

**Files:**
- Create: `Sources/ScrollControl/ScrollSettings.swift`
- Test: `Tests/FuseTests/ScrollTransformerTests.swift` (created here; Task 2.2 appends to it)

Why a snapshot struct: the event-tap hot path must never read UserDefaults (latency), and the pure transformer must be testable without global state. `ScrollSettings.current(defaults:)` reads the four master-plan §6.4 keys with their exact defaults: `"scroll.enabled"` (Bool, default **true**), `"scroll.reverseTrackpad"` (Bool, default **true**), `"scroll.reverseMouse"` (Bool, default **true**), `"scroll.reverseHorizontal"` (Bool, default **false**). Defaults are applied via an `object(forKey:) == nil` check because `UserDefaults.bool(forKey:)` alone returns `false` for missing keys, which would silently flip three of the four defaults.

- [ ] **Step 1: Write the failing tests — create `Tests/FuseTests/ScrollTransformerTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

// Tests for the scroll feature's pure logic: ScrollSettings (this task)
// and ScrollTransformer (Task 2.2 appends its test class below).

final class ScrollSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "FuseTests.ScrollSettings"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNoKeysWereEverWritten() {
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.reverseTrackpad)
        XCTAssertTrue(s.reverseMouse)
        XCTAssertFalse(s.reverseHorizontal)
    }

    func testReadsExplicitlySetFalseValues() {
        defaults.set(false, forKey: "scroll.enabled")
        defaults.set(false, forKey: "scroll.reverseTrackpad")
        defaults.set(false, forKey: "scroll.reverseMouse")
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.reverseTrackpad)
        XCTAssertFalse(s.reverseMouse)
        XCTAssertFalse(s.reverseHorizontal)
    }

    func testReadsExplicitlySetTrueHorizontal() {
        defaults.set(true, forKey: "scroll.reverseHorizontal")
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertTrue(s.reverseHorizontal)
    }

    func testRegisterDefaultsSeedsAllFourKeys() {
        ScrollSettings.registerDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "scroll.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "scroll.reverseTrackpad"))
        XCTAssertTrue(defaults.bool(forKey: "scroll.reverseMouse"))
        XCTAssertFalse(defaults.bool(forKey: "scroll.reverseHorizontal"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'ScrollSettings' in scope` (a compile failure is this step's "red"). If it instead succeeds, the test file was not picked up — re-run `xcodegen generate` and check the file path.

- [ ] **Step 3: Implement — create `Sources/ScrollControl/ScrollSettings.swift` with exactly this content**

```swift
import Foundation

/// Immutable snapshot of the four scroll-related UserDefaults values
/// (master plan §6.4). The event-tap hot path reads a cached snapshot instead
/// of UserDefaults, and the pure ScrollTransformer takes a snapshot parameter
/// so it is fully unit-testable.
struct ScrollSettings: Equatable {
    var enabled: Bool
    var reverseTrackpad: Bool
    var reverseMouse: Bool
    var reverseHorizontal: Bool

    /// Read current values. Keys that have never been written fall back to the
    /// master-plan defaults: enabled/reverseTrackpad/reverseMouse = true,
    /// reverseHorizontal = false. The `object(forKey:) == nil` check is
    /// load-bearing: `bool(forKey:)` alone returns false for missing keys.
    static func current(defaults: UserDefaults = .standard) -> ScrollSettings {
        ScrollSettings(
            enabled: bool("scroll.enabled", default: true, in: defaults),
            reverseTrackpad: bool("scroll.reverseTrackpad", default: true, in: defaults),
            reverseMouse: bool("scroll.reverseMouse", default: true, in: defaults),
            reverseHorizontal: bool("scroll.reverseHorizontal", default: false, in: defaults))
    }

    /// Seed the registration domain so @AppStorage in ScrollSettingsView and
    /// `current(defaults:)` agree before the user ever opens the Scroll tab.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "scroll.enabled": true,
            "scroll.reverseTrackpad": true,
            "scroll.reverseMouse": true,
            "scroll.reverseHorizontal": false,
        ])
    }

    private static func bool(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, and the log lists all four `ScrollSettingsTests` tests as passed alongside the pre-existing Phase 0/1 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScrollControl/ScrollSettings.swift Tests/FuseTests/ScrollTransformerTests.swift
git commit -m "feat(scroll): ScrollSettings snapshot of scroll.* defaults"
```

---

### Task 2.2: ScrollTransformer — pure delta math (TDD)

**Files:**
- Create: `Sources/ScrollControl/ScrollTransformer.swift`
- Modify (append): `Tests/FuseTests/ScrollTransformerTests.swift`

The contract, in full (the tests below encode it):
- `transform` returns `nil` when the event must pass through unchanged; non-`nil` means "rewrite the event with these deltas".
- `settings.enabled == false` → `nil`, always.
- Source `.continuous` (trackpad & Magic Mouse) is governed by `reverseTrackpad`; source `.lineBased` (classic wheel) by `reverseMouse`. If the governing flag is off → `nil` — `reverseHorizontal` alone never reverses anything.
- When the governing flag is on: negate the vertical (axis-1) triplet `deltaAxis1` / `pointDeltaAxis1` / `fixedPtDeltaAxis1`; additionally negate the horizontal (axis-2) triplet only when `reverseHorizontal` is also on.
- All six fields are raw `Int64` values as returned by `CGEvent.getIntegerValueField`; the fixed-point fields are two's-complement, so integer negation correctly negates the fixed-point value.

- [ ] **Step 1: Append the failing test class to `Tests/FuseTests/ScrollTransformerTests.swift`** — add the following at the END of the file (after the closing brace of `ScrollSettingsTests`), changing nothing above it:

```swift
final class ScrollTransformerTests: XCTestCase {
    /// Asymmetric values so a wrong-axis negation can never pass by accident.
    private let sample = ScrollDeltas(
        deltaAxis1: 3, deltaAxis2: -2,
        pointDeltaAxis1: 30, pointDeltaAxis2: -20,
        fixedPtDeltaAxis1: 196_608, fixedPtDeltaAxis2: -131_072)

    private func settings(enabled: Bool = true,
                          trackpad: Bool = true,
                          mouse: Bool = true,
                          horizontal: Bool = false) -> ScrollSettings {
        ScrollSettings(enabled: enabled, reverseTrackpad: trackpad,
                       reverseMouse: mouse, reverseHorizontal: horizontal)
    }

    func testTrackpadVerticalReversedHorizontalUntouched() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings())
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: -2,
            pointDeltaAxis1: -30, pointDeltaAxis2: -20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: -131_072))
    }

    func testMouseWheelVerticalReversed() {
        let out = ScrollTransformer.transform(sample, source: .lineBased, settings: settings())
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: -2,
            pointDeltaAxis1: -30, pointDeltaAxis2: -20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: -131_072))
    }

    func testMousePassesThroughWhenMouseFlagOff() {
        let out = ScrollTransformer.transform(sample, source: .lineBased, settings: settings(mouse: false))
        XCTAssertNil(out)
    }

    func testTrackpadPassesThroughWhenTrackpadFlagOff() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings(trackpad: false))
        XCTAssertNil(out)
    }

    func testHorizontalAlsoReversedWhenBothFlagsOn() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings(horizontal: true))
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: 2,
            pointDeltaAxis1: -30, pointDeltaAxis2: 20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: 131_072))
    }

    func testHorizontalFlagAloneDoesNotReverse() {
        let out = ScrollTransformer.transform(
            sample, source: .continuous,
            settings: settings(trackpad: false, horizontal: true))
        XCTAssertNil(out)
    }

    func testDisabledReturnsNilEvenWithAllFlagsOn() {
        let out = ScrollTransformer.transform(
            sample, source: .continuous,
            settings: settings(enabled: false, horizontal: true))
        XCTAssertNil(out)
    }

    func testZeroDeltasStayZero() {
        let zero = ScrollDeltas(deltaAxis1: 0, deltaAxis2: 0,
                                pointDeltaAxis1: 0, pointDeltaAxis2: 0,
                                fixedPtDeltaAxis1: 0, fixedPtDeltaAxis2: 0)
        let out = ScrollTransformer.transform(zero, source: .continuous, settings: settings(horizontal: true))
        XCTAssertEqual(out, zero)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'ScrollDeltas' in scope` (and/or `cannot find 'ScrollTransformer' in scope`). That compile failure is this step's "red".

- [ ] **Step 3: Implement — create `Sources/ScrollControl/ScrollTransformer.swift` with exactly this content**

```swift
/// The six integer delta fields of a scroll-wheel CGEvent, as read with
/// `getIntegerValueField`. Axis 1 is vertical, axis 2 is horizontal.
/// `fixedPt` fields are 16.16 fixed-point in two's complement, so negating the
/// raw Int64 negates the value.
struct ScrollDeltas: Equatable {
    var deltaAxis1: Int64          // vertical, line-based units
    var deltaAxis2: Int64          // horizontal, line-based units
    var pointDeltaAxis1: Int64     // vertical, pixel units
    var pointDeltaAxis2: Int64     // horizontal, pixel units
    var fixedPtDeltaAxis1: Int64   // vertical, fixed-point
    var fixedPtDeltaAxis2: Int64   // horizontal, fixed-point
}

/// Device class of a scroll event. Trackpads AND Magic Mice emit continuous
/// events; classic scroll wheels emit line-based events. v1 cannot tell them
/// apart (per-device IOKit is out of scope), so `reverseTrackpad` governs both.
enum ScrollSource {
    case continuous   // trackpad & Magic Mouse
    case lineBased    // classic scroll wheel
}

/// Pure scroll-direction math. No I/O, no globals — fully unit-tested.
enum ScrollTransformer {
    /// Returns nil when the event should pass through unchanged; otherwise the
    /// rewritten deltas to copy back onto the event.
    static func transform(_ d: ScrollDeltas,
                          source: ScrollSource,
                          settings: ScrollSettings) -> ScrollDeltas? {
        guard settings.enabled else { return nil }

        let reverseThisDevice: Bool
        switch source {
        case .continuous:
            reverseThisDevice = settings.reverseTrackpad
        case .lineBased:
            reverseThisDevice = settings.reverseMouse
        }
        guard reverseThisDevice else { return nil }

        var out = d
        out.deltaAxis1 = -d.deltaAxis1
        out.pointDeltaAxis1 = -d.pointDeltaAxis1
        out.fixedPtDeltaAxis1 = -d.fixedPtDeltaAxis1
        if settings.reverseHorizontal {
            out.deltaAxis2 = -d.deltaAxis2
            out.pointDeltaAxis2 = -d.pointDeltaAxis2
            out.fixedPtDeltaAxis2 = -d.fixedPtDeltaAxis2
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, and the log lists all eight `ScrollTransformerTests` tests plus the four `ScrollSettingsTests` tests as passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScrollControl/ScrollTransformer.swift Tests/FuseTests/ScrollTransformerTests.swift
git commit -m "feat(scroll): pure scroll-delta transformer with per-device-class reversal"
```

---

### Task 2.3: ScrollEventTapController — the CGEventTap (OS integration)

**Files:**
- Create: `Sources/ScrollControl/ScrollEventTap.swift` (contains `ScrollEventTapController`)

This is OS-integration code that cannot be unit-tested (a modifying tap needs Accessibility permission and a GUI session). The strategy: implement → compile-verify → human-verify after wiring (Task 2.5). Key mechanics, all reflected in the code below:

1. **Permission gate.** A modifying tap (`options: .defaultTap`) REQUIRES Accessibility. If `PermissionsService.hasAccessibility` is false, do NOT call `tapCreate`; poll every 5 seconds with a `Timer` and install the tap once granted.
2. **C callback.** `CGEventTapCallBack` is a C function pointer — it must be a top-level function (or non-capturing closure). `self` travels through `userInfo` as an unretained opaque pointer and is recovered with `Unmanaged<ScrollEventTapController>.fromOpaque(userInfo!).takeUnretainedValue()`. Because the pointer is unretained, AppDelegate MUST keep the controller alive for the whole app lifetime (Task 2.5 stores it in a property).
3. **Mandatory re-enable.** The OS disables taps it deems slow (`.tapDisabledByTimeout`) or on its user-input safeguard (`.tapDisabledByUserInput`). The callback must detect those pseudo-events, call `CGEvent.tapEnable(tap:enable: true)`, and pass the event through — otherwise scroll reversal silently stops forever.
4. **Device classification.** `event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0` → `.continuous`, else `.lineBased`. Momentum events (`.scrollWheelEventMomentumPhase != 0`) are also continuous and intentionally take the SAME inversion path — do NOT special-case them, or flick-scrolls snap direction mid-glide.
5. **HOT PATH RULE.** Inside the callback: integer field reads, value-type math, integer field writes. No heap allocation, no logging, no UserDefaults reads. Settings come from `cachedSettings`, refreshed by observing `UserDefaults.didChangeNotification` on the main queue. The tap's run-loop source lives on the MAIN run loop, so the callback and the refresh both run on the main thread — no locking needed.
6. **Reacting to "scroll.enabled".** When it flips to false the tap is torn down entirely (Fuse leaves the event path); when it flips to true the tap is (re)installed, re-checking permission.

- [ ] **Step 1: Create `Sources/ScrollControl/ScrollEventTap.swift` with exactly this content**

```swift
import AppKit

/// C-compatible tap callback (CGEventTapCallBack). Must not capture context, hence
/// a top-level function; `userInfo` points (unretained) at the owning controller.
private func scrollTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ScrollEventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

/// Owns a session-wide modifying CGEventTap on scroll-wheel events and
/// rewrites their delta fields according to the user's scroll settings.
/// Lifetime: constructed and retained by AppDelegate; the tap holds only an
/// UNRETAINED pointer to this object — never create a temporary instance.
/// Threading: the run-loop source lives on the MAIN run loop, so
/// `handle(type:event:)` always runs on the main thread; `cachedSettings` is
/// also only written on the main queue — no locking needed.
final class ScrollEventTapController {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionRetryTimer: Timer?
    private var settingsObserver: NSObjectProtocol?

    /// Snapshot read on the event-tap hot path. NEVER read UserDefaults inside
    /// the callback — the didChangeNotification observer refreshes this instead.
    private var cachedSettings = ScrollSettings.current()

    // MARK: - Public lifecycle

    func start() {
        ScrollSettings.registerDefaults()
        cachedSettings = ScrollSettings.current()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.settingsDidChange()
        }

        if cachedSettings.enabled {
            installTapWhenPermitted()
        }
    }

    func stop() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        removeTap()
    }

    // MARK: - Tap lifecycle

    private func installTapWhenPermitted() {
        guard machPort == nil else { return }
        guard PermissionsService.hasAccessibility else {
            Log.scroll.info("Accessibility not granted yet; retrying scroll tap every 5 s")
            schedulePermissionRetry()
            return
        }
        installTap()
    }

    private func installTap() {
        guard machPort == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Happens when permission was revoked between check and create, or
            // when this macOS build additionally wants Input Monitoring.
            Log.scroll.error("CGEvent.tapCreate returned nil; retrying every 5 s")
            schedulePermissionRetry()
            return
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.scroll.info("Scroll event tap installed")
    }

    private func removeTap() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        machPort = nil
        Log.scroll.info("Scroll event tap removed")
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard PermissionsService.hasAccessibility else { return }
            self.permissionRetryTimer?.invalidate()
            self.permissionRetryTimer = nil
            if self.cachedSettings.enabled {
                self.installTap()
            }
        }
    }

    // MARK: - Settings changes (main queue)

    private func settingsDidChange() {
        let fresh = ScrollSettings.current()
        guard fresh != cachedSettings else { return }   // fires for ANY defaults change; bail cheaply
        cachedSettings = fresh
        if fresh.enabled {
            installTapWhenPermitted()
        } else {
            removeTap()
        }
    }

    // MARK: - Hot path

    /// Called for every scroll-wheel event in the login session.
    /// HOT PATH RULES: integer field reads, value-type math, integer field
    /// writes. No heap allocation, no logging, no UserDefaults access.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables taps it deems too slow. Re-enabling here is
        // MANDATORY or scroll reversal silently stops (master plan §10).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // Trackpads and Magic Mice report continuous scrolls; classic wheels
        // do not. Momentum events (scrollWheelEventMomentumPhase != 0) are
        // also continuous and intentionally take the SAME path — special-
        // casing them causes direction snaps mid-glide.
        let source: ScrollSource =
            event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? .continuous : .lineBased

        let deltas = ScrollDeltas(
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPtDeltaAxis1: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPtDeltaAxis2: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2))

        guard let t = ScrollTransformer.transform(deltas, source: source, settings: cachedSettings) else {
            return Unmanaged.passUnretained(event)
        }

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: t.deltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: t.deltaAxis2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: t.pointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: t.pointDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: t.fixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: t.fixedPtDeltaAxis2)
        return Unmanaged.passUnretained(event)
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the test suite (regression check — nothing new is tested here)**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`. Note: hosted tests launch the real app, but `AppDelegate.applicationDidFinishLaunching` returns early under XCTest (Phase 0 guard), so no tap is ever created during test runs. Behavior is human-verified in Task 2.5 after wiring.

- [ ] **Step 4: Commit**

```bash
git add Sources/ScrollControl/ScrollEventTap.swift
git commit -m "feat(scroll): CGEventTap controller with permission retry and tap re-enable"
```

---

### Task 2.4: ScrollSettingsView — settings tab UI

**Files:**
- Create: `Sources/ScrollControl/ScrollSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (anchor insert only)

A SwiftUI Form bound via `@AppStorage` to the EXACT §6.4 keys. The `@AppStorage` default values match the registered defaults from Task 2.1 — they must never disagree. The view also shows a red callout (with a Grant button) when Accessibility is missing, refreshed every 2 seconds like the Phase 1 General tab, plus a footnote explaining the trackpad/Magic-Mouse grouping.

- [ ] **Step 1: Create `Sources/ScrollControl/ScrollSettingsView.swift` with exactly this content**

```swift
import SwiftUI

struct ScrollSettingsView: View {
    @AppStorage("scroll.enabled") private var enabled = true
    @AppStorage("scroll.reverseTrackpad") private var reverseTrackpad = true
    @AppStorage("scroll.reverseMouse") private var reverseMouse = true
    @AppStorage("scroll.reverseHorizontal") private var reverseHorizontal = false

    @State private var hasAccessibility = PermissionsService.hasAccessibility
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.red)
                            Text("Scroll control intercepts scroll events, which needs Accessibility. Fuse keeps retrying and starts reversing as soon as it is granted.")
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
            Section("Scroll direction") {
                Toggle("Reverse scrolling", isOn: $enabled)
                Toggle("Reverse trackpad & Magic Mouse", isOn: $reverseTrackpad)
                    .disabled(!enabled)
                Toggle("Reverse mouse scroll wheel", isOn: $reverseMouse)
                    .disabled(!enabled)
                Toggle("Also reverse horizontal scrolling", isOn: $reverseHorizontal)
                    .disabled(!enabled)
            }
            Section {
                Text("Trackpads and Magic Mice both report \"continuous\" scrolling, so macOS cannot tell them apart without per-device drivers. Fuse treats them as one class: the trackpad toggle also covers Magic Mice. Classic scroll wheels are controlled by the mouse toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

- [ ] **Step 2: Insert the tab above the anchor in `Sources/App/SettingsRootView.swift`**

Find this exact block (the anchor line and the line above it):

```swift
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            // FUSE:SETTINGS_TABS
```

Replace it with (the new tab goes ABOVE the anchor; the anchor line stays, verbatim, for later phases):

```swift
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ScrollSettingsView()
                .tabItem { Label("Scroll", systemImage: "computermouse") }
            // FUSE:SETTINGS_TABS
```

Note: if another phase already inserted its own tab above the anchor, do NOT match on the `GeneralSettingsView()` lines — just insert the two `ScrollSettingsView()` lines directly above the `// FUSE:SETTINGS_TABS` line, keeping the same 12-space indentation as the anchor.

- [ ] **Step 3: Regenerate, build, and run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/ScrollControl/ScrollSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(scroll): scroll settings tab with per-device toggles"
```

---

### Task 2.5: Wire the controller into AppDelegate + end-to-end HUMAN-VERIFY

**Files:**
- Modify: `Sources/App/AppDelegate.swift` (two anchor inserts only)

- [ ] **Step 1: Insert the controller property above the `// FUSE:CONTROLLER-PROPS` anchor in `Sources/App/AppDelegate.swift`**

Find this exact line (4-space indentation):

```swift
    // FUSE:CONTROLLER-PROPS
```

Replace it with (property ABOVE the anchor; the anchor line stays, verbatim):

```swift
    private var scrollController: ScrollEventTapController!
    // FUSE:CONTROLLER-PROPS
```

- [ ] **Step 2: Insert the controller startup above the `// FUSE:CONTROLLER-START` anchor in `Sources/App/AppDelegate.swift`**

Find this exact line (8-space indentation, inside `applicationDidFinishLaunching`):

```swift
        // FUSE:CONTROLLER-START
```

Replace it with (construction + start ABOVE the anchor; the anchor line stays, verbatim):

```swift
        scrollController = ScrollEventTapController()
        scrollController.start()
        // FUSE:CONTROLLER-START
```

This code only runs in real launches: `applicationDidFinishLaunching` returns early under XCTest (Phase 0 guard at the top of the method), so the tap never starts inside test runs. AppDelegate retains the controller for the whole app lifetime, which the tap's unretained `userInfo` pointer requires.

- [ ] **Step 3: Build and run the full test suite**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 4: Launch the app**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

- [ ] **Step 5: HUMAN-VERIFY — permission and tab**

Ask the human to:
1. Open the menu-bar bolt icon → "Settings…" → confirm a **Scroll** tab exists with a computer-mouse icon.
2. On the Scroll tab: if a red "Accessibility permission required" callout shows, click "Grant…", enable Fuse in System Settings → Privacy & Security → Accessibility, and confirm the callout disappears within ~5 seconds (2-second UI refresh + 5-second tap retry). If Accessibility was already granted in Phase 1, confirm no callout shows.
3. **Ad-hoc signing gotcha (master plan §10):** if Accessibility shows as granted but scrolling never changes in the next step, remove Fuse from the Accessibility list, re-add `.build/Build/Products/Debug/Fuse.app`, then quit and relaunch Fuse.

Record the human's answers before continuing.

- [ ] **Step 6: HUMAN-VERIFY — scroll behavior end-to-end**

Ask the human to perform ALL of the following and report each result:
1. **Trackpad flip:** scroll a long page with a two-finger trackpad swipe. Toggle "Reverse trackpad & Magic Mouse" off and on in the Scroll tab — the scroll direction must flip immediately each time (no app restart).
2. **Mouse wheel flip:** with an external mouse with a classic scroll wheel connected, scroll the same page. Toggle "Reverse mouse scroll wheel" off and on — the wheel direction must flip immediately, and the trackpad direction must NOT change when only the mouse toggle changes (and vice versa).
3. **Momentum feels natural:** flick-scroll on the trackpad and let the page glide. The glide must continue in the same (reversed) direction with no direction snap mid-glide.
4. **Gestures unaffected:** Mission Control (three/four-finger swipe up), app-switching swipes, and pinch-to-zoom must all behave exactly as they do with Fuse quit — only scrolling is altered.
5. **Master toggle:** turn "Reverse scrolling" off — ALL scrolling immediately returns to stock system behavior. Turn it back on — reversal resumes.
6. **Horizontal:** turn "Also reverse horizontal scrolling" on and scroll sideways (shift-wheel or two-finger horizontal swipe) — horizontal direction flips; turn it off — horizontal returns to stock while vertical stays reversed.
7. **Quit restores system behavior:** quit Fuse from the menu bar ("Quit Fuse"). All scrolling must return to stock system behavior instantly. Relaunch with `open .build/Build/Products/Debug/Fuse.app` — reversal resumes within a second.

Record the human's answers before continuing. If any item fails, STOP and debug before committing (start with the §10 TCC gotcha, then `log stream --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "scroll"' --level debug` to see tap install/remove messages).

- [ ] **Step 7: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat(scroll): wire ScrollEventTapController into app lifecycle"
```

---

### Task 2.6: Honor the global pause switch

Precondition: `Sources/Core/PauseManager.swift` exists (Phase 1 Task 1.7). If `ls Sources/Core/PauseManager.swift` fails, complete that task first. Pausing must physically remove the event tap (taking Fuse out of the scroll event path entirely), not merely pass events through.

**Files:**
- Modify: `Sources/ScrollControl/ScrollEventTap.swift`

- [ ] **Step 1: Apply five precise edits to `ScrollEventTapController`**

Edit A — add a property directly below `private var settingsObserver: NSObjectProtocol?`:

```swift
    private var pauseObserver: NSObjectProtocol?
```

Edit B — in `start()`, insert immediately BEFORE the `if cachedSettings.enabled {` line:

```swift
        pauseObserver = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlePauseChange()
        }

```

Edit C — in `stop()`, insert directly after the existing `settingsObserver` removal block:

```swift
        if let pauseObserver {
            NotificationCenter.default.removeObserver(pauseObserver)
            self.pauseObserver = nil
        }
```

Edit D — in `installTapWhenPermitted()`, add as the FIRST line of the body (covers every install path, including `settingsDidChange()` re-installs while paused):

```swift
        guard !PauseManager.shared.isPaused else { return }
```

Edit E — add this method in the `// MARK: - Tap lifecycle` section:

```swift
    private func handlePauseChange() {
        if PauseManager.shared.isPaused {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            removeTap()
            Log.scroll.info("scroll tap paused")
        } else if cachedSettings.enabled {
            Log.scroll.info("scroll tap resuming")
            installTapWhenPermitted()
        }
    }
```

- [ ] **Step 2: Build and run unit tests**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **` (no new unit tests — the tap cannot be unit-tested; behavior is verified next).

- [ ] **Step 3: HUMAN-VERIFY — pause round-trip**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
With "Reverse mouse" ON and an external mouse connected: wheel scrolling is reversed → menu-bar icon → "Pause Fuse" → wheel returns to SYSTEM behavior instantly → "Paused — click to resume" → reversal returns. `log stream --predicate 'subsystem == "com.rgv250cc.Fuse"' --level debug` shows "scroll tap paused" / "scroll tap resuming".

- [ ] **Step 4: Commit**

```bash
git add Sources/ScrollControl/ScrollEventTap.swift
git commit -m "feat(scroll): remove event tap while Fuse is paused"
```

---

## Manual verification checklist

- [ ] **HUMAN-VERIFY** Scroll tab visible in Settings with all four toggles; sub-toggles disabled while "Reverse scrolling" is off (Task 2.5 Step 5).
- [ ] **HUMAN-VERIFY** Accessibility callout flow works; tap installs within ~5 s of granting (Task 2.5 Step 5).
- [ ] **HUMAN-VERIFY** Trackpad two-finger scroll direction flips when toggling "Reverse trackpad & Magic Mouse" (Task 2.5 Step 6.1).
- [ ] **HUMAN-VERIFY** External mouse wheel flips with "Reverse mouse scroll wheel", independently of the trackpad toggle (Task 2.5 Step 6.2).
- [ ] **HUMAN-VERIFY** Momentum scrolling glides naturally, no direction snap mid-glide (Task 2.5 Step 6.3).
- [ ] **HUMAN-VERIFY** Mission Control / pinch / swipe gestures unaffected (Task 2.5 Step 6.4).
- [ ] **HUMAN-VERIFY** With Fuse quit, scrolling returns to stock system behavior (Task 2.5 Step 6.7).
- [ ] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (12 new tests: 4 ScrollSettingsTests + 8 ScrollTransformerTests).
- [ ] `git log --oneline | head -5` shows the five Phase 2 commits on top (scroll settings snapshot, transformer, tap controller, settings tab, wiring).
- [ ] `git status` clean; `ls Sources/ScrollControl` shows exactly: `ScrollEventTap.swift  ScrollSettings.swift  ScrollSettingsView.swift  ScrollTransformer.swift`.

## Risks & gotchas

- **TCC caches grants by code signature (master plan §10 — this WILL bite).** With ad-hoc signing, a rebuilt Fuse.app can lose Accessibility while System Settings still shows it granted; the tap then never installs (or `tapCreate` returns nil) with no visible error. Fix: remove Fuse from the Accessibility list, re-add the current `.build/Build/Products/Debug/Fuse.app`, relaunch. Suspect this FIRST whenever scrolling stops responding to toggles after a rebuild.
- **Input Monitoring may also be demanded.** On some macOS builds, HID-level event taps additionally require Input Monitoring (master plan §4). Symptom: Accessibility is green but `CGEvent.tapCreate` still returns nil (logged as an error in the `scroll` category). Fix: grant Input Monitoring via the General tab row added in Phase 1. The 5-second retry timer picks it up; relaunch if not.
- **The tap re-enable in the callback is load-bearing.** macOS sends `.tapDisabledByTimeout` when a tap callback is slow (e.g. system under heavy load) and reversal would silently stop forever without the `tapEnable` recovery. It is intentionally silent (no logging on the hot path) — do not "improve" it with logging.
- **Never add work to `handle(type:event:)`.** Every scroll event in the login session goes through it. Logging, UserDefaults reads, or heap allocation there degrades scrolling latency system-wide (master plan §11). `ScrollDeltas` is a stack-allocated value type — keep it that way. All settings reads go through `cachedSettings`.
- **`Unmanaged.passUnretained(self)` means the controller must outlive the tap.** AppDelegate's strong property guarantees that. Never construct a `ScrollEventTapController` as a local variable and `start()` it — the tap would dangle and crash on the next scroll.
- **Magic Mouse is grouped with the trackpad — by design.** Both emit continuous events and v1 has no per-device IOKit identification. A user with "natural" trackpad and "traditional" Magic Mouse preferences cannot split them; the settings footnote says so. Do not attempt to special-case Magic Mouse in this phase.
- **System "Natural scrolling" stacks with Fuse.** Fuse negates whatever macOS delivers, so the observed direction is the XOR of the system Trackpad/Mouse "Natural scrolling" checkbox and Fuse's toggle. During HUMAN-VERIFY, keep the system setting fixed and only flip Fuse's toggles, or results will look inconsistent.
- **`UserDefaults.didChangeNotification` fires for ANY defaults change** (other features' settings, even other processes' KVO-triggered syncs). The `fresh != cachedSettings` guard makes the observer cheap; keep it.
- **Momentum events must take the same path as finger scrolls.** They are continuous (`scrollWheelEventMomentumPhase != 0` events also report `scrollWheelEventIsContinuous == 1`). Special-casing them — or toggling settings mid-glide — produces a direction snap; the cached-snapshot design makes a mid-glide settings change take effect on the next event, which is acceptable and matches Scroll Reverser behavior.
- **Theoretical Int64 overflow:** negating `Int64.min` traps, but real scroll deltas are tiny (line counts, pixels, 16.16 fixed-point) — noted only so nobody "fixes" the plain negation into something clever.
- **Scrolling inside Fuse's own settings window is also reversed** — the tap is session-wide and Fuse does not exempt itself. Expected; matches Scroll Reverser.
