import SwiftUI

/// Shared building blocks for every floating HUD pill (the voice
/// RecordingHUD and the capture RecHUD). One visual family: dark glass,
/// recording red / transcribe orange accents, shimmer labels, capsule
/// buttons. Every indicator renders in a fixed 24×24 slot so all pills
/// have identical height regardless of state.

/// Pulsing glow dot — the "live" indicator. `hollow` = armed, not yet
/// recording.
struct HUDGlowDot: View {
    var hollow = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 3.0)
            let gradient = LinearGradient(
                colors: [FuseTheme.recordingRedBright, FuseTheme.recordingRed],
                startPoint: .top, endPoint: .bottom)
            ZStack {
                Circle()
                    .fill(FuseTheme.recordingRed.opacity(hollow ? 0 : 0.25 + 0.25 * pulse))
                    .frame(width: 22, height: 22)
                    .blur(radius: 6)
                Group {
                    if hollow {
                        Circle().strokeBorder(gradient, lineWidth: 2.5)
                    } else {
                        Circle().fill(gradient)
                    }
                }
                .frame(width: 12, height: 12)
                .shadow(color: FuseTheme.recordingRed.opacity(0.5 + 0.3 * pulse),
                        radius: 4 + 4 * pulse)
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// Five animated equalizer bars, phase-shifted so they dance independently.
/// Color-parameterized: red while recording, orange while transcribing —
/// same structure in both pills so they read as one family.
struct HUDEqualizerBars: View {
    var bright: Color = FuseTheme.recordingRedBright
    var base: Color = FuseTheme.recordingRed

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    let phase = Double(index) * 0.9
                    let height = 5 + 13 * abs(sin(t * 2.7 + phase) * sin(t * 1.6 + phase * 1.4))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [bright, base],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height)
                }
            }
            .frame(width: 27, height: 24)
        }
    }
}

/// Rotating angular-gradient ring — the transcription spinner (deep orange).
struct HUDTranscribeRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [FuseTheme.transcribeOrange.opacity(0.0),
                                 FuseTheme.transcribeOrange,
                                 FuseTheme.transcribeOrangeDeep],
                        center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 17, height: 17)
                .rotationEffect(.radians(t * 2.6))
                .shadow(color: FuseTheme.transcribeOrange.opacity(0.5), radius: 5)
                .frame(width: 24, height: 24)
        }
    }
}

/// Capsule buttons that live INSIDE a HUD pill — replaces the stock macOS
/// bordered buttons that broke the dark-glass look.
/// `.hudRecordRed` = filled red gradient (Start / Stop).
/// `.hudGhost` = translucent white (Cancel).
struct HUDPillButtonStyle: ButtonStyle {
    enum Kind { case prominent(bright: Color, base: Color), ghost }
    var kind: Kind = .ghost

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 27)
            .background {
                Group {
                    switch kind {
                    case .prominent(let bright, let base):
                        Capsule().fill(LinearGradient(
                            colors: [bright, base],
                            startPoint: .top, endPoint: .bottom))
                    case .ghost:
                        Capsule().fill(Color.white.opacity(0.10))
                    }
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HUDPillButtonStyle {
    static var hudGhost: HUDPillButtonStyle { HUDPillButtonStyle(kind: .ghost) }
    static var hudRecordRed: HUDPillButtonStyle {
        HUDPillButtonStyle(kind: .prominent(bright: FuseTheme.recordingRedBright,
                                            base: FuseTheme.recordingRed))
    }
}
