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
