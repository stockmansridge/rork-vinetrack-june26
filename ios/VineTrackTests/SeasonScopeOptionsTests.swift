import XCTest
@testable import VineTrack

/// The available-vintage list is derived from EVERY non-deleted record on the
/// surface, computed BEFORE the selected vintage is applied.
///
/// This is the rule that makes the selector usable: if the options were derived
/// from the already-filtered rows, selecting 2027 would leave 2027 as the only
/// option and the operator could never get back to 2026. Mirrored on Android by
/// `SeasonScopeOptionsTest.kt`.
///
/// Season start here is 1 July, so vintage 2027 runs 1 Jul 2026 – 30 Jun 2027.
final class SeasonScopeOptionsTests: XCTestCase {

    private let timeZone = TimeZone(identifier: "Australia/Adelaide")!
    private let startMonth = 7
    private let startDay = 1

    private func date(_ iso: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)!
    }

    /// Records spanning three seasons plus one undated row.
    private var allRecords: [Date?] {
        [
            date("2024-11-04"), // vintage 2025
            date("2026-02-18"), // vintage 2026
            date("2026-06-30"), // vintage 2026 — final day of the season
            date("2026-07-01"), // vintage 2027 — first day of the season
            date("2027-01-09"), // vintage 2027
            nil // undated: contributes no option, reachable only via All
        ]
    }

    private func scope(_ selection: SeasonSelection, dates: [Date?]? = nil) -> SeasonScope {
        SeasonScope.resolve(
            eventDates: dates ?? allRecords,
            selection: selection,
            seasonStartMonth: startMonth,
            seasonStartDay: startDay,
            timeZone: timeZone
        )
    }

    func test2026StaysSelectableWhileViewing2027() {
        // The operator is looking at the 2027 season...
        let viewing2027 = scope(.vintage(2027))
        XCTAssertEqual(viewing2027.vintage, 2027)

        // ...and 2026 is still offered, because the option list is built from
        // all of the surface's records rather than the visible subset.
        XCTAssertTrue(
            viewing2027.available.contains(2026),
            "2026 must remain selectable while 2027 is applied"
        )
        XCTAssertEqual(viewing2027.available, [2027, 2026, 2025])

        // And it can actually be selected: switching to it resolves to 2026.
        let switched = scope(.vintage(2026))
        XCTAssertEqual(switched.vintage, 2026)
        XCTAssertTrue(switched.available.contains(2027), "2027 must remain selectable in turn")
        XCTAssertEqual(switched.available, viewing2027.available)
    }

    func testOptionListIsIdenticalWhicheverVintageIsApplied() {
        let selections: [SeasonSelection] = [
            .all, .automatic, .vintage(2025), .vintage(2026), .vintage(2027)
        ]
        for selection in selections {
            XCTAssertEqual(scope(selection).available, [2027, 2026, 2025])
        }
    }

    func testOptionsComeFromAllRecordsNotTheFilteredRows() {
        // Simulating the bug: deriving options from the rows left after the
        // 2027 filter would offer only 2027.
        let applied = scope(.vintage(2027))
        let filteredTo2027 = allRecords.filter { applied.contains($0) }
        let wrong = scope(.vintage(2027), dates: filteredTo2027)
        XCTAssertEqual(wrong.available, [2027])

        // The real call passes the unfiltered list and keeps every season.
        XCTAssertEqual(applied.available, [2027, 2026, 2025])
    }

    func testSeasonBoundariesAreHalfOpenOnTheVineyardsOwnDay() {
        let season2027 = scope(.vintage(2027))
        XCTAssertTrue(season2027.contains(date("2026-07-01")))
        XCTAssertTrue(season2027.contains(date("2027-06-30")))
        XCTAssertFalse(season2027.contains(date("2026-06-30")), "30 Jun 2026 belongs to vintage 2026")
        XCTAssertFalse(season2027.contains(date("2027-07-01")), "1 Jul 2027 opens vintage 2028")
    }

    func testAllVintagesAppliesNoDateRestrictionAndReachesUndatedRecords() {
        let all = scope(.all)
        XCTAssertNil(all.vintage)
        XCTAssertTrue(all.isAll)
        XCTAssertEqual(all.title, SeasonScope.allTitle)
        for record in allRecords {
            XCTAssertTrue(all.contains(record), "All vintages must pass every record")
        }
    }

    func testScopedViewHidesUndatedRecords() {
        XCTAssertFalse(scope(.vintage(2027)).contains(nil))
    }

    func testVintageWithNoRecordsFallsBackToAll() {
        let gone = scope(.vintage(2019))
        XCTAssertNil(gone.vintage)
        XCTAssertTrue(gone.isAll)
        // The real seasons are still offered so the operator can pick one.
        XCTAssertEqual(gone.available, [2027, 2026, 2025])
    }

    func testUndatedRecordsNeverCreateAPhantomOption() {
        let scope = scope(.automatic, dates: [nil, nil])
        XCTAssertTrue(scope.available.isEmpty)
        XCTAssertTrue(scope.isAll)
    }
}
