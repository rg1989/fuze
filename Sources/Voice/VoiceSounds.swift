import AppKit

/// Optional UI sounds for the dictation lifecycle, configured in Speech-to-Text
/// settings. Each event maps to a UserDefaults key holding a macOS system sound
/// name (see `NSSound(named:)`); "" or "None" stays silent.
enum VoiceSounds {
    static let stopKey = "voice.stopSound"
    static let finishKey = "voice.finishSound"

    /// System sounds shipped with macOS (/System/Library/Sounds), offered in
    /// the settings pickers.
    static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Played when recording stops (Fuse stopped listening).
    static func playStopped() { play(UserDefaults.standard.string(forKey: stopKey)) }

    /// Played when the transcript is ready.
    static func playFinished() { play(UserDefaults.standard.string(forKey: finishKey)) }

    /// Settings preview: play a named sound immediately.
    static func preview(_ name: String) { play(name) }

    private static func play(_ name: String?) {
        guard let name, !name.isEmpty, name != "None",
              let sound = NSSound(named: name) else { return }
        sound.play()
    }
}
