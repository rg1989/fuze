import AppKit
import SwiftUI

/// Fuse's HUD design language: dark translucent glass, white text, recording
/// red and transcribing orange as the only accent colors. Used by the voice
/// RecordingHUD and the capture RecHUD so every floating pill reads as one
/// family.
enum FuseTheme {
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.11)             // warm near-black

    // Recording is universally RED — used for every live-capture indicator.
    static let recordingRed = Color(red: 0.92, green: 0.10, blue: 0.11)
    static let recordingRedBright = Color(red: 1.00, green: 0.32, blue: 0.27)
    static let recordingRedShine = Color(red: 1.00, green: 0.62, blue: 0.52)  // shimmer highlight

    // Transcribing: a step down from red — deep, saturated orange.
    static let transcribeOrange = Color(red: 0.96, green: 0.52, blue: 0.09)
    static let transcribeOrangeDeep = Color(red: 0.72, green: 0.33, blue: 0.03)
    static let transcribeOrangeShine = Color(red: 1.00, green: 0.78, blue: 0.42)

    /// HUD status face: italic, tracked, slightly condensed weight — a
    /// broadcast-style "REC" label. Pass `italic: false` for digits (timers),
    /// which read better upright.
    static func hudFont(size: CGFloat, weight: Font.Weight = .semibold, italic: Bool = true) -> Font {
        let font = Font.system(size: size, weight: weight, design: .default)
        return italic ? font.italic() : font
    }
}

/// Real behind-window blur for borderless transparent panels. `.hudWindow`
/// is the material macOS uses for floating HUDs — genuinely translucent, the
/// desktop shows through with a soft dark blur. (SwiftUI materials can't do
/// behind-window blending in these panels; light materials like `.popover`
/// render nearly opaque.)
private struct HUDBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Shared dark-glass pill chrome for HUD content.
struct HUDPillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    HUDBlur()
                    Color.black.opacity(0.18)
                }
                .clipShape(Capsule())
            }
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.40), .white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

extension View {
    func hudPillChrome() -> some View { modifier(HUDPillChrome()) }
}

/// Colored text with a lighter "reflection" band sweeping through the glyphs
/// once every `period` seconds — smooth, not frantic.
struct ShimmerText: View {
    let text: String
    let base: Color
    let highlight: Color
    var period: Double = 2.0
    var font: Font = FuseTheme.hudFont(size: 12.5)
    var tracking: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let center = phase * 1.8 - 0.4   // start and end fully off the text
            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(LinearGradient(
                    stops: [
                        .init(color: base, location: 0),
                        .init(color: base, location: clamp(center - 0.22)),
                        .init(color: highlight, location: clamp(center)),
                        .init(color: base, location: clamp(center + 0.22)),
                        .init(color: base, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing))
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
