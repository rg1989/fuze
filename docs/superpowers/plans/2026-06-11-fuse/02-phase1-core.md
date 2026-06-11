# Phase 1: Core Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phase 0 complete.

**Goal:** The shared services every feature consumes: logging, permission checks/prompts, a pasteboard write/snapshot/restore + ⌘V-synthesis service, the AXUIElement wrapper, the central hotkey-name registry, and a General settings tab that shows live permission status.

**Architecture:** Everything lives in `Sources/Core/` as small, dependency-free files. `PasteService` is fully unit-tested against named (non-global) pasteboards. AX and permission code can't be unit-tested without GUI grants, so those tasks end in compile checks plus HUMAN-VERIFY steps.

**Tech Stack:** AppKit, ApplicationServices (AX), IOKit.hid, AVFoundation, ServiceManagement, KeyboardShortcuts.

---

### Task 1.1: Logging

**Files:**
- Create: `Sources/Core/Log.swift`

- [ ] **Step 1: Write `Sources/Core/Log.swift`**

```swift
import os

enum Log {
    static let app = Logger(subsystem: "com.rgv250cc.Fuse", category: "app")
    static let scroll = Logger(subsystem: "com.rgv250cc.Fuse", category: "scroll")
    static let tiling = Logger(subsystem: "com.rgv250cc.Fuse", category: "tiling")
    static let clipboard = Logger(subsystem: "com.rgv250cc.Fuse", category: "clipboard")
    static let voice = Logger(subsystem: "com.rgv250cc.Fuse", category: "voice")
    static let downloader = Logger(subsystem: "com.rgv250cc.Fuse", category: "downloader")
    static let notifications = Logger(subsystem: "com.rgv250cc.Fuse", category: "notifications")
}
```

- [ ] **Step 2: Regenerate, build, commit**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -3
git add Sources/Core/Log.swift
git commit -m "feat(core): add per-feature loggers"
```
Expected: `** BUILD SUCCEEDED **`

Tip for all later phases: stream a feature's logs while testing with
`log stream --predicate 'subsystem == "com.rgv250cc.Fuse"' --level debug`.

---

### Task 1.2: PasteService (TDD)

**Files:**
- Create: `Sources/Core/PasteService.swift`
- Test: `Tests/FuseTests/PasteServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import AppKit
@testable import Fuse

