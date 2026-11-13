import XCTest
@testable import AccountDock

final class DayKeyTests: XCTestCase {
    func testDayKeysAreGregorianWhateverCalendarTheUserHasSet() throws {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour) = (2026, 11, 13, 12)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        XCTAssertEqual(DayKey.string(from: date), "2026-11-13")
        XCTAssertEqual(DayKey.makeFormatter().calendar.identifier, .gregorian)
        XCTAssertEqual(DayKey.date(from: "2026-11-13").map(DayKey.string(from:)), "2026-11-13")

        // What a formatter left on a Buddhist calendar writes for the same day.
        let buddhist = DateFormatter()
        buddhist.calendar = Calendar(identifier: .buddhist)
        buddhist.dateFormat = "yyyy-MM-dd"
        XCTAssertNotEqual(buddhist.string(from: date), DayKey.string(from: date))
    }
}
