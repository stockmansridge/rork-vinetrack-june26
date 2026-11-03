import Foundation
import Testing
@testable import VineTrack

/// PR #50: tank dates are written as fractional ISO-8601 strings. Existing
/// whole-second archives, historical numeric caches and server snake_case
/// payloads must still decode to the same instants.
struct TankSessionTimestampEncodingTests {
    private let start = Date(timeIntervalSince1970: 1_793_660_400.75)
    private let end = Date(timeIntervalSince1970: 1_793_662_000.125)

    @Test func fractionalEncodingRoundTripsUnderEveryArchiveStrategyAndOmitsNils() throws {
        let session = TankSession(id: UUID(), tankNumber: 2, startTime: start, endTime: end,
                                  pathsCovered: [1.5, 2.5], startRow: 1, endRow: 3,
                                  fillStartTime: nil, fillEndTime: nil)
        let strategies: [(JSONEncoder.DateEncodingStrategy, JSONDecoder.DateDecodingStrategy)] = [
            (.iso8601, .iso8601), (.deferredToDate, .deferredToDate), (.secondsSince1970, .secondsSince1970)]
        for (strategy, decoding) in strategies {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = strategy
            let data = try encoder.encode(session)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["startTime"] as? String == "2026-11-02T23:00:00.750Z")
            #expect(object["endTime"] as? String == "2026-11-02T23:26:40.125Z")
            #expect(object["fillStartTime"] == nil && object["fillEndTime"] == nil, "nil dates stay omitted")
            #expect(Set(object.keys) == ["id", "tankNumber", "startTime", "endTime", "pathsCovered", "startRow", "endRow"])
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = decoding
            let restored = try decoder.decode(TankSession.self, from: data)
            #expect(TankSessionReceiptMatch.sameTime(restored.startTime, start))
            #expect(TankSessionReceiptMatch.sameTime(restored.endTime, end))
            #expect(restored.fillStartTime == nil && restored.fillEndTime == nil)
            #expect(TankSessionReceiptMatch.equivalent(local: restored, remote: session))
        }
    }

    @Test func existingWholeSecondArchiveAndNumericCacheStillDecode() throws {
        let id = UUID()
        let wholeSecond = Data("""
        {"id":"\(id)","tankNumber":1,"startTime":"2026-11-02T23:00:00Z","endTime":"2026-11-02T23:26:40Z","pathsCovered":[]}
        """.utf8)
        let iso = JSONDecoder(); iso.dateDecodingStrategy = .iso8601
        let archived = try iso.decode(TankSession.self, from: wholeSecond)
        #expect(archived.startTime == Date(timeIntervalSince1970: 1_793_660_400))
        #expect(archived.endTime == Date(timeIntervalSince1970: 1_793_662_000))

        let numeric = Data("""
        {"id":"\(id)","tankNumber":1,"startTime":\(start.timeIntervalSinceReferenceDate),"pathsCovered":[]}
        """.utf8)
        let cached = try JSONDecoder().decode(TankSession.self, from: numeric)
        #expect(cached.startTime == start && cached.endTime == nil)
    }

    @Test func serverSnakeCasePayloadDecodesAndReEncodesToTheSameInstant() throws {
        let id = UUID()
        let server = Data("""
        {"id":"\(id)","tank_number":3,"start_time":"2026-11-02T23:00:00.75+00:00","end_time":"2026-11-02T23:26:40.125Z",
         "paths_covered":[4.5],"fill_start_time":"2026-11-02T22:50:00.5Z"}
        """.utf8)
        let decoded = try JSONDecoder().decode(TankSession.self, from: server)
        #expect(decoded.tankNumber == 3 && decoded.pathsCovered == [4.5])
        #expect(TankSessionReceiptMatch.sameTime(decoded.startTime, start))
        let reencoded = try JSONDecoder().decode(TankSession.self, from: JSONEncoder().encode(decoded))
        #expect(reencoded.startTime == decoded.startTime && reencoded.endTime == decoded.endTime)
        #expect(reencoded.fillStartTime == decoded.fillStartTime)
    }

    @Test func legacyComparatorBridgesOnlyWholeSecondTruncationOfTheSameInstant() {
        let id = UUID()
        func session(_ start: Date) -> TankSession { TankSession(id: id, tankNumber: 1, startTime: start, pathsCovered: [1.5]) }
        let server = session(start)
        let truncated = session(Date(timeIntervalSince1970: floor(start.timeIntervalSince1970)))
        #expect(TankSessionReceiptMatch.terminalLegacyEquivalent(local: truncated, remote: server))
        #expect(!TankSessionReceiptMatch.equivalent(local: truncated, remote: server), "Exact path stays strict")
        // Genuinely different events: next second, a fractional local value, a rounded-up local value.
        for other in [floor(start.timeIntervalSince1970) + 1, start.timeIntervalSince1970 - 0.5, ceil(start.timeIntervalSince1970)] {
            #expect(!TankSessionReceiptMatch.terminalLegacyEquivalent(local: session(Date(timeIntervalSince1970: other)), remote: server))
        }
        #expect(TankSessionReceiptMatch.discrepancy(local: truncated, remote: server)?.hasSuffix("SUBSECOND") == true)
    }
}
