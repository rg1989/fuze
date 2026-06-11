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

/// Pulsing red-orange orb with a soft glow — the "live mic" indicator.
private struct GlowOrb: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 3.0)
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.30 + 0.25 * pulse))
                    .frame(width: 22, height: 22)
                    .blur(radius: 6)
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.45, blue: 0.30),
                                 Color(red: 0.90, green: 0.07, blue: 0.25)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 12, height: 12)
                    .shadow(color: .red.opacity(0.55 + 0.30 * pulse), radius: 4 + 4 * pulse)
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// Five animated equalizer bars, phase-shifted so they dance independently.
private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    let phase = Double(index) * 0.9
                    let height = 5 + 13 * abs(sin(t * 2.7 + phase) * sin(t * 1.6 + phase * 1.4))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.55, blue: 0.30), .red],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height)
                }
            }
            .frame(width: 27, height: 20)
        }
    }
}

/// Rotating angular-gradient ring — the transcription spinner.
private struct ShimmerRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.cyan.opacity(0.0), .cyan, Color(red: 0.45, green: 0.55, blue: 1.0)],
                        center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 17, height: 17)
                .rotationEffect(.radians(t * 2.6))
                .shadow(color: .cyan.opacity(0.5), radius: 5)
                .frame(width: 24, height: 24)
        }
    }
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.display {
            case .hidden:
                EmptyView()
            case .recording:
                GlowOrb()
                EqualizerBars()
                Text("Recording")
                    .foregroundStyle(.white.opacity(0.92))
            case .transcribing:
                ShimmerRing()
                Text("Transcribing…")
                    .foregroundStyle(.white.opacity(0.92))
            case .message(let text):
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .shadow(color: .orange.opacity(0.5), radius: 5)
                Text(text)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 18, y: 7)
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
