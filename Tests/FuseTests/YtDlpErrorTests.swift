import XCTest
@testable import Fuse

final class YtDlpErrorTests: XCTestCase {

    // The exact stderr Fuse received for the reported IMDb URL.
    func testRealIMDbWafFailureMapsToExtractorBroken() {
        let stderr = """
        [imdb] Extracting URL: https://www.imdb.com/video/vi662489881/
        [imdb] 662489881: Downloading webpage
        ERROR: [imdb] 662489881: Unable to extract next.js data; please report this \
        issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the \
        appropriate issue template. Confirm you are on the latest version using  yt-dlp -U
        """
        XCTAssertEqual(YtDlpFailure.classify(stderr: stderr), .extractorBroken)
        XCTAssertTrue(YtDlpFailure.friendlyMessage(stderr: stderr).contains("recently changed"))
    }

    func testCategorySignatures() {
        let cases: [(String, YtDlpFailure)] = [
            ("ERROR: You have requested merging of multiple formats but ffmpeg is not installed. Aborting.", .ffmpegMissing),
            ("ERROR: [youtube] abc: Sign in to confirm you're not a bot", .needsSignIn),
            ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access", .needsSignIn),
            ("ERROR: [youtube] abc: Join this channel to get access to members-only content", .needsSignIn),
            ("ERROR: [youtube] abc: This video is not available in your country", .geoBlocked),
            ("ERROR: [generic] HTTP Error 429: Too Many Requests", .rateLimited),
            ("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader", .unavailable),
            ("ERROR: Unsupported URL: https://example.com/not-a-video", .unsupportedSite),
            ("ERROR: [imdb] 1: Unable to extract next.js data; please report this issue", .extractorBroken),
            ("ERROR: [youtube] abc: Requested format is not available", .noVideoFound),
            ("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>", .network),
        ]
        for (stderr, expected) in cases {
            XCTAssertEqual(YtDlpFailure.classify(stderr: stderr), expected,
                           "misclassified: \(stderr)")
        }
    }

    func testUnknownFallbackExtractsCleanErrorLine() {
        let stderr = """
        [debug] Command-line config: ['-J', 'https://x.test/v']
        [info] some chatter
        ERROR: [sometest] 42: Something weird happened that we don't recognize
        """
        guard case let .unknown(detail) = YtDlpFailure.classify(stderr: stderr) else {
            return XCTFail("expected .unknown")
        }
        // ERROR: prefix and "[sometest] 42:" prefix both stripped.
        XCTAssertEqual(detail, "Something weird happened that we don't recognize")
        XCTAssertEqual(YtDlpFailure.friendlyMessage(stderr: stderr),
                       "Download failed: Something weird happened that we don't recognize")
    }

    func testEmptyStderrGivesGenericMessage() {
        XCTAssertEqual(YtDlpFailure.classify(stderr: ""), .unknown(""))
        XCTAssertTrue(YtDlpFailure.friendlyMessage(stderr: "").contains("See Console logs"))
    }

    func testCleanedErrorLineStripsReportTail() {
        let line = YtDlpFailure.cleanedErrorLine(
            "ERROR: [imdb] 99: Unable to extract next.js data; please report this issue on https://...")
        XCTAssertEqual(line, "Unable to extract next.js data")
    }
}
