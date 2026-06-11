import XCTest
@testable import Fuse

// Tests for the capture feature's pure geometry (this task) and the
// recording state machine (Task 10.4 appends its test class below).

final class RegionGeometryTests: XCTestCase {
    func testNormalizedRectDragDownRight() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 80))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragUpLeft() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 110, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragDownLeft() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 110, y: 20), to: CGPoint(x: 10, y: 80))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectDragUpRight() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 110, y: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testNormalizedRectClick() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(r, CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    /// screencapture -R wants GLOBAL top-left-origin points; the overlay
    /// delivers Cocoa (bottom-left) coordinates. A Cocoa rect whose bottom
    /// edge is at y=200 on a 1000-pt-tall primary screen has its TOP edge
    /// 700 pt below the top of the screen.
    func testTopLeftRectFlip() {
        let cocoa = CGRect(x: 50, y: 200, width: 300, height: 100)
        let flipped = CaptureGeometry.topLeftRect(fromCocoaRect: cocoa, primaryScreenHeight: 1000)
        XCTAssertEqual(flipped, CGRect(x: 50, y: 700, width: 300, height: 100))
    }

    func testTopLeftRectFullScreenIsIdentityOrigin() {
        let cocoa = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let flipped = CaptureGeometry.topLeftRect(fromCocoaRect: cocoa, primaryScreenHeight: 1117)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 0, width: 1728, height: 1117))
    }
}

final class RecordingStateMachineTests: XCTestCase {
    typealias SM = RecordingStateMachine

    private func assertTransition(_ phase: SM.Phase, _ event: SM.Event,
                                  becomes expectedPhase: SM.Phase,
                                  doing expectedAction: SM.Action,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let (next, action) = SM.transition(from: phase, on: event)
        XCTAssertEqual(next, expectedPhase, file: file, line: line)
        XCTAssertEqual(action, expectedAction, file: file, line: line)
    }

    func testToggleFromIdlePresentsPicker() {
        assertTransition(.idle, .toggle, becomes: .selectingRegion, doing: .presentRegionPicker)
    }

    func testRegionConfirmedStartsProcess() {
        assertTransition(.selectingRegion, .regionConfirmed, becomes: .recording, doing: .startProcess)
    }

    func testRegionCancelledReturnsToIdle() {
        assertTransition(.selectingRegion, .regionCancelled, becomes: .idle, doing: .none)
    }

    func testToggleWhileSelectingDismissesPicker() {
        assertTransition(.selectingRegion, .toggle, becomes: .idle, doing: .dismissRegionPicker)
    }

    func testToggleWhileRecordingStopsProcess() {
        assertTransition(.recording, .toggle, becomes: .finishing, doing: .stopProcess)
    }

    func testStopRequestWhileRecordingStopsProcess() {
        assertTransition(.recording, .stopRequested, becomes: .finishing, doing: .stopProcess)
    }

    func testProcessExitWhileFinishingFinalizes() {
        assertTransition(.finishing, .processExited, becomes: .idle, doing: .finalize)
    }

    func testUnexpectedProcessExitWhileRecordingStillFinalizes() {
        // screencapture died or was killed externally — recover, don't wedge.
        assertTransition(.recording, .processExited, becomes: .idle, doing: .finalize)
    }

    func testNoOps() {
        assertTransition(.idle, .processExited, becomes: .idle, doing: .none)
        assertTransition(.idle, .stopRequested, becomes: .idle, doing: .none)
        assertTransition(.finishing, .toggle, becomes: .finishing, doing: .none)
        assertTransition(.recording, .regionConfirmed, becomes: .recording, doing: .none)
    }
}
