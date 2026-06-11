# Phase 7: Notification Clearing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** One keystroke (⌃⌥⌫, the existing `.clearNotifications` hotkey) — or a status-bar menu item, or an optional timer — dismisses every macOS notification banner, alert, and Notification Center drawer entry, plus a debug AX-tree dumper so the feature can be re-calibrated after macOS updates.

**Architecture:** macOS has **no public API** to dismiss another app's notifications. The only viable technique is Accessibility: the Notification Center UI is its own process (bundle id `com.apple.notificationcenterui`, process name `NotificationCenter`); each banner/alert/group in its windows exposes AX actions whose localized **descriptions** are strings like "Clear All" and "Close" (the action *names* are opaque, version-dependent identifiers like `Name:close`). We traverse the AX tree, collect those actions, and perform them. The code is deliberately split into three layers so the brittle part is as thin as possible: (a) `NotificationSweep` — a pure, fully unit-tested sweep algorithm over an abstract `AXTreeNode` tree (no AX at all); (b) `NotificationClearer` — a thin live adapter that points the algorithm at the real Notification Center process; (c) `AXDump` — a debug tree-dumper used to re-calibrate the string matchers whenever a macOS update changes the action descriptions. This feature is **version-brittle BY NATURE**; re-calibration is normal maintenance, not failure (master plan §10, §11).

**Tech Stack:** AppKit, ApplicationServices (via the Phase 1 `AXElement` wrapper in `Sources/Core/AX.swift`), KeyboardShortcuts (hotkey `.clearNotifications` from `Sources/Core/HotkeyNames.swift`), XCTest with a mock tree, `Log.notifications` from `Sources/Core/Log.swift`, UserDefaults keys `notifications.autoClearEnabled` (Bool, default false) and `notifications.autoClearIntervalMinutes` (Int, default 30) per master plan §6.4.

---

### Task 7.0: Preflight

**Files:**
- None created or modified. Verification only.

- [x] **Step 1: Verify the Phase 1 Core files exist**

```bash
ls /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core
```
Expected output contains ALL of: `AX.swift`, `HotkeyNames.swift`, `Log.swift`, `PasteService.swift`, `Permissions.swift`. If any is missing, STOP — Phase 1 is not complete.

- [x] **Step 2: Verify the integration anchors and the hotkey constant exist**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
grep -n "FUSE:CONTROLLER-PROPS\|FUSE:CONTROLLER-START\|FUSE:MENU-ITEMS" Sources/App/AppDelegate.swift
grep -n "FUSE:SETTINGS_TABS" Sources/App/SettingsRootView.swift
grep -n "clearNotifications" Sources/Core/HotkeyNames.swift
ls Sources/Notifications 2>/dev/null || echo "Notifications dir not present yet (expected)"
```
Expected: three anchor lines, then one anchor line, then the line defining `static let clearNotifications` (default ⌃⌥⌫), then `Notifications dir not present yet (expected)`. If `Sources/Notifications/` already has files, STOP and ask the user whether Phase 7 was partially executed before.

- [x] **Step 3: Verify the build and tests are green before changing anything**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`. If either is red, STOP and fix the pre-existing breakage first (it is not caused by this phase).

---

### Task 7.1: AXTreeNode abstraction

**Files:**
- Create: `Sources/Notifications/AXTreeNode.swift`

The sweep algorithm must be testable without GUI permissions, so it operates on a protocol instead of `AXElement` directly. The live `AXElement` (Phase 1, `Sources/Core/AX.swift`) conforms here; tests conform a `MockNode` in Task 7.2.

- [x] **Step 1: Write `Sources/Notifications/AXTreeNode.swift`** (complete file)

```swift
import Foundation

/// Abstraction over an accessibility-tree node so the sweep algorithm can be
/// unit-tested against in-memory mock trees, with no live Accessibility API.
protocol AXTreeNode {
    var childNodes: [Self] { get }
    var nodeRole: String? { get }
    var nodeSubrole: String? { get }
    /// (actionName, localizedDescription) pairs, e.g. ("Name:close", "Close").
    /// Action NAMES are opaque, version-dependent identifiers; the localized
    /// DESCRIPTIONS ("Clear All", "Close") are what we match against.
    func nodeActions() -> [(name: String, description: String?)]
    @discardableResult
    func performNodeAction(named name: String) -> Bool
}

/// Live conformance: AXElement is the Phase 1 wrapper over AXUIElement
/// (Sources/Core/AX.swift). All accessors degrade to nil/[]/false without
/// Accessibility permission, so this never crashes.
extension AXElement: AXTreeNode {
    var childNodes: [AXElement] { children }
    var nodeRole: String? { role }
    var nodeSubrole: String? { subrole }

    func nodeActions() -> [(name: String, description: String?)] {
        actionNames().map { ($0, actionDescription($0)) }
    }

    func performNodeAction(named name: String) -> Bool {
        perform(name)
    }
}
```

