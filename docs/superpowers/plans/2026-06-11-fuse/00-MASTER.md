# Fuse — Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute **one phase plan per session**, in order (Phases 2–7 may run in any order after Phase 1). Always read this master file before starting any phase plan.

**Goal:** Build "Fuse" — a single macOS 14+ menu-bar app for Apple Silicon that replaces six separate utilities: push-to-talk local Whisper dictation, Rectangle-style window tiling, a smart clipboard history with paste picker, a Downie-style video downloader, per-device scroll-direction reversal, and one-keystroke notification clearing.

**Architecture:** A non-sandboxed, ad-hoc-signed (Developer ID at packaging time) AppKit menu-bar app (`LSUIElement`) with a SwiftUI settings window. One Xcode target, one folder per feature, a small `Core/` layer shared by all features (permissions, AX wrapper, paste synthesis, hotkey names). Project file is generated from `project.yml` by XcodeGen so agents never hand-edit `.pbxproj`. Pure logic is unit-tested with XCTest; OS-integration code is verified through explicit HUMAN-VERIFY checklists.

**Tech Stack:** Swift 5.10+, AppKit + SwiftUI, XcodeGen, XCTest, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (global hotkeys + recorder UI), [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML Whisper, Apple Silicon optimized), [GRDB](https://github.com/groue/GRDB.swift) (SQLite clipboard store), bundled `yt-dlp` binary (+ Homebrew `ffmpeg`) for downloads, CGEventTap (scroll), AXUIElement (tiling + notification clearing), AVAudioEngine (audio capture).

---

## 1. Product summary

| # | Feature | Replaces | Phase | Plan file |
|---|---------|----------|-------|-----------|
| — | App shell (menu bar, settings window, build system) | — | 0 | `01-phase0-scaffold.md` |
| — | Core services (permissions, paste, AX, hotkey names) | — | 1 | `02-phase1-core.md` |
| 1 | Scroll direction control per device class | Scroll Reverser | 2 | `03-phase2-scroll-reverser.md` |
| 2 | Window tiling via keyboard shortcuts | Rectangle | 3 | `04-phase3-window-tiling.md` |
| 3 | Clipboard history + paste picker (text/RTF/images/files/links) | Paste/Maccy | 4 | `05-phase4-clipboard.md` |
| 4 | Hold-hotkey voice recording → local Whisper → auto-paste | Wispr Flow / superwhisper | 5 | `06-phase5-voice.md` |
| 5 | Smart video downloader (any site yt-dlp supports) | Downie | 6 | `07-phase6-downloader.md` |
| 6 | Clear all macOS notifications via hotkey / on schedule | manual clicking | 7 | `08-phase7-notifications.md` |
| 7 | Quick-capture notes panel: hotkey-toggled, block-based (text / code / image / link), per-block copy, Markdown export | Heynote / Apple Quick Note | 8 | `09-phase8-notes.md` |
| — | Packaging: signing, notarization, DMG, final QA | — | 9 | `10-phase9-packaging.md` |

## 2. Architecture decisions (locked — do not revisit during execution)

| Decision | Choice | Rejected alternative & why |
|----------|--------|---------------------------|
| App model | AppKit `NSApplicationDelegate` + `NSStatusItem`, `LSUIElement=true` | SwiftUI `MenuBarExtra`: less control over panels, status item, and lifecycle hooks the features need |
| Sandbox | **Not sandboxed** | Accessibility API, CGEventTap, and pasting into other apps are impossible in the sandbox. No App Store distribution. |
| Project file | XcodeGen `project.yml`; `Fuse.xcodeproj` is generated and **git-ignored** | Hand-maintained pbxproj: merge hell for agents. SPM-only app bundles: fragile Info.plist/bundle handling |
| Modularity | One app target, folder-per-feature, shared `Core/` | Local SPM package per feature: more correct long-term but doubles build-config surface for the executing model |
| Whisper runtime | WhisperKit (CoreML) | whisper.cpp bindings: faster cold-start but manual model management and C interop; WhisperKit is Swift-native and auto-downloads models |
| Clipboard store | GRDB/SQLite | SwiftData: poor fit for BLOB-heavy rows + harder to unit test; raw SQLite: too error-prone |
| Video downloads | Drive a managed `yt-dlp` binary via `Process` | Reimplementing extractors: absurd; yt-dlp supports ~1800 sites and is the engine Downie-class apps effectively compete with |
| Notification clearing | AX traversal of the `com.apple.notificationcenterui` process, performing its "Clear All"/"Close" actions | No public API exists. AppleScript UI scripting: same mechanism, slower and harder to debug. This is the one **version-brittle** feature; see §10 |
| Hotkeys | KeyboardShortcuts package | Carbon `RegisterEventHotKey` direct: no recorder UI, more code; CGEventTap for hotkeys: overkill and needs extra permissions |
| Notes editor | Block-based model: a note is an ordered list of text/code/image/link blocks, each rendered by its own small SwiftUI editor; stored in GRDB | Single `NSTextView` with RTFD image attachments: per-block copy is impossible, attachment handling is fragile, and nothing is unit-testable |

## 3. Dependencies (declared once in Phase 0 `project.yml`)

- `KeyboardShortcuts` from `2.0.0` — global shortcuts, supports `onKeyDown` **and** `onKeyUp` (required for push-to-talk hold).
- `WhisperKit` from `0.9.0` — requires macOS 14+, hence our deployment target.
- `GRDB.swift` from `6.27.0` — `DatabaseQueue`, migrations, in-memory DBs for tests.
- Binaries (Phase 6): `yt-dlp_macos` downloaded into Application Support at runtime; `ffmpeg` resolved from Homebrew with a settings-UI fallback message.

First build downloads all SPM dependencies (WhisperKit pulls swift-transformers) — expect **5–10 minutes once**; do not interpret as a hang.

## 4. Permissions matrix

| Permission | Needed by | API used | Granted via |
|------------|-----------|----------|-------------|
| Accessibility | Tiling (AX window moves), Paste synthesis (clipboard/voice), Notification clearing (AX actions), Scroll tap (modifying CGEventTap) | `AXIsProcessTrusted`, `CGEvent.tapCreate` | System Settings → Privacy & Security → Accessibility |
| Input Monitoring | Sometimes additionally demanded for HID-level event taps on modern macOS | `IOHIDCheckAccess` / `IOHIDRequestAccess` | Privacy & Security → Input Monitoring |
| Microphone | Voice recording | `AVCaptureDevice.requestAccess(for: .audio)` | Prompted on first record; usage string in Info.plist |

`Core/Permissions.swift` (Phase 1) wraps all checks/prompts; the General settings tab shows live status with "Open System Settings" buttons.

## 5. Repository layout (target state)

```
Fuse/
├── project.yml                  # XcodeGen definition (source of truth)
├── Brewfile                     # xcodegen
├── Info.plist                   # GENERATED by xcodegen (git-ignored)
├── Fuse.entitlements            # GENERATED by xcodegen (git-ignored)
├── Sources/
│   ├── App/
│   │   ├── main.swift
│   │   ├── AppDelegate.swift            # status item, controller registry (anchored)
│   │   ├── SettingsRootView.swift       # TabView (anchored)
│   │   └── GeneralSettingsView.swift
│   ├── Core/
│   │   ├── Log.swift
│   │   ├── Permissions.swift            # PermissionsService
│   │   ├── AX.swift                     # AXElement wrapper
│   │   ├── PasteService.swift           # pasteboard snapshot/write/restore + ⌘V synthesis
│   │   └── HotkeyNames.swift            # ALL KeyboardShortcuts.Name constants + defaults
│   ├── ScrollControl/                   # Phase 2
│   ├── Tiling/                          # Phase 3
│   ├── Clipboard/                       # Phase 4
│   ├── Voice/                           # Phase 5
│   ├── Downloader/                      # Phase 6
│   ├── Notifications/                   # Phase 7
│   └── Notes/                           # Phase 8
├── Tests/FuseTests/                     # XCTest unit tests (hosted in Fuse.app)
├── Resources/                           # Assets.xcassets, .gitkeep
├── scripts/                             # packaging helpers (Phase 8)
└── docs/superpowers/plans/2026-06-11-fuse/   # these plans
```

## 6. Shared contracts (defined in Phases 0–1; later phases consume, never redefine)

### 6.1 Code anchors (exact comment lines; feature phases insert code ABOVE them)

| File | Anchor | What gets inserted |
|------|--------|--------------------|
| `Sources/App/AppDelegate.swift` | `// FUSE:CONTROLLER-PROPS` | `private var xController: XController!` property |
| `Sources/App/AppDelegate.swift` | `// FUSE:CONTROLLER-START` | controller construction/start call |
| `Sources/App/AppDelegate.swift` | `// FUSE:MENU-ITEMS` | feature-specific status-bar menu items (e.g. "Downloads…", "Clear Notifications") |
| `Sources/App/SettingsRootView.swift` | `// FUSE:SETTINGS_TABS` | the feature's `.tabItem` entry |

Anchors make phase plans order-independent. Never reference line numbers in cross-phase edits; always reference anchors.

### 6.2 Core API surface (signatures are authoritative; bodies in `02-phase1-core.md`)

```swift
// Core/Permissions.swift
enum PermissionsService {
    static var hasAccessibility: Bool { get }          // AXIsProcessTrusted()
    static func promptForAccessibility()               // AXIsProcessTrustedWithOptions(prompt)
    static var hasInputMonitoring: Bool { get }        // IOHIDCheckAccess(.listenEvent)
    static func promptForInputMonitoring()             // IOHIDRequestAccess
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void)
    static func openSystemSettings(pane: SettingsPane) // deep links, see Phase 1
}

// Core/PasteService.swift
enum PasteService {
    static let fuseInternalMarker: NSPasteboard.PasteboardType  // "com.rgv250cc.fuse.internal"
    typealias ItemRepresentation = [NSPasteboard.PasteboardType: Data]
    static func snapshot(of pasteboard: NSPasteboard) -> [ItemRepresentation]
    static func write(_ items: [ItemRepresentation], to pasteboard: NSPasteboard, markInternal: Bool)
    static func paste(_ items: [ItemRepresentation], restoreAfter seconds: Double)  // write → ⌘V → restore snapshot
    static func paste(text: String, restoreAfter seconds: Double)
    static func synthesizeCmdV()
}
// Anything Fuse itself puts on the general pasteboard carries fuseInternalMarker.
// The clipboard watcher (Phase 4) MUST skip items carrying it.

// Core/AX.swift — thin Swift wrapper over AXUIElement (used by Tiling + Notifications)
struct AXElement {
    let raw: AXUIElement
    static func systemWide() -> AXElement
    static func application(pid: pid_t) -> AXElement
    func copyValue(_ attribute: String) -> AnyObject?
    var role: String? { get }
    var subrole: String? { get }
    var title: String? { get }
    var identifier: String? { get }
    var children: [AXElement] { get }
    var windows: [AXElement] { get }
    var focusedWindow: AXElement? { get }
    var position: CGPoint? { get }
    var size: CGSize? { get }
    func setPosition(_ point: CGPoint) -> Bool
    func setSize(_ size: CGSize) -> Bool
    func actionNames() -> [String]
    func actionDescription(_ action: String) -> String?
    @discardableResult func perform(_ action: String) -> Bool
}

// Core/PauseManager.swift — global kill switch (Phase 1 Task 1.7)
final class PauseManager {
    static let shared: PauseManager
    static let pauseStateChanged: Notification.Name
    private(set) var isPaused: Bool   // in-memory only; relaunch always resumes
    func setPaused(_ paused: Bool)    // flips KeyboardShortcuts.isEnabled, posts pauseStateChanged
    func toggle()
}
// Continuously-running services (scroll tap, clipboard watcher, notification
// auto-clear timer, voice recorder) MUST observe pauseStateChanged.
// Hotkey-only features need nothing — KeyboardShortcuts.isEnabled covers them.

// Core/ConflictDetector.swift — overlapping-utility detection (Phase 1 Task 1.8)
struct AppConflict: Equatable, Identifiable {
    let bundleID: String; let appName: String; let fuseFeature: String; let advice: String
}
enum ConflictDetector {
    static let knownConflicts: [String: (name: String, feature: String, advice: String)]
    static func conflicts(amongBundleIDs: Set<String>) -> [AppConflict]   // pure, tested
    static func currentConflicts() -> [AppConflict]                       // NSWorkspace-backed
}
```

### 6.3 Global hotkey registry (`Core/HotkeyNames.swift`, all defaults live HERE — no feature may invent a hotkey elsewhere)

| Constant | Default | Behavior |
|----------|---------|----------|
| `.pushToTalk` | ⌃⌥Space (hold) | keyDown starts recording, keyUp stops + transcribes + pastes |
| `.pastePicker` | ⇧⌘V | opens clipboard picker panel |
| `.clearNotifications` | ⌃⌥⌫ | clears all notifications |
| `.tileLeftHalf` / `.tileRightHalf` / `.tileTopHalf` / `.tileBottomHalf` | ⌃⌥← / ⌃⌥→ / ⌃⌥↑ / ⌃⌥↓ | tile halves |
| `.tileTopLeft` / `.tileTopRight` / `.tileBottomLeft` / `.tileBottomRight` | ⌃⌥1 / ⌃⌥2 / ⌃⌥3 / ⌃⌥4 | tile quarters |
| `.tileMaximize` | ⌃⌥↩ | fill visible frame |
| `.tileCenter` | ⌃⌥C | center, keep size |
| `.tileNextDisplay` | ⌃⌥N | move window to next screen |
| `.toggleNotesPanel` | ⌃⌥M | show/hide the quick-notes panel |

### 6.4 UserDefaults keys (convention: `"<feature>.<name>"`)

| Key | Type | Default |
|-----|------|---------|
| `scroll.enabled` | Bool | true |
| `scroll.reverseTrackpad` | Bool | true |
| `scroll.reverseMouse` | Bool | true |
| `scroll.reverseHorizontal` | Bool | false |
| `tiling.enabled` | Bool | true |
| `tiling.gap` | Double | 0 |
| `clipboard.enabled` | Bool | true |
| `clipboard.maxItems` | Int | 500 |
| `voice.modelName` | String | `"openai_whisper-base.en"` |
| `voice.language` | String | `"en"` |
| `downloader.destinationPath` | String | `~/Downloads` |
| `downloader.qualityPreset` | String | `"best"` |
| `downloader.maxConcurrent` | Int | 2 |
| `notifications.autoClearEnabled` | Bool | false |
| `notifications.autoClearIntervalMinutes` | Int | 30 |
| `notes.panelPinned` | Bool | false |
| `clipboard.excludedApps` | [String] (via `stringArray(forKey:)`) | [] |
| `core.didRunBefore` | Bool | false |

### 6.5 Identity

- Bundle id: `com.rgv250cc.Fuse` (prefix `com.rgv250cc` in project.yml).
- App Support dir: `~/Library/Application Support/Fuse/` (clipboard DB, managed `bin/yt-dlp`, model cache).

## 7. Phase ordering & dependency graph

```
Phase 0 (scaffold) ──► Phase 1 (core) ──► Phases 2,3,4,5,6,7,8 (independent of each other;
                                          4, 5, and 8 use Core's PasteService)
All ──► Phase 9 (packaging)
```

Recommended order (risk-ascending, value-early): 0 → 1 → 2 (scroll) → 3 (tiling) → 4 (clipboard) → 5 (voice) → 6 (downloader) → 7 (notifications) → 8 (notes) → 9. Phases 2–8 are mutually independent thanks to the anchors in §6.1 — a blocked phase never blocks the others.

## 8. Build & test commands (identical in every phase)

```bash
# regenerate project after ANY file add/remove (xcodegen globs Sources/, Tests/, Resources/)
xcodegen generate

# build
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
# expect: ** BUILD SUCCEEDED **

# unit tests
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
# expect: ** TEST SUCCEEDED **

# run the app / stop it
open .build/Build/Products/Debug/Fuse.app
pkill -x Fuse
```

## 9. Execution protocol for the implementing model

1. Work through tasks **in order**; tick checkboxes as you go.
2. Never skip a "run the test / build" step. If output differs from the stated expectation, **stop and fix before proceeding** — do not continue on a red build.
3. Steps marked **HUMAN-VERIFY** require a human at the GUI (granting permissions, watching a window move, hearing audio). Pause and ask the user to perform them; record their answer before continuing.
4. After creating or deleting any source file: `xcodegen generate` before building.
5. Commit exactly where the plan says, with the given message (conventional commits).
6. If an external API doesn't match the plan's code (library minor-version drift), fix the call site minimally, note the deviation at the bottom of the plan file under `## Deviations`, and continue.
7. Plans never reference line numbers across phases — only the §6.1 anchors.

## 10. Development gotchas (read before every phase)

- **TCC caches grants by code signature.** With ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`), a rebuilt binary may silently lose Accessibility permission while System Settings still shows it granted. Fix: remove Fuse from the Accessibility list and re-add `.build/Build/Products/Debug/Fuse.app`. If AX calls mysteriously fail, suspect this **first**.
- **AX coordinates are top-left origin** (global display space); `NSScreen` frames are bottom-left origin. All conversions go through the tested helper in Phase 3 — never flip ad hoc.
- **Event taps get disabled by the OS** under load (`tapDisabledByTimeout`) — every tap callback must handle re-enabling (Phase 2 shows the pattern).
- **Hosted unit tests launch the real app.** `AppDelegate.applicationDidFinishLaunching` begins with an `XCTestCase` guard so taps/hotkeys/watchers never start inside test runs. Keep it.
- **Notification clearing is version-brittle by nature** (private UI traversal). Phase 7 ships an AX tree dumper; on any macOS update, re-dump and adjust matchers. This is expected maintenance, not a bug.
- macOS on this machine is **26.5**; deployment target stays 14.0, but HUMAN-VERIFY outcomes (especially Phase 7) are validated against 26.x.

## 11. Risk register

| Risk | Severity | Mitigation |
|------|----------|------------|
| Notification Center AX layout changes between macOS versions | High | Tree dumper + matcher table in one file; feature degrades gracefully (logs, never crashes) |
| WhisperKit API drift / model download size | Med | Pin version; model picker with explicit download UI; `base.en` (~150 MB) default |
| Event tap latency degrades scrolling | Med | Callback does integer math only, no allocation/log on hot path; momentum events passed through same cheap path |
| yt-dlp breakage as sites change | Med | "Update yt-dlp" menu action re-fetches latest release binary |
| TCC re-grant friction during development | Low | Documented in §10; packaging phase moves to stable Developer ID signing |
| Pasteboard restore races (app reads clipboard late) | Low | 0.6 s restore delay; marker type prevents self-capture loops |
| Clipboard history is plaintext SQLite on disk | Med | Per-app exclusion list (Phase 4 Task 4.7), concealed-type skip, FileVault for at-rest; DB encryption deferred |

## 12. Coexistence & safety layer

Added after the initial plan set; lives inside existing phases (no new phase number).

**Global pause switch** (`Core/PauseManager.swift`, Phase 1 Task 1.7; "Pause Fuse" in the status-bar menu). Pausing sets `KeyboardShortcuts.isEnabled = false` — every hotkey feature (tiling, paste picker, push-to-talk, notes panel, clear-notifications) goes silent in one place — and posts `pauseStateChanged` for the services hotkeys don't cover: the scroll tap is removed (Task 2.6), the clipboard watcher swallows changes made while paused (Task 4.7), the notification auto-clear timer no-ops (Task 7.7), and an in-flight voice recording is discarded through the state machine (Task 5.6). Deliberately NOT paused: running downloads, opening the notes panel from the menu, and the menu's explicit "Clear Notifications" action (explicit clicks are user intent; pause exists to stop interception and automation — e.g. while gaming or screen-sharing). State is in-memory only.

**Conflict detection** (`Core/ConflictDetector.swift`, Phase 1 Task 1.8). Fuse replaces apps the user may still be running; overlaps actively misbehave (two scroll inverters cancel out, two tiling apps race the same shortcuts, two clipboard watchers double-record). A bundle-id table covers Rectangle/Rectangle Pro/Magnet/BetterSnapTool (tiling), Scroll Reverser/Mos (scroll), Maccy/Paste (clipboard), Downie (informational). The General tab shows a live advice banner; on the very first launch (`core.didRunBefore` flag) Settings auto-opens if conflicts exist. Extend the table with `osascript -e 'id of app "AppName"'`.

**Clipboard privacy exclusions** (Phase 4 Task 4.7). History is plaintext SQLite; the concealed-type skip covers password managers but NOT terminals or other apps that don't mark secrets. `clipboard.excludedApps` suppresses capture while an excluded app is frontmost, with a settings UI to pick from running apps. Recommend excluding terminals and password tools.
