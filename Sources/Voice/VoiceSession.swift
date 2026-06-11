/// Pure state machine for the push-to-talk flow. The controller feeds it events
/// and executes the returned command; all re-entrancy decisions live here,
/// unit-testable, with no OS dependencies.
enum VoiceState: Equatable {
    case idle
    case recording
    case transcribing
}

enum VoiceEvent: Equatable {
    case hotkeyDown
    case hotkeyUp
    case transcriptionFinished
    case transcriptionFailed
}

enum VoiceCommand: Equatable {
    case startRecording
    case stopRecordingAndTranscribe
    case discardRecording
    case none
}

struct VoiceSession {
    private(set) var state: VoiceState = .idle

    mutating func handle(_ event: VoiceEvent) -> VoiceCommand {
        switch (state, event) {
        // idle: only a fresh key-down does anything.
        case (.idle, .hotkeyDown):
            state = .recording
            return .startRecording
        case (.idle, .hotkeyUp),
             (.idle, .transcriptionFinished),
             (.idle, .transcriptionFailed):
            return .none

        // recording: key-up hands off to transcription; key-repeat downs are
        // ignored; a failure while recording (recorder could not start)
        // abandons the attempt and discards any captured audio.
        case (.recording, .hotkeyUp):
            state = .transcribing
            return .stopRecordingAndTranscribe
        case (.recording, .hotkeyDown),
             (.recording, .transcriptionFinished):
            return .none
        case (.recording, .transcriptionFailed):
            state = .idle
            return .discardRecording

        // transcribing: ignore key input while busy; either outcome -> idle.
        case (.transcribing, .hotkeyDown),
             (.transcribing, .hotkeyUp):
            return .none
        case (.transcribing, .transcriptionFinished),
             (.transcribing, .transcriptionFailed):
            state = .idle
            return .none
        }
    }
}
