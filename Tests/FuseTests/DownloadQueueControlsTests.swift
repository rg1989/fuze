import XCTest
@testable import Fuse

/// Covers the non-spawning queue controls: clear actions, pause/cancel state
/// transitions, and that paused items don't consume or claim scheduler slots.
/// (Resume's re-queue path launches a real yt-dlp process, so it's verified
/// manually rather than here.)
@MainActor
final class DownloadQueueControlsTests: XCTestCase {
    private func item(_ state: DownloadState, id: UUID = UUID()) -> DownloadItem {
        DownloadItem(id: id, url: "https://example.com/v", state: state)
    }

    func testClearFinishedRemovesOnlyFinished() {
        let q = DownloadQueue()
        q.items = [item(.finished), item(.failed), item(.finished)]
        q.clearFinished()
        XCTAssertEqual(q.items.map(\.state), [.failed])
    }

    func testClearFailedRemovesFailedAndCancelled() {
        let q = DownloadQueue()
        q.items = [item(.finished), item(.failed), item(.cancelled), item(.paused)]
        q.clearFailed()
        XCTAssertEqual(Set(q.items.map(\.state)), [.finished, .paused])
    }

    func testHasFinishedAndHasFailedFlags() {
        let q = DownloadQueue()
        XCTAssertFalse(q.hasFinished)
        XCTAssertFalse(q.hasFailed)
        q.items = [item(.finished), item(.cancelled)]
        XCTAssertTrue(q.hasFinished)
        XCTAssertTrue(q.hasFailed)
    }

    func testPauseMovesDownloadingToPaused() {
        let q = DownloadQueue()
        let id = UUID()
        q.items = [item(.downloading, id: id)]
        q.pause(id: id)
        XCTAssertEqual(q.items.first?.state, .paused)
    }

    func testCancelPausedBecomesCancelled() {
        let q = DownloadQueue()
        let id = UUID()
        q.items = [item(.paused, id: id)]
        q.cancel(id: id)
        XCTAssertEqual(q.items.first?.state, .cancelled)
    }

    func testResumeIgnoresNonPausedItem() {
        let q = DownloadQueue()
        let id = UUID()
        q.items = [item(.finished, id: id)]
        q.resume(id: id)   // not paused → no-op, must not spawn or mutate
        XCTAssertEqual(q.items.first?.state, .finished)
    }

    func testPausedItemIsNeitherActiveNorStartable() {
        // One downloading (active) + one paused + one queued, max 2:
        // the paused item must not count as active, so the queued one starts.
        let items = [item(.downloading), item(.paused), item(.queued)]
        XCTAssertEqual(DownloadQueue.nextStartable(items: items, maxConcurrent: 2), [2])
        // Paused alone must never be auto-started.
        XCTAssertEqual(DownloadQueue.nextStartable(items: [item(.paused)], maxConcurrent: 2), [])
    }
}
