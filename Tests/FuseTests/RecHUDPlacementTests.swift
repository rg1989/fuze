import XCTest
@testable import Fuse

final class RecHUDPlacementTests: XCTestCase {
    private let panel = CGSize(width: 240, height: 44)
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testArmedCenteredInSelection() {
        let region = CGRect(x: 400, y: 300, width: 600, height: 400)
        let origin = RecHUD.hudOrigin(mode: .armed, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.x, region.midX - panel.width / 2)
        XCTAssertEqual(origin.y, region.midY - panel.height / 2)
    }

    func testArmedClampedToVisibleFrameForTinySelectionsAtEdges() {
        let region = CGRect(x: 700, y: 990, width: 40, height: 10)   // hugs top edge
        let origin = RecHUD.hudOrigin(mode: .armed, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertLessThanOrEqual(origin.y + panel.height, screen.maxY - 8)
    }

    func testRecordingSitsBelowSelectionOutsideCapturedRegion() {
        let region = CGRect(x: 400, y: 300, width: 600, height: 400)
        let origin = RecHUD.hudOrigin(mode: .recording, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.y, region.minY - panel.height - 8)
        XCTAssertLessThan(origin.y + panel.height, region.minY, "must not overlap the recording")
    }

    func testRecordingFallsBackAboveWhenNoRoomBelow() {
        let region = CGRect(x: 400, y: 10, width: 600, height: 400)   // hugs bottom
        let origin = RecHUD.hudOrigin(mode: .recording, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.y, region.maxY + 8)
    }

    func testRecordingFallsBackInsideWhenNoRoomEither() {
        let region = CGRect(x: 0, y: 0, width: 1600, height: 1000)    // whole screen
        let origin = RecHUD.hudOrigin(mode: .recording, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.y, region.minY + 12)
    }

    func testXClampedToScreenForEdgeSelections() {
        let region = CGRect(x: 0, y: 300, width: 60, height: 200)     // far left
        let origin = RecHUD.hudOrigin(mode: .armed, region: region,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.x, screen.minX + 8)
    }

    func testFullScreenUsesBottomCenterOfVisibleFrame() {
        let origin = RecHUD.hudOrigin(mode: .recording, region: nil,
                                      panelSize: panel, screenVisible: screen)
        XCTAssertEqual(origin.x, screen.midX - panel.width / 2)
        XCTAssertEqual(origin.y, screen.minY + 24)
    }
}
