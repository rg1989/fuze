import Foundation

/// The subset of `yt-dlp -J --no-playlist <url>` output that Fuse displays.
/// yt-dlp emits hundreds of keys; JSONDecoder ignores everything not listed here.
struct VideoMetadata: Decodable, Equatable {
    let id: String
    let title: String
    let duration: Double?      // seconds; absent for live streams / some extractors
    let thumbnail: String?     // URL string; absent on some extractors
    let extractor: String      // e.g. "youtube", "vimeo", "generic"
    let webpageURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, duration, thumbnail, extractor
        case webpageURL = "webpage_url"
    }

    static func decode(from data: Data) throws -> VideoMetadata {
        try JSONDecoder().decode(VideoMetadata.self, from: data)
    }
}
