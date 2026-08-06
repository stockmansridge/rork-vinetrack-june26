import Testing
import Foundation
@testable import VineTrack

/// Unified "Add Pin / Action" composer contract — mirrored by Android's
/// `UnifiedPinContractTest.kt`. Tab ordering, the location validation matrix
/// and the custom-name duplicate rule MUST stay identical across iOS,
/// Android and the portal contract.
struct UnifiedPinComposerContractTests {

    private func type(_ name: String, active: Bool = true) -> CustomPinTypeRecord {
        CustomPinTypeRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            vineyardId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: name,
            color: nil,
            icon: nil,
            isActive: active,
            createdBy: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    @Test func tabsAreRepairGrowthCustomInThatExactOrder() {
        #expect(UnifiedPinContract.tabs == ["Repair", "Growth", "Custom"])
    }

    @Test func pointPlacementNeverRequiresABlock() {
        let error = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopePoint,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: nil,
            segments: []
        )
        #expect(error == nil)
    }

    @Test func rowSelectionRequiresASegmentAndADerivableBlock() {
        // Rows are selected FIRST; a missing block is a derivation failure,
        // reported with a safe message — never a prompt to open a dropdown.
        let noBlock = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeRow,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: nil,
            segments: [ManualIssueSegment(row: 3, segment: 1)]
        )
        #expect(noBlock == UnifiedPinContract.errorRowBlock)
        #expect(noBlock == "Couldn't match the selected row to a block.")

