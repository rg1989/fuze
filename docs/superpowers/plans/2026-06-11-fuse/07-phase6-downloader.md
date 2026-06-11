# Phase 6: Smart Video Downloader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** A Downie-style video downloader: the user pastes any URL (yt-dlp supports ~1800 extractor sites — YouTube, Vimeo, news sites, social media, …), Fuse fetches the video's metadata, downloads it at a chosen quality preset with live progress (percent / speed / ETA), runs up to N downloads concurrently, and manages its own self-updating `yt-dlp` binary so site breakage is fixed with one click — no app re-release needed.

**Architecture:** Fuse drives the standalone `yt-dlp_macos` binary (universal2, self-contained, ~35 MB) with Foundation `Process` — one process per job. Fuse keeps its own managed copy at `~/Library/Application Support/Fuse/bin/yt-dlp` so it can self-update without re-signing the app bundle; `ffmpeg` (needed for merging bestvideo+bestaudio and for MP3 extraction) is resolved from Homebrew with graceful degradation when absent. Pure logic (progress-line parsing, preset→argument mapping, metadata decoding, queue scheduling) is TDD'd; process and UI code is build-verified plus HUMAN-VERIFY. UI is a lazily created `NSWindow` ("Fuse Downloads") owned by `DownloaderController`, plus a "Downloads" settings tab. Menu + window only — this feature registers **no hotkeys** and never touches `Core/HotkeyNames.swift`.

**Tech Stack:** Foundation (`Process`, `Pipe`, `URLSession`, `JSONDecoder`), AppKit (`NSWindow`, `NSMenuItem`, `NSOpenPanel`, `NSWorkspace`, `NSPasteboard`), SwiftUI (views), Darwin (`removexattr`), XCTest. No SPM packages are needed for this phase.

All shell commands in this plan run from the repo root: `/Users/rgv250cc/Documents/Projects/Fuse`.

---

### Task 6.0: Preflight

**Files:**
- None created or modified. Verification only.

- [ ] **Step 1: Verify Phase 1 Core files exist**

```bash
ls /Users/rgv250cc/Documents/Projects/Fuse/Sources/Core
```
Expected output contains all of: `AX.swift`, `HotkeyNames.swift`, `Log.swift`, `PasteService.swift`, `Permissions.swift`. If any is missing, STOP — Phase 1 is not complete; do not proceed.

- [ ] **Step 2: Verify the integration anchors exist**

```bash
grep -n "FUSE:" /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/AppDelegate.swift /Users/rgv250cc/Documents/Projects/Fuse/Sources/App/SettingsRootView.swift
```
Expected: four hits — `// FUSE:CONTROLLER-PROPS`, `// FUSE:MENU-ITEMS`, `// FUSE:CONTROLLER-START` in `AppDelegate.swift` and `// FUSE:SETTINGS_TABS` in `SettingsRootView.swift`. If any anchor is missing, STOP and fix Phase 0/1 first.

- [ ] **Step 3: Verify the build and tests are green before touching anything**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`. Do not start Task 6.1 on a red build.

- [ ] **Step 4: Create the feature directory**

```bash
mkdir -p /Users/rgv250cc/Documents/Projects/Fuse/Sources/Downloader
```

---

### Task 6.1: ProgressParser (TDD)

yt-dlp is invoked with `--newline` and `--progress-template "download:FUSEP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"`, so during a download stdout emits one line per update shaped like `FUSEP|  42.7%|  3.21MiB/s|00:35`. This task builds the pure parser for those lines.

**Files:**
- Create: `Sources/Downloader/ProgressParser.swift`
- Test: `Tests/FuseTests/ProgressParserTests.swift`

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/ProgressParserTests.swift`**