- [x] **Step 2: Regenerate, build**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 3: Commit**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
git add Sources/Notifications/AXTreeNode.swift
git commit -m "feat(notifications): AXTreeNode abstraction over the accessibility tree"
```

---

### Task 7.2: NotificationSweep — pure sweep algorithm (TDD)

**Files:**
- Create: `Sources/Notifications/NotificationSweep.swift`
- Test: `Tests/FuseTests/NotificationSweepTests.swift`

This is the TDD centerpiece of the phase. The algorithm: walk the tree breadth-first to a depth limit, collect every action whose localized description matches a "clear-ish" phrase, then perform them with a preference rule — if any "Clear All" action exists, perform ONLY those (each one nukes a whole app group in one shot); otherwise perform the individual "Close"/"Clear" actions.

- [x] **Step 1: Write the failing tests — `Tests/FuseTests/NotificationSweepTests.swift`** (complete file)

```swift
import XCTest
@testable import Fuse

/// In-memory AX tree node for exercising NotificationSweep without the
/// live Accessibility API.
final class MockNode: AXTreeNode {
    var mockChildren: [MockNode]
    var mockRole: String?
    var mockSubrole: String?
    var mockActions: [(name: String, description: String?)]
    /// When true, performNodeAction records the attempt but reports failure.
    var failActions: Bool
    private(set) var performedActions: [String] = []

    init(role: String? = nil, subrole: String? = nil,
         actions: [(name: String, description: String?)] = [],
         children: [MockNode] = [], failActions: Bool = false) {
        self.mockRole = role
        self.mockSubrole = subrole
        self.mockActions = actions
        self.mockChildren = children
        self.failActions = failActions
    }

    var childNodes: [MockNode] { mockChildren }
    var nodeRole: String? { mockRole }
    var nodeSubrole: String? { mockSubrole }
    func nodeActions() -> [(name: String, description: String?)] { mockActions }

    @discardableResult
    func performNodeAction(named name: String) -> Bool {
        performedActions.append(name)
        return !failActions
    }
}

final class NotificationSweepTests: XCTestCase {

    // MARK: - SweepMatch (description matchers)

    func testClearAllMatcherAcceptsAndRejects() {
        XCTAssertTrue(SweepMatch.isClearAll("Clear All"))
        XCTAssertTrue(SweepMatch.isClearAll("clear all"))
        XCTAssertTrue(SweepMatch.isClearAll("CLEAR ALL"))
        XCTAssertFalse(SweepMatch.isClearAll(nil))
        XCTAssertFalse(SweepMatch.isClearAll(""))
        XCTAssertFalse(SweepMatch.isClearAll("Close"))
        XCTAssertFalse(SweepMatch.isClearAll("Show Details"))
    }

    func testCloseMatchesCloseAndClearButNotClearAll() {
        XCTAssertTrue(SweepMatch.isClose("Close"))
        XCTAssertTrue(SweepMatch.isClose("close"))
        XCTAssertTrue(SweepMatch.isClose("Clear"))
        XCTAssertFalse(SweepMatch.isClose("Clear All"))
        XCTAssertFalse(SweepMatch.isClose(nil))
    }

    func testExtraPhrasesExtendTheMatchers() {
        XCTAssertFalse(SweepMatch.isClearAll("Alle entfernen"))
        XCTAssertTrue(SweepMatch.isClearAll("Alle entfernen", extraPhrases: ["alle entfernen"]))
    }

    // MARK: - collect

