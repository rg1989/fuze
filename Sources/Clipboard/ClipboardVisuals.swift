import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Pure presentation mapping for clipboard item kinds: one color + symbol per
/// kind so rows are scannable at a glance.
struct KindStyle: Equatable {
    let symbol: String
    let tint: Color

    static func style(for kind: String) -> KindStyle {
        switch kind {
        case "text": return KindStyle(symbol: "text.alignleft", tint: .blue)
        case "rtf": return KindStyle(symbol: "doc.richtext", tint: .indigo)
        case "link": return KindStyle(symbol: "link", tint: .purple)
        case "image": return KindStyle(symbol: "photo", tint: .orange)
        case "file": return KindStyle(symbol: "doc", tint: .teal)
        default: return KindStyle(symbol: "questionmark.square", tint: .gray)
        }
    }
}

enum ClipboardMedia {
    /// True when the path's extension is a video / audiovisual type.
    static func isVideo(path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}

/// Favicon fetch + cache for link rows (Google s2 service, 64 px). Misses and
/// offline states degrade to nil; the row falls back to the colored link icon.
@MainActor
enum FaviconLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func favicon(forLink urlString: String) async -> NSImage? {
        guard let host = URL(string: urlString)?.host else { return nil }
        if let hit = cache.object(forKey: host as NSString) { return hit }
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: host as NSString)
        return image
    }
}

/// QuickLook thumbnails for file rows — covers images, videos, PDFs, and
/// anything else QuickLook understands; falls back to the Finder icon.
@MainActor
enum FileThumbnailLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for fileURL: URL, side: CGFloat = 88) async -> NSImage? {
        let key = fileURL.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .thumbnail)
        let image: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: fileURL.path)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
