import Testing
import Foundation
@testable import VineTrack

/// Canonical pin placement contract (sql/171) — mirrored by Android's
/// `PinPlacementContractTest.kt`. The resolution matrix, warning rules,
/// row summaries and display lines MUST stay identical across iOS, Android,
/// the SQL view and the portal contract. Fixture expectations here are the
/// shared cross-platform fixtures: any change must land on both platforms.
struct PinPlacementContractTests {

    private func wholeRow(_ row: Int) -> [ManualIssueSegment] {
        (1...4).map { ManualIssueSegment(row: row, segment: $0) }
    }

    private func resolve(
        storedScope: String? = nil,
        hasBlock: Bool = false,
        segments: [ManualIssueSegment] = [],
        hasCoordinates: Bool = false,
        snappedToRow: Bool = false,
        hasRowValues: Bool = false
    ) -> PinPlacement {
        PinPlacementContract.resolve(
            storedScope: storedScope,
            hasBlock: hasBlock,
            segments: segments,
            hasCoordinates: hasCoordinates,
            snappedToRow: snappedToRow,
            hasRowValues: hasRowValues
        )
    }

    // MARK: - The canonical assignment matrix

    @Test func blockScopePinWithABlockAndNoRowAnywhereIsAssigned() {
        let p = resolve(storedScope: "block", hasBlock: true, hasCoordinates: true)
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisBlock)
        #expect(p.warningCode == nil)
    }

    @Test func rowScopePinWithSegmentsAndNoBaseRowNumberIsAssigned() {
        let p = resolve(
            storedScope: "row",
            hasBlock: true,
            segments: wholeRow(41) + wholeRow(42) + wholeRow(43),
            hasCoordinates: true,
            hasRowValues: false
        )
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisRowSegments)
        #expect(p.warningCode == nil)
        #expect(p.hasRowSegments)
    }

    @Test func rowSummaryIsDerivedFromSegmentsNotBaseRowFields() {
        let ranges = resolve(
            storedScope: "row", hasBlock: true,
            segments: wholeRow(41) + wholeRow(42) + wholeRow(43),
            hasCoordinates: true
        )
        #expect(ranges.rowSummary == "Rows 41–43")

        let partial = resolve(
            storedScope: "row", hasBlock: true,
            segments: [ManualIssueSegment(row: 41, segment: 1), ManualIssueSegment(row: 41, segment: 2)],
            hasCoordinates: true
        )
        #expect(partial.rowSummary == "Row 41 (sections 1–2)")
    }

    @Test func pointPinWithCoordinatesAndNoBlockIsAssigned() {
        let p = resolve(storedScope: "point", hasCoordinates: true)
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisPointCoordinates)
        #expect(p.warningCode == nil)
    }

    @Test func snappedPointWithBlockAndRowIsAssignedAsSnappedPoint() {
        let p = resolve(
            storedScope: "point", hasBlock: true, hasCoordinates: true,
            snappedToRow: true, hasRowValues: true
        )
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisSnappedPoint)
        #expect(p.warningCode == nil)
    }

    @Test func legacyPinWithBlockButNoRowIsAValidBlockAssignment() {
        let p = resolve(storedScope: nil, hasBlock: true, hasCoordinates: true)
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisLegacyBlock)
        #expect(p.locationScope == "block")
        #expect(p.warningCode == nil)
    }

    @Test func legacyPinWithCoordinatesButNoBlockIsAValidPointAssignment() {
        let p = resolve(storedScope: nil, hasCoordinates: true)
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisPointCoordinates)
        #expect(p.locationScope == "point")
        #expect(p.warningCode == nil)
    }

    @Test func legacyPinWithBlockAndRowValuesResolvesAsSnappedPoint() {
        let p = resolve(storedScope: nil, hasBlock: true, hasCoordinates: true, hasRowValues: true)
        #expect(p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisSnappedPoint)
        #expect(p.locationScope == "point")
        #expect(p.warningCode == nil)
    }

    @Test func genuinelyEmptyPinIsUnassignedWithTheAmberWarning() {
        let p = resolve()
        #expect(!p.isAssigned)
        #expect(p.basis == PinPlacementContract.basisUnassigned)
        #expect(p.warningCode == PinPlacementContract.warningUnassigned)
    }

    @Test func deletedSegmentsDoNotCountStoredRowScopeFallsBackSafely() {
        // Server excludes dead segments; the pin arrives with none. The block
        // stays a valid assignment, flagged as incomplete metadata — never
        // the amber unassigned warning.
        let p = resolve(storedScope: "row", hasBlock: true, hasCoordinates: true)
        #expect(p.isAssigned)
        #expect(p.warningCode == PinPlacementContract.warningMetadataIncomplete)
        #expect(!p.hasRowSegments)
    }

    @Test func warningAppearsOnlyForGenuinelyUnassignedRecords() {
        let valid = [
            resolve(storedScope: "block", hasBlock: true, hasCoordinates: true),
            resolve(storedScope: "row", hasBlock: true, segments: wholeRow(3), hasCoordinates: true),
            resolve(storedScope: "point", hasCoordinates: true),
            resolve(hasBlock: true, hasCoordinates: true),
            resolve(hasCoordinates: true)
        ]
        for p in valid {
            #expect(p.warningCode == nil, "no warning for \(p.basis)")
        }
    }

    // MARK: - Display lines

    @Test func blockNameRemainsVisibleWhenRowMetadataIsAbsent() {
        let block = resolve(storedScope: "block", hasBlock: true, hasCoordinates: true)
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: block, attachedRowText: nil) == "Pinot Noir")
        let legacy = resolve(hasBlock: true, hasCoordinates: true)
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: legacy, attachedRowText: nil) == "Pinot Noir")
    }

    @Test func rowScopeLineCombinesTheBlockWithTheSegmentSummary() {
        let p = resolve(
            storedScope: "row", hasBlock: true,
            segments: wholeRow(41) + wholeRow(42),
            hasCoordinates: true
        )
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: p, attachedRowText: nil) == "Pinot Noir — Rows 41–42")
    }

    @Test func pointPinWithoutABlockShowsAValidPointLocationNeverUnassigned() {
        let p = resolve(storedScope: "point", hasCoordinates: true)
        #expect(PinPlacementContract.blockContextLine(blockName: nil, placement: p, attachedRowText: nil) == PinPlacementContract.pointLocationLabel)
    }

    @Test func unassignedLabelAppearsOnlyForTheGenuinelyEmptyRecord() {
        let p = resolve()
        #expect(PinPlacementContract.blockContextLine(blockName: nil, placement: p, attachedRowText: nil) == PinPlacementContract.unassignedLocationLabel)
    }

    @Test func noSideIsInventedAndExactPathRowsArePreserved() {
        // 19.5 stays 19.5, whole rows trim, legacy backfills ".5".
        #expect(PinPlacementContract.attachedRowText(pinRowNumber: nil, drivingRowNumber: 19.5, legacyRowNumber: nil) == "19.5")
        #expect(PinPlacementContract.attachedRowText(pinRowNumber: 15, drivingRowNumber: nil, legacyRowNumber: nil) == "15")
        #expect(PinPlacementContract.attachedRowText(pinRowNumber: nil, drivingRowNumber: nil, legacyRowNumber: 14) == "14.5")
        #expect(PinPlacementContract.attachedRowText(pinRowNumber: nil, drivingRowNumber: nil, legacyRowNumber: nil) == nil)
        // The snapped line never includes a side — sides are rendered only by
        // the facing line, and only from a genuinely stored value.
        let snapped = resolve(
            storedScope: "point", hasBlock: true, hasCoordinates: true,
            snappedToRow: true, hasRowValues: true
        )
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: snapped, attachedRowText: "19.5") == "Pinot Noir row 19.5")
    }

    // MARK: - Every surface resolves the same placement

    @Test func listDetailMapAndExportResolveTheIdenticalPlacementForOnePin() {
        let pin = VinePin(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            vineyardId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            latitude: -34.5,
            longitude: 148.5,
            heading: nil,
            buttonName: "Broken Wire",
            buttonColor: "orange",
            side: nil,
            mode: .repairs,
            paddockId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            locationScope: "row",
            rowSegments: (1...4).map { ManualIssueSegment(row: 41, segment: $0) }
        )
        let a = PinPlacementContract.placement(for: pin)
        let b = PinPlacementContract.placement(for: pin)
        #expect(a == b)
        #expect(a.basis == PinPlacementContract.basisRowSegments)
        #expect(a.rowSummary == "Row 41")
    }

    @Test func repairGrowthAndCustomPinsResolveThroughTheSameRules() {
        for mode in [PinMode.repairs, PinMode.growth, PinMode.manualIssue] {
            let pin = VinePin(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                vineyardId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                latitude: -34.5,
                longitude: 148.5,
                heading: nil,
                buttonName: "Any",
                buttonColor: "orange",
                side: nil,
                mode: mode,
                paddockId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                locationScope: "block"
            )
            let p = PinPlacementContract.placement(for: pin)
            #expect(p.isAssigned, "\(mode) block pin must be assigned")
            #expect(p.basis == PinPlacementContract.basisBlock)
            #expect(p.warningCode == nil)
        }
    }

    // MARK: - Cache compatibility

    @Test func cachedRowScopePinWithoutEmbeddedSegmentsKeepsItsBlockAndRegainsTheSummaryAfterRefresh() throws {
        // A pins payload synced BEFORE the placement contract: no
        // pin_row_segments key at all. Must decode and fall back safely.
        let staleJSON = Data("""
        {"id":"33333333-3333-3333-3333-333333333333",
         "vineyard_id":"22222222-2222-2222-2222-222222222222",
         "paddock_id":"44444444-4444-4444-4444-444444444444",
         "mode":"Repairs","latitude":-34.5,"longitude":148.5,
         "location_scope":"row","is_completed":false}
        """.utf8)
        let stale = try JSONDecoder().decode(BackendPin.self, from: staleJSON)
        let stalePin = try #require(stale.toVinePin())
        let before = PinPlacementContract.placement(for: stalePin)
        #expect(before.isAssigned)
        #expect(before.warningCode == PinPlacementContract.warningMetadataIncomplete)
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: before, attachedRowText: nil) == "Pinot Noir")

        // After refresh the delta sync embeds the segments.
        let freshJSON = Data("""
        {"id":"33333333-3333-3333-3333-333333333333",
         "vineyard_id":"22222222-2222-2222-2222-222222222222",
         "paddock_id":"44444444-4444-4444-4444-444444444444",
         "mode":"Repairs","latitude":-34.5,"longitude":148.5,
         "location_scope":"row","is_completed":false,
         "pin_row_segments":[
           {"row_number":41,"segment_number":1},{"row_number":41,"segment_number":2},
           {"row_number":41,"segment_number":3},{"row_number":41,"segment_number":4}]}
        """.utf8)
        let fresh = try JSONDecoder().decode(BackendPin.self, from: freshJSON)
        let freshPin = try #require(fresh.toVinePin())
        let after = PinPlacementContract.placement(for: freshPin)
        #expect(after.basis == PinPlacementContract.basisRowSegments)
        #expect(after.warningCode == nil)
        #expect(PinPlacementContract.blockContextLine(blockName: "Pinot Noir", placement: after, attachedRowText: nil) == "Pinot Noir — Row 41")
    }

    @Test func sharedCrossPlatformFixturesMatchTheAndroidExpectationsExactly() {
        // These literals are asserted identically in
        // PinPlacementContractTest.kt — do not change one side only.
        #expect(PinPlacementContract.basisPointCoordinates == "point_coordinates")
        #expect(PinPlacementContract.basisSnappedPoint == "snapped_point")
        #expect(PinPlacementContract.basisRowSegments == "row_segments")
        #expect(PinPlacementContract.basisBlock == "block")
        #expect(PinPlacementContract.basisLegacyBlock == "legacy_block")
        #expect(PinPlacementContract.basisUnassigned == "unassigned")
        #expect(PinPlacementContract.warningUnassigned == "unassigned_location")
        #expect(PinPlacementContract.warningMetadataIncomplete == "location_metadata_incomplete")
        #expect(PinPlacementContract.unassignedLocationLabel == "Unassigned location")
        #expect(PinPlacementContract.pointLocationLabel == "Point location")
    }
}
