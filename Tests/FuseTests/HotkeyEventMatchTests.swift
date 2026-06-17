import XCTest
import KeyboardShortcuts
@testable import Fuse

final class HotkeyEventMatchTests: XCTestCase {
    private func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> CGEvent? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return nil
        }
        event.flags = flags
        return event
    }

    func testMatchesCmdShiftD() {
        let shortcut = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .shift])
        guard let event = keyEvent(keyCode: CGKeyCode(KeyboardShortcuts.Key.d.rawValue),
                                   flags: [.maskCommand, .maskShift]) else {
            XCTFail("could not synthesize key event")
            return
        }
        XCTAssertTrue(HotkeyEventMatch.matches(event, shortcut: shortcut))
    }

    func testRejectsCmdDWithoutShift() {
        let shortcut = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .shift])
        guard let event = keyEvent(keyCode: CGKeyCode(KeyboardShortcuts.Key.d.rawValue), flags: .maskCommand) else {
            XCTFail("could not synthesize key event")
            return
        }
        XCTAssertFalse(HotkeyEventMatch.matches(event, shortcut: shortcut))
    }

    func testRejectsWrongKey() {
        let shortcut = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .shift])
        guard let event = keyEvent(keyCode: CGKeyCode(KeyboardShortcuts.Key.v.rawValue),
                                   flags: [.maskCommand, .maskShift]) else {
            XCTFail("could not synthesize key event")
            return
        }
        XCTAssertFalse(HotkeyEventMatch.matches(event, shortcut: shortcut))
    }
}
