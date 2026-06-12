import XCTest
@testable import Fuse

/// The panel must be resized for the CURRENT mode at present time. The
/// persistent hosting view applies @Published mode changes asynchronously,
/// so naively reading its fittingSize right after a mode switch yields the
/// PREVIOUS mode's size — the armed pill (Start + Cancel) then gets clipped
/// into a recording-sized panel.
@MainActor
final class RecHUDSizingTests: XCTestCase {
    func testPanelWidthTracksModeAcrossSynchronousSwitches() {
        let hud = RecHUD()

        hud.showArmed(near: nil)
        guard let armedWidth = hud.panelFrameForTesting?.width else {
            return XCTFail("no panel after showArmed")
        }

        hud.show(near: nil)   // armed → recording, same runloop turn
        guard let recordingWidth = hud.panelFrameForTesting?.width else {
            return XCTFail("no panel after show")
        }
        XCTAssertLessThan(recordingWidth, armedWidth,
                          "recording pill (no Cancel button) must be narrower")

        hud.showArmed(near: nil)   // recording → armed, same runloop turn
        XCTAssertEqual(hud.panelFrameForTesting?.width, armedWidth,
                       "armed pill clipped by a stale recording-sized panel")

        hud.hide()
    }

    func testControlsFrameIsPanelMinusShadowPadding() {
        let hud = RecHUD()
        hud.show(near: nil)
        guard let panel = hud.panelFrameForTesting,
              let controls = hud.controlsFrame else {
            return XCTFail("no panel after show")
        }
        XCTAssertEqual(controls, panel.insetBy(dx: 20, dy: 20),
                       "controls opening must match the visible pill capsule")
        hud.hide()
    }
}
