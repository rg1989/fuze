import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

extension AnnotationColor {
    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .black: return .black
        }
    }
}

/// Editor session state + the impure actions (flatten, crop, copy, save).
final class ImageEditorState: ObservableObject {
    @Published var image: NSImage
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow
    @Published var color: AnnotationColor = .red
    @Published var lineWidth: CGFloat = 4
    @Published var inProgress: Annotation?
    @Published var cropMode = false
    @Published var cropRect: CGRect?
    @Published var pendingText: CGPoint?
    @Published var pixelatePreview: CGRect?
    @Published var textDraft = ""

    let fileURL: URL

    init(image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
    }

    // MARK: - Gesture handling (image point coords, top-left origin)

    func dragChanged(start: CGPoint, current: CGPoint) {
        if cropMode {
            cropRect = CaptureGeometry.normalizedRect(from: start, to: current)
            return
        }
        switch tool {
        case .text:
            break   // text places on dragEnded (a click)
        case .pixelate:
            pixelatePreview = CaptureGeometry.normalizedRect(from: start, to: current)
        case .arrow:
            var a = inProgress ?? newAnnotation()
            a.points = [start, current]
            inProgress = a
        case .rectangle, .ellipse:
            var a = inProgress ?? newAnnotation()
            a.rect = CaptureGeometry.normalizedRect(from: start, to: current)
            inProgress = a
        case .freehand, .highlighter:
            var a = inProgress ?? newAnnotation()
            if a.points.isEmpty { a.points.append(start) }
            a.points.append(current)
            inProgress = a
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        if cropMode { return }   // crop rect persists until "Apply Crop"
        if tool == .text {
            pendingText = end
            textDraft = ""
            return
        }
        if tool == .pixelate {
            let region = CaptureGeometry.normalizedRect(from: start, to: end)
            pixelatePreview = nil
            applyPixelate(in: region)
            return
        }
        dragChanged(start: start, current: end)
        if let a = inProgress {
            annotations.append(a)
            inProgress = nil
        }
    }

    func commitText() {
        defer {
            pendingText = nil
            textDraft = ""
        }
        guard let anchor = pendingText, !textDraft.isEmpty else { return }
        var a = newAnnotation()
        a.tool = .text
        a.text = textDraft
        a.rect = CGRect(origin: anchor, size: .zero)
        annotations.append(a)
    }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast() }
    }

    private func newAnnotation() -> Annotation {
        var a = Annotation(tool: tool)
        a.color = color
        a.lineWidth = lineWidth
        return a
    }

    // MARK: - Flatten / crop / output

    /// Renders base image + all annotations into one NSImage. flipped: true
    /// gives the handler a TOP-LEFT-origin context, matching the Canvas, so
    /// annotation coordinates are used verbatim — no ad-hoc flips.
    func flattened() -> NSImage {
        let size = image.size
        let base = image
        let annotations = self.annotations
        return NSImage(size: size, flipped: true) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            for a in annotations {
                Self.drawWithAppKit(a)
            }
            return true
        }
    }

    /// AppKit stroker — thin twin of the Canvas stroker in ImageEditorView.
    /// Both consume AnnotationPaths.path(for:); only stroke application and
    /// text drawing are duplicated (GraphicsContext vs NSGraphicsContext).
    static func drawWithAppKit(_ a: Annotation) {
        if a.tool == .text {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: a.color.nsColor,
            ]
            a.text.draw(at: a.rect.origin, withAttributes: attrs)
            return
        }
        let path = NSBezierPath(cgPath: AnnotationPaths.path(for: a))
        path.lineWidth = a.tool == .highlighter ? a.lineWidth * 4 : a.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let color = a.tool == .highlighter
            ? a.color.nsColor.withAlphaComponent(0.4)
            : a.color.nsColor
        color.setStroke()
        path.stroke()
    }

    /// Flatten current annotations into the image, then trim. Annotations
    /// are cleared (they are now part of the pixels) — Undo does not cross
    /// a crop, by design.
    func applyCrop() {
        guard let cropRect, cropRect.width >= 1, cropRect.height >= 1 else { return }
        let flat = flattened()
        guard let cg = flat.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // CGImage pixel space is top-left origin, same as our annotation
        // space — only the point→pixel scale differs (Retina backing).
        let scaleX = CGFloat(cg.width) / flat.size.width
        let scaleY = CGFloat(cg.height) / flat.size.height
        let pixelRect = CGRect(x: cropRect.minX * scaleX,
                               y: cropRect.minY * scaleY,
                               width: cropRect.width * scaleX,
                               height: cropRect.height * scaleY)
        guard let cropped = cg.cropping(to: pixelRect.integral) else { return }
        image = NSImage(cgImage: cropped, size: cropRect.size)
        annotations = []
        inProgress = nil
        self.cropRect = nil
        cropMode = false
    }

    /// Bake a pixelated version of `rect` (image points, top-left origin)
    /// into the base image. Destructive — not undoable, like crop.
    func applyPixelate(in rect: CGRect) {
        guard rect.width >= 2, rect.height >= 2,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let scaleX = CGFloat(cg.width) / image.size.width
        let scaleY = CGFloat(cg.height) / image.size.height
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter.pixellate()
        filter.inputImage = ci
        filter.scale = Float(16 * max(scaleX, 1))
        filter.center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        guard let pixelated = filter.outputImage else { return }
        // CoreImage is BOTTOM-LEFT origin; our rect is top-left — flip Y.
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: CGFloat(cg.height) - rect.maxY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY)
        let composited = pixelated.cropped(to: pixelRect).composited(over: ci)
        let context = CIContext()
        guard let outCG = context.createCGImage(composited, from: ci.extent) else { return }
        image = NSImage(cgImage: outCG, size: image.size)
    }

    static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func copyFlattened() {
        guard let data = Self.pngData(of: flattened()) else { return }
        // markInternal: false — clipboard history records the edited image too.
        PasteService.write([[.png: data]], markInternal: false)
    }

    func save() {
        guard let data = Self.pngData(of: flattened()) else { return }
        do {
            try data.write(to: fileURL)
            Log.capture.info("editor saved over \(self.fileURL.path, privacy: .public)")
        } catch {
            Log.capture.error("editor save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveAs() {
        guard let data = Self.pngData(of: flattened()) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.directoryURL = fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            Log.capture.info("editor saved as \(url.path, privacy: .public)")
        } catch {
            Log.capture.error("editor save-as failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct ImageEditorView: View {
    @ObservedObject var state: ImageEditorState
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                canvasStack
                    .frame(width: state.image.size.width,
                           height: state.image.size.height)
                    .padding(12)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $state.tool) {
                ForEach(AnnotationTool.allCases) { tool in
                    Image(systemName: tool.symbolName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            HStack(spacing: 5) {
                ForEach(AnnotationColor.allCases) { color in
                    Button {
                        state.color = color
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(
                                Color.primary.opacity(state.color == color ? 0.8 : 0),
                                lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Width", selection: $state.lineWidth) {
                Text("2").tag(CGFloat(2))
                Text("4").tag(CGFloat(4))
                Text("6").tag(CGFloat(6))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
            Button("Undo") { state.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(state.annotations.isEmpty)
            Toggle("Crop", isOn: $state.cropMode)
                .toggleStyle(.button)
            if state.cropMode {
                Button("Apply Crop") { state.applyCrop() }
                    .disabled(state.cropRect == nil)
            }
            Spacer()
            Button("Copy") { state.copyFlattened() }
            Button("Save") { state.save() }
            Button("Save As…") { state.saveAs() }
        }
        .padding(10)
    }

    private var canvasStack: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: state.image)
                .resizable()
                .frame(width: state.image.size.width,
                       height: state.image.size.height)
            Canvas { context, _ in
                for a in state.annotations { draw(a, in: &context) }
                if let a = state.inProgress { draw(a, in: &context) }
                if state.cropMode, let crop = state.cropRect {
                    context.stroke(Path(crop), with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let preview = state.pixelatePreview {
                    context.stroke(Path(preview), with: .color(.gray),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .gesture(dragGesture)
            if let anchor = state.pendingText {
                TextField("Text", text: $state.textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($textFieldFocused)
                    .offset(x: anchor.x, y: anchor.y)
                    .onSubmit { state.commitText() }
                    .onAppear { textFieldFocused = true }
            }
        }
    }

    /// Canvas stroker — thin twin of ImageEditorState.drawWithAppKit.
    private func draw(_ a: Annotation, in context: inout GraphicsContext) {
        if a.tool == .text {
            context.draw(
                Text(a.text)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(nsColor: a.color.nsColor)),
                at: a.rect.origin, anchor: .topLeading)
            return
        }
        let path = Path(AnnotationPaths.path(for: a))
        let opacity = a.tool == .highlighter ? 0.4 : 1.0
        let width = a.tool == .highlighter ? a.lineWidth * 4 : a.lineWidth
        context.stroke(
            path,
            with: .color(Color(nsColor: a.color.nsColor).opacity(opacity)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                state.dragChanged(start: value.startLocation, current: value.location)
            }
            .onEnded { value in
                state.dragEnded(start: value.startLocation, end: value.location)
            }
    }
}

/// Plain NSWindow hosting the editor. Retained by CaptureController until
/// the window closes (multiple editors may be open at once).
final class ImageEditorWindowController {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    var onClose: (() -> Void)?

    init?(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        let state = ImageEditorState(image: image, fileURL: fileURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: min(image.size.width + 48, 1200),
                                height: min(image.size.height + 110, 800)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.contentView = NSHostingView(rootView: ImageEditorView(state: state))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
