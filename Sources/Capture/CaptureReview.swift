import AppKit
import AVKit
import CoreMedia
import SwiftUI

/// Callback box so CaptureController can wire the action handler AFTER the
/// window (and the SwiftUI views referencing this object) exist — same
/// pattern as the old CapturePreviewActions / RecHUDModel.
final class ReviewActionRelay: ObservableObject {
    var onAction: ((ReviewAction) -> Void)?
}

/// Trim state for the recording review: player + fractional start/end.
final class VideoReviewState: ObservableObject {
    let fileURL: URL
    let player: AVPlayer
    @Published var start: Double = 0
    @Published var end: Double = 1
    @Published var durationSeconds: Double = 0

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

    /// nil when the sliders are at (effectively) full range or the range is
    /// invalid — Save skips the export entirely.
    var pendingTrim: CMTimeRange? {
        guard durationSeconds > 0,
              !TrimMath.isNoOp(start: start, end: end) else { return nil }
        return TrimMath.trimRange(start: start, end: end, duration: durationSeconds)
    }
}

/// The four-way exit row shown at the bottom of both review windows.
/// Esc/Return are handled by the window controller's key monitor (single
/// press = with copy, quick double press = without); buttons stay clickable.
struct ReviewActionBar: View {
    var onAction: (ReviewAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { onAction(.delete) } label: {
                Label(ReviewAction.delete.title, systemImage: "trash")
            }

            Button { onAction(.deleteAndCopy) } label: {
                Label(ReviewAction.deleteAndCopy.title, systemImage: "trash.square")
            }

            Spacer()

            Text("↩ save+copy · ↩↩ save · esc delete+copy · esc esc delete")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button { onAction(.save) } label: {
                Label(ReviewAction.save.title, systemImage: "internaldrive")
            }
            .keyboardShortcut("s", modifiers: .command)

            Button { onAction(.saveAndCopy) } label: {
                Label(ReviewAction.saveAndCopy.title, systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }
}

/// Screenshot review = the annotation editor with the action bar under it.
/// No "Edit…" step: draw, crop, pixelate immediately, then pick an exit.
struct ScreenshotReviewView: View {
    @ObservedObject var state: ImageEditorState
    var onAction: (ReviewAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ImageEditorPane(state: state)
            Divider()
            ReviewActionBar(onAction: onAction)
                .padding(12)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

/// AppKit AVPlayerView bridged into SwiftUI. SwiftUI's VideoPlayer
/// (_AVKit_SwiftUI) aborts in generic-metadata instantiation on this OS,
/// so the review window uses the AppKit player directly.
private struct ReviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// Recording review = player + trim sliders with the action bar under it.
struct VideoReviewView: View {
    @ObservedObject var state: VideoReviewState
    var onAction: (ReviewAction) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ReviewPlayerView(player: state.player)
                .frame(minWidth: 560, minHeight: 320)
            HStack(spacing: 8) {
                Text(timeLabel(state.start)).monospacedDigit()
                Slider(value: $state.start, in: 0...1) { Text("Start") }
                Slider(value: $state.end, in: 0...1) { Text("End") }
                Text(timeLabel(state.end)).monospacedDigit()
            }
            ReviewActionBar(onAction: onAction)
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { state.player.play() }
    }

    private func timeLabel(_ fraction: Double) -> String {
        let s = Int(fraction * state.durationSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Floating window shown after every capture (when enabled). Owns the
/// window + per-kind edit state; the action side effects live in
/// CaptureController.
final class CaptureReviewWindowController {
    private let window: NSWindow
    private let relay: ReviewActionRelay
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    /// Pending single-press action, waiting out the double-press window.
    private var pendingKey: (key: ReviewKey, work: DispatchWorkItem)?
    /// Two presses of the same key within this interval = the double action.
    static let doublePressWindow: TimeInterval = 0.35
    /// Set for screenshots — exposes annotations/crop to CaptureController.
    let imageState: ImageEditorState?
    /// Set for recordings — exposes the pending trim range.
    let videoState: VideoReviewState?

    var onAction: ((ReviewAction) -> Void)? {
        get { relay.onAction }
        set { relay.onAction = newValue }
    }
    var onClose: (() -> Void)?

    /// nil when a screenshot file can't be read — nothing to review (the
    /// file is already saved on disk; the pipeline just skips the window).
    init?(fileURL: URL, kind: CaptureKind) {
        let relay = ReviewActionRelay()
        self.relay = relay
        let hosting: NSView
        switch kind {
        case .screenshot:
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            let state = ImageEditorState(image: image, fileURL: fileURL)
            imageState = state
            videoState = nil
            hosting = NSHostingView(rootView: ScreenshotReviewView(state: state) {
                relay.onAction?($0)
            })
        case .recording:
            let state = VideoReviewState(fileURL: fileURL)
            imageState = nil
            videoState = state
            hosting = NSHostingView(rootView: VideoReviewView(state: state) {
                relay.onAction?($0)
            })
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.videoState?.player.pause()
            self?.removeKeyMonitor()
            self?.onClose?()
        }
        installKeyMonitor()
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        removeKeyMonitor()
    }

    /// Esc / Return with single-vs-double-press semantics. A local monitor
    /// (not button shortcuts) so a quick second press can cancel the first
    /// press's pending action.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // While a text annotation is being typed, Esc/Return belong to
            // the text field, not the action bar.
            if let imageState = self.imageState, imageState.pendingText != nil { return event }
            switch event.keyCode {
            case 53:        // Esc
                self.handleKey(.escape)
                return nil
            case 36, 76:    // Return / keypad Enter
                self.handleKey(.return)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        pendingKey?.work.cancel()
        pendingKey = nil
    }

    private func handleKey(_ key: ReviewKey) {
        if let pending = pendingKey, pending.key == key {
            // Second press in time: fire the double action instead.
            pending.work.cancel()
            pendingKey = nil
            relay.onAction?(ReviewKeyMap.action(for: key, isDouble: true))
            return
        }
        pendingKey?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKey = nil
            self.relay.onAction?(ReviewKeyMap.action(for: key, isDouble: false))
        }
        pendingKey = (key, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doublePressWindow, execute: work)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    func close() {
        window.close()
    }
}
