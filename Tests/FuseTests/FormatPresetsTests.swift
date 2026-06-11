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
