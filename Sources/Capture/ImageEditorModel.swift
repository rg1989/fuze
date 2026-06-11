import CoreGraphics
import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, freehand, highlighter, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        }
    }
}

/// Six preset colors stored as an enum (trivially Equatable/Codable-ready;
/// no NSColor in the model). The NSColor mapping lives in the view layer.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, black
    var id: String { rawValue }
}

/// One annotation, in image POINT coordinates with TOP-LEFT origin
/// (the SwiftUI Canvas space; the flattener uses a flipped context to match).
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var points: [CGPoint] = []   // freehand/highlighter vertices; arrow = [from, to]
    var rect: CGRect = .zero     // rectangle/ellipse bounds; text anchor = rect.origin
    var text: String = ""
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 4

    init(id: UUID = UUID(), tool: AnnotationTool) {
        self.id = id
        self.tool = tool
    }
}

enum AnnotationGeometry {
    /// The two barb endpoints of an arrow head whose tip is at `to`,
    /// pointing back toward `from`, each `length` long, 30° off the shaft.
    static func arrowHeadPoints(from: CGPoint, to: CGPoint,
                                length: CGFloat) -> (CGPoint, CGPoint) {
        let back = atan2(to.y - from.y, to.x - from.x) + .pi
        let spread = CGFloat.pi / 6
        let left = CGPoint(x: to.x + length * cos(back - spread),
                           y: to.y + length * sin(back - spread))
        let right = CGPoint(x: to.x + length * cos(back + spread),
                            y: to.y + length * sin(back + spread))
        return (left, right)
    }
}

/// THE shared geometry between the live Canvas and the AppKit flattener:
/// one CGPath per annotation. Text is not a path — both renderers draw it
/// as an attributed string (the only intentionally duplicated rendering).
enum AnnotationPaths {
    static func path(for a: Annotation) -> CGPath {
        let path = CGMutablePath()
        switch a.tool {
        case .arrow:
            guard a.points.count >= 2 else { break }
            let from = a.points[0]
            let to = a.points[a.points.count - 1]
            path.move(to: from)
            path.addLine(to: to)
            let head = AnnotationGeometry.arrowHeadPoints(
                from: from, to: to, length: max(10, a.lineWidth * 3))
            path.move(to: head.0)
            path.addLine(to: to)
            path.addLine(to: head.1)
        case .rectangle:
            path.addRect(a.rect)
        case .ellipse:
            path.addEllipse(in: a.rect)
        case .freehand, .highlighter:
            guard let first = a.points.first else { break }
            path.move(to: first)
            for p in a.points.dropFirst() {
                path.addLine(to: p)
            }
        case .text:
            break   // drawn as a string by each renderer
        }
        return path
    }
}
