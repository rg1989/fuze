import Foundation

/// Pure decision logic: which kind of block should "+ From Clipboard" create?
/// Inputs are plain values, so this is fully unit-testable without NSPasteboard.
/// Code blocks are NEVER auto-detected — heuristics misfire; the user converts
/// a text block to code manually in the UI.
enum BlockImport {
    /// `types` = raw NSPasteboard.PasteboardType strings currently available;
    /// `plainString` = the pasteboard's string contents, if any.
    /// Priority: image > link > text. Returns nil when nothing usable exists.
    static func plannedBlock(types: Set<String>, plainString: String?) -> BlockKind? {
        if types.contains("public.png") || types.contains("public.tiff") {
            return .image
        }
        guard let trimmed = plainString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if isHTTPURL(trimmed) { return .link }
        return .text
    }

    /// True only for http/https URLs with a non-empty host and NO whitespace.
    /// The explicit whitespace check MUST come first: on macOS 14+ URL(string:)
    /// is lenient and percent-encodes spaces instead of returning nil.
    private static func isHTTPURL(_ string: String) -> Bool {
        guard string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
