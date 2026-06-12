import GRDB
import XCTest
@testable import Fuse

final class ClipboardStagingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("clip".utf8).write(to: url)
        return url
    }

    func testSweepDeletesUnreferencedOldFiles() throws {
        let url = try makeFile("a.mp4")
        // "now" 2 minutes in the future puts the file safely past the grace period.
        ClipboardStaging.sweep(directory: tempDir, referencedPaths: [],
                               now: Date().addingTimeInterval(120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSweepKeepsReferencedFiles() throws {
        let url = try makeFile("b.mp4")
        ClipboardStaging.sweep(directory: tempDir,
                               referencedPaths: [url.standardizedFileURL.path],
                               now: Date().addingTimeInterval(120))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSweepSparesYoungUnreferencedFiles() throws {
        // Just-created file: inside the grace window even though unreferenced —
        // insurance against the gap between the pasteboard write and the
        // watcher recording the history entry.
        let url = try makeFile("c.mp4")
        ClipboardStaging.sweep(directory: tempDir, referencedPaths: [], now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStageMovesFileIntoDirectoryWithUniqueName() throws {
        let source = try makeFile("Fuse Recording.mp4")
        let staged = try ClipboardStaging.stage(source)
        defer { try? FileManager.default.removeItem(at: staged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(staged.path.hasPrefix(ClipboardStaging.directory.path))
        XCTAssertTrue(staged.lastPathComponent.hasSuffix("Fuse Recording.mp4"))
    }

    func testReferencedFilePathsFindsFileURLRepsUnderDirectory() throws {
        let store = try ClipboardStore(dbQueue: DatabaseQueue())
        let inside = tempDir.appendingPathComponent("kept.mp4")
        let outside = URL(fileURLWithPath: "/somewhere/else/other.mp4")
        func saveFileURL(_ url: URL) throws {
            let reps = [(type: "public.file-url", data: url.dataRepresentation)]
            try store.save(kind: "file", preview: url.lastPathComponent, thumbnail: nil,
                           sourceApp: nil,
                           contentHash: ClipboardStore.hash(representations: reps),
                           representations: reps)
        }
        try saveFileURL(inside)
        try saveFileURL(outside)
        try store.save(kind: "text", preview: "txt", thumbnail: nil, sourceApp: nil,
                       contentHash: "texthash",
                       representations: [(type: "public.utf8-plain-text", data: Data("hi".utf8))])
        let paths = try store.referencedFilePaths(under: tempDir)
        XCTAssertEqual(paths, [inside.standardizedFileURL.path])
    }
}
