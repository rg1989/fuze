import AppKit
import Vision

/// One recognized text line with its position, normalized to the image with the
/// origin at the TOP-left (y grows downward) so reading order is a simple sort.
struct RecognizedLine: Equatable {
    let text: String
    let rect: CGRect
}

/// On-device OCR via Apple's Vision framework — fast (Neural Engine), no model
/// download, no dependency. Recognizes text in an image and renders it as
/// structured markdown.
enum TextExtractor {
    /// Recognizes text lines with positions. Returns [] if the image can't be
    /// read or Vision finds nothing.
    static func recognize(_ image: NSImage) async -> [RecognizedLine] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { o -> RecognizedLine? in
                    guard let text = o.topCandidates(1).first?.string,
                          !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    // Vision boundingBox: normalized, origin BOTTOM-left → flip to top-based.
                    let bb = o.boundingBox
                    return RecognizedLine(text: text,
                                          rect: CGRect(x: bb.minX, y: 1 - bb.maxY,
                                                       width: bb.width, height: bb.height))
                }
                cont.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                // On success the completion handler above resumes; only resume here
                // if perform() throws (then the handler never ran).
                do { try handler.perform([request]) } catch { cont.resume(returning: []) }
            }
        }
    }

    static func markdown(from image: NSImage) async -> String {
        TextStructurer.markdown(from: await recognize(image))
    }
}

/// Turns positioned OCR lines into structured markdown: groups same-row
/// fragments left-to-right, separates blocks with blank lines by vertical gap,
/// promotes visually larger lines to headings, and normalizes bullet lists.
/// Pure and deterministic — unit-tested without Vision.
enum TextStructurer {
    static func markdown(from lines: [RecognizedLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let heights = lines.map { $0.rect.height }.sorted()
        let median = max(heights[heights.count / 2], 0.0001)

        // Sort into reading order: quantize y into rows, then left-to-right.
        let q = median * 0.6
        let sorted = lines.sorted { a, b in
            let ay = (a.rect.minY / q).rounded(), by = (b.rect.minY / q).rounded()
            return ay != by ? ay < by : a.rect.minX < b.rect.minX
        }

        // Merge fragments that sit on the same visual row.
        struct Row { var text: String; var y: Double; var h: Double; var bottom: Double }
        var rows: [Row] = []
        for line in sorted {
            let y = line.rect.minY, h = line.rect.height
            if var last = rows.last, abs(y - last.y) < median * 0.5 {
                last.text += " " + line.text
                last.h = max(last.h, h)
                last.bottom = max(last.bottom, y + h)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(text: line.text, y: y, h: h, bottom: y + h))
            }
        }

        var out: [String] = []
        var prevBottom: Double?
        for row in rows {
            if let pb = prevBottom, row.y - pb > median * 1.2 { out.append("") }   // block gap
            out.append(format(row.text, height: row.h, median: median))
            prevBottom = row.bottom
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func format(_ text: String, height: Double, median: Double) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        // Bullet lists → normalized "- ".
        if let m = t.range(of: #"^[-•*‣·◦]\s+"#, options: .regularExpression) {
            return "- " + t[m.upperBound...]
        }
        // Ordered lists ("1." / "1)") kept as-is.
        if t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil { return t }
        // Headings by relative size.
        if height > median * 1.8 { return "# " + t }
        if height > median * 1.4 { return "## " + t }
        return t
    }
}
