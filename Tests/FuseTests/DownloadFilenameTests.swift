import XCTest
@testable import Fuse

final class DownloadIndexTests: XCTestCase {
    func testExistingFilenameFromIndex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("My Clip.mp4")
        try Data().write(to: file)

        let indexURL = DownloadIndex.url
        let indexBackup = try? Data(contentsOf: indexURL)
        defer {
            if let indexBackup { try? indexBackup.write(to: indexURL) }
            else { try? FileManager.default.removeItem(at: indexURL) }
        }

        DownloadIndex.record(videoId: "abc123", path: file.path)
        XCTAssertEqual(DownloadIndex.existingFilename(forVideoId: "abc123", in: dir.path),
                       "My Clip.mp4")
        XCTAssertNil(DownloadIndex.existingFilename(forVideoId: "other", in: dir.path))
    }

    func testLegacyFilenameWithIdTag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "My Clip [abc123].mp4"
        try Data().write(to: dir.appendingPathComponent(name))

        let indexURL = DownloadIndex.url
        let indexBackup = try? Data(contentsOf: indexURL)
        defer {
            if let indexBackup { try? indexBackup.write(to: indexURL) }
            else { try? FileManager.default.removeItem(at: indexURL) }
        }
        try? FileManager.default.removeItem(at: indexURL)

        XCTAssertEqual(DownloadIndex.existingFilename(forVideoId: "abc123", in: dir.path), name)
    }
}

final class DownloadURLDedupTests: XCTestCase {
    private func item(_ state: DownloadState, url: String = "https://example.com/v") -> DownloadItem {
        DownloadItem(id: UUID(), url: url, state: state,
                     metadata: nil, progress: nil, resultPath: nil, errorMessage: nil)
    }

    func testActiveURLDetected() {
        let url = "https://example.com/watch?v=1"
        let items = [item(.downloading, url: url), item(.finished, url: url)]
        XCTAssertTrue(DownloadQueue.isURLActive(url, in: items))
    }

    func testFinishedURLNotActive() {
        let url = "https://example.com/watch?v=1"
        let items = [item(.finished, url: url)]
        XCTAssertFalse(DownloadQueue.isURLActive(url, in: items))
    }
}
