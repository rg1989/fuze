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
