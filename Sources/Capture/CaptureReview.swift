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
/// `shortcutsEnabled: false` while a text annotation is being typed, so
/// Return/Esc go to the text field instead of firing actions.
struct ReviewActionBar: View {
    var shortcutsEnabled = true
    var onAction: (ReviewAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { onAction(.delete) } label: {
                Label(ReviewAction.delete.title, systemImage: "trash")
            }
            .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.escape) : nil)

            Button { onAction(.deleteAndCopy) } label: {
                Label(ReviewAction.deleteAndCopy.title, systemImage: "trash.square")
            }

            Spacer()

            Text("Return = Save & Copy · Esc = Delete")
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
            .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return) : nil)
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
            ReviewActionBar(shortcutsEnabled: state.pendingText == nil,
                            onAction: onAction)
                .padding(12)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

/// Recording review = player + trim sliders with the action bar under it.
struct VideoReviewView: View {
    @ObservedObject var state: VideoReviewState
    var onAction: (ReviewAction) -> Void

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

    func close() {
        window.close()
    }
}
