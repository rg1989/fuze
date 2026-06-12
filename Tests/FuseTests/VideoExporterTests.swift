import AVFoundation
import XCTest
@testable import Fuse

final class VideoExporterTests: XCTestCase {
    func testFileTypeMapping() {
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "mp4"), .mp4)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "MP4"), .mp4)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: "mov"), .mov)
        XCTAssertEqual(VideoExporter.fileType(forPathExtension: ""), .mov)
    }
}
