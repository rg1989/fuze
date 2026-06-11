import AVKit
import AppKit
import SwiftUI

/// Pure slider math: fractional start/end (0…1) of a clip → CMTimeRange.
/// nil when duration is non-positive or the clamped range is empty.
enum TrimMath {
    static func trimRange(start: Double, end: Double, duration: Double) -> CMTimeRange? {
        guard duration > 0 else { return nil }
        let s = min(max(start, 0), 1)
        let e = min(max(end, 0), 1)
        guard e > s else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: s * duration, preferredTimescale: 600),
            end: CMTime(seconds: e * duration, preferredTimescale: 600))
    }
}

final class VideoTrimmerState: ObservableObject {
    let fileURL: URL
    let player: AVPlayer
    @Published var start: Double = 0
    @Published var end: Double = 1
    @Published var durationSeconds: Double = 0
    @Published var exporting = false
    @Published var statusMessage = ""

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.player = AVPlayer(url: fileURL)
        Task { @MainActor in
            let asset = AVURLAsset(url: fileURL)
            if let duration = try? await asset.load(.duration) {
                self.durationSeconds = duration.seconds
            }
        }
    }

    var exportDisabled: Bool {
        exporting || TrimMath.trimRange(start: start, end: end,
                                        duration: durationSeconds) == nil
    }

    func exportTrimmed() {
        guard let range = TrimMath.trimRange(start: start, end: end,
                                             duration: durationSeconds) else { return }
        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            statusMessage = "Export session unavailable"
            return
        }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let outURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(base) trimmed.mov")
        try? FileManager.default.removeItem(at: outURL)
        session.outputURL = outURL
        session.outputFileType = .mov
        session.timeRange = range
        exporting = true
        statusMessage = "Exporting…"
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                if session.status == .completed {
                    self.statusMessage = "Saved \(outURL.lastPathComponent)"
                    PasteService.write(
                        [[CaptureController.fileURLType: outURL.dataRepresentation]],
                        markInternal: false)
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                    Log.capture.info("trimmed export saved: \(outURL.path, privacy: .public)")
                } else {
                    let reason = session.error?.localizedDescription ?? "unknown error"
                    self.statusMessage = "Export failed: \(reason)"
                    Log.capture.error("trim export failed: \(reason, privacy: .public)")
                }
            }
        }
    }
}

struct VideoTrimmerView: View {
    @ObservedObject var state: VideoTrimmerState

    var body: some View {
        VStack(spacing: 12) {
            VideoPlayer(player: state.player)
                .frame(minWidth: 560, minHeight: 320)
            HStack(spacing: 8) {
                Text(timeLabel(state.start)).monospacedDigit()
                Slider(value: $state.start, in: 0...1) { Text("Start") }
                Slider(value: $state.end, in: 0...1) { Text("End") }
                Text(timeLabel(state.end)).monospacedDigit()
            }
            HStack {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export Trimmed") { state.exportTrimmed() }
                    .disabled(state.exportDisabled)
            }
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 420)
    }

    private func timeLabel(_ fraction: Double) -> String {
        let s = Int(fraction * state.durationSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Plain NSWindow hosting the trimmer. Retained by CaptureController until
/// the window closes.
final class VideoTrimmerWindowController {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    var onClose: (() -> Void)?

    init(fileURL: URL) {
        let state = VideoTrimmerState(fileURL: fileURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.contentView = NSHostingView(rootView: VideoTrimmerView(state: state))
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
