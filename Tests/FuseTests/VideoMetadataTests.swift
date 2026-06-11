import XCTest
@testable import Fuse

final class VideoMetadataTests: XCTestCase {
    /// Realistic excerpt of `yt-dlp -J` output. The extra keys (uploader,
    /// view_count, formats, …) prove decoding tolerates unknown fields.
    private let fixture = """
    {
      "id": "aqz-KE-bpKQ",
      "title": "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film",
      "duration": 635.0,
      "thumbnail": "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp",
      "extractor": "youtube",
      "webpage_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
      "uploader": "Blender",
      "view_count": 8512341,
      "like_count": 124000,
      "formats": [{"format_id": "137", "ext": "mp4", "height": 1080}],
      "categories": ["Film & Animation"],
      "age_limit": 0,
      "is_live": false
    }
    """

    func testDecodesRealisticFixtureIgnoringUnknownKeys() throws {
        let metadata = try VideoMetadata.decode(from: Data(fixture.utf8))
        XCTAssertEqual(metadata.id, "aqz-KE-bpKQ")
        XCTAssertEqual(metadata.title, "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        XCTAssertEqual(metadata.duration, 635.0)
        XCTAssertEqual(metadata.thumbnail, "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp")
        XCTAssertEqual(metadata.extractor, "youtube")
        XCTAssertEqual(metadata.webpageURL, "https://www.youtube.com/watch?v=aqz-KE-bpKQ")
    }

    func testDecodesWhenOptionalFieldsAreMissing() throws {
        // Live streams and some extractors omit duration/thumbnail entirely.
        let minimal = """
        {"id": "x1", "title": "Clip", "extractor": "generic", "webpage_url": "https://example.com/clip"}
        """
        let metadata = try VideoMetadata.decode(from: Data(minimal.utf8))
        XCTAssertNil(metadata.duration)
        XCTAssertNil(metadata.thumbnail)
        XCTAssertEqual(metadata.title, "Clip")
    }

    func testThrowsOnNonJSONData() {
        // yt-dlp sometimes prints an error string instead of JSON; decoding must throw, not crash.
        XCTAssertThrowsError(try VideoMetadata.decode(from: Data("ERROR: not json".utf8)))
    }
}
