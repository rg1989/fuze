import XCTest
@testable import Fuse

final class VoiceSessionTests: XCTestCase {
    /// Builds a session already driven into `state` via real events.
    private func makeSession(in state: VoiceState) -> VoiceSession {
        var session = VoiceSession()
        switch state {
        case .idle:
            break
        case .recording:
            _ = session.handle(.hotkeyDown)
        case .transcribing:
            _ = session.handle(.hotkeyDown)
            _ = session.handle(.hotkeyUp)
        }
        XCTAssertEqual(session.state, state, "test setup failed to reach \(state)")
        return session
    }

    func testAllTwelveTransitionsExhaustively() {
        // (start state, event, expected command, expected end state)
        let table: [(VoiceState, VoiceEvent, VoiceCommand, VoiceState)] = [
            (.idle, .hotkeyDown, .startRecording, .recording),
            (.idle, .hotkeyUp, .none, .idle),                          // stray key-up
            (.idle, .transcriptionFinished, .none, .idle),             // stale callback
            (.idle, .transcriptionFailed, .none, .idle),               // stale callback
            (.recording, .hotkeyDown, .none, .recording),              // key-repeat ignored
            (.recording, .hotkeyUp, .stopRecordingAndTranscribe, .transcribing),
            (.recording, .transcriptionFinished, .none, .recording),   // stale callback
            (.recording, .transcriptionFailed, .discardRecording, .idle), // recorder failed to start
            (.transcribing, .hotkeyDown, .none, .transcribing),        // input ignored while busy
            (.transcribing, .hotkeyUp, .none, .transcribing),          // input ignored while busy
            (.transcribing, .transcriptionFinished, .none, .idle),
            (.transcribing, .transcriptionFailed, .none, .idle),
        ]
        for (start, event, expectedCommand, expectedState) in table {
            var session = makeSession(in: start)
            let command = session.handle(event)
            XCTAssertEqual(command, expectedCommand,
                           "(\(start), \(event)) returned \(command), expected \(expectedCommand)")
            XCTAssertEqual(session.state, expectedState,
                           "(\(start), \(event)) ended in \(session.state), expected \(expectedState)")
        }
    }

    func testTwoFullDictationCyclesBackToBack() {
        var session = VoiceSession()
        XCTAssertEqual(session.handle(.hotkeyDown), .startRecording)
        XCTAssertEqual(session.handle(.hotkeyUp), .stopRecordingAndTranscribe)
        XCTAssertEqual(session.handle(.transcriptionFinished), .none)
        XCTAssertEqual(session.handle(.hotkeyDown), .startRecording)
        XCTAssertEqual(session.handle(.hotkeyUp), .stopRecordingAndTranscribe)
        XCTAssertEqual(session.handle(.transcriptionFailed), .none)
        XCTAssertEqual(session.state, .idle)
    }
}