        let noSegments = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeRow,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: UUID(),
            segments: []
        )
        #expect(noSegments == UnifiedPinContract.errorSelectRow)

        let valid = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeRow,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: UUID(),
            segments: [ManualIssueSegment(row: 3, segment: 1)]
        )
        #expect(valid == nil)
    }

    @Test func quickActionLabelIsExactlyManualPinRepairObservation() {
        #expect(UnifiedPinContract.quickActionTitle == "Manual Pin / Repair / Observation")
        #expect(UnifiedPinContract.quickActionSubtitle == "Drop a pin, select a row or select a block")
    }

    @Test func quickActionUsesTheSharedBurgundySemanticColour() {
        #expect(UnifiedPinContract.quickActionColorHex == "#800020")
        #expect(UnifiedPinContract.quickActionColorDarkHex == "#5C0017")
    }

    @Test func locationControlsUseTheEnlargedLayoutInCanonicalOrder() {
        #expect(UnifiedPinContract.methodButtonMinHeight == 128)
        #expect(UnifiedPinContract.methodTitles == ["Drop a pin manually", "Select a row", "Select a block"])
        #expect(UnifiedPinContract.methodSubtitles.count == 3)
        // Row selection is row-first: the subtitle never asks for a block.
        #expect(UnifiedPinContract.methodSubtitles[1] == "Tap rows or row sections — the block is detected automatically")
    }

    @Test func growthTabIncludesGrowthStageExactlyOnceAndFirst() {
        let items = UnifiedPinContract.growthTabItems(
            existingNames: ["Powdery", "Downy", "Blackberries", "Powdery", "growth stage"]
        )
        #expect(items == ["Growth Stage", "Powdery", "Downy", "Blackberries"])
    }

    @Test func growthStagePinStoresTheExistingStageIdentifierAndColour() {
        #expect(UnifiedPinContract.growthStagePinTitle(stageCode: "12") == "Growth Stage 12")
        #expect(UnifiedPinContract.growthStagePinColor == "darkgreen")
    }

    @Test func repairAndGrowthCataloguesStayDeduplicatedByNameAndColour() {
        let entries: [(String, String?)] = [
            ("Irrigation", "blue"),
            ("Broken Post", "brown"),
            ("Irrigation", "blue"), // left/right launcher duplicate
            ("Broken Post", "brown"),
        ]
        var seen = Set<String>()
        let deduped = entries.filter { seen.insert(UnifiedPinContract.catalogueKey(name: $0.0, color: $0.1)).inserted }
        #expect(deduped.map(\.0) == ["Irrigation", "Broken Post"])
    }

    @Test func tappingARowDerivesItsBlockAutomatically() {
        let blockA = UUID()
        let tapped: Set<ManualIssueSegment> = [ManualIssueSegment(row: 41, segment: 1)]
        let result = UnifiedPinContract.applyRowTap(
            currentBlockId: nil,
            tappedBlockId: blockA,
            currentSegments: [],
            tappedSegments: tapped
        )
        #expect(result.blockId == blockA)
        #expect(result.segments == tapped)
    }

    @Test func tappingARowInAnotherBlockSwitchesBlockAndStartsFresh() {
        // "Row 41" exists in two blocks — the tapped block's geometry wins and
        // the previous block's selection is discarded (a pin has one block).
        let blockA = UUID()
        let blockB = UUID()
        let result = UnifiedPinContract.applyRowTap(
            currentBlockId: blockA,
            tappedBlockId: blockB,
            currentSegments: [ManualIssueSegment(row: 41, segment: 1), ManualIssueSegment(row: 41, segment: 2)],
            tappedSegments: [ManualIssueSegment(row: 41, segment: 3)]
        )
        #expect(result.blockId == blockB)
        #expect(result.segments == [ManualIssueSegment(row: 41, segment: 3)])
    }

    @Test func tappingWithinTheCurrentBlockTogglesSegments() {
        let block = UUID()
        let current: Set<ManualIssueSegment> = [ManualIssueSegment(row: 3, segment: 1), ManualIssueSegment(row: 3, segment: 2)]
        // Add a new quarter.
        let added = UnifiedPinContract.applyRowTap(
            currentBlockId: block, tappedBlockId: block,
            currentSegments: current, tappedSegments: [ManualIssueSegment(row: 3, segment: 3)]
        )
        #expect(added.segments == current.union([ManualIssueSegment(row: 3, segment: 3)]))
        // Re-tapping a selected quarter removes it.
        let removed = UnifiedPinContract.applyRowTap(
            currentBlockId: block, tappedBlockId: block,
            currentSegments: current, tappedSegments: [ManualIssueSegment(row: 3, segment: 1)]
        )
        #expect(removed.segments == [ManualIssueSegment(row: 3, segment: 2)])
        // Whole-row tap on a fully selected row clears the row.
        let fullRow = Set((1...4).map { ManualIssueSegment(row: 3, segment: $0) })
        let cleared = UnifiedPinContract.applyRowTap(
            currentBlockId: block, tappedBlockId: block,
            currentSegments: fullRow, tappedSegments: fullRow
        )
        #expect(cleared.segments.isEmpty)
    }

    @Test func blockSelectionRequiresABlock() {
        let missing = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeBlock,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: nil,
            segments: []
        )
        #expect(missing == "Select a block.")

        let valid = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeBlock,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: UUID(),
            segments: []
        )
        #expect(valid == nil)
    }

    @Test func everyScopeRequiresASelectedTypeAndAMarkerCoordinate() {
        #expect(UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopePoint,
            hasSelectedType: false,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: nil,
            segments: []
        ) == "Select a pin type.")
        #expect(UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopePoint,
            hasSelectedType: true,
            latitude: nil,
            longitude: nil,
            paddockId: nil,
            segments: []
        ) == "A map location is required.")
    }

    @Test func customNamesAreTrimmedAndBlankNamesRejected() {
        #expect(UnifiedPinContract.normalizeCustomTypeName("  Broken Wire  ") == "Broken Wire")
        #expect(UnifiedPinContract.normalizeCustomTypeName("   ") == nil)
        #expect(UnifiedPinContract.normalizeCustomTypeName("") == nil)
    }

    @Test func duplicateDetectionIsTrimmedCaseInsensitiveAndIgnoresInactiveItems() {
        let existing = [type("Broken Wire"), type("Large Divot", active: false)]
        #expect(UnifiedPinContract.isDuplicateCustomTypeName("broken wire", existing: existing))
        #expect(UnifiedPinContract.isDuplicateCustomTypeName("  BROKEN WIRE ", existing: existing))
        // Inactive items are hidden from selection, so re-adding the name is allowed.
        #expect(!UnifiedPinContract.isDuplicateCustomTypeName("Large Divot", existing: existing))
        #expect(!UnifiedPinContract.isDuplicateCustomTypeName("Check Irrigation", existing: existing))
    }

    @Test func queuedComposerOpsRoundTripWithStableClientIds() throws {
        let typeId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let pinId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let op = CustomPinPendingOp(
            id: UUID(),
            kind: .pinCreate,
            typeParams: nil,
            pinParams: CustomPinCreateParams(
                id: pinId,
                vineyardId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                title: "Broken Wire",
                locationScope: "row",
                customTypeId: typeId,
                paddockId: UUID(),
                latitude: -34.0005,
                longitude: 138.00008,
                clientUpdatedAt: "2026-08-06T10:00:00Z",
                segments: [ManualIssueSegment(row: 3, segment: 1), ManualIssueSegment(row: 3, segment: 2)]
            ),
            pinId: nil,
            segments: nil,
            queuedAt: Date(),
            attempts: 0,
            lastError: nil
        )
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(CustomPinPendingOp.self, from: data)
        #expect(decoded.pinParams?.id == pinId)
        #expect(decoded.pinParams?.customTypeId == typeId)
        #expect(decoded.pinParams?.locationScope == "row")
        #expect(decoded.pinParams?.segments?.count == 2)

        // The RPC argument names must be exact (p_-prefixed) so the queued
        // payload replays against create_custom_pin without translation.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op.pinParams!)) as? [String: Any]
        #expect(json?["p_title"] as? String == "Broken Wire")
        #expect(json?["p_location_scope"] as? String == "row")
        #expect(json?["p_custom_type_id"] != nil)
    }

    @Test func replayOrderIsTypeThenPinThenSegments() {
        #expect(CustomPinPendingOp.Kind.typeCreate.replayOrder < CustomPinPendingOp.Kind.pinCreate.replayOrder)
        #expect(CustomPinPendingOp.Kind.pinCreate.replayOrder < CustomPinPendingOp.Kind.segments.replayOrder)
    }
}
