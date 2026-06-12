import AppKit
import SwiftUI

/// Observable model the SwiftUI HUD view renders from.
@MainActor
final class RecordingHUDModel: ObservableObject {
    enum Display: Equatable {
        case hidden
        case recording
        case transcribing
        case message(String)
    }

    @Published var display: Display = .hidden
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.display {
            case .hidden:
                EmptyView()
            case .recording:
                HUDGlowDot()
                HUDEqualizerBars()
                ShimmerText(text: "RECORDING",
                            base: FuseTheme.recordingRedBright,
                            highlight: FuseTheme.recordingRedShine)
            case .transcribing:
                HUDTranscribeRing()
                HUDEqualizerBars(bright: FuseTheme.transcribeOrangeShine,
                                 base: FuseTheme.transcribeOrange)
                ShimmerText(text: "TRANSCRIBING",
                            base: FuseTheme.transcribeOrange,
                            highlight: FuseTheme.transcribeOrangeShine)
            case .message(let text):
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(FuseTheme.transcribeOrange)
                    .shadow(color: FuseTheme.transcribeOrange.opacity(0.4), radius: 5)
                Text(text)
                    .font(FuseTheme.hudFont(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 27)   // identical pill height in every state
        .padding(.horizontal, 19)
        .padding(.vertical, 11)
        .hudPillChrome()
        .padding(24)   // room for the shadow inside the borderless panel
    }
}

/// Floating, mouse-transparent, non-activating status panel shown bottom-center
/// of the screen that has keyboard focus. Never steals focus.
@MainActor
final class RecordingHUD {
    private let model = RecordingHUDModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<RecordingHUDView>?
    /// Bumped on every show/flash/hide so a stale flash timer never hides a newer display.
    private var generation = 0

    /// Shows a persistent display (stays until the next show/flash/hide call).
    /// Pass .recording, .transcribing, or .message("Downloading model…").
    func show(_ display: RecordingHUDModel.Display) {
        generation += 1
        model.display = display
        present()
    }

    /// Shows a transient message and auto-hides after `seconds`.
    func flash(_ message: String, hideAfter seconds: Double = 1.2) {
        generation += 1
        let current = generation
        model.display = .message(message)
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        model.display = .hidden
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = ensurePanel()
        // Content varies per display state; resize before positioning so the
        // panel stays centered on its content.
        if let hosting {
            panel.setContentSize(hosting.fittingSize)
        }
        position(panel)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: RecordingHUDView(model: model))
        newPanel.contentView = hosting
        self.hosting = hosting
        panel = newPanel
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        // NSScreen.main is the screen with keyboard focus — where the user is typing.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 64))
    }
}