    func testFindsClearAllTwoLevelsDeep() {
        let grandchild = MockNode(role: "AXButton", actions: [(name: "Name:clear-all", description: "Clear All")])
        let child = MockNode(role: "AXGroup", children: [grandchild])
        let root = MockNode(role: "AXWindow", children: [child])

        let items = NotificationSweep.collect(root: root, maxDepth: 12)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].actionName, "Name:clear-all")
        XCTAssertTrue(items[0].isClearAll)
    }

    func testDepthLimitRespected() {
        // Linear chain: root is depth 0; `deepest` (which carries the action)
        // ends up at depth 13 after 13 wraps.
        let deepest = MockNode(actions: [(name: "Name:close", description: "Close")])
        var node = deepest
        for _ in 0..<13 {
            node = MockNode(children: [node])
        }
        let root = node

        XCTAssertTrue(NotificationSweep.collect(root: root, maxDepth: 12).isEmpty,
                      "an action at depth 13 must be ignored when maxDepth is 12")
        XCTAssertEqual(NotificationSweep.collect(root: root, maxDepth: 13).count, 1)
    }

    // MARK: - performSweep

    func testPrefersClearAllOverCloseWhenBothPresent() {
        let closeButton = MockNode(actions: [(name: "Name:close", description: "Close")])
        let clearAllButton = MockNode(actions: [(name: "Name:clear-all", description: "Clear All")])
        let root = MockNode(children: [closeButton, clearAllButton])

        let performed = NotificationSweep.performSweep(root: root, maxDepth: 12)

        XCTAssertEqual(performed, 1)
        XCTAssertEqual(clearAllButton.performedActions, ["Name:clear-all"])
        XCTAssertTrue(closeButton.performedActions.isEmpty,
                      "Close must not fire when a Clear All exists")
    }

    func testPerformsAllCloseActionsWhenNoClearAll() {
        let banners = (0..<3).map { i in
            MockNode(actions: [(name: "Name:close-\(i)", description: "Close")])
        }
        let root = MockNode(children: banners)

        let performed = NotificationSweep.performSweep(root: root, maxDepth: 12)

        XCTAssertEqual(performed, 3)
        for banner in banners {
            XCTAssertEqual(banner.performedActions.count, 1)
        }
    }

    func testEmptyTreeReturnsZero() {
        let root = MockNode()
        XCTAssertTrue(NotificationSweep.collect(root: root, maxDepth: 12).isEmpty)
        XCTAssertEqual(NotificationSweep.performSweep(root: root, maxDepth: 12), 0)
    }

    func testFailedActionsAreNotCounted() {
        let stuck = MockNode(actions: [(name: "Name:close", description: "Close")], failActions: true)
        let root = MockNode(children: [stuck])

        XCTAssertEqual(NotificationSweep.performSweep(root: root, maxDepth: 12), 0)
        XCTAssertEqual(stuck.performedActions, ["Name:close"], "the action must still be attempted")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'SweepMatch' in scope` / `cannot find 'NotificationSweep' in scope` (a compile failure is this step's "red"). Do NOT proceed if the failure is anything else.

- [x] **Step 3: Write `Sources/Notifications/NotificationSweep.swift`** (complete file)

```swift
import Foundation

/// Matches localized AX action descriptions against "clear-ish" phrases.
/// Exact full-string compare, case- and diacritic-insensitive, after trimming
/// whitespace. English defaults; after a macOS update changes the strings,
/// re-dump with AXDump and extend these lists (+ one matcher test per phrase).
enum SweepMatch {
    /// Descriptions meaning "remove this entire app group in one shot".
    static let clearAllPhrases: [String] = ["clear all"]
    /// Descriptions meaning "dismiss this single banner/alert".
    static let closePhrases: [String] = ["close", "clear"]

    static func isClearAll(_ description: String?, extraPhrases: [String] = []) -> Bool {
        matches(description, against: clearAllPhrases + extraPhrases)
    }

    static func isClose(_ description: String?, extraPhrases: [String] = []) -> Bool {
        matches(description, against: closePhrases + extraPhrases)
    }

    private static func matches(_ description: String?, against phrases: [String]) -> Bool {
        guard let description else { return false }
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return phrases.contains { phrase in
            normalized.compare(phrase,
                               options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

/// One performable clear action found during a sweep.
struct SweepPlanItem<Node: AXTreeNode> {
    let node: Node
    let actionName: String
    /// true → "Clear All" (whole app group); false → "Close"/"Clear" (one item).
    let isClearAll: Bool
}

/// Pure sweep algorithm over an abstract AX tree. No Accessibility calls
/// in this file — the live adapter is NotificationClearer.
enum NotificationSweep {
    static let defaultMaxDepth = 12

    /// Walks the tree breadth-first, visiting nodes at depth 0...maxDepth
    /// (root is depth 0), collecting every performable clear action.
    static func collect<Node: AXTreeNode>(root: Node, maxDepth: Int = defaultMaxDepth) -> [SweepPlanItem<Node>] {
        var items: [SweepPlanItem<Node>] = []
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            let (node, depth) = queue[index]
            index += 1
            for action in node.nodeActions() {
                if SweepMatch.isClearAll(action.description) {
                    items.append(SweepPlanItem(node: node, actionName: action.name, isClearAll: true))
                } else if SweepMatch.isClose(action.description) {
                    items.append(SweepPlanItem(node: node, actionName: action.name, isClearAll: false))
                }
            }
            if depth < maxDepth {
                for child in node.childNodes {
                    queue.append((child, depth + 1))
                }
            }
        }
        return items
    }

    /// Strategy: if any "Clear All" items exist, perform ONLY those (they nuke
    /// whole app groups; firing Closes too races the reflowing UI). Otherwise
    /// perform all "Close" items. Returns the number that reported success.
    @discardableResult
    static func performSweep<Node: AXTreeNode>(root: Node, maxDepth: Int = defaultMaxDepth) -> Int {
        let items = collect(root: root, maxDepth: maxDepth)
        let clearAllItems = items.filter(\.isClearAll)
        let toPerform = clearAllItems.isEmpty ? items : clearAllItems
        var performed = 0
        for item in toPerform where item.node.performNodeAction(named: item.actionName) {
            performed += 1
        }
        return performed
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, with all 9 `NotificationSweepTests` listed as passed alongside the pre-existing suites. If any sweep test fails, fix `NotificationSweep.swift` (not the tests) and re-run.

- [x] **Step 5: Commit**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
git add Sources/Notifications/NotificationSweep.swift Tests/FuseTests/NotificationSweepTests.swift
git commit -m "feat(notifications): tested breadth-first sweep algorithm for clear actions"
```

---

### Task 7.3: NotificationClearer (live adapter) + AXDump (recalibration tool)

**Files:**
- Create: `Sources/Notifications/NotificationClearer.swift`
- Create: `Sources/Notifications/AXDump.swift`

OS-integration code: both files talk to the real Notification Center process via AX, so they cannot be unit-tested (hosted tests have no Accessibility grant and must not nuke the developer's notifications anyway). Implement → build; live behavior is HUMAN-VERIFIED in Tasks 7.4 and 7.5. AXDump is REQUIRED, not optional — it is the maintenance hatch for the version-brittle matchers: after a macOS update breaks clearing, the human dumps the tree, reads the new action descriptions, and updates `SweepMatch`'s phrase lists.

- [x] **Step 1: Write `Sources/Notifications/NotificationClearer.swift`** (complete file)

```swift
import AppKit

/// Live adapter: locates the Notification Center process and repeatedly
/// sweeps its windows' AX trees, performing "Clear All"/"Close" actions.
/// THREADING: AX calls block (synchronous IPC). `clearAll()` MUST run off
/// the main thread — NotificationsController uses a utility-QoS queue.
final class NotificationClearer {
    /// The Notification Center UI process. If this stops matching after a
    /// macOS update, probe with:
    ///   osascript -e 'tell application "System Events" to get bundle identifier of every process whose name contains "otification"'
    /// and update this constant (record a Deviation in the plan file).
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// Safety cap on sweep passes per clearAll() call.
    private let maxPasses: Int
    /// Pause between passes — the Notification Center UI needs time to
    /// collapse groups and reflow after actions are performed.
    private let interPassDelay: TimeInterval

    init(maxPasses: Int = 10, interPassDelay: TimeInterval = 0.25) {
        self.maxPasses = maxPasses
        self.interPassDelay = interPassDelay
    }

    /// Sweeps until a pass performs 0 actions or maxPasses is hit.
    /// Returns the total number of clear actions performed.
    func clearAll() -> Int {
        guard PermissionsService.hasAccessibility else {
            Log.notifications.error("clearAll: Accessibility permission missing; prompting")
            DispatchQueue.main.async {
                PermissionsService.promptForAccessibility()
            }
            return 0
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == NotificationClearer.notificationCenterBundleID
        }) else {
            Log.notifications.error("clearAll: Notification Center process not found for bundle id \(NotificationClearer.notificationCenterBundleID, privacy: .public)")
            return 0
        }

        let root = AXElement.application(pid: app.processIdentifier)
        var total = 0
        for pass in 1...maxPasses {
            var performedThisPass = 0
            // root.windows is re-fetched every pass; with zero notifications
            // the window list is typically empty, so this returns instantly.
            for window in root.windows {
                performedThisPass += NotificationSweep.performSweep(root: window, maxDepth: 12)
            }
            total += performedThisPass
            Log.notifications.debug("clearAll pass \(pass): performed \(performedThisPass) action(s)")
            if performedThisPass == 0 { break }
            Thread.sleep(forTimeInterval: interPassDelay)
        }
        Log.notifications.info("clearAll finished: \(total) action(s) performed in total")
        return total
    }
}
```

- [x] **Step 2: Write `Sources/Notifications/AXDump.swift`** (complete file)

```swift
import AppKit

/// Debug/recalibration tool for the notification-clearing feature.
/// Produces an indented text dump of an AX tree: role/subrole/identifier
/// plus every action as "name (localized description)".
enum AXDump {
    static func dumpTree(_ element: AXElement, maxDepth: Int = 12) -> String {
        var lines: [String] = []
        appendNode(element, depth: 0, maxDepth: maxDepth, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendNode(_ element: AXElement, depth: Int, maxDepth: Int,
                                   into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let role = element.role ?? "?"
        let subrole = element.subrole.map { "/\($0)" } ?? ""
        let identifier = element.identifier.map { " id=\($0)" } ?? ""
        var line = "\(indent)\(role)\(subrole)\(identifier)"
        let actionNames = element.actionNames()
        if !actionNames.isEmpty {
            let described = actionNames.map { name in
                "\(name) (\(element.actionDescription(name) ?? "-"))"
            }
            line += "  actions: [" + described.joined(separator: ", ") + "]"
        }
        lines.append(line)
        guard depth < maxDepth else { return }
        for child in element.children {
            appendNode(child, depth: depth + 1, maxDepth: maxDepth, into: &lines)
        }
    }

    /// Dumps the Notification Center AX tree to ~/Desktop/fuse-nc-dump.txt.
    /// Returns the file path, or nil when the NC process is not running or
    /// the file cannot be written. Call off the main thread.
    static func dumpNotificationCenter() -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == NotificationClearer.notificationCenterBundleID
        }) else {
            Log.notifications.error("AXDump: Notification Center process not found")
            return nil
        }
        let root = AXElement.application(pid: app.processIdentifier)
        var text = "Fuse Notification Center AX dump — \(Date())\n"
        text += "pid \(app.processIdentifier), bundle \(NotificationClearer.notificationCenterBundleID)\n"
        text += "\nAPPLICATION ELEMENT (depth 1)\n"
        text += dumpTree(root, maxDepth: 1)
        for (index, window) in root.windows.enumerated() {
            text += "\n\nWINDOW \(index)\n"
            text += dumpTree(window, maxDepth: 12)
        }
        if root.windows.isEmpty {
            text += "\n\n(no windows — post a test notification first, then re-dump)\n"
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/fuse-nc-dump.txt")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Log.notifications.error("AXDump: writing dump failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        Log.notifications.info("AXDump: wrote \(path, privacy: .public)")
        return path
    }
}
```

- [x] **Step 3: Regenerate, build**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 4: Commit**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
git add Sources/Notifications/NotificationClearer.swift Sources/Notifications/AXDump.swift
git commit -m "feat(notifications): live clearer with multi-pass sweep and AX tree dumper"
```

---

### Task 7.4: NotificationsController + AppDelegate integration

**Files:**
- Create: `Sources/Notifications/NotificationsController.swift`
- Modify: `Sources/App/AppDelegate.swift` (anchor inserts only)

The controller owns: the `.clearNotifications` hotkey (⌃⌥⌫ — defined ONLY in `Sources/Core/HotkeyNames.swift`; never define new `KeyboardShortcuts.Name` constants), the status-bar menu action, and the optional auto-clear timer. It subclasses `NSObject` because the NSMenuItem target/action mechanism requires Objective-C messaging.

- [x] **Step 1: Write `Sources/Notifications/NotificationsController.swift`** (complete file)

```swift
import AppKit
import KeyboardShortcuts

/// Owns the clear-notifications hotkey, the status-bar menu action, the
/// optional auto-clear timer, and the background queue all sweeps run on.
/// NSObject subclass: NSMenuItem target/action requires ObjC messaging.
final class NotificationsController: NSObject {
    static let autoClearEnabledKey = "notifications.autoClearEnabled"
    static let autoClearIntervalKey = "notifications.autoClearIntervalMinutes"

    private let clearer = NotificationClearer()
    /// AX calls block; every sweep runs here, never on the main thread.
    private let queue = DispatchQueue(label: "com.rgv250cc.Fuse.notifications", qos: .utility)
    private var autoClearTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    /// Call once from applicationDidFinishLaunching (after its XCTestCase
    /// guard, so hotkeys/timers never start inside hosted test runs).
    func start() {
        UserDefaults.standard.register(defaults: [
            Self.autoClearEnabledKey: false,
            Self.autoClearIntervalKey: 30,
        ])

        KeyboardShortcuts.onKeyDown(for: .clearNotifications) { [weak self] in
            self?.clearNow()
        }

        rebuildAutoClearTimer()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            self?.rebuildAutoClearTimer()
        }

        Log.notifications.info("NotificationsController started")
    }

    /// Hotkey, menu item, and auto-clear timer all funnel through here.
    /// Main-thread safe: the AX work is dispatched to the utility queue.
    @objc func clearNow() {
        queue.async { [clearer] in
            let performed = clearer.clearAll()
            Log.notifications.info("clearNow: \(performed) clear action(s) performed")
        }
    }

    // MARK: - Auto-clear timer

    private var isAutoClearEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoClearEnabledKey)
    }

    private var autoClearIntervalMinutes: Int {
        min(240, max(5, UserDefaults.standard.integer(forKey: Self.autoClearIntervalKey)))
    }

    /// Runs on the main queue. UserDefaults.didChangeNotification fires for
    /// ANY default change, so this early-returns unless the effective timer
    /// configuration actually changed.
    private func rebuildAutoClearTimer() {
        let wanted: TimeInterval? = isAutoClearEnabled ? TimeInterval(autoClearIntervalMinutes * 60) : nil
        let current: TimeInterval? = autoClearTimer.map { $0.timeInterval }
        guard wanted != current else { return }

        autoClearTimer?.invalidate()
        autoClearTimer = nil

        guard let interval = wanted else {
            Log.notifications.info("auto-clear disabled")
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.clearNow()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        autoClearTimer = timer
        Log.notifications.info("auto-clear enabled, every \(Int(interval / 60)) min")
    }

    deinit {
        autoClearTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
}
```

- [x] **Step 2: Wire the controller into `Sources/App/AppDelegate.swift` via the three anchors**

ORDERING NOTE (do not "simplify" this away): inside `applicationDidFinishLaunching`, the `// FUSE:MENU-ITEMS` anchor executes BEFORE `// FUSE:CONTROLLER-START`. The controller does not exist yet while the menu is being built, so the menu item is held in a property and its `target` is assigned in the CONTROLLER-START block, right after construction.

Edit 1 — insert directly ABOVE the line `// FUSE:CONTROLLER-PROPS` (keep the anchor line; do not touch any other lines already above it):

```swift
    private var notificationsController: NotificationsController!
    private var clearNotificationsMenuItem: NSMenuItem!
```

Edit 2 — insert directly ABOVE the line `// FUSE:MENU-ITEMS` (keep the anchor line):

```swift
        clearNotificationsMenuItem = NSMenuItem(
            title: "Clear Notifications",
            action: #selector(NotificationsController.clearNow),
            keyEquivalent: "")
        menu.addItem(clearNotificationsMenuItem)
```

Edit 3 — insert directly ABOVE the line `// FUSE:CONTROLLER-START` (keep the anchor line):

```swift
        notificationsController = NotificationsController()
        notificationsController.start()
        clearNotificationsMenuItem.target = notificationsController
```

- [x] **Step 3: Build and test** (the AppDelegate XCTestCase guard must keep tests green)

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — hotkey and menu item clear live notifications**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to do EXACTLY this and report each observation:
1. Confirm Accessibility is granted (Fuse Settings → General → green checkmark). If the row is red even though System Settings shows Fuse enabled, this is the TCC/ad-hoc-signing cache (master plan §10): remove Fuse from System Settings → Privacy & Security → Accessibility and re-add `.build/Build/Products/Debug/Fuse.app`, then relaunch Fuse.
2. Post three test notifications (they appear under the Script Editor/osascript app identity — if nothing appears, allow notifications for Script Editor in System Settings → Notifications, set its style to Banners or Alerts, and re-run):
```bash
osascript -e 'display notification "hello one" with title "Fuse QA"'
osascript -e 'display notification "hello two" with title "Fuse QA"'
osascript -e 'display notification "hello three" with title "Fuse QA Other"'
```
3. While at least one banner is still on screen, press **⌃⌥⌫**. Expected: every banner disappears within ~2 seconds, with no mouse movement.
4. Post the three notifications again, wait ~10 s for the banners to slide away, then click the clock in the menu bar to open the Notification Center drawer — the entries are there. Close the drawer, press **⌃⌥⌫**, reopen the drawer. Expected: the drawer is empty.
5. Post one more notification, then use the status-bar menu: Fuse bolt icon → "Clear Notifications". Expected: same result as the hotkey (and the menu item is enabled, not grayed out).
6. Check the log shows non-zero counts:
```bash
log show --last 5m --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "notifications"' | tail -20
```
Expected: lines like `clearAll finished: N action(s) performed in total` with N ≥ 1, and `clearNow: N clear action(s) performed`.

If step 3/4 clears nothing (count stays 0): the matchers need recalibration for this macOS version — finish Task 7.5 first (it adds the dump button), run the dump, and follow the recalibration procedure in `## Risks & gotchas`. Record a Deviation.

- [x] **Step 5: Commit**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
git add Sources/Notifications/NotificationsController.swift Sources/App/AppDelegate.swift
git commit -m "feat(notifications): controller with hotkey, menu item, and auto-clear timer"
```

---

### Task 7.5: NotificationsSettingsView + settings tab

**Files:**
- Create: `Sources/Notifications/NotificationsSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (anchor insert only)

- [x] **Step 1: Write `Sources/Notifications/NotificationsSettingsView.swift`** (complete file)

```swift
import KeyboardShortcuts
import SwiftUI

struct NotificationsSettingsView: View {
    @AppStorage("notifications.autoClearEnabled") private var autoClearEnabled = false
    @AppStorage("notifications.autoClearIntervalMinutes") private var autoClearIntervalMinutes = 30
    @State private var lastClearResult: String?
    @State private var lastDumpResult: String?
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading) {
                            Text("Accessibility permission required")
                            Text("Fuse clears notifications by performing Notification Center's accessibility actions.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForAccessibility()
                            PermissionsService.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }

            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Clear notifications", name: .clearNotifications)
                HStack {
                    Button("Clear now") {
                        lastClearResult = "Clearing…"
                        DispatchQueue.global(qos: .utility).async {
                            let performed = NotificationClearer().clearAll()
                            DispatchQueue.main.async {
                                lastClearResult = "Performed \(performed) clear action(s)"
                            }
                        }
                    }
                    if let lastClearResult {
                        Text(lastClearResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Auto-clear") {
                Toggle("Clear automatically on a schedule", isOn: $autoClearEnabled)
                Stepper("Every \(autoClearIntervalMinutes) minutes",
                        value: $autoClearIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoClearEnabled)
                Text("Auto-clear silently dismisses every notification on the schedule — including ones you haven't read yet. That's why it ships OFF.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Debug") {
                Button("Dump Notification Center AX tree (debug)") {
                    lastDumpResult = "Dumping…"
                    DispatchQueue.global(qos: .utility).async {
                        let path = AXDump.dumpNotificationCenter()
                        DispatchQueue.main.async {
                            lastDumpResult = path ?? "Notification Center process not found"
                        }
                    }
                }
                if let lastDumpResult {
                    Text(lastDumpResult).font(.caption).textSelection(.enabled)
                }
                Text("If clearing stops working after a macOS update: dump the tree, find the new action descriptions, and update SweepMatch in NotificationSweep.swift.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Fuse performs Notification Center's own \"Clear All\" and \"Close\" accessibility actions — the same clicks you would make by hand, just automated. Focus and Do Not Disturb don't block it: clearing empties the notification drawer; it never suppresses new arrivals.")
                    .font(.caption).foregroundStyle(.secondary)
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

- [x] **Step 2: Add the tab in `Sources/App/SettingsRootView.swift`**

Insert directly ABOVE the line `// FUSE:SETTINGS_TABS` (keep the anchor line; do not touch tabs other phases may already have inserted above it):

```swift
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
```

- [x] **Step 3: Build and test**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — settings tab and AX dump**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to:
1. Open Fuse Settings → confirm a "Notifications" tab (bell.badge icon) exists, showing the shortcut recorder (displaying ⌃⌥⌫), the auto-clear toggle (OFF) with a disabled stepper reading "Every 30 minutes", the "Clear now" button, and the debug dump button. Toggle auto-clear ON → stepper enables; toggle OFF again.
2. Post two test notifications so the tree has content:
```bash
osascript -e 'display notification "hello" with title "Fuse QA"'
osascript -e 'display notification "world" with title "Fuse QA"'
```
3. While the banners are visible (or with the drawer open), click "Dump Notification Center AX tree (debug)". Expected: the path `~/Desktop/fuse-nc-dump.txt` appears under the button.
4. Open the dump (`open ~/Desktop/fuse-nc-dump.txt`) and confirm it contains indented role lines with actions, including descriptions matching the matchers — e.g. `... (Clear All)` and/or `... (Close)`.
5. **If the descriptions on this macOS 26.x install differ** (different wording, different language): add the exact strings seen in the dump to `SweepMatch.clearAllPhrases` / `SweepMatch.closePhrases` in `Sources/Notifications/NotificationSweep.swift` (lowercase), add one matcher assertion per new phrase to `NotificationSweepTests`, re-run the tests, and record a Deviation. Then redo Task 7.4 Step 4.
6. Click "Clear now" → expected caption "Performed N clear action(s)" with N ≥ 1 and the notifications disappear.

- [x] **Step 5: Commit**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
git add Sources/Notifications/NotificationsSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(notifications): settings tab with hotkey recorder, auto-clear, and AX dump"
```

---

### Task 7.6: End-to-end scenarios (HUMAN-VERIFY)

**Files:**
- None created or modified. Verification only — no commit at the end of this task.

- [ ] **Step 1: HUMAN-VERIFY — zero-notification no-op**

With Notification Center completely empty (drawer empty, no banners), press **⌃⌥⌫**. Expected: nothing visible happens, no beep, no crash. Then:

```bash
log show --last 2m --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "notifications"' | tail -10
```
Expected: `clearAll finished: 0 action(s) performed in total` — a silent, instant no-op.

- [ ] **Step 2: HUMAN-VERIFY — auto-clear timer**

Ask the human to:
1. Open Fuse Settings → Notifications, toggle auto-clear ON, and step the interval down to **5 minutes** (do NOT hardcode a shorter interval in code — verify the real path).
2. Post one notification: `osascript -e 'display notification "auto-clear me" with title "Fuse QA"'`
3. Wait — up to 5 minutes after toggling (post the notification ~1 minute before the expected tick if convenient). Expected: the notification vanishes on its own at the tick; the log shows a `clearNow:` line with count ≥ 1 around that time.
4. Toggle auto-clear OFF and set the stepper back to 30. Expected: log line `auto-clear disabled`.

- [ ] **Step 3: HUMAN-VERIFY — missing Accessibility degrades gracefully**

Ask the human to:
1. Open System Settings → Privacy & Security → Accessibility and toggle Fuse OFF (do not remove it).
2. Press **⌃⌥⌫**. Expected: Fuse does NOT crash; the system Accessibility prompt (or System Settings) appears; the log shows `clearAll: Accessibility permission missing; prompting` and a count of 0.
3. Re-enable Fuse in the Accessibility list. If clearing still fails afterwards, remove Fuse from the list entirely and re-add `.build/Build/Products/Debug/Fuse.app` (TCC signature cache, master plan §10), then relaunch.
4. Press **⌃⌥⌫** with a test notification posted. Expected: clearing works again.

- [x] **Step 4: Final green run**

```bash
cd /Users/rgv250cc/Documents/Projects/Fuse
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`. Confirm `git status` shows a clean tree (all Phase 7 work committed in Tasks 7.1–7.5).

---

### Task 7.7: Honor the global pause switch (auto-clear only)

Precondition: `Sources/Core/PauseManager.swift` exists (Phase 1 Task 1.7). Semantics: while paused, the hotkey is already dead globally (`KeyboardShortcuts.isEnabled = false`), and the status-menu "Clear Notifications" item DELIBERATELY keeps working (an explicit click is user intent — pause exists to stop interception and automation). Only the automatic timer must no-op.

**Files:**
- Modify: `Sources/Notifications/NotificationsController.swift`

- [x] **Step 1: Gate the timer callback.** In `rebuildAutoClearTimer()`, replace:

```swift
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.clearNow()
        }
```

with:

```swift
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard !PauseManager.shared.isPaused else { return }   // pause = no automation
            self?.clearNow()
        }
```

- [x] **Step 2: Build and run unit tests**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: HUMAN-VERIFY — paused timer skips, menu still works**

Enable auto-clear at 5 minutes; post a test notification (`osascript -e 'display notification "pause test" with title "Fuse QA"'`); "Pause Fuse"; wait past the tick → notification SURVIVES; while still paused, click the status-menu "Clear Notifications" item → it clears (explicit intent honored); resume.

- [x] **Step 4: Commit**

```bash
git add Sources/Notifications/NotificationsController.swift
git commit -m "feat(notifications): auto-clear timer no-ops while Fuse is paused"
```

---

## Manual verification checklist

- [ ] **HUMAN-VERIFY** ⌃⌥⌫ clears visible banners within ~2 s, hands-free (Task 7.4 Step 4.3).
- [ ] **HUMAN-VERIFY** Drawer entries clear with the drawer closed, confirmed by reopening it (Task 7.4 Step 4.4).
- [ ] **HUMAN-VERIFY** Status-bar "Clear Notifications" menu item is enabled and works (Task 7.4 Step 4.5).
- [ ] **HUMAN-VERIFY** Settings tab renders; recorder shows ⌃⌥⌫; stepper disabled while toggle is off (Task 7.5 Step 4.1).
- [ ] **HUMAN-VERIFY** AX dump writes `~/Desktop/fuse-nc-dump.txt` containing action descriptions ("Clear All"/"Close" or this OS's equivalents) (Task 7.5 Step 4.3–4.4).
- [ ] **HUMAN-VERIFY** "Clear now" button reports a non-zero count and clears (Task 7.5 Step 4.6).
- [ ] **HUMAN-VERIFY** Zero notifications → silent no-op, log shows 0 (Task 7.6 Step 1).
- [ ] **HUMAN-VERIFY** Auto-clear at a 5-minute interval clears an unattended notification; default remains OFF (Task 7.6 Step 2).
- [ ] **HUMAN-VERIFY** Revoked Accessibility → prompt, no crash; re-grant restores function (Task 7.6 Step 3).
- [x] All unit tests green: `xcodebuild ... test` → `** TEST SUCCEEDED **` (includes the 9 `NotificationSweepTests`).
- [x] `git log --oneline | head -5` shows the five Phase 7 commits on top.

## Risks & gotchas

- **Version brittleness is the design constraint, not a bug.** The feature drives private Notification Center UI via localized AX action descriptions; Apple changes both the tree layout and the strings between macOS releases (demonstrably even between 15.0.1 and 15.1). Recalibration when clearing performs 0 actions with notifications present: (1) post test notifications, (2) Settings → Notifications → dump button, (3) read the action descriptions in `~/Desktop/fuse-nc-dump.txt`, (4) add the new lowercase phrases to `SweepMatch.clearAllPhrases` / `closePhrases`, (5) add a matcher test per phrase, re-run tests, (6) record a Deviation at the bottom of this file. Routine maintenance.
- **Bundle id drift.** If no running process has bundle id `com.apple.notificationcenterui`, probe with `osascript -e 'tell application "System Events" to get bundle identifier of every process whose name contains "otification"'`, update `NotificationClearer.notificationCenterBundleID`, record a Deviation.
- **TCC caches grants by code signature** (master plan §10). With ad-hoc signing, a rebuilt Fuse may silently lose Accessibility while System Settings still shows it granted — `clearAll()` then logs 0 forever. Remove Fuse from the Accessibility list and re-add the current `.build/Build/Products/Debug/Fuse.app`. Suspect this FIRST whenever AX returns nothing.
- **Never run AX on the main thread.** AX attribute/action calls are synchronous IPC and can block for seconds. Every live sweep and dump in this phase runs on a utility-QoS queue; keep it that way.
- **Drawer-closed clearing** is expected to work because the NC process keeps its notification window populated while entries exist. If on this macOS version it only works with the drawer open, document "open the drawer first" as supported behavior and record a Deviation — do not synthesize clicks on the menu-bar clock.
- **"Clear All" preference is load-bearing.** Firing individual "Close" actions while a "Clear All" exists races the reflowing UI (group collapse invalidates sibling elements mid-sweep). Hence `performSweep` performs ONLY clearAll items when present, and `NotificationClearer` re-walks fresh `root.windows` each pass with a 250 ms pause.
- **`UserDefaults.didChangeNotification` fires for every default of every feature.** `rebuildAutoClearTimer()` must keep its early-return guard or unrelated settings changes churn the timer constantly.
- **osascript test notifications** appear under the Script Editor identity; they show nothing if Script Editor's notifications are disabled or styled "None" — fix in System Settings → Notifications before concluding the feature is broken.
- **Auto-clear is destructive by design** — it dismisses notifications the user never saw. The default ships OFF; do not change it.

## Deviations

- No API drift: `AXElement` (Sources/Core/AX.swift), `PermissionsService`, `Log.notifications`, `PauseManager`, and the `.clearNotifications` hotkey all matched the plan exactly; every file was written verbatim from the plan.
- All HUMAN-VERIFY steps (Tasks 7.4 Step 4, 7.5 Step 4, 7.6 Steps 1–3, 7.7 Step 3, and the Manual verification checklist) were SKIPPED — this run was non-interactive with no GUI/Accessibility access, so live behavior against Notification Center is unverified. The full unit suite (15 pre-existing + 9 NotificationSweepTests = 24) is green.
