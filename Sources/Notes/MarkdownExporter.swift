import Foundation

/// Deterministic Markdown rendering of a note. Pure — fully unit-tested.
enum MarkdownExporter {
    /// Title (if non-empty) becomes "# <title>". Blocks render in array order,
    /// separated by single blank lines:
    ///   text  -> content verbatim
    ///   code  -> ```<language> fence (bare ``` when language is "")
    ///   link  -> <url> autolink form
    ///   image -> "> *[image block — not exported]*" placeholder
    /// The result always ends with exactly one trailing newline.
    /// (Empty title AND zero blocks yields "\n" — deterministic, never crashes.)
    static func markdown(title: String, blocks: [NoteBlock]) -> String {
        var sections: [String] = []
        if !title.isEmpty {
            sections.append("# \(title)")
        }
        for block in blocks {
            switch block.kind {
            case .text:
                sections.append(block.textContent)
            case .code:
                sections.append("```\(block.language)\n\(block.textContent)\n```")
            case .link:
                sections.append("<\(block.textContent)>")
            case .image:
                sections.append("> *[image block — not exported]*")
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
