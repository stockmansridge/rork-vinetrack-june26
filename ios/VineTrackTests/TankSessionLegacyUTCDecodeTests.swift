import Foundation
import XCTest
@testable import VineTrack

/// Production data contains historical camelCase tank timestamps without Z;
/// these were checked against Trip.start_time and are UTC, not vineyard-local.
final class TankSessionLegacyUTCDecodeTests: XCTestCase {
    private let tankId = "e020eea5-bfed-4a5f-a7a7-9b968dd548e6"

    func testHistoricalTimezoneLessTankDateDecodesAsUTC() throws {
        let payload = """
        {"id":"\(tankId)","tankNumber":1,
         "startTime":"2026-09-04T01:21:27.000",
         "endTime":"2026-09-04T03:59:30.000",
         "pathsCovered":[1.0,2.0]}
        """
        let actual = try JSONDecoder().decode(TankSession.self, from: Data(payload.utf8))
        let expected = try XCTUnwrap(TankSessionDateParser.parse("2026-09-04T01:21:27.000Z"))
        XCTAssertEqual(actual.startTime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(actual.tankNumber, 1)
        XCTAssertEqual(actual.pathsCovered, [1.0, 2.0])
        XCTAssertNotNil(actual.endTime)
    }

    func testMicrosecondSnakeCaseUTCStillDecodes() throws {
        let payload = """
        {"id":"\(tankId)","tank_number":2,
         "start_time":"2026-10-14T06:23:23.407852Z",
         "end_time":"2026-10-14T07:33:20.532682Z",
         "paths_covered":[]}
        """
        let actual = try JSONDecoder().decode(TankSession.self, from: Data(payload.utf8))
        let expected = try XCTUnwrap(TankSessionDateParser.parse("2026-10-14T06:23:23.407852Z"))
        XCTAssertEqual(actual.startTime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(actual.tankNumber, 2)
    }

    func testExplicitOffsetStillPreserved() throws {
        let utc = try XCTUnwrap(TankSessionDateParser.parse("2026-09-04T01:21:27.000Z"))
        let offset = try XCTUnwrap(TankSessionDateParser.parse("2026-09-04T11:21:27.000+10:00"))
        XCTAssertEqual(offset.timeIntervalSince1970, utc.timeIntervalSince1970, accuracy: 0.001)
    }

    func testStrictLegacyFormatDoesNotInventUnclearDates() {
        XCTAssertNil(TankSessionDateParser.parse("2026-09-04"))
        XCTAssertNil(TankSessionDateParser.parse("2026-09-04T01:21:27 LOCAL"))
        XCTAssertNil(TankSessionDateParser.parse("2026-99-44T01:21:27.000"))
    }

    func testImpossibleCalendarDatesAndTrailingTextAreRejected() {
        for raw in ["2026-02-30T01:21:27.000", "2026-02-29T01:21:27Z", "2100-02-29T01:21:27Z", "2026-04-31T01:21:27", "2026-09-04T25:21:27", "2026-09-04T01:21:27+25:00", "2026-09-04T01:21:27.000Z trailing"] {
            XCTAssertNil(TankSessionDateParser.parse(raw), raw)
            let payload = """
            {"id":"\(tankId)","tankNumber":1,"startTime":"\(raw)","pathsCovered":[]}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(TankSession.self, from: Data(payload.utf8)), raw)
        }
        let aliases = """
        {"id":"\(tankId)","tankNumber":1,"startTime":"2026-02-30T01:21:27.000",
         "start_time":"2026-03-02T01:21:27.000Z","pathsCovered":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(TankSession.self, from: Data(aliases.utf8)))
    }

    func testMixedHistoricalAndModernBackendTripResponsePreservesIDsAndFailsAsAWholeOnMalformedTank() throws {
        let vineyard = UUID(), first = UUID(), second = UUID()
        let legacy = """
        {"id":"\(first)","vineyard_id":"\(vineyard)","is_active":false,
         "tank_sessions":[{"id":"\(tankId)","tankNumber":1,"startTime":"2026-09-04T01:21:27.000","pathsCovered":[1,2]}]}
        """
        let modern = """
        {"id":"\(second)","vineyard_id":"\(vineyard)","is_active":false,
         "tank_sessions":[{"id":"\(tankId)","tank_number":2,"start_time":"2026-10-14T06:23:23.407852Z","paths_covered":[3]}]}
        """
        let original = Data("[\(legacy),\(modern)]".utf8)
        let records = try JSONDecoder().decode([BackendTrip].self, from: original)
        XCTAssertEqual(records.map(\.id), [first, second])
        XCTAssertEqual(records.map { $0.toTrip().tankSessions.first?.id }, [UUID(uuidString: tankId), UUID(uuidString: tankId)])
        XCTAssertEqual(records.map { $0.toTrip().tankSessions.first?.tankNumber }, [1, 2])
        XCTAssertEqual(records.map { $0.toTrip().tankSessions.first?.pathsCovered }, [[1, 2], [3]])
        XCTAssertEqual(original, Data("[\(legacy),\(modern)]".utf8))
        let malformed = legacy.replacingOccurrences(of: "2026-09-04", with: "2026-02-30")
        XCTAssertThrowsError(try JSONDecoder().decode([BackendTrip].self, from: Data("[\(modern),\(malformed)]".utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("Expected explicit date error: \(error)") }
            XCTAssertEqual(context.codingPath.first?.intValue, 1)
            XCTAssertEqual(context.codingPath.last?.stringValue, "startTime")
        }
        XCTAssertNotNil(TankSessionDateParser.parse("2024-02-29T01:21:27Z"))
        XCTAssertNotNil(TankSessionDateParser.parse("2000-02-29T01:21:27"))
    }

    func testContradictoryTankAliasesStillRejectEntireRecord() {
        let payload = """
        {"id":"\(tankId)","tankNumber":1,"tank_number":2,
         "startTime":"2026-09-04T01:21:27.000",
         "pathsCovered":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(TankSession.self, from: Data(payload.utf8)))
    }

    func testLocalNumericDateEncodingRemainsCompatible() throws {
        let original = TankSession(
            id: UUID(uuidString: tankId)!,
            tankNumber: 1,
            startTime: Date(timeIntervalSince1970: 1_788_483_687),
            pathsCovered: [1.0]
        )
        let restored = try JSONDecoder().decode(TankSession.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }
}
