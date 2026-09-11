import Foundation
import Testing
@testable import VineTrack

struct PinQueryPolicyTests {
    private func pin(
        mode: PinMode = .repairs,
        stage: String? = nil,
        completed: Bool = false,
        row: Int? = nil,
        segments: [ManualIssueSegment]? = nil
    ) -> VinePin {
        VinePin(
            latitude: -33.0,
            longitude: 149.0,
            heading: nil,
            buttonName: "Test",
            buttonColor: "blue",
            side: nil,
            mode: mode,
            isCompleted: completed,
            growthStageCode: stage,
            pinRowNumber: row,
            rowSegments: segments
        )
    }

    @Test func defaultFilterExcludesELAndCompletedPins() {
        let filter = PinQueryFilter()
        #expect(filter.matches(pin()))
        #expect(!filter.matches(pin(stage: "EL12")))
        #expect(!filter.matches(pin(completed: true)))
    }

    @Test func selectedELStagesMatchExactRecognizedIdentity() {
        let filter = PinQueryFilter(includesELStages: true, selectedELStageCodes: ["EL12"])
        #expect(filter.matches(pin(mode: .growth, stage: "EL12")))
        #expect(!filter.matches(pin(mode: .growth, stage: "EL13")))
        #expect(!filter.matches(pin(mode: .growth, stage: "unknown")))
    }

    @Test func usableRowUsesAttachedOrRecordedSegmentsButNeverLegacyRow() {
        #expect(PinQueryPolicy.usableRow(pin(row: 8)) == 8)
        #expect(PinQueryPolicy.usableRow(pin(segments: [ManualIssueSegment(row: 4, segment: 2)])) == 4)
        let legacy = VinePin(latitude: 0, longitude: 0, heading: nil, buttonName: "Legacy", buttonColor: "blue", side: nil, mode: .repairs, rowNumber: 22)
        #expect(PinQueryPolicy.usableRow(legacy) == nil)
    }

    @Test func travelContextRequiresQualifiedRowAndSeparatelyQualifiedHeading() {
        #expect(PinQueryPolicy.qualifiedTravelContext(row: 12.5, isRowQualified: false, heading: 90, isHeadingQualified: true) == nil)
        let rowOnly = PinQueryPolicy.qualifiedTravelContext(row: 12.5, isRowQualified: true, heading: 90, isHeadingQualified: false)
        #expect(rowOnly?.row == 12.5)
        #expect(rowOnly?.heading == nil)
        #expect(PinQueryPolicy.qualifiedTravelContext(row: 12.5, isRowQualified: true, heading: 90, isHeadingQualified: true)?.heading == 90)
    }

    @Test func nearestRowSortIsNumericStableAndLeavesUnusableRowsLast() {
        let rows = [pin(row: 14), pin(row: nil), pin(row: 11), pin(row: 13)]
        let ordered = PinQueryPolicy.nearestRowOrdered(rows, currentRow: 12.5)
        #expect(ordered.compactMap(PinQueryPolicy.usableRow) == [11, 13, 14])
        #expect(PinQueryPolicy.usableRow(ordered.last!) == nil)
    }
}
