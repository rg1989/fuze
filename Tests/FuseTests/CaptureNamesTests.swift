import XCTest
@testable import Fuse

final class CaptureNamesTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int,
                      _ h: Int, _ mi: Int, _ s: Int, tz: TimeZone) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: components)!
    }

    func testScreenshotName() {
        let tz = TimeZone(identifier: "Europe/Riga")!
        let d = date(2026, 6, 11, 17, 23, 45, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .screenshot, date: d, timeZone: tz),
                       "Fuse Shot 2026-06-11 at 17.23.45.png")
    }

    func testRecordingName() {
        let tz = TimeZone(identifier: "UTC")!
        let d = date(2026, 1, 2, 3, 4, 5, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .recording, date: d, timeZone: tz),
                       "Fuse Recording 2026-01-02 at 03.04.05.mov")
    }

    func testMidnightZeroPadding() {
        let tz = TimeZone(identifier: "UTC")!
        let d = date(2026, 12, 31, 0, 0, 0, tz: tz)
        XCTAssertEqual(CaptureNames.fileName(kind: .screenshot, date: d, timeZone: tz),
                       "Fuse Shot 2026-12-31 at 00.00.00.png")
    }
}
