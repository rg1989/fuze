import SwiftUI

/// Fuse's HUD design language: Anthropic-inspired warm palette — ivory paper,
/// warm ink, terracotta accent — paired with a serif face for HUD labels.
/// Used by the voice RecordingHUD and the capture RecHUD so every floating
/// pill reads as one family.
enum FuseTheme {
    static let terracotta = Color(red: 0.85, green: 0.47, blue: 0.34)      // #D97757
    static let terracottaDeep = Color(red: 0.73, green: 0.33, blue: 0.21)
    static let ivory = Color(red: 0.94, green: 0.93, blue: 0.89)           // #F0EEE6
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.11)             // warm near-black

    /// HUD label face: serif, medium — the "fable" look.
    static func hudFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Shared semi-transparent warm pill chrome for HUD content.
struct HUDPillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .background(FuseTheme.ivory.opacity(0.55), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), FuseTheme.terracotta.opacity(0.30)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
    }
}

extension View {
    func hudPillChrome() -> some View { modifier(HUDPillChrome()) }
}