final class PasteServiceTests: XCTestCase {
    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("FuseTests.\(UUID().uuidString)"))
    }

    func testSnapshotCapturesAllTypesOfAllItems() {
        let pb = freshPasteboard()
        pb.clearContents()
        pb.setString("hello", forType: .string)

        let snap = PasteService.snapshot(of: pb)

        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0][.string], Data("hello".utf8))
    }

    func testWriteThenSnapshotRoundtrips() {
        let pb = freshPasteboard()
        let items: [PasteService.ItemRepresentation] = [
            [.string: Data("one".utf8)],
            [.string: Data("two".utf8), NSPasteboard.PasteboardType("public.html"): Data("<b>two</b>".utf8)],
        ]

        PasteService.write(items, to: pb, markInternal: false)
        let snap = PasteService.snapshot(of: pb)

        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[0][.string], Data("one".utf8))
        XCTAssertEqual(snap[1][NSPasteboard.PasteboardType("public.html")], Data("<b>two</b>".utf8))
    }

    func testWriteMarksInternalByDefaultSemantics() {
        let pb = freshPasteboard()

        PasteService.write([[.string: Data("x".utf8)]], to: pb, markInternal: true)

        XCTAssertTrue(pb.types?.contains(PasteService.fuseInternalMarker) ?? false)
    }

    func testWriteWithoutMarkerLeavesNoMarker() {
        let pb = freshPasteboard()

        PasteService.write([[.string: Data("x".utf8)]], to: pb, markInternal: false)

        XCTAssertFalse(pb.types?.contains(PasteService.fuseInternalMarker) ?? false)
    }

    func testRestoreReplacesCurrentContents() {
        let pb = freshPasteboard()
        pb.clearContents()
        pb.setString("original", forType: .string)
        let saved = PasteService.snapshot(of: pb)

        pb.clearContents()
        pb.setString("intruder", forType: .string)
        PasteService.write(saved, to: pb, markInternal: true)

        XCTAssertEqual(pb.string(forType: .string), "original")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: **BUILD FAILS** with `cannot find 'PasteService' in scope` (a compile failure is this step's "red").

- [ ] **Step 3: Write `Sources/Core/PasteService.swift`**

```swift
import AppKit
import Carbon.HIToolbox

/// Writes content to a pasteboard, synthesizes ⌘V into the frontmost app,
/// and restores the previous pasteboard contents afterwards.
/// Everything Fuse writes carries `fuseInternalMarker` so the clipboard
/// watcher (Phase 4) can ignore Fuse's own writes.
enum PasteService {
    static let fuseInternalMarker = NSPasteboard.PasteboardType("com.rgv250cc.fuse.internal")

    typealias ItemRepresentation = [NSPasteboard.PasteboardType: Data]

    static func snapshot(of pasteboard: NSPasteboard = .general) -> [ItemRepresentation] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var rep: ItemRepresentation = [:]
            for type in item.types where type != fuseInternalMarker {
                if let data = item.data(forType: type) {
                    rep[type] = data
                }
            }
            return rep
        }
    }

    static func write(_ items: [ItemRepresentation],
                      to pasteboard: NSPasteboard = .general,
                      markInternal: Bool = true) {
        pasteboard.clearContents()
        let pbItems = items.enumerated().map { index, rep -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in rep {
                item.setData(data, forType: type)
            }
            if markInternal && index == 0 {
                item.setData(Data(), forType: fuseInternalMarker)
            }
            return item
        }
        pasteboard.writeObjects(pbItems)
    }

    /// Snapshot current clipboard → write `items` → ⌘V → restore snapshot after `seconds`.
    static func paste(_ items: [ItemRepresentation], restoreAfter seconds: Double = 0.6) {
        let saved = snapshot()
        write(items, markInternal: true)
        synthesizeCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            write(saved, markInternal: true)
        }
    }

    static func paste(text: String, restoreAfter seconds: Double = 0.6) {
        paste([[.string: Data(text.utf8)]], restoreAfter: seconds)
    }

    /// Requires Accessibility permission; otherwise the events are silently dropped.
    static func synthesizeCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`, 6 tests passed (1 sanity + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PasteService.swift Tests/FuseTests/PasteServiceTests.swift
git commit -m "feat(core): PasteService with snapshot/write/restore and Cmd+V synthesis"
```

---

### Task 1.3: PermissionsService

**Files:**
- Create: `Sources/Core/Permissions.swift`
- Test: `Tests/FuseTests/PermissionsTests.swift`

- [ ] **Step 1: Write the (smoke) test** — permission state can't be granted in CI, but the calls must not crash and must return stable types.

```swift
import XCTest
@testable import Fuse

final class PermissionsTests: XCTestCase {
    func testChecksReturnWithoutCrashing() {
        _ = PermissionsService.hasAccessibility
        _ = PermissionsService.hasInputMonitoring
    }

    func testSettingsPaneURLsAreWellFormed() {
        for pane in SettingsPane.allCases {
            XCTAssertNotNil(URL(string: pane.urlString), "bad URL for \(pane)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure, `cannot find 'PermissionsService' in scope`.

- [ ] **Step 3: Write `Sources/Core/Permissions.swift`**

```swift
import ApplicationServices
import AVFoundation
import AppKit
import IOKit.hid

enum SettingsPane: CaseIterable {
    case accessibility
    case inputMonitoring
    case microphone

    var urlString: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}

enum PermissionsService {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptForInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func openSystemSettings(pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Permissions.swift Tests/FuseTests/PermissionsTests.swift
git commit -m "feat(core): PermissionsService for accessibility, input monitoring, microphone"
```

---

### Task 1.4: AXElement wrapper

**Files:**
- Create: `Sources/Core/AX.swift`
- Test: `Tests/FuseTests/AXElementTests.swift`

- [ ] **Step 1: Write the smoke test** (real AX values need GUI permission; we test construction and nil-safety)

```swift
import XCTest
@testable import Fuse

final class AXElementTests: XCTestCase {
    func testSystemWideElementConstructs() {
        let element = AXElement.systemWide()
        // Without Accessibility permission these return nil/[] — they must never crash.
        _ = element.role
        _ = element.children
        _ = element.actionNames()
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure, `cannot find 'AXElement' in scope`.

- [ ] **Step 3: Write `Sources/Core/AX.swift`**

```swift
import ApplicationServices

/// Thin Swift wrapper over AXUIElement. Every accessor degrades to nil/[]/false
/// when permission is missing or the attribute doesn't exist — callers never crash.
struct AXElement {
    let raw: AXUIElement

    static func systemWide() -> AXElement {
        AXElement(raw: AXUIElementCreateSystemWide())
    }

    static func application(pid: pid_t) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid))
    }

    func copyValue(_ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func elementArray(_ attribute: String) -> [AXElement] {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(raw: item as! AXUIElement)
        }
    }

    var role: String? { copyValue(kAXRoleAttribute) as? String }
    var subrole: String? { copyValue(kAXSubroleAttribute) as? String }
    var title: String? { copyValue(kAXTitleAttribute) as? String }
    var identifier: String? { copyValue("AXIdentifier") as? String }
    var children: [AXElement] { elementArray(kAXChildrenAttribute) }
    var windows: [AXElement] { elementArray(kAXWindowsAttribute) }

    var focusedWindow: AXElement? {
        guard let value = copyValue(kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw: value as! AXUIElement)
    }

    var position: CGPoint? {
        guard let value = copyValue(kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    var size: CGSize? {
        guard let value = copyValue(kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, value) == .success
    }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func actionDescription(_ action: String) -> String? {
        var description: CFString?
        guard AXUIElementCopyActionDescription(raw, action as CFString, &description) == .success else { return nil }
        return description as String?
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AX.swift Tests/FuseTests/AXElementTests.swift
git commit -m "feat(core): AXElement wrapper over AXUIElement"
```

---

### Task 1.5: Hotkey name registry

**Files:**
- Create: `Sources/Core/HotkeyNames.swift`
- Test: `Tests/FuseTests/HotkeyNamesTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import KeyboardShortcuts
@testable import Fuse

final class HotkeyNamesTests: XCTestCase {
    func testAllNamesHaveDefaultShortcuts() {
        let all: [KeyboardShortcuts.Name] = [
            .pushToTalk, .pastePicker, .clearNotifications,
            .tileLeftHalf, .tileRightHalf, .tileTopHalf, .tileBottomHalf,
            .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
            .tileMaximize, .tileCenter, .tileNextDisplay,
            .toggleNotesPanel,
        ]
        for name in all {
            XCTAssertNotNil(name.defaultShortcut, "\(name.rawValue) is missing a default shortcut")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure on the missing `KeyboardShortcuts.Name` extensions.

- [ ] **Step 3: Write `Sources/Core/HotkeyNames.swift`** (the §6.3 master table, in code — the ONLY place hotkey defaults exist)

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Voice (Phase 5) — hold to talk
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.control, .option]))

    // Clipboard (Phase 4)
    static let pastePicker = Self("pastePicker", default: .init(.v, modifiers: [.command, .shift]))

    // Notifications (Phase 7)
    static let clearNotifications = Self("clearNotifications", default: .init(.delete, modifiers: [.control, .option]))

    // Notes (Phase 8)
    static let toggleNotesPanel = Self("toggleNotesPanel", default: .init(.m, modifiers: [.control, .option]))

    // Tiling (Phase 3)
    static let tileLeftHalf = Self("tileLeftHalf", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let tileRightHalf = Self("tileRightHalf", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let tileTopHalf = Self("tileTopHalf", default: .init(.upArrow, modifiers: [.control, .option]))
    static let tileBottomHalf = Self("tileBottomHalf", default: .init(.downArrow, modifiers: [.control, .option]))
    static let tileTopLeft = Self("tileTopLeft", default: .init(.one, modifiers: [.control, .option]))
    static let tileTopRight = Self("tileTopRight", default: .init(.two, modifiers: [.control, .option]))
    static let tileBottomLeft = Self("tileBottomLeft", default: .init(.three, modifiers: [.control, .option]))
    static let tileBottomRight = Self("tileBottomRight", default: .init(.four, modifiers: [.control, .option]))
    static let tileMaximize = Self("tileMaximize", default: .init(.return, modifiers: [.control, .option]))
    static let tileCenter = Self("tileCenter", default: .init(.c, modifiers: [.control, .option]))
    static let tileNextDisplay = Self("tileNextDisplay", default: .init(.n, modifiers: [.control, .option]))
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`. (If `defaultShortcut` isn't the property name in the pinned KeyboardShortcuts version, check the package source under `.build/SourcePackages/checkouts/KeyboardShortcuts/Sources/` for the current accessor and adjust the test only.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HotkeyNames.swift Tests/FuseTests/HotkeyNamesTests.swift
git commit -m "feat(core): central hotkey registry with defaults"
```

---

### Task 1.6: General settings tab — permissions dashboard + launch at login

**Files:**
- Modify: `Sources/App/GeneralSettingsView.swift` (replace entire file)

- [ ] **Step 1: Replace `Sources/App/GeneralSettingsView.swift`**

```swift
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var hasAccessibility = PermissionsService.hasAccessibility
    @State private var hasInputMonitoring = PermissionsService.hasInputMonitoring
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Window tiling, pasting, notification clearing, scroll control",
                    granted: hasAccessibility,
                    pane: .accessibility,
                    prompt: PermissionsService.promptForAccessibility)
                permissionRow(
                    title: "Input Monitoring",
                    detail: "May be required for scroll event interception",
                    granted: hasInputMonitoring,
                    pane: .inputMonitoring,
                    prompt: PermissionsService.promptForInputMonitoring)
                permissionRow(
                    title: "Microphone",
                    detail: "Push-to-talk dictation",
                    granted: micStatus == .authorized,
                    pane: .microphone,
                    prompt: { PermissionsService.requestMicrophone { _ in } })
            }
            Section("Startup") {
                Toggle("Launch Fuse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
            hasInputMonitoring = PermissionsService.hasInputMonitoring
            micStatus = PermissionsService.microphoneStatus
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, granted: Bool,
                               pane: SettingsPane, prompt: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            if !granted {
                Button("Grant…") {
                    prompt()
                    PermissionsService.openSystemSettings(pane: pane)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: HUMAN-VERIFY — grant Accessibility**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Ask the human to: open Settings → General, click "Grant…" next to Accessibility, add/enable Fuse in System Settings, and confirm the row flips to a green checkmark within ~2 seconds. Also toggle "Launch Fuse at login" on and off without errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/GeneralSettingsView.swift
git commit -m "feat(core): permissions dashboard and launch-at-login in General settings"
```

---

### Task 1.7: PauseManager — global pause switch (TDD)

One menu click silences ALL of Fuse: every KeyboardShortcuts hotkey is disabled in one place (`KeyboardShortcuts.isEnabled`), and continuously-running services (scroll tap, clipboard watcher, notification auto-clear, voice recorder — added in their own phases as Tasks 2.6 / 4.7 / 7.7 / 5.6) observe `pauseStateChanged` and stand down. Pause is in-memory only; relaunching always resumes.

**Files:**
- Create: `Sources/Core/PauseManager.swift`
- Modify: `Sources/App/AppDelegate.swift` (menu item + handler)
- Test: `Tests/FuseTests/PauseManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import KeyboardShortcuts
@testable import Fuse

final class PauseManagerTests: XCTestCase {
    override func tearDown() {
        PauseManager.shared.setPaused(false)   // never leak paused state into other tests
        super.tearDown()
    }

    func testPauseFlipsStateDisablesShortcutsAndPosts() {
        let manager = PauseManager.shared
        manager.setPaused(false)
        let note = expectation(forNotification: PauseManager.pauseStateChanged, object: manager)

        manager.setPaused(true)

        XCTAssertTrue(manager.isPaused)
        XCTAssertFalse(KeyboardShortcuts.isEnabled)
        wait(for: [note], timeout: 1)

        manager.setPaused(false)
        XCTAssertFalse(manager.isPaused)
        XCTAssertTrue(KeyboardShortcuts.isEnabled)
    }

    func testRedundantSetPostsNothing() {
        let manager = PauseManager.shared
        manager.setPaused(false)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged, object: manager, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.setPaused(false)   // already false — must be a no-op

        XCTAssertEqual(posts, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure, `cannot find 'PauseManager' in scope`.

- [ ] **Step 3: Write `Sources/Core/PauseManager.swift`**

```swift
import Foundation
import KeyboardShortcuts

/// Global kill switch ("Pause Fuse" in the status-bar menu).
/// Pausing disables every KeyboardShortcuts hotkey app-wide and notifies
/// continuously-running services (scroll tap, clipboard watcher, notification
/// auto-clear timer, voice recorder) to stand down.
/// Deliberately NOT persisted: a relaunch always starts un-paused.
final class PauseManager {
    static let shared = PauseManager()
    static let pauseStateChanged = Notification.Name("com.rgv250cc.fuse.pauseStateChanged")

    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        KeyboardShortcuts.isEnabled = !paused
        NotificationCenter.default.post(name: Self.pauseStateChanged, object: self)
    }

    func toggle() {
        setPaused(!isPaused)
    }
}
```

API drift note: `KeyboardShortcuts.isEnabled` is the package's global on/off switch. If the resolved version lacks it, check the checkout (`grep -rn "isEnabled" .build/SourcePackages/checkouts/KeyboardShortcuts/Sources/ | head`) and fall back to `KeyboardShortcuts.disable(...)` / `.enable(...)` with the full name list from `HotkeyNames.swift`; record under `## Deviations`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Add the menu item in `Sources/App/AppDelegate.swift`**

Replace this block inside `applicationDidFinishLaunching` (keep the `// FUSE:MENU-ITEMS` anchor verbatim):

```swift
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        // FUSE:MENU-ITEMS
```

with:

```swift
        let menu = NSMenu()
        let pauseItem = NSMenuItem(title: "Pause Fuse", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        // FUSE:MENU-ITEMS
```

Then add this method to `AppDelegate`, directly below `openSettings()`:

```swift
    @objc private func togglePause(_ sender: NSMenuItem) {
        PauseManager.shared.toggle()
        let paused = PauseManager.shared.isPaused
        sender.state = paused ? .on : .off
        sender.title = paused ? "Paused — click to resume" : "Pause Fuse"
        statusItem.button?.appearsDisabled = paused
    }
```

- [ ] **Step 6: Build and test**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: HUMAN-VERIFY — pause behavior**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Ask the human to confirm: clicking "Pause Fuse" puts a checkmark on the item, renames it "Paused — click to resume", and dims the menu-bar icon; clicking again restores all three. (Hotkey silencing becomes observable once feature phases land — at this point in the build there are no hotkey features yet, and that is fine.)

- [ ] **Step 8: Commit**

```bash
git add Sources/Core/PauseManager.swift Sources/App/AppDelegate.swift Tests/FuseTests/PauseManagerTests.swift
git commit -m "feat(core): global pause switch with menu toggle"
```

---

### Task 1.8: ConflictDetector — warn when replaced utilities are still running (TDD)

Fuse replaces apps the user likely still has running. Overlaps actively misbehave: two scroll inverters cancel out, two tiling managers race the same shortcuts, two clipboard watchers double-record. This task detects known apps and surfaces advice in the General tab, plus a one-time auto-open of Settings on first launch.

**Files:**
- Create: `Sources/Core/ConflictDetector.swift`
- Modify: `Sources/App/GeneralSettingsView.swift` (replace entire file)
- Modify: `Sources/App/AppDelegate.swift` (first-launch hook)
- Test: `Tests/FuseTests/ConflictDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Fuse

final class ConflictDetectorTests: XCTestCase {
    func testKnownConflictDetectedAndDescribed() {
        let conflicts = ConflictDetector.conflicts(
            amongBundleIDs: ["com.knollsoft.Rectangle", "com.example.unrelated"])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].appName, "Rectangle")
        XCTAssertEqual(conflicts[0].fuseFeature, "Window tiling")
        XCTAssertFalse(conflicts[0].advice.isEmpty)
    }

    func testResultsSortedByBundleID() {
        let ids: Set<String> = ["org.p0deje.Maccy", "com.knollsoft.Rectangle", "com.pilotmoon.scroll-reverser"]
        let bundleIDs = ConflictDetector.conflicts(amongBundleIDs: ids).map(\.bundleID)
        XCTAssertEqual(bundleIDs, bundleIDs.sorted())
        XCTAssertEqual(bundleIDs.count, 3)
    }

    func testNoKnownAppsMeansNoConflicts() {
        XCTAssertTrue(ConflictDetector.conflicts(amongBundleIDs: ["com.apple.finder"]).isEmpty)
        XCTAssertTrue(ConflictDetector.conflicts(amongBundleIDs: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure, `cannot find 'ConflictDetector' in scope`.

- [ ] **Step 3: Write `Sources/Core/ConflictDetector.swift`**

```swift
import AppKit

/// A known third-party utility whose behavior overlaps a Fuse feature.
struct AppConflict: Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let fuseFeature: String
    let advice: String
}

enum ConflictDetector {
    /// Known overlapping utilities. Extend freely — unknown ids are harmless.
    /// Find any app's bundle id with:  osascript -e 'id of app "AppName"'
    static let knownConflicts: [String: (name: String, feature: String, advice: String)] = [
        "com.knollsoft.Rectangle": ("Rectangle", "Window tiling",
            "Quit Rectangle or disable Fuse tiling — both grab ⌃⌥-arrow shortcuts."),
        "com.knollsoft.Hookshot": ("Rectangle Pro", "Window tiling",
            "Quit Rectangle Pro or disable Fuse tiling."),
        "com.crowdcafe.windowmagnet": ("Magnet", "Window tiling",
            "Quit Magnet or disable Fuse tiling."),
        "com.hegenberg.BetterSnapTool": ("BetterSnapTool", "Window tiling",
            "Quit BetterSnapTool or disable Fuse tiling."),
        "com.pilotmoon.scroll-reverser": ("Scroll Reverser", "Scroll direction",
            "Quit Scroll Reverser — two inverters cancel each other out."),
        "com.caldis.Mos": ("Mos", "Scroll direction",
            "Quit Mos or disable Fuse scroll control."),
        "org.p0deje.Maccy": ("Maccy", "Clipboard history",
            "Quit Maccy — two watchers double-record every copy."),
        "com.wiheads.paste": ("Paste", "Clipboard history",
            "Quit Paste or disable Fuse clipboard history."),
        "com.charliemonroe.Downie-4": ("Downie", "Video downloads",
            "No hard conflict, but downloads are duplicated effort — pick one."),
    ]

    /// Pure core (unit-tested): which of `running` are known conflicts, sorted by bundle id.
    static func conflicts(amongBundleIDs running: Set<String>) -> [AppConflict] {
        running.intersection(knownConflicts.keys).sorted().map { bundleID in
            let info = knownConflicts[bundleID]!
            return AppConflict(bundleID: bundleID, appName: info.name,
                               fuseFeature: info.feature, advice: info.advice)
        }
    }

    static func currentConflicts() -> [AppConflict] {
        conflicts(amongBundleIDs:
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Replace `Sources/App/GeneralSettingsView.swift`** (Task 1.6's version plus the conflicts banner — full file):

```swift
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var hasAccessibility = PermissionsService.hasAccessibility
    @State private var hasInputMonitoring = PermissionsService.hasInputMonitoring
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var conflicts = ConflictDetector.currentConflicts()

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !conflicts.isEmpty {
                Section("Conflicting utilities detected") {
                    ForEach(conflicts) { conflict in
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading) {
                                Text("\(conflict.appName) — overlaps \(conflict.fuseFeature)")
                                Text(conflict.advice).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Window tiling, pasting, notification clearing, scroll control",
                    granted: hasAccessibility,
                    pane: .accessibility,
                    prompt: PermissionsService.promptForAccessibility)
                permissionRow(
                    title: "Input Monitoring",
                    detail: "May be required for scroll event interception",
                    granted: hasInputMonitoring,
                    pane: .inputMonitoring,
                    prompt: PermissionsService.promptForInputMonitoring)
                permissionRow(
                    title: "Microphone",
                    detail: "Push-to-talk dictation",
                    granted: micStatus == .authorized,
                    pane: .microphone,
                    prompt: { PermissionsService.requestMicrophone { _ in } })
            }
            Section("Startup") {
                Toggle("Launch Fuse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
            hasInputMonitoring = PermissionsService.hasInputMonitoring
            micStatus = PermissionsService.microphoneStatus
            conflicts = ConflictDetector.currentConflicts()
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, granted: Bool,
                               pane: SettingsPane, prompt: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            if !granted {
                Button("Grant…") {
                    prompt()
                    PermissionsService.openSystemSettings(pane: pane)
                }
            }
        }
    }
}
```

- [ ] **Step 6: First-launch hook in `Sources/App/AppDelegate.swift`.** Core code may live BELOW the `// FUSE:CONTROLLER-START` anchor (features insert above it, so controllers will start before this check). Replace:

```swift
        // FUSE:CONTROLLER-START
    }
```

with:

```swift
        // FUSE:CONTROLLER-START

        // One-time coexistence check: if a known overlapping utility is running
        // on the very first launch, open Settings so the General banner is seen.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "core.didRunBefore") {
            defaults.set(true, forKey: "core.didRunBefore")
            if !ConflictDetector.currentConflicts().isEmpty {
                openSettings()
            }
        }
    }
```

- [ ] **Step 7: Build and test**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: HUMAN-VERIFY — banner and first-launch behavior**

```bash
defaults delete com.rgv250cc.Fuse core.didRunBefore 2>/dev/null
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Ask the human: if any known utility (Rectangle, Scroll Reverser, Maccy, …) is running, Settings opens by itself and General shows the yellow banner naming it with advice; quitting that utility clears the banner within ~2 s. If none of the known apps is installed, temporarily add `"com.apple.TextEdit": ("TextEdit", "Test", "Temporary test entry — remove.")` to `knownConflicts`, rebuild, open TextEdit, verify, then REVERT the entry and rebuild.

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/ConflictDetector.swift Sources/App/GeneralSettingsView.swift Sources/App/AppDelegate.swift Tests/FuseTests/ConflictDetectorTests.swift
git commit -m "feat(core): conflict detection for overlapping utilities with General-tab banner"
```

---

## Manual verification checklist (end of phase)

- [ ] **HUMAN-VERIFY** Accessibility granted and shown green (needed by Phases 3, 5, 7 and partially 2).
- [ ] **HUMAN-VERIFY** Microphone "Grant…" triggers the system prompt (can defer actual grant to Phase 5).
- [ ] **HUMAN-VERIFY** "Pause Fuse" toggles the checkmark, renames itself, and dims the menu-bar icon (Task 1.7).
- [ ] **HUMAN-VERIFY** Conflict banner lists running known utilities and clears when they quit (Task 1.8).
- [ ] All unit tests green: `xcodebuild ... test` → `** TEST SUCCEEDED **`.
- [ ] `git log --oneline | head -12` shows the eight Phase 1 commits on top.

## Risks & gotchas

- **TCC + ad-hoc signing:** after rebuilds, macOS may show Accessibility as granted while `AXIsProcessTrusted()` returns false. Remove Fuse from the list and re-add the current `.build/.../Fuse.app`. (Master plan §10 — this WILL happen during development.)
- `SMAppService.mainApp.register()` can throw when the app runs from a path macOS dislikes (e.g. a translocated copy); running from `.build/Build/Products/Debug/` is fine.
- `kAXTrustedCheckOptionPrompt` must go through `.takeUnretainedValue()` — passing the raw `Unmanaged` constant into the dictionary compiles but never prompts.
