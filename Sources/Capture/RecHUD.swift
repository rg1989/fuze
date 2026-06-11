import AppKit
import SwiftUI

final class RecHUDModel: ObservableObject {
    @Published var elapsedText = "0:00"
    var onStop: (() -> Void)?
}

struct RecHUDView: View {
    @ObservedObject var model: RecHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(model.elapsedText)
                .font(.system(.body, design: .monospaced))
            Button("Stop") { model.onStop?() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Small floating REC indicator shown while a recording runs: red dot,
/// elapsed timer, Stop button. Non-activating panel pinned to the top-right
/// of the main screen (usually outside the recorded region — see gotchas).
final class RecHUD {
    private let model = RecHUDModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?

    var onStop: (() -> Void)? {
        get { model.onStop }
        set { model.onStop = newValue }
    }

    func show() {
        startedAt = Date()
        model.elapsedText = "0:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let s = Int(Date().timeIntervalSince(startedAt))
            self.model.elapsedText = String(format: "%d:%02d", s / 60, s % 60)
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 170, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: RecHUDView(model: model))
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel?.setFrameOrigin(CGPoint(x: f.maxX - 200, y: f.maxY - 64))
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
