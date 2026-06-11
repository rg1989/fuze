import Foundation

/// How the push-to-talk trigger behaves.
enum ActivationMode: String {
    case hold     // press starts, release stops (classic PTT)
    case toggle   // press starts, press again stops; releases are ignored

    static func current(defaults: UserDefaults = .standard) -> ActivationMode {
        ActivationMode(rawValue: defaults.string(forKey: "voice.activationMode") ?? "hold") ?? .hold
    }
}

/// Pure mapping from physical trigger edges to VoiceSession events, so both
/// the keyboard shortcut and the modifier-hold monitor share one behavior.
enum ActivationMapper {
    /// Event to feed when the trigger goes DOWN (key pressed / combo held).
    static func event(forDownIn state: VoiceState, mode: ActivationMode) -> VoiceEvent? {
        switch mode {
        case .hold:
            return .hotkeyDown
        case .toggle:
            switch state {
            case .idle: return .hotkeyDown        // first press: start
            case .recording: return .hotkeyUp     // second press: stop + transcribe
            case .transcribing: return nil        // busy: ignore
            }
        }
    }

    /// Event to feed when the trigger goes UP (key released / combo released).
    static func event(forUpIn mode: ActivationMode) -> VoiceEvent? {
        mode == .hold ? .hotkeyUp : nil
    }
}
