import AppKit

/// Translucent rounded rectangle previewing where a dragged window would snap.
/// Mouse-transparent and non-activating so the in-progress OS window drag is
/// never disturbed; frame changes animate so the preview glides between zones.
final class SnapPreviewOverlay {
    private var window: NSWindow?
    private var isShowing = false

    func show(frame: CGRect) {
        let window = ensureWindow()
        if isShowing {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            isShowing = true
            window.setFrame(frame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isShowing, let window else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new show() may have raced the fade-out; only hide if still off.
            guard let self, !self.isShowing else { return }
            self.window?.orderOut(nil)
        })
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        self.window = window
        return window
    }
}
