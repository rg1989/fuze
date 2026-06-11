import AppKit
import AVKit
import SwiftUI

/// Callback box so CaptureController can wire actions AFTER the window (and
/// the SwiftUI view referencing this object) has been constructed — same
/// pattern as RecHUDModel.
final class CapturePreviewActions: ObservableObject {
    var onKeep: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
}

/// Post-capture review: a look at what was just captured plus two large,
/// unambiguous buttons. Return keeps the file, Esc deletes it (file → Trash,
/// clipboard + history purged by CaptureController).
struct CapturePreviewView: View {
    let fileURL: URL
    let kind: CaptureKind
    @ObservedObject var actions: CapturePreviewActions

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 12) {
            previewContent
                .frame(width: 560, height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 14) {
                Button { actions.onDelete?() } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .keyboardShortcut(.cancelAction)
                .tint(.red)

                Button { actions.onKeep?() } label: {
                    Label("Keep", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            HStack {
                Text("Return keeps  ·  Esc deletes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(kind == .screenshot ? "Edit…" : "Trim…") { actions.onEdit?() }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .padding(.top, 6)   // breathe under the transparent titlebar
    }

    @ViewBuilder private var previewContent: some View {
        switch kind {
        case .screenshot:
            if let image = NSImage(contentsOf: fileURL) {
                ZStack {
                    Color.black.opacity(0.15)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                missingPreview
            }
        case .recording:
            VideoPlayer(player: player)
                .background(Color.black)
                .onAppear {
                    let player = AVPlayer(url: fileURL)
                    self.player = player
                    player.play()
                }
                .onDisappear {
                    player?.pause()
                }
        }
    }

    private var missingPreview: some View {
        ZStack {
            Color.black.opacity(0.15)
            VStack(spacing: 6) {
                Image(systemName: "questionmark.square.dashed").font(.largeTitle)
                Text("Preview unavailable").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Floating window shown after every capture (when enabled). Keep/Delete
/// semantics live in CaptureController; this type only owns the window.
final class CapturePreviewWindowController {
    private let window: NSWindow
    private let actions = CapturePreviewActions()
    private var closeObserver: NSObjectProtocol?

    var onClose: (() -> Void)?
    var onKeep: (() -> Void)? {
        get { actions.onKeep }
        set { actions.onKeep = newValue }
    }
    var onDelete: (() -> Void)? {
        get { actions.onDelete }
        set { actions.onDelete = newValue }
    }
    var onEdit: (() -> Void)? {
        get { actions.onEdit }
        set { actions.onEdit = newValue }
    }

    init(fileURL: URL, kind: CaptureKind) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 592, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = fileURL.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: CapturePreviewView(
            fileURL: fileURL, kind: kind, actions: actions))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
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

    func close() {
        window.close()
    }
}
