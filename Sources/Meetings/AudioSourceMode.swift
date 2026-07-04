import Foundation

/// Per-recording capture choice, set at record start. Persisted as a raw string
/// under "meetings.audioSource". Distinct from FluidAudio's own `AudioSource`
/// (which is only a label passed to `startStreaming`).
enum AudioSourceMode: String, CaseIterable, Identifiable, Sendable {
    case micOnly = "micOnly"
    case micSystem = "micSystem"   // mic + ScreenCaptureKit system audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .micOnly: return "Microphone only"
        case .micSystem: return "Microphone + system audio"
        }
    }

    /// Only mic+system needs the Screen Recording TCC grant.
    var needsScreenRecording: Bool { self == .micSystem }
}