```swift
import XCTest
@testable import Fuse

final class ProgressParserTests: XCTestCase {
    func testParsesHappyPathLine() {
        let result = ProgressParser.parse(line: "FUSEP|  42.7%|  3.21MiB/s|00:35")
        XCTAssertEqual(result, DownloadProgress(percent: 42.7, speed: "3.21MiB/s", eta: "00:35"))
    }

    func testParsesPaddedWhitespaceInEveryField() {
        let result = ProgressParser.parse(line: "FUSEP|   5.0% |  512.00KiB/s | 01:02:03 ")
        XCTAssertEqual(result, DownloadProgress(percent: 5.0, speed: "512.00KiB/s", eta: "01:02:03"))
    }

    func testParsesHundredPercent() {
        let result = ProgressParser.parse(line: "FUSEP|100.0%|10.00MiB/s|00:00")
        XCTAssertEqual(result?.percent, 100.0)
    }

    func testMapsNotAvailableSpeedAndEtaToEmptyStrings() {
        // Early in a download yt-dlp does not know speed/ETA yet and prints "N/A".
        let result = ProgressParser.parse(line: "FUSEP|  0.0%|N/A|N/A")
        XCTAssertEqual(result, DownloadProgress(percent: 0.0, speed: "", eta: ""))
    }

    func testGarbageAfterPrefixReturnsNil() {
        XCTAssertNil(ProgressParser.parse(line: "FUSEP|garbage"))
        XCTAssertNil(ProgressParser.parse(line: "FUSEP|not-a-percent|3.21MiB/s|00:35"))
    }

    func testLineWithoutPrefixReturnsNil() {
        XCTAssertNil(ProgressParser.parse(line: "[download] Destination: video.mp4"))
        XCTAssertNil(ProgressParser.parse(line: ""))
        XCTAssertNil(ProgressParser.parse(line: "/Users/x/Downloads/Big Buck Bunny [aqz-KE-bpKQ].mp4"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'ProgressParser' in scope` (a compile failure is this step's "red").

- [ ] **Step 3: Write `Sources/Downloader/ProgressParser.swift`**

```swift
import Foundation

/// One parsed yt-dlp progress update.
struct DownloadProgress: Equatable {
    var percent: Double
    var speed: String
    var eta: String
}

/// Parses progress lines produced by running yt-dlp with `--newline` and
/// `--progress-template "download:FUSEP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"`.
/// Example stdout line: `FUSEP|  42.7%|  3.21MiB/s|00:35`
enum ProgressParser {
    /// Returns nil for non-progress lines (yt-dlp also prints destination
    /// paths, merge notices, and the final `--print` file path on stdout).
    static func parse(line: String) -> DownloadProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("FUSEP|") else { return nil }

        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }

        let percentField = parts[1].trimmingCharacters(in: .whitespaces)
        guard percentField.hasSuffix("%"),
              let percent = Double(percentField.dropLast()) else { return nil }

        // yt-dlp emits "N/A" (and occasionally "Unknown") before it can
        // estimate speed/ETA — map those to empty strings so the UI shows nothing.
        func clean(_ field: String) -> String {
            let value = field.trimmingCharacters(in: .whitespaces)
            if value == "N/A" || value.hasPrefix("Unknown") { return "" }
            return value
        }

        return DownloadProgress(percent: percent, speed: clean(parts[2]), eta: clean(parts[3]))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`; the 6 new `ProgressParserTests` are listed as passed (total test count depends on which other phases are already merged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Downloader/ProgressParser.swift Tests/FuseTests/ProgressParserTests.swift
git commit -m "feat(downloader): add ProgressParser for yt-dlp progress lines"
```

---

### Task 6.2: FormatPresets (TDD)

Maps the `"downloader.qualityPreset"` settings value (`"best" | "1080p" | "720p" | "audio"`) to yt-dlp command-line arguments. Merged selectors (`bv*+ba`) and MP3 extraction (`-x`) require ffmpeg; when ffmpeg is unavailable the presets degrade to single-file formats that need no post-processing.

**Files:**
- Create: `Sources/Downloader/FormatPresets.swift`
- Test: `Tests/FuseTests/FormatPresetsTests.swift`

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/FormatPresetsTests.swift`**

```swift
import XCTest
@testable import Fuse

final class FormatPresetsTests: XCTestCase {
    func testVideoPresetsWithFfmpegUseMergedSelectors() {
        XCTAssertEqual(FormatPresets.arguments(preset: "best", ffmpegAvailable: true),
                       ["-f", "bv*+ba/b"])
        XCTAssertEqual(FormatPresets.arguments(preset: "1080p", ffmpegAvailable: true),
                       ["-f", "bv*[height<=1080]+ba/b[height<=1080]"])
        XCTAssertEqual(FormatPresets.arguments(preset: "720p", ffmpegAvailable: true),
                       ["-f", "bv*[height<=720]+ba/b[height<=720]"])
    }

    func testVideoPresetsWithoutFfmpegDegradeToSingleFile() {
        XCTAssertEqual(FormatPresets.arguments(preset: "best", ffmpegAvailable: false), ["-f", "b"])
        XCTAssertEqual(FormatPresets.arguments(preset: "1080p", ffmpegAvailable: false), ["-f", "b"])
        XCTAssertEqual(FormatPresets.arguments(preset: "720p", ffmpegAvailable: false), ["-f", "b"])
    }

    func testAudioPresetExtractsMp3OnlyWithFfmpeg() {
        XCTAssertEqual(FormatPresets.arguments(preset: "audio", ffmpegAvailable: true),
                       ["-f", "ba/b", "-x", "--audio-format", "mp3"])
        XCTAssertEqual(FormatPresets.arguments(preset: "audio", ffmpegAvailable: false),
                       ["-f", "ba/b"])
    }

    func testUnknownPresetFallsBackToBest() {
        XCTAssertEqual(FormatPresets.arguments(preset: "weird", ffmpegAvailable: true),
                       ["-f", "bv*+ba/b"])
        XCTAssertEqual(FormatPresets.arguments(preset: "", ffmpegAvailable: false), ["-f", "b"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'FormatPresets' in scope`.

- [ ] **Step 3: Write `Sources/Downloader/FormatPresets.swift`**

```swift
import Foundation

/// Maps the "downloader.qualityPreset" settings value to yt-dlp arguments
/// (the -f format selector plus any post-processing extras).
///
/// With ffmpeg: merged selectors (separate bestvideo + bestaudio streams,
/// merged locally — required for 4K on most sites) and MP3 extraction.
/// Without ffmpeg: degrade to single-file formats ("b") that need no merging,
/// and "audio" downloads the native best-audio file without converting to MP3.
enum FormatPresets {
    static func arguments(preset: String, ffmpegAvailable: Bool) -> [String] {
        switch preset {
        case "1080p":
            return ffmpegAvailable
                ? ["-f", "bv*[height<=1080]+ba/b[height<=1080]"]
                : ["-f", "b"]
        case "720p":
            return ffmpegAvailable
                ? ["-f", "bv*[height<=720]+ba/b[height<=720]"]
                : ["-f", "b"]
        case "audio":
            return ffmpegAvailable
                ? ["-f", "ba/b", "-x", "--audio-format", "mp3"]
                : ["-f", "ba/b"]
        default: // "best" and any unknown/corrupt settings value
            return ffmpegAvailable ? ["-f", "bv*+ba/b"] : ["-f", "b"]
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`; the 4 new `FormatPresetsTests` pass (every preset × ffmpeg branch is asserted).

- [ ] **Step 5: Commit**

```bash
git add Sources/Downloader/FormatPresets.swift Tests/FuseTests/FormatPresetsTests.swift
git commit -m "feat(downloader): add FormatPresets quality-to-arguments mapping"
```

---

### Task 6.3: VideoMetadata (TDD)

Metadata is fetched with `yt-dlp -J --no-playlist <url>`, which prints a single (very large) JSON object on stdout. We decode only the handful of fields the UI shows; decoding must tolerate the hundreds of keys we ignore.

**Files:**
- Create: `Sources/Downloader/VideoMetadata.swift`
- Test: `Tests/FuseTests/VideoMetadataTests.swift`

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/VideoMetadataTests.swift`**

```swift
import XCTest
@testable import Fuse

final class VideoMetadataTests: XCTestCase {
    /// Realistic excerpt of `yt-dlp -J` output. The extra keys (uploader,
    /// view_count, formats, …) prove decoding tolerates unknown fields.
    private let fixture = """
    {
      "id": "aqz-KE-bpKQ",
      "title": "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
      "duration": 635.0,
      "thumbnail": "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp",
      "extractor": "youtube",
      "webpage_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
      "uploader": "Blender",
      "view_count": 8512341,
      "like_count": 124000,
      "formats": [{"format_id": "137", "ext": "mp4", "height": 1080}],
      "categories": ["Film & Animation"],
      "age_limit": 0,
      "is_live": false
    }
    """

    func testDecodesRealisticFixtureIgnoringUnknownKeys() throws {
        let metadata = try VideoMetadata.decode(from: Data(fixture.utf8))
        XCTAssertEqual(metadata.id, "aqz-KE-bpKQ")
        XCTAssertEqual(metadata.title, "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        XCTAssertEqual(metadata.duration, 635.0)
        XCTAssertEqual(metadata.thumbnail, "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp")
        XCTAssertEqual(metadata.extractor, "youtube")
        XCTAssertEqual(metadata.webpageURL, "https://www.youtube.com/watch?v=aqz-KE-bpKQ")
    }

    func testDecodesWhenOptionalFieldsAreMissing() throws {
        // Live streams and some extractors omit duration/thumbnail entirely.
        let minimal = """
        {"id": "x1", "title": "Clip", "extractor": "generic", "webpage_url": "https://example.com/clip"}
        """
        let metadata = try VideoMetadata.decode(from: Data(minimal.utf8))
        XCTAssertNil(metadata.duration)
        XCTAssertNil(metadata.thumbnail)
        XCTAssertEqual(metadata.title, "Clip")
    }

    func testThrowsOnNonJSONData() {
        // yt-dlp sometimes prints an error string instead of JSON; decoding must throw, not crash.
        XCTAssertThrowsError(try VideoMetadata.decode(from: Data("ERROR: not json".utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'VideoMetadata' in scope`.

- [ ] **Step 3: Write `Sources/Downloader/VideoMetadata.swift`**

```swift
import Foundation

/// The subset of `yt-dlp -J --no-playlist <url>` output that Fuse displays.
/// yt-dlp emits hundreds of keys; JSONDecoder ignores everything not listed here.
struct VideoMetadata: Decodable, Equatable {
    let id: String
    let title: String
    let duration: Double?      // seconds; absent for live streams / some extractors
    let thumbnail: String?     // URL string; absent on some extractors
    let extractor: String      // e.g. "youtube", "vimeo", "generic"
    let webpageURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, duration, thumbnail, extractor
        case webpageURL = "webpage_url"
    }

    static func decode(from data: Data) throws -> VideoMetadata {
        try JSONDecoder().decode(VideoMetadata.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`; the 3 new `VideoMetadataTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Downloader/VideoMetadata.swift Tests/FuseTests/VideoMetadataTests.swift
git commit -m "feat(downloader): add VideoMetadata decoding for yt-dlp -J output"
```

---

### Task 6.4: ToolManager — managed yt-dlp binary + ffmpeg discovery

Downloads the latest standalone `yt-dlp_macos` release into `~/Library/Application Support/Fuse/bin/yt-dlp`, makes it executable, and strips the quarantine attribute (CRITICAL: files downloaded by `URLSession` carry `com.apple.quarantine`, and Gatekeeper blocks executing a quarantined binary via `Process` — without `removexattr` every run fails). Also resolves Homebrew ffmpeg. This is network/filesystem integration code — no unit tests; it is exercised by HUMAN-VERIFY in Tasks 6.9/6.10.

**Files:**
- Create: `Sources/Downloader/ToolManager.swift`

- [ ] **Step 1: Write `Sources/Downloader/ToolManager.swift`**

```swift
import Darwin
import Foundation

/// Locates and manages the external command-line tools the downloader drives.
///
/// Fuse keeps its OWN copy of yt-dlp at ~/Library/Application Support/Fuse/bin/yt-dlp
/// so it can self-update the binary without re-signing the app bundle.
/// ffmpeg (needed to merge bestvideo+bestaudio and to extract MP3 audio)
/// is resolved from the standard Homebrew locations if installed.
final class ToolManager {
    static let shared = ToolManager()

    enum ToolError: LocalizedError {
        case badDownloadResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badDownloadResponse(let code):
                return "yt-dlp download failed (HTTP \(code)). Check your network connection and try again."
            }
        }
    }

    /// Standalone universal2 macOS build published with every yt-dlp release.
    static let ytDlpReleaseURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// ~/Library/Application Support/Fuse/bin/yt-dlp (master plan §6.5).
    var ytDlpURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Fuse/bin/yt-dlp")
    }

    var ytDlpInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ytDlpURL.path)
    }

    /// First existing executable among the standard Homebrew install paths
    /// (Apple Silicon first, then Intel/Rosetta prefix).
    func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Downloads the latest yt-dlp_macos to `ytDlpURL` via URLSession,
    /// then chmod 755 and strips the quarantine attribute.
    func installOrUpdateYtDlp() async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: Self.ytDlpReleaseURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolError.badDownloadResponse(http.statusCode)
        }

        let fm = FileManager.default
        let binDir = ytDlpURL.deletingLastPathComponent()
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ytDlpURL.path) {
            try fm.removeItem(at: ytDlpURL)
        }
        try fm.moveItem(at: tempURL, to: ytDlpURL)

        // CRITICAL: URLSession-downloaded files carry the com.apple.quarantine
        // extended attribute; Gatekeeper blocks executing a quarantined binary
        // via Process. Make it executable, then remove the quarantine xattr.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytDlpURL.path)
        if removexattr(ytDlpURL.path, "com.apple.quarantine", 0) != 0 && errno != ENOATTR {
            Log.downloader.warning("removexattr failed: errno \(errno)")
        }
        Log.downloader.info("yt-dlp installed at \(self.ytDlpURL.path, privacy: .public)")
    }

    /// Runs `yt-dlp --version` and returns the trimmed output (e.g. "2026.05.13"),
    /// or nil if the binary is missing or fails to launch.
    func installedVersion() async -> String? {
        guard ytDlpInstalled else { return nil }
        let ytDlp = ytDlpURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ytDlp
                process.arguments = ["--version"]
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let version = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: version.isEmpty ? nil : version)
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **` (no new tests; existing suite stays green).

- [ ] **Step 3: Commit**

```bash
git add Sources/Downloader/ToolManager.swift
git commit -m "feat(downloader): add ToolManager for managed yt-dlp and ffmpeg discovery"
```

---

### Task 6.5: YtDlpRunner — one Process per job

Two operations: metadata fetch (`yt-dlp -J --no-playlist <url>`, stdout decoded as `VideoMetadata`) and download (streaming stdout line-by-line through `ProgressParser`, stderr kept as a 20-line tail for error messages, cancellation via `terminate()`). The final file path comes from `--print after_move:filepath` — IMPORTANT: `--print` alone implies simulation (no download); `--no-simulate` cancels that, so yt-dlp downloads AND prints the final path as the last non-progress stdout line. OS-integration code — build-verified here, exercised end-to-end in Task 6.10.

**Files:**
- Create: `Sources/Downloader/YtDlpRunner.swift`

- [ ] **Step 1: Write `Sources/Downloader/YtDlpRunner.swift`**

```swift
import Foundation

/// Drives one yt-dlp `Process` per job.
/// - `fetchMetadata`: `yt-dlp -J --no-playlist <url>` → decoded `VideoMetadata`.
/// - `startDownload`: real download with parseable progress lines on stdout.
/// All `onProgress`/`completion` callbacks are delivered on the main actor.
final class YtDlpRunner {

    enum RunnerError: LocalizedError {
        case ytDlpMissing
        case cancelled
        case noOutputPath
        case processFailed(status: Int32, stderrTail: String)
        case metadataDecodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .ytDlpMissing:
                return "yt-dlp is not installed. Install it from Settings → Downloads."
            case .cancelled:
                return "Download cancelled."
            case .noOutputPath:
                return "yt-dlp finished but did not report an output file."
            case .processFailed(let status, let stderrTail):
                let detail = stderrTail.isEmpty ? "no error output" : stderrTail
                return "yt-dlp exited with status \(status): \(detail)"
            case .metadataDecodingFailed(let detail):
                return "Could not read video information: \(detail)"
            }
        }
    }

    /// Produces stdout lines like `FUSEP|  42.7%|  3.21MiB/s|00:35` (see ProgressParser).
    static let progressTemplate =
        "download:FUSEP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"

    // MARK: - Metadata

    func fetchMetadata(url: String) async throws -> VideoMetadata {
        guard ToolManager.shared.ytDlpInstalled else { throw RunnerError.ytDlpMissing }
        let ytDlp = ToolManager.shared.ytDlpURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ytDlp
                process.arguments = ["-J", "--no-playlist", url]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Drain stderr asynchronously so a chatty stderr can never fill
                // its 64 KB pipe buffer and deadlock the stdout read below.
                let stderrSync = DispatchQueue(label: "com.rgv250cc.Fuse.ytdlp.meta.stderr")
                var stderrData = Data()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stderrSync.sync { stderrData.append(chunk) }
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                guard process.terminationStatus == 0 else {
                    let stderrText = stderrSync.sync { String(decoding: stderrData, as: UTF8.self) }
                    let tail = stderrText
                        .components(separatedBy: "\n")
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .suffix(20)
                        .joined(separator: "\n")
                    continuation.resume(throwing: RunnerError.processFailed(
                        status: process.terminationStatus, stderrTail: tail))
                    return
                }
                do {
                    continuation.resume(returning: try VideoMetadata.decode(from: stdoutData))
                } catch {
                    continuation.resume(throwing: RunnerError.metadataDecodingFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Download

    /// Cancellation handle for a running download.
    final class DownloadHandle {
        private let process: Process
        fileprivate init(process: Process) { self.process = process }
        /// SIGTERM — yt-dlp exits promptly and leaves .part files for later cleanup.
        func cancel() {
            if process.isRunning { process.terminate() }
        }
    }

    /// Thread-safe accumulator shared by the pipe readability handlers
    /// (background queues) and the termination handler (another thread).
    private final class StreamState {
        private let lock = NSLock()
        private var stdoutRemainder = ""
        private var stderrLines: [String] = []
        private var lastNonProgressLine: String?

        /// Appends raw stdout bytes; returns the complete lines now available.
        func appendStdout(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            stdoutRemainder += String(decoding: data, as: UTF8.self)
            var lines = stdoutRemainder.components(separatedBy: "\n")
            stdoutRemainder = lines.removeLast() // unterminated tail stays buffered
            return lines
        }

        /// Returns and clears any unterminated final line (call at termination).
        func flushStdoutTail() -> String? {
            lock.lock(); defer { lock.unlock() }
            let tail = stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutRemainder = ""
            return tail.isEmpty ? nil : tail
        }

        /// The last non-progress stdout line is the `--print after_move:filepath` result.
        func recordCandidateFilePath(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lastNonProgressLine = line
        }

        var candidateFilePath: String? {
            lock.lock(); defer { lock.unlock() }
            return lastNonProgressLine
        }

        func appendStderr(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            let lines = String(decoding: data, as: UTF8.self)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            stderrLines.append(contentsOf: lines)
            if stderrLines.count > 20 {
                stderrLines.removeFirst(stderrLines.count - 20)
            }
        }

        var stderrTail: String {
            lock.lock(); defer { lock.unlock() }
            return stderrLines.joined(separator: "\n")
        }
    }

    /// Starts a download. Returns a handle for cancellation.
    /// `onProgress` and `completion` are invoked on the main actor;
    /// `completion` delivers the final file path or an error.
    @discardableResult
    func startDownload(url: String,
                       preset: String,
                       destinationPath: String,
                       onProgress: @escaping @MainActor (DownloadProgress) -> Void,
                       completion: @escaping @MainActor (Result<String, Error>) -> Void) throws -> DownloadHandle {
        guard ToolManager.shared.ytDlpInstalled else { throw RunnerError.ytDlpMissing }

        let ffmpegPath = ToolManager.shared.ffmpegPath()
        var arguments = FormatPresets.arguments(preset: preset, ffmpegAvailable: ffmpegPath != nil)
        arguments += [
            "--no-playlist",
            "--newline",
            "--progress-template", Self.progressTemplate,
            "--print", "after_move:filepath", // final path, after any merge/move
            "--no-simulate",                  // --print alone implies simulation; cancel that
            "-P", destinationPath,
            "-o", "%(title)s [%(id)s].%(ext)s",
        ]
        if let ffmpegPath {
            arguments += ["--ffmpeg-location", (ffmpegPath as NSString).deletingLastPathComponent]
        }
        arguments.append(url)

        let process = Process()
        process.executableURL = ToolManager.shared.ytDlpURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = StreamState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { // EOF
                handle.readabilityHandler = nil
                return
            }
            for line in state.appendStdout(data) {
                if let progress = ProgressParser.parse(line: line) {
                    Task { @MainActor in onProgress(progress) }
                } else {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.recordCandidateFilePath(trimmed) }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.appendStderr(data)
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Drain anything buffered after the handlers detached.
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                for line in state.appendStdout(rest) where ProgressParser.parse(line: line) == nil {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.recordCandidateFilePath(trimmed) }
                }
            }
            if let tail = state.flushStdoutTail(), ProgressParser.parse(line: tail) == nil {
                state.recordCandidateFilePath(tail)
            }
            if let errRest = try? stderrPipe.fileHandleForReading.readToEnd(), !errRest.isEmpty {
                state.appendStderr(errRest)
            }

            let result: Result<String, Error>
            if proc.terminationReason == .uncaughtSignal {
                result = .failure(RunnerError.cancelled) // our own terminate() → SIGTERM
            } else if proc.terminationStatus == 0 {
                if let path = state.candidateFilePath {
                    result = .success(path)
                } else {
                    result = .failure(RunnerError.noOutputPath)
                }
            } else {
                result = .failure(RunnerError.processFailed(
                    status: proc.terminationStatus, stderrTail: state.stderrTail))
            }
            Task { @MainActor in completion(result) }
        }

        try process.run()
        Log.downloader.info("yt-dlp started for \(url, privacy: .public)")
        return DownloadHandle(process: process)
    }
}
```

- [ ] **Step 2: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Downloader/YtDlpRunner.swift
git commit -m "feat(downloader): add YtDlpRunner process driver with streaming progress"
```

---

### Task 6.6: DownloadQueue (TDD for the scheduling helper)

The observable queue the UI binds to. The scheduling decision ("which queued items may start now?") is a pure, `nonisolated static` function so it can be unit-tested without MainActor or processes; everything else is integration glue around `YtDlpRunner`.

**Files:**
- Create: `Sources/Downloader/DownloadQueue.swift`
- Test: `Tests/FuseTests/DownloadQueueTests.swift`

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/DownloadQueueTests.swift`**

```swift
import XCTest
@testable import Fuse

final class DownloadQueueTests: XCTestCase {
    private func item(_ state: DownloadState) -> DownloadItem {
        DownloadItem(id: UUID(), url: "https://example.com/v", state: state,
                     metadata: nil, progress: nil, resultPath: nil, errorMessage: nil)
    }

    func testEmptyQueueOrZeroSlotsStartsNothing() {
        XCTAssertEqual(DownloadQueue.nextStartable(items: [], maxConcurrent: 2), [])
        XCTAssertEqual(DownloadQueue.nextStartable(items: [item(.queued)], maxConcurrent: 0), [])
    }

    func testStartsUpToMaxConcurrentInOrder() {
        let items = [item(.queued), item(.queued), item(.queued)]
        XCTAssertEqual(DownloadQueue.nextStartable(items: items, maxConcurrent: 2), [0, 1])
    }

    func testActiveDownloadsConsumeSlots() {
        let items = [item(.downloading), item(.queued), item(.queued)]
        XCTAssertEqual(DownloadQueue.nextStartable(items: items, maxConcurrent: 2), [1])
    }

    func testFetchingMetadataCountsAsActive() {
        let items = [item(.fetchingMetadata), item(.downloading), item(.queued)]
        XCTAssertEqual(DownloadQueue.nextStartable(items: items, maxConcurrent: 2), [])
    }

    func testTerminalStatesDoNotConsumeSlots() {
        let items = [item(.finished), item(.failed), item(.cancelled), item(.queued)]
        XCTAssertEqual(DownloadQueue.nextStartable(items: items, maxConcurrent: 1), [3])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'DownloadQueue' in scope` (and/or `DownloadItem`/`DownloadState`).

- [ ] **Step 3: Write `Sources/Downloader/DownloadQueue.swift`**

```swift
import Foundation

enum DownloadState: Equatable {
    case queued
    case fetchingMetadata
    case downloading
    case finished
    case failed
    case cancelled
}

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    var url: String
    var state: DownloadState
    var metadata: VideoMetadata?
    var progress: DownloadProgress?
    var resultPath: String?
    var errorMessage: String?
}

/// Observable download queue. Settings (destination, preset, concurrency)
/// are read live from UserDefaults using the master-plan §6.4 keys so changes
/// in the settings tab apply to the next job without restart.
@MainActor
final class DownloadQueue: ObservableObject {
    @Published var items: [DownloadItem] = []

    private let runner = YtDlpRunner()
    private var handles: [UUID: YtDlpRunner.DownloadHandle] = [:]

    var maxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: "downloader.maxConcurrent")
        return value > 0 ? value : 2
    }

    var destinationPath: String {
        UserDefaults.standard.string(forKey: "downloader.destinationPath")
            ?? NSHomeDirectory() + "/Downloads"
    }

    var qualityPreset: String {
        UserDefaults.standard.string(forKey: "downloader.qualityPreset") ?? "best"
    }

    /// Pure scheduling helper: indices of queued items allowed to start now.
    /// Active = fetchingMetadata or downloading. nonisolated so unit tests
    /// can call it synchronously without MainActor hops.
    nonisolated static func nextStartable(items: [DownloadItem], maxConcurrent: Int) -> [Int] {
        let active = items.filter { $0.state == .downloading || $0.state == .fetchingMetadata }.count
        let slots = max(0, maxConcurrent - active)
        guard slots > 0 else { return [] }
        var result: [Int] = []
        for (index, item) in items.enumerated() where item.state == .queued {
            result.append(index)
            if result.count == slots { break }
        }
        return result
    }

    /// Validates and enqueues a URL, then pumps the queue.
    /// Returns false (and enqueues nothing) when the string is not an http(s) URL.
    @discardableResult
    func add(url rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil else {
            Log.downloader.info("rejected non-http(s) input")
            return false
        }
        items.append(DownloadItem(id: UUID(), url: trimmed, state: .queued,
                                  metadata: nil, progress: nil,
                                  resultPath: nil, errorMessage: nil))
        pump()
        return true
    }

    func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .queued:
            items[index].state = .cancelled
        case .fetchingMetadata:
            // No process handle yet; beginDownload's state guard aborts the job.
            items[index].state = .cancelled
        case .downloading:
            items[index].state = .cancelled
            handles[id]?.cancel()
            handles[id] = nil
        case .finished, .failed, .cancelled:
            return
        }
        pump()
    }

    func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .failed || items[index].state == .cancelled else { return }
        items[index].state = .queued
        items[index].progress = nil
        items[index].resultPath = nil
        items[index].errorMessage = nil
        pump()
    }

    func remove(id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }),
           items[index].state == .downloading || items[index].state == .fetchingMetadata {
            cancel(id: id)
        }
        items.removeAll { $0.id == id }
        handles[id] = nil
        pump()
    }

    /// Starts queued jobs while the active count is below maxConcurrent.
    func pump() {
        for index in Self.nextStartable(items: items, maxConcurrent: maxConcurrent) {
            start(itemAt: index)
        }
    }

    private func start(itemAt index: Int) {
        let id = items[index].id
        let url = items[index].url
        items[index].state = .fetchingMetadata
        Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await self.runner.fetchMetadata(url: url)
                self.beginDownload(id: id, metadata: metadata)
            } catch {
                self.markFailed(id: id, message: error.localizedDescription)
            }
        }
    }

    private func beginDownload(id: UUID, metadata: VideoMetadata) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .fetchingMetadata else { return } // cancelled/removed meanwhile
        items[index].metadata = metadata
        items[index].state = .downloading
        do {
            let handle = try runner.startDownload(
                url: items[index].url,
                preset: qualityPreset,
                destinationPath: destinationPath,
                onProgress: { [weak self] progress in
                    self?.updateProgress(id: id, progress: progress)
                },
                completion: { [weak self] result in
                    self?.finish(id: id, result: result)
                })
            handles[id] = handle
        } catch {
            markFailed(id: id, message: error.localizedDescription)
        }
    }

    private func updateProgress(id: UUID, progress: DownloadProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .downloading else { return }
        items[index].progress = progress
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        handles[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            pump()
            return
        }
        if items[index].state == .cancelled {
            pump() // user already cancelled; ignore the late completion
            return
        }
        switch result {
        case .success(let path):
            items[index].state = .finished
            items[index].resultPath = path
            items[index].progress = DownloadProgress(percent: 100, speed: "", eta: "")
            Log.downloader.info("finished: \(path, privacy: .public)")
        case .failure(let error):
            if let runnerError = error as? YtDlpRunner.RunnerError, case .cancelled = runnerError {
                items[index].state = .cancelled
            } else {
                items[index].state = .failed
                items[index].errorMessage = error.localizedDescription
                Log.downloader.error("failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        pump()
    }

    private func markFailed(id: UUID, message: String) {
        if let index = items.firstIndex(where: { $0.id == id }),
           items[index].state != .cancelled {
            items[index].state = .failed
            items[index].errorMessage = message
        }
        pump()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`; the 5 new `DownloadQueueTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Downloader/DownloadQueue.swift Tests/FuseTests/DownloadQueueTests.swift
git commit -m "feat(downloader): add DownloadQueue with concurrency-limited scheduling"
```

---

### Task 6.7: Downloads window — DownloaderController + DownloadsView

`DownloaderController` owns a lazily created 560×440 `NSWindow` titled "Fuse Downloads" (same pattern as AppDelegate's settings window) and exposes the two `@objc` menu actions. `DownloadsView` is the window content: URL field + Paste + Download, the item list with progress rows, and an inline "yt-dlp not installed" banner (first-use flow: Fuse never auto-downloads the binary without user action).

**Files:**
- Create: `Sources/Downloader/DownloaderController.swift`
- Create: `Sources/Downloader/DownloadsView.swift`

- [ ] **Step 1: Write `Sources/Downloader/DownloaderController.swift`**

```swift
import AppKit
import SwiftUI

/// Owns the downloader feature: the shared DownloadQueue and the Downloads window.
/// Menu items in AppDelegate target the two @objc actions below.
@MainActor
final class DownloaderController: NSObject {
    let queue = DownloadQueue()
    private var downloadsWindow: NSWindow?

    func start() {
        // First-use flow: never auto-download the binary without user action.
        // DownloadsView shows an inline banner pointing at Settings → Downloads.
        if !ToolManager.shared.ytDlpInstalled {
            Log.downloader.info("yt-dlp not installed; user must install from Settings → Downloads")
        }
    }

    @objc func openDownloadsWindow() {
        if downloadsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Fuse Downloads"
            window.contentView = NSHostingView(rootView: DownloadsView(queue: queue))
            window.isReleasedWhenClosed = false
            window.center()
            downloadsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        downloadsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func downloadFromClipboard() {
        openDownloadsWindow()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            Log.downloader.info("clipboard download requested but pasteboard has no string")
            return
        }
        if !queue.add(url: text) {
            Log.downloader.info("clipboard text is not an http(s) URL")
        }
    }
}
```

- [ ] **Step 2: Write `Sources/Downloader/DownloadsView.swift`**

```swift
import AppKit
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var queue: DownloadQueue
    @State private var urlText = ""
    @State private var ytDlpInstalled = ToolManager.shared.ytDlpInstalled

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !ytDlpInstalled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("yt-dlp not installed — install from Settings → Downloads")
                        .font(.callout)
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.15))
            }

            HStack(spacing: 8) {
                TextField("Video URL (https://…)", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        urlText = text
                    }
                }
                Button("Download", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

            Divider()

            if queue.items.isEmpty {
                Spacer()
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(queue.items) { item in
                    DownloadRowView(item: item, queue: queue)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onReceive(refresh) { _ in
            ytDlpInstalled = ToolManager.shared.ytDlpInstalled
        }
    }

    private func submit() {
        if queue.add(url: urlText) {
            urlText = ""
        }
    }
}

struct DownloadRowView: View {
    let item: DownloadItem
    let queue: DownloadQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.metadata?.title ?? item.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: min(max((item.progress?.percent ?? 0) / 100.0, 0), 1))
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            actionButtons
        }
        .padding(.vertical, 4)
    }

    private var stateSymbol: String {
        switch item.state {
        case .queued: return "clock"
        case .fetchingMetadata: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .finished: return .green
        case .failed: return .red
        case .downloading: return .accentColor
        case .queued, .fetchingMetadata, .cancelled: return .secondary
        }
    }

    private var caption: String {
        switch item.state {
        case .queued: return "Queued"
        case .fetchingMetadata: return "Fetching video info…"
        case .downloading:
            guard let p = item.progress else { return "Starting…" }
            var parts = [String(format: "%.1f%%", p.percent)]
            if !p.speed.isEmpty { parts.append(p.speed) }
            if !p.eta.isEmpty { parts.append("ETA \(p.eta)") }
            return parts.joined(separator: " · ")
        case .finished: return item.resultPath ?? "Done"
        case .failed: return item.errorMessage ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.state {
        case .fetchingMetadata, .downloading:
            Button("Cancel") { queue.cancel(id: item.id) }
        case .finished:
            Button("Show in Finder") { showInFinder() }
        case .failed, .cancelled:
            Button("Retry") { queue.retry(id: item.id) }
            Button("Remove") { queue.remove(id: item.id) }
        case .queued:
            Button("Remove") { queue.remove(id: item.id) }
        }
    }

    private func showInFinder() {
        guard let path = item.resultPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
```

- [ ] **Step 3: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`. (The window is not reachable yet — wiring happens in Task 6.9.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Downloader/DownloaderController.swift Sources/Downloader/DownloadsView.swift
git commit -m "feat(downloader): add Downloads window with queue UI"
```

---

### Task 6.8: DownloaderSettingsView

The "Downloads" settings tab: destination folder picker (`NSOpenPanel`, directories only), quality preset picker, max-concurrent stepper (1–4), yt-dlp status row with Install/Update button, and an ffmpeg status row with a Homebrew hint. Uses exactly the master-plan §6.4 keys: `"downloader.destinationPath"`, `"downloader.qualityPreset"`, `"downloader.maxConcurrent"`.

**Files:**
- Create: `Sources/Downloader/DownloaderSettingsView.swift`

- [ ] **Step 1: Write `Sources/Downloader/DownloaderSettingsView.swift`**

```swift
import AppKit
import SwiftUI

struct DownloaderSettingsView: View {
    @AppStorage("downloader.destinationPath") private var destinationPath = NSHomeDirectory() + "/Downloads"
    @AppStorage("downloader.qualityPreset") private var qualityPreset = "best"
    @AppStorage("downloader.maxConcurrent") private var maxConcurrent = 2

    @State private var installing = false
    @State private var installError: String?
    @State private var installedVersion: String?

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Save to") {
                    HStack {
                        Text(destinationPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseDestination)
                    }
                }
            }
            Section("Quality") {
                Picker("Preset", selection: $qualityPreset) {
                    Text("Best available").tag("best")
                    Text("Up to 1080p").tag("1080p")
                    Text("Up to 720p").tag("720p")
                    Text("Audio only (MP3)").tag("audio")
                }
                Stepper("Max concurrent downloads: \(maxConcurrent)",
                        value: $maxConcurrent, in: 1...4)
            }
            Section("Tools") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("yt-dlp")
                        Text(ytDlpStatusText)
                            .font(.caption)
                            .foregroundStyle(installError == nil ? Color.secondary : Color.red)
                    }
                    Spacer()
                    if installing {
                        ProgressView().controlSize(.small)
                    }
                    Button(installedVersion == nil ? "Install yt-dlp" : "Update yt-dlp",
                           action: installYtDlp)
                        .disabled(installing)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("ffmpeg")
                        if let path = ToolManager.shared.ffmpegPath() {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not found. brew install ffmpeg — without it: no 4K merging or MP3 extraction")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: ToolManager.shared.ffmpegPath() != nil
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ToolManager.shared.ffmpegPath() != nil ? .green : .yellow)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            installedVersion = await ToolManager.shared.installedVersion()
        }
    }

    private var ytDlpStatusText: String {
        if installing { return "Installing…" }
        if let installError { return installError }
        if let installedVersion { return "Installed — version \(installedVersion)" }
        return "Not installed"
    }

    private func installYtDlp() {
        installing = true
        installError = nil
        Task {
            do {
                try await ToolManager.shared.installOrUpdateYtDlp()
                installedVersion = await ToolManager.shared.installedVersion()
                if installedVersion == nil {
                    installError = "Installed file does not run — try again."
                }
            } catch {
                installError = error.localizedDescription
            }
            installing = false
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}
```

- [ ] **Step 2: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Downloader/DownloaderSettingsView.swift
git commit -m "feat(downloader): add Downloads settings tab"
```

---

### Task 6.9: Wire into the app via anchors

Three insertions in `AppDelegate.swift` and one in `SettingsRootView.swift` — always insert **immediately ABOVE** the anchor comment line, leaving the anchor itself untouched. Other phases may already have inserted their own lines above the same anchors; do not disturb them.

Ordering note: in `applicationDidFinishLaunching` the menu is built (and `// FUSE:MENU-ITEMS` executes) BEFORE `// FUSE:CONTROLLER-START` runs, but the menu items need a non-nil `target`. Therefore both insertion sites construct the controller with a nil-guard — whichever executes first wins, and the code stays correct regardless of anchor order.

**Files:**
- Modify: `Sources/App/AppDelegate.swift`
- Modify: `Sources/App/SettingsRootView.swift`

- [ ] **Step 1: Add the controller property in `Sources/App/AppDelegate.swift`**

Find the line `    // FUSE:CONTROLLER-PROPS` and insert one line directly above it, so the region reads:

```swift
    private var downloaderController: DownloaderController!
    // FUSE:CONTROLLER-PROPS
```

- [ ] **Step 2: Add the menu items in `Sources/App/AppDelegate.swift`**

Find the line `        // FUSE:MENU-ITEMS` and insert directly above it, so the region reads:

```swift
        if downloaderController == nil { downloaderController = DownloaderController() }
        let downloadsItem = NSMenuItem(title: "Downloads…",
                                       action: #selector(DownloaderController.openDownloadsWindow),
                                       keyEquivalent: "")
        downloadsItem.target = downloaderController
        menu.addItem(downloadsItem)
        let clipboardDownloadItem = NSMenuItem(title: "Download URL from Clipboard",
                                               action: #selector(DownloaderController.downloadFromClipboard),
                                               keyEquivalent: "")
        clipboardDownloadItem.target = downloaderController
        menu.addItem(clipboardDownloadItem)
        // FUSE:MENU-ITEMS
```

- [ ] **Step 3: Construct and start the controller in `Sources/App/AppDelegate.swift`**

Find the line `        // FUSE:CONTROLLER-START` and insert directly above it, so the region reads:

```swift
        if downloaderController == nil { downloaderController = DownloaderController() }
        downloaderController.start()
        // FUSE:CONTROLLER-START
```

- [ ] **Step 4: Add the settings tab in `Sources/App/SettingsRootView.swift`**

Find the line `            // FUSE:SETTINGS_TABS` and insert directly above it, so the region reads:

```swift
            DownloaderSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            // FUSE:SETTINGS_TABS
```

- [ ] **Step 5: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 6: HUMAN-VERIFY — wiring smoke test**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Ask the human to confirm, in this order:
1. The status-bar menu now contains "Downloads…" and "Download URL from Clipboard".
2. Clicking "Downloads…" opens a window titled "Fuse Downloads" (560×440) showing the URL field, Paste and Download buttons, "No downloads yet", and — since yt-dlp is not installed yet — the yellow banner "yt-dlp not installed — install from Settings → Downloads".
3. "Settings…" → the settings window now has a "Downloads" tab showing: destination path (default `~/Downloads`), preset picker on "Best available", stepper at 2, yt-dlp row saying "Not installed" with an "Install yt-dlp" button, and the ffmpeg row (green path if Homebrew ffmpeg exists, orange hint otherwise).

Record the human's answers. Do not proceed until all three are confirmed.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/AppDelegate.swift Sources/App/SettingsRootView.swift
git commit -m "feat(downloader): wire downloader into menu bar and settings tabs"
```

---

### Task 6.10: End-to-end HUMAN-VERIFY

Real network, real yt-dlp, real downloads — none of this is unit-testable. The app must already be running from Task 6.9. Suggest the Creative Commons "Big Buck Bunny" URL `https://www.youtube.com/watch?v=aqz-KE-bpKQ` for the video scenarios, but the human may use any site they prefer — yt-dlp supports ~1800 extractors; that breadth is the "smart, not just YouTube" requirement. While testing, the implementer can stream feature logs with:
`log stream --predicate 'subsystem == "com.rgv250cc.Fuse"' --level debug`

**Files:**
- None. Verification only.

- [ ] **Step 1: HUMAN-VERIFY — install yt-dlp from Settings**

Ask the human to: open Settings → Downloads, click "Install yt-dlp", wait (~35 MB download). Observe: the button disables and a small spinner shows during install; afterwards the row reads "Installed — version 2026.x.x" (any recent version string) and the button title changes to "Update yt-dlp". Then the implementer verifies the quarantine strip worked:

```bash
xattr "$HOME/Library/Application Support/Fuse/bin/yt-dlp"
```
Expected: output does NOT contain `com.apple.quarantine`. Also confirm with the human that reopening the "Fuse Downloads" window (give it up to 2 seconds) no longer shows the yellow banner.

- [ ] **Step 2: HUMAN-VERIFY — download a video at preset "best"**

Ask the human to: confirm preset is "Best available", open Downloads…, paste `https://www.youtube.com/watch?v=aqz-KE-bpKQ` (or their preferred URL for content they have rights to), click Download. Observe: row appears as "Fetching video info…", then the title replaces the URL, a progress bar moves with a caption like `42.7% · 3.21MiB/s · ETA 00:35`, state flips to a green checkmark, the caption shows the final file path, the file exists in the destination folder, and "Show in Finder" reveals exactly that file.

- [ ] **Step 3: HUMAN-VERIFY — audio preset produces an .mp3** (requires ffmpeg installed; if the ffmpeg row is orange, `brew install ffmpeg` first or skip and note it)

Ask the human to: switch Settings → Downloads preset to "Audio only (MP3)", download the same URL again. Observe: the finished file in the destination folder has an `.mp3` extension. Switch the preset back to "Best available" afterwards.

- [ ] **Step 4: HUMAN-VERIFY — bogus URL fails with a readable error**

Ask the human to: enter `https://example.com/definitely-not-a-video` and click Download. Observe: the row turns into a red ✗ failed state with a human-readable message (yt-dlp's stderr tail, e.g. "Unsupported URL"), the app does not crash or hang, and Retry/Remove buttons appear. Also enter `not a url at all` — observe: nothing is enqueued (the input is rejected before any process runs).

- [ ] **Step 5: HUMAN-VERIFY — concurrency limit respected**

Ask the human to: set "Max concurrent downloads" to 1, then quickly queue TWO different video URLs. Observe: the second row stays "Queued" while the first downloads, and starts only after the first finishes. Then ask them to set the stepper back to 2.

- [ ] **Step 6: HUMAN-VERIFY — cancel mid-download**

Ask the human to: start a download and click "Cancel" while the progress bar is moving. Observe: the row flips to "Cancelled" within ~2 seconds, and Retry restarts it from the queued state.

- [ ] **Step 7: HUMAN-VERIFY — Update yt-dlp re-installs cleanly while idle**

With no downloads running, ask the human to click "Update yt-dlp" in Settings → Downloads. Observe: spinner during download, then a version string appears again (same or newer) with no errors, and a subsequent download still works.

---

## Manual verification checklist

- [ ] **HUMAN-VERIFY** Menu items, Downloads window, settings tab, and first-use banner present (Task 6.9 Step 6).
- [ ] **HUMAN-VERIFY** yt-dlp installs from Settings; version shown; quarantine xattr absent (Task 6.10 Step 1).
- [ ] **HUMAN-VERIFY** Video downloads at "best" with live progress; file lands in destination; Show in Finder works (Task 6.10 Step 2).
- [ ] **HUMAN-VERIFY** Audio preset produces `.mp3` when ffmpeg is present (Task 6.10 Step 3).
- [ ] **HUMAN-VERIFY** Bogus URL fails readably; non-URL input rejected (Task 6.10 Step 4).
- [ ] **HUMAN-VERIFY** maxConcurrent=1 runs two URLs sequentially (Task 6.10 Step 5).
- [ ] **HUMAN-VERIFY** Cancel and Retry work mid-download (Task 6.10 Step 6).
- [ ] **HUMAN-VERIFY** "Update yt-dlp" re-installs cleanly while idle (Task 6.10 Step 7).
- [ ] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (18 Phase 6 tests: 6 ProgressParser + 4 FormatPresets + 3 VideoMetadata + 5 DownloadQueue).
- [ ] `git log --oneline | head -10` shows the nine Phase 6 commits on top.

## Risks & gotchas

- **LEGAL:** this tool is for downloading content the user has rights to — their own uploads, Creative Commons-licensed, or public-domain material. Respecting each site's Terms of Service is the user's responsibility. Keep the CC "Big Buck Bunny" URL as the documented test case.
- **Quarantine is the #1 silent failure.** If `removexattr` is skipped (or fails), every `Process.run()` of yt-dlp dies instantly with a Gatekeeper kill. Symptom: downloads fail immediately with no stderr. Check `xattr` on the binary first (Task 6.10 Step 1).
- **`--print` implies simulation.** Forgetting `--no-simulate` makes yt-dlp print a path and download nothing — the job "succeeds" instantly with no file. Both flags must always travel together (they do, in `YtDlpRunner.startDownload`).
- **Without ffmpeg there is no merging:** "best" silently caps at the best single-file format (often 720p on YouTube), and "audio" delivers `.m4a`/`.webm` instead of `.mp3`. That is the designed degradation — the settings tab's orange ffmpeg row (`brew install ffmpeg`) is the remedy, not a bug.
- **yt-dlp breaks when sites change** (master plan §11). The mitigation IS this phase's "Update yt-dlp" button — if downloads start failing with extractor errors, update the binary before debugging Fuse code.
- **Pipe deadlocks:** never read stdout to end while stderr is unconsumed (or vice versa) on a chatty process — a full 64 KB pipe buffer blocks the child forever. `fetchMetadata` drains stderr via `readabilityHandler` for exactly this reason; keep that pattern if modifying.
- **Cancelled-vs-failed races:** `terminate()` → `terminationReason == .uncaughtSignal` → mapped to `RunnerError.cancelled`, and `DownloadQueue.finish` ignores completions for items already marked `.cancelled`. Don't "simplify" either check away — a cancel would then resurface as a scary red failure row.
- **Titles with `/` or odd Unicode:** yt-dlp sanitizes filenames itself for the `-o "%(title)s [%(id)s].%(ext)s"` template; do not add extra sanitization on the Swift side, and always treat the `--print after_move:filepath` line as the truth about where the file landed.
- **HLS/fragmented downloads** report progress per fragment, so the bar may jump or briefly regress; harmless. Live streams have no duration — `VideoMetadata.duration` is optional for that reason.
- **First metadata fetch can take several seconds** on slow extractors; the "Fetching video info…" state is expected to linger. Cancellation during that state does not kill the metadata process (no handle yet) — the state guard in `beginDownload` simply discards its result. Acceptable: `-J` processes are short-lived.
- **App Transport Security:** the yt-dlp binary download is HTTPS from github.com — no Info.plist ATS exceptions needed. Do not add any.
- No hotkeys in this phase: the feature is menu + window only. `Core/HotkeyNames.swift` must not be touched.
