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

    func testSortForDisplayActiveBeforeInactiveMostRecentFirst() {
        let a = item(.finished)
        let b = item(.downloading)
        let c = item(.queued)
        let d = item(.finished)
        let items = [a, b, c, d]
        let sorted = DownloadQueue.sortForDisplay(items)
        XCTAssertEqual(sorted.map(\.id), [c.id, b.id, d.id, a.id])
    }
}
