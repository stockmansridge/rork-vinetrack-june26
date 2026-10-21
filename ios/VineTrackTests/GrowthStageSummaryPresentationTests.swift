import Foundation
import XCTest
@testable import VineTrack

@MainActor
final class GrowthStageSummaryPresentationTests: XCTestCase {
    private let vineyardID = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    func testCurrentStageRetainsMaximumInfluencingPolicy() {
        let now = instant("2026-10-21T01:00:00Z")
        let blocks = [block("A", "Alpha"), block("B", "Beta"), block("C", "Gamma")]
        let observations = [
            observation("older-high", "a", 35, "2026-10-10"),
            observation("newer-low", "A", 19, "2026-10-21"),
            observation("future", "a", 47, "2026-10-22"),
            observation("stale", "A", 46, "2026-07-01"),
            observation("other-block", "B", 27, "2026-10-21"),
            observation("unassigned", nil, 45, "2026-10-21"),
            // The Summary's shipped policy matches paddock ID. It does not
            // introduce an extra assigned-flag filter over the normalised feed.
            observation("retained-paddock", "C", 17, "2026-10-21", assigned: false)
        ]
        let actual = presentation(blocks, observations, now: now)

        assertMatchesLegacy(actual, blocks: blocks, observations: observations, now: now, timeZone: utc)
        XCTAssertEqual(actual.rows.map(\.currentEL), [35, 27, 17])
        XCTAssertEqual(actual.rows.map { $0.block.id }, ["A", "B", "C"])
    }

    func testMissingStagesEqualKeysAndDuplicateIDsKeepTheirRows() {
        let now = instant("2026-10-21T01:00:00Z")
        let blocks = [
            block("same", "Alpha", marker: 1),
            block("SAME", "Alpha", marker: 2),
            block("same", "Alpha", marker: 3),
            block("lower", "alpha", marker: 4),
            block("missing-name", nil, marker: 5),
            block("missing-stage", "Beta", marker: 6)
        ]
        let observations = [
            observation("one", "Same", 21, "2026-10-21"),
            observation("two", "LOWER", 21, "2026-10-21")
        ]
        let actual = presentation(blocks, observations, now: now)

        assertMatchesLegacy(actual, blocks: blocks, observations: observations, now: now, timeZone: utc)
        XCTAssertEqual(actual.rows.count, blocks.count)
        XCTAssertEqual(actual.rows.prefix(3).map { $0.block.polygon[0].lat }, [1, 2, 3])
        XCTAssertEqual(actual.rows.suffix(2).map(\.currentEL), [nil, nil])
        XCTAssertTrue(presentation([], observations, now: now).rows.isEmpty)
        assertMatchesLegacy(presentation(blocks, [], now: now), blocks: blocks, observations: [], now: now, timeZone: utc)
    }

