import AppKit
import SwiftUI

final class RecHUDModel: ObservableObject {
    enum Mode { case armed, recording }
    @Published var mode: Mode = .recording
    @Published var elapsedText = "0:00"
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
}

/// Recording dot with a soft pulsing glow.
private struct RecPulseDot: View {
    var hollow = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 3.2)
            let gradient = LinearGradient(
                colors: [FuseTheme.terracotta, FuseTheme.terracottaDeep],
                startPoint: .top, endPoint: .bottom)
            Group {
                if hollow {
                    Circle().strokeBorder(gradient, lineWidth: 2.5)
                } else {
                    Circle().fill(gradient)
                }
            }
            .frame(width: 12, height: 12)
            .shadow(color: FuseTheme.terracotta.opacity(0.45 + 0.35 * pulse),
                    radius: 5 + 3 * pulse)
        }
    }
}

struct RecHUDView: View {
    @ObservedObject var model: RecHUDModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.mode {
            case .armed:
                RecPulseDot(hollow: true)
                Text("Ready to record")
                    .font(FuseTheme.hudFont(size: 14))
                    .foregroundStyle(FuseTheme.ink.opacity(0.92))
                Button { model.onStart?() } label: {
                    Label("Start", systemImage: "record.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(FuseTheme.terracottaDeep)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.onCancel?() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(FuseTheme.ink)
            case .recording:
                RecPulseDot()
                Text(model.elapsedText)
                    .font(FuseTheme.hudFont(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(FuseTheme.ink.opacity(0.92))
                Button { model.onStop?() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(FuseTheme.terracottaDeep)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .hudPillChrome()
        .padding(20)   // room for the shadow inside the borderless panel
    }
}

/// Floating REC controls. Armed: Ready/Start/Cancel centered in the middle of
/// the selection. Recording: red dot, elapsed timer, Stop button — kept just
/// OUTSIDE the selection so the controls never appear in the captured video.
final class RecHUD {
    private let model = RecHUDModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<RecHUDView>?
    private var timer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }
    var onStart: (() -> Void)? {
        get { model.onStart }
        set { model.onStart = newValue }
    }
    var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    /// Where to place the HUD panel (Cocoa coords). Armed: dead-center of the
    /// selection, clamped to the visible frame. Recording: just BELOW the
    /// selection (outside the captured region — the HUD must not appear in the
    /// video), falling back to above the top edge, then inside.
    /// nil region = full screen: bottom-center of the visible frame.
    static func hudOrigin(mode: RecHUDModel.Mode, region: CGRect?,
                          panelSize: CGSize, screenVisible: CGRect) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat {
            min(max(x, screenVisible.minX + 8), screenVisible.maxX - panelSize.width - 8)
        }
        func clampY(_ y: CGFloat) -> CGFloat {
            min(max(y, screenVisible.minY + 8), screenVisible.maxY - panelSize.height - 8)
        }
        guard let region else {
            return CGPoint(x: clampX(screenVisible.midX - panelSize.width / 2),
                           y: screenVisible.minY + 24)
        }
        let x = clampX(region.midX - panelSize.width / 2)
        switch mode {
        case .armed:
            return CGPoint(x: x, y: clampY(region.midY - panelSize.height / 2))
        case .recording:
            let below = region.minY - panelSize.height - 8
            if below >= screenVisible.minY { return CGPoint(x: x, y: below) }
            let above = region.maxY + 8
            if above + panelSize.height <= screenVisible.maxY { return CGPoint(x: x, y: above) }
            return CGPoint(x: x, y: region.minY + 12)   // no room outside
        }
    }

    private var region: CGRect?

    /// Pre-recording controls: region picked, waiting for Start/Cancel.
    func showArmed(near region: CGRect?) {
        self.region = region
        timer?.invalidate()
        timer = nil
        startedAt = nil
        model.mode = .armed
        presentPanel()
    }

    func show(near region: CGRect?) {
        self.region = region
        model.mode = .recording
        startedAt = Date()
        model.elapsedText = "0:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let s = Int(Date().timeIntervalSince(startedAt))
            self.model.elapsedText = String(format: "%d:%02d", s / 60, s % 60)
        }
        presentPanel()
    }

    private func presentPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let hosting = NSHostingView(rootView: RecHUDView(model: model))
            panel.contentView = hosting
            self.hosting = hosting
            self.panel = panel
        }
        // Mode switches change the content size (armed has two buttons);
        // resize before computing the origin so centering uses real bounds.
        if let panel, let hosting {
            panel.setContentSize(hosting.fittingSize)
        }
        let screen = region.flatMap { r in
            NSScreen.screens.first { $0.frame.intersects(r) }
        } ?? NSScreen.main
        if let screen, let panel {
            panel.setFrameOrigin(Self.hudOrigin(
                mode: model.mode,
                region: region,
                panelSize: panel.frame.size,
                screenVisible: screen.visibleFrame))
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        panel?.orderOut(nil)
    }
}
