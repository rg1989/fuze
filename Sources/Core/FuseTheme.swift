import AppKit
import SwiftUI

/// Fuse's HUD design language: Anthropic-inspired warm palette — ivory paper,
/// warm ink, terracotta accent — paired with an italic serif face for HUD
/// labels. Used by the voice RecordingHUD and the capture RecHUD so every
/// floating pill reads as one family.
enum FuseTheme {
    static let terracotta = Color(red: 0.85, green: 0.47, blue: 0.34)      // #D97757
    static let terracottaDeep = Color(red: 0.73, green: 0.33, blue: 0.21)
    static let ivory = Color(red: 0.94, green: 0.93, blue: 0.89)           // #F0EEE6
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.11)             // warm near-black

    // Recording is universally RED — used for every live-capture indicator.
    static let recordingRed = Color(red: 0.92, green: 0.10, blue: 0.11)
    static let recordingRedBright = Color(red: 1.00, green: 0.32, blue: 0.27)
    static let recordingRedShine = Color(red: 1.00, green: 0.58, blue: 0.48)  // shimmer highlight

    // Transcribing: a step down from red — deep, saturated orange.
    static let transcribeOrange = Color(red: 0.86, green: 0.42, blue: 0.05)
    static let transcribeOrangeDeep = Color(red: 0.69, green: 0.30, blue: 0.02)
    static let transcribeOrangeShine = Color(red: 1.00, green: 0.73, blue: 0.36)

    /// HUD label face: italic serif — the "fable" look. Pass `italic: false`
    /// for digits (timers), which read better upright.
    static func hudFont(size: CGFloat, weight: Font.Weight = .medium, italic: Bool = true) -> Font {
        let font = Font.system(size: size, weight: weight, design: .serif)
        return italic ? font.italic() : font
    }
}

/// Genuine behind-window blur. SwiftUI materials don't get behind-window
/// blending inside transparent borderless panels — they render as a flat
/// opaque-looking gray plate. NSVisualEffectView with `.behindWindow` lets
/// the desktop actually show through. Forced light appearance keeps the warm
/// ivory pill consistent regardless of system dark mode.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantLight)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Shared semi-transparent warm pill chrome for HUD content.
struct HUDPillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    BehindWindowBlur()
                    FuseTheme.ivory.opacity(0.35)
                }
                .clipShape(Capsule())
            }
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.75), FuseTheme.terracotta.opacity(0.25)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
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
    var font: Font = FuseTheme.hudFont(size: 14, weight: .semibold)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let center = phase * 1.8 - 0.4   // start and end fully off the text
            Text(text)
                .font(font)
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
