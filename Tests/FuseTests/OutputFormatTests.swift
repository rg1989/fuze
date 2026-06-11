import XCTest
@testable import Fuse

final class OutputFormatTests: XCTestCase {
    // MARK: - Downloader container arguments

    func testMP4ContainerWithFfmpeg() {
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "mp4", preset: "best", ffmpegAvailable: true),
            ["--merge-output-format", "mp4", "--remux-video", "mp4"])
    }

    func testMKVAndWebMAccepted() {
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "mkv", preset: "1080p", ffmpegAvailable: true),
            ["--merge-output-format", "mkv", "--remux-video", "mkv"])
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "webm", preset: "720p", ffmpegAvailable: true),
            ["--merge-output-format", "webm", "--remux-video", "webm"])
    }

    func testNoContainerArgsWithoutFfmpeg() {
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "mp4", preset: "best", ffmpegAvailable: false),
            [])
    }

    func testNoContainerArgsForAudioPreset() {
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "mp4", preset: "audio", ffmpegAvailable: true),
            [])
    }

    func testOriginalAndUnknownContainersAddNothing() {
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "original", preset: "best", ffmpegAvailable: true),
            [])
        XCTAssertEqual(
            FormatPresets.containerArguments(container: "avi", preset: "best", ffmpegAvailable: true),
            [])
    }

    // MARK: - Capture filename extensions

    func testCaptureNameDefaultsToPngAndMov() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(CaptureNames.fileName(kind: .screenshot, date: date, timeZone: utc).hasSuffix(".png"))
        XCTAssertTrue(CaptureNames.fileName(kind: .recording, date: date, timeZone: utc).hasSuffix(".mov"))
    }

    func testCaptureNameHonorsExplicitExtension() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(CaptureNames.fileName(kind: .screenshot, date: date, timeZone: utc,
                                            fileExtension: "jpg").hasSuffix(".jpg"))
        XCTAssertTrue(CaptureNames.fileName(kind: .recording, date: date, timeZone: utc,
                                            fileExtension: "mp4").hasSuffix(".mp4"))
    }
}
