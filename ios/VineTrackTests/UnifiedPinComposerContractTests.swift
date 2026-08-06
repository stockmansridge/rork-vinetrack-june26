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

    @Test func rowSelectionRequiresABlockAndAtLeastOneSegment() {
        let noBlock = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeRow,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: nil,
            segments: [ManualIssueSegment(row: 3, segment: 1)]
        )
        #expect(noBlock == "Select the block that owns the rows.")

        let noSegments = UnifiedPinContract.validationError(
            scope: UnifiedPinContract.scopeRow,
            hasSelectedType: true,
            latitude: -34.0,
            longitude: 138.0,
            paddockId: UUID(),
            segments: []
        )
        #expect(noSegments == "Select at least one row.")

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
