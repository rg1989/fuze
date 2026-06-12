import XCTest
@testable import Fuse

final class YtDlpStatusTests: XCTestCase {
    func testRecognizedSteps() {
        let cases: [(String, String?)] = [
            ("[youtube] dQw4w9WgXcQ: Downloading webpage", "Reading page…"),
            ("[generic] video: Downloading m3u8 information", "Reading stream info…"),
            ("[youtube] dQw4: Downloading android player API JSON", "Reading video data…"),
            ("[info] dQw4: Downloading 1 format(s): 137+140", "Preparing download…"),
            ("[Merger] Merging formats into \"clip.mp4\"", "Merging audio + video…"),
            ("[ExtractAudio] Destination: clip.mp3", "Extracting audio…"),
            ("[imdb] Extracting URL: https://www.imdb.com/video/vi1/", "Resolving link…"),
            ("[download] Destination: /Users/me/Downloads/clip.mp4", "Starting download…"),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(YtDlpStatus.currentStep(line: line), expected, "for: \(line)")
        }
    }

    func testGenericVerbFallbackStripsPrefix() {
        XCTAssertEqual(
            YtDlpStatus.currentStep(line: "[twitter] 12345: Downloading guest token"),
            "Downloading guest token…")
    }

    func testNonStepLinesReturnNil() {
        let noise = [
            "[debug] Encodings: locale utf-8",
            "WARNING: some warning",
            "ERROR: [imdb] 1: Unable to extract next.js data",
            "FUSEP|  42.7%|  3.21MiB/s|00:35",
            "",
            "   ",
            "[youtube] dQw4: Some non-verb status message",
        ]
        for line in noise {
            XCTAssertNil(YtDlpStatus.currentStep(line: line), "should be nil: \(line)")
        }
    }
}
