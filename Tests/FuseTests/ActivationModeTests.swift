import XCTest
@testable import Fuse

final class ActivationModeTests: XCTestCase {
    func testHoldModeMapsEdgesDirectly() {
        XCTAssertEqual(ActivationMapper.event(forDownIn: .idle, mode: .hold), .hotkeyDown)
        XCTAssertEqual(ActivationMapper.event(forDownIn: .recording, mode: .hold), .hotkeyDown)
        XCTAssertEqual(ActivationMapper.event(forUpIn: .hold), .hotkeyUp)
    }

    func testToggleModeFirstPressStartsSecondPressStops() {
        XCTAssertEqual(ActivationMapper.event(forDownIn: .idle, mode: .toggle), .hotkeyDown)
        XCTAssertEqual(ActivationMapper.event(forDownIn: .recording, mode: .toggle), .hotkeyUp)
    }

    func testToggleModeIgnoresReleasesAndBusyPresses() {
        XCTAssertNil(ActivationMapper.event(forUpIn: .toggle))
        XCTAssertNil(ActivationMapper.event(forDownIn: .transcribing, mode: .toggle))
    }

    func testCurrentModeParsesDefaultsWithHoldFallback() {
        let defaults = UserDefaults(suiteName: "FuseTests.activation")!
        defaults.removePersistentDomain(forName: "FuseTests.activation")
        XCTAssertEqual(ActivationMode.current(defaults: defaults), .hold)
        defaults.set("toggle", forKey: "voice.activationMode")
        XCTAssertEqual(ActivationMode.current(defaults: defaults), .toggle)
        defaults.set("garbage", forKey: "voice.activationMode")
        XCTAssertEqual(ActivationMode.current(defaults: defaults), .hold)
    }
}