    func testVineyardLocalMidnightReevaluatesFutureAndExpiringStages() {
        let before = instant("2026-10-20T12:59:59Z") // 23:59:59 in Sydney.
        let after = before.addingTimeInterval(2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let lastInfluencingDay = calendar.date(byAdding: .day, value: -83, to: before)!
        let blocks = [block("future", "Future"), block("expiring", "Expiring")]
        let observations = [
            observation("next-day", "future", 35, "2026-10-21"),
            observation("old", "expiring", 25, localDay(lastInfluencingDay, timeZone: sydney))
        ]
        let beforeRows = presentation(blocks, observations, now: before, timeZone: sydney)
        let afterRows = presentation(blocks, observations, now: after, timeZone: sydney)

        assertMatchesLegacy(beforeRows, blocks: blocks, observations: observations, now: before, timeZone: sydney)
        assertMatchesLegacy(afterRows, blocks: blocks, observations: observations, now: after, timeZone: sydney)
        XCTAssertEqual(beforeRows.rows.map(\.currentEL), [25, nil])
        XCTAssertEqual(afterRows.rows.map(\.currentEL), [35, nil])
        XCTAssertEqual(afterRows.rows.first?.block.id, "future")
        let utcRows = presentation(blocks, observations, now: after, timeZone: utc)
        XCTAssertNil(utcRows.rows.first { $0.block.id == "future" }?.currentEL)
    }

    func testNewEvaluationUsesChangedFeedAndBlockInputs() {
        let now = instant("2026-10-21T01:00:00Z")
        let originalBlocks = [block("A", "Alpha"), block("B", "Beta")]
        let originalObservations = [observation("a", "A", 12, "2026-10-21"), observation("b", "B", 19, "2026-10-21")]
        let original = presentation(originalBlocks, originalObservations, now: now)

        let changedBlocks = [block("A", "Renamed"), block("C", "New block")]
        let changedObservations = [observation("a", "a", 27, "2026-10-21"), observation("c", "c", 35, "2026-10-21")]
        let changed = presentation(changedBlocks, changedObservations, now: now)

        XCTAssertEqual(original.rows.map { $0.block.id }, ["B", "A"])
        XCTAssertEqual(changed.rows.map { $0.block.id }, ["C", "A"])
        XCTAssertEqual(changed.rows.map(\.currentEL), [35, 27])
        XCTAssertEqual(changed.rows.last?.block.name, "Renamed")
        assertMatchesLegacy(changed, blocks: changedBlocks, observations: changedObservations, now: now, timeZone: utc)
    }

    func testDetailKeepsInstantCutoffRecordOrderAndFullContents() {
        let now = instant("2026-10-21T01:00:00Z")
        let blockID = uuid(1)
        let records = [
            record(1, blockID, now.addingTimeInterval(-60), notes: "first"),
            record(2, blockID, now.addingTimeInterval(1), notes: "future same day"),
            record(3, uuid(2), now, notes: "other block"),
            record(4, blockID, now, notes: "inclusive cutoff"),
            record(5, nil, now, notes: "unassigned"),
            record(1, blockID, now.addingTimeInterval(-3600), notes: "same ID, distinct retained content")
        ]
        let observations = [
            // Its day can influence the Summary even though the corresponding
            // detail record is still one second in the future.
            observation("later-today", blockID.uuidString, 35, "2026-10-21T01:00:01Z")
        ]
        let actual = GrowthStageSummaryPresentation.detail(
            for: blockID.uuidString.lowercased(), observations: observations,
            records: records, now: now, timeZone: utc
        )
        let expected = records.filter {
            $0.paddockId?.uuidString.lowercased() == blockID.uuidString.lowercased() && $0.observedAt <= now
        }

        XCTAssertEqual(actual.currentEL, 35)
        XCTAssertEqual(actual.records, expected)
        XCTAssertEqual(actual.records, [records[0], records[3], records[5]])
        XCTAssertEqual(actual.records.map(\.notes), ["first", "inclusive cutoff", "same ID, distinct retained content"])
    }

    func testDetailUsesFreshFeedAndTimeAfterEarlierRowPresentation() {
        let before = instant("2026-10-20T12:59:59Z")
        let after = before.addingTimeInterval(2)
        let blockID = uuid(1)
        let blocks = [block(blockID.uuidString, "Alpha")]
        let future = observation("next-day", blockID.uuidString, 27, "2026-10-21")
        let earlierRow = presentation(blocks, [future], now: before, timeZone: sydney)
        let newObservation = observation("newly-synced", blockID.uuidString, 35, "2026-10-21")
        let newlyVisibleRecord = record(1, blockID, before.addingTimeInterval(1), notes: "arrived after row render")
        let detail = GrowthStageSummaryPresentation.detail(
            for: blockID.uuidString,
            observations: [future, newObservation], records: [newlyVisibleRecord],
            now: after, timeZone: sydney
        )

        XCTAssertNil(earlierRow.rows.first?.currentEL)
        XCTAssertEqual(detail.currentEL, 35)
        XCTAssertEqual(detail.records, [newlyVisibleRecord])
        XCTAssertEqual(detail.currentEL, legacyStage(blockID.uuidString, observations: [future, newObservation], now: after, timeZone: sydney))
    }

    func testPopulatedVintageMatchesTheExistingScreenComputation() {
        let now = instant("2026-10-21T01:00:00Z")
        let blocks = (0..<24).map { block("block-\($0)", "Block \($0)", marker: Double($0)) }
        var observations: [ELRipeness.Observation] = []
        for index in 0..<480 {
            let date = index.isMultiple(of: 7) ? "2026-07-01" : (index.isMultiple(of: 11) ? "2026-10-22" : "2026-10-20")
            observations.append(observation("obs-\(index)", "BLOCK-\(index % 30)", Double(1 + index % 47), date))
        }
        let actual = presentation(blocks, observations, now: now)
        assertMatchesLegacy(actual, blocks: blocks, observations: observations, now: now, timeZone: utc)
    }

    // MARK: - Shipped computation as an equivalence oracle

    private func assertMatchesLegacy(
        _ actual: GrowthStageSummaryPresentation,
        blocks: [ELRipeness.BlockInput], observations: [ELRipeness.Observation],
        now: Date, timeZone: TimeZone,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let sorted = blocks.sorted { left, right in
            let leftEL = legacyStage(left.id, observations: observations, now: now, timeZone: timeZone) ?? -1
            let rightEL = legacyStage(right.id, observations: observations, now: now, timeZone: timeZone) ?? -1
            return leftEL == rightEL ? (left.name ?? "") < (right.name ?? "") : leftEL > rightEL
        }
        XCTAssertEqual(actual.rows.map { $0.block.id }, sorted.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.rows.map { $0.block.name }, sorted.map(\.name), file: file, line: line)
        XCTAssertEqual(actual.rows.map { $0.block.polygon }, sorted.map(\.polygon), file: file, line: line)
        XCTAssertEqual(actual.rows.map(\.currentEL), sorted.map { legacyStage($0.id, observations: observations, now: now, timeZone: timeZone) }, file: file, line: line)
    }

    private func legacyStage(_ blockID: String, observations: [ELRipeness.Observation], now: Date, timeZone: TimeZone) -> Double? {
        let today = localDay(now, timeZone: timeZone)
        return observations
            .filter { $0.paddockId?.lowercased() == blockID.lowercased() && ELRipeness.isInfluencing($0, atDateISO: today) }
            .map(\.el).max()
    }

    // MARK: - Fixed inputs

    private func presentation(
        _ blocks: [ELRipeness.BlockInput], _ observations: [ELRipeness.Observation],
        now: Date, timeZone: TimeZone? = nil
    ) -> GrowthStageSummaryPresentation {
        GrowthStageSummaryPresentation(blocks: blocks, observations: observations, now: now, timeZone: timeZone ?? utc)
    }

    private func block(_ id: String, _ name: String?, marker: Double = 0) -> ELRipeness.BlockInput {
        ELRipeness.BlockInput(id: id, name: name, polygon: [ELRipeness.LatLng(lat: marker, lng: 149)])
    }

    private func observation(_ id: String, _ blockID: String?, _ el: Double, _ date: String, assigned: Bool = true) -> ELRipeness.Observation {
        ELRipeness.Observation(id: id, paddockId: blockID, assigned: assigned, el: el, lat: -33, lng: 149, dateISO: date)
    }

    private func record(_ id: Int, _ blockID: UUID?, _ observedAt: Date, notes: String) -> GrowthStageRecord {
        GrowthStageRecord(
            id: uuid(id), vineyardId: vineyardID, paddockId: blockID,
            stageCode: "EL35", stageLabel: "Veraison", variety: "Pinot Noir",
            observedAt: observedAt, latitude: -33, longitude: 149,
            rowNumber: id, side: "left", notes: notes,
            photoPaths: ["growth/\(id).jpg"], recordedByName: "Fixture operator",
            createdAt: observedAt, updatedAt: observedAt
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func localDay(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
