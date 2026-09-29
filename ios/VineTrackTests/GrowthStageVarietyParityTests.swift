import Foundation
import XCTest
@testable import VineTrack

final class GrowthStageVarietyParityTests: XCTestCase {
    @MainActor
    func testNewPinSnapshotsPrimaryAllocationIntoCanonicalUpsertWithoutChangingOtherFields() throws {
        let vineyardId = UUID()
        let blockId = UUID()
        let pinId = UUID()
        let operatorId = UUID()
        let pinotId = UUID()
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let pinot = GrapeVariety(id: pinotId, vineyardId: vineyardId, name: "Pinot Noir", optimalGDD: 0)
        store.grapeVarieties = [pinot]
        store.paddocks = [Paddock(id: blockId, vineyardId: vineyardId, name: "North", varietyAllocations: [
            PaddockVarietyAllocation(varietyId: UUID(), percent: 20, name: "Shiraz"),
            PaddockVarietyAllocation(varietyId: pinotId, percent: 80, name: "Pinot Noir")
        ])]
        let service = GrowthStageRecordSyncService(
            metadata: GrowthStageRecordSyncMetadata(persistence: persistence), persistence: persistence
        )
        service.configure(store: store, auth: NewBackendAuthService())
        let pin = VinePin(
            id: pinId, vineyardId: vineyardId, latitude: -33.3, longitude: 149.1,
            heading: nil, buttonName: "Growth", buttonColor: "green", side: nil, mode: .growth,
            paddockId: blockId, rowNumber: 12, timestamp: observedAt,
            createdBy: "Operator", createdByUserId: operatorId,
            growthStageCode: "EL23", notes: "Keep this note"
        )
        service.mirrorGrowthStagePin(pin)
        service.mirrorGrowthStagePin(pin)
        let record = try XCTUnwrap(service.records.first)
        XCTAssertEqual(service.records.count, 1)
        let payload = BackendGrowthStageRecord.upsert(from: record, createdBy: operatorId, clientUpdatedAt: observedAt)
        XCTAssertEqual(payload.vineyardId, vineyardId)
        XCTAssertEqual(payload.paddockId, blockId)
        XCTAssertEqual(payload.pinId, pinId)
        XCTAssertEqual(payload.variety, "Pinot Noir")
        XCTAssertEqual(payload.varietyId, pinotId)
        XCTAssertEqual(payload.stageCode, "EL23")
        XCTAssertEqual(payload.stageLabel, GrowthStage.allStages.first { $0.code == "EL23" }?.description)
        XCTAssertEqual(payload.observedAt, observedAt)
        XCTAssertEqual(payload.latitude, -33.3)
        XCTAssertEqual(payload.longitude, 149.1)
        XCTAssertEqual(payload.rowNumber, 12)
        XCTAssertNil(payload.side)
        XCTAssertEqual(payload.notes, "Keep this note")
        XCTAssertEqual(payload.photoPaths, [])
        XCTAssertEqual(payload.recordedByName, "Operator")
        XCTAssertEqual(payload.createdBy, operatorId)
        XCTAssertEqual(payload.clientUpdatedAt, observedAt)

        store.paddocks[0].varietyAllocations = [PaddockVarietyAllocation(varietyId: UUID(), percent: 100, name: "Chardonnay")]
        service.mirrorGrowthStagePin(pin)
        XCTAssertEqual(service.records.count, 1)
        XCTAssertEqual(service.records[0].variety, "Pinot Noir")
        XCTAssertEqual(service.records[0].varietyId, pinotId)
        XCTAssertEqual(service.records[0].notes, "Keep this note")
        XCTAssertEqual(service.records[0].stageCode, "EL23")
        XCTAssertEqual(service.records[0].pinId, pinId)
    }

    @MainActor
    func testNoAllocationHasNoSnapshotAndEqualPercentSelectsFirst() {
        let vineyardId = UUID()
        let block = Paddock(vineyardId: vineyardId, name: "Empty")
        XCTAssertNil(GrowthStageRecordSyncService.primaryVariety(in: block, varieties: []))
        var equal = block
        equal.varietyAllocations = [
            PaddockVarietyAllocation(varietyId: UUID(), percent: 50, name: "Pinot Noir"),
            PaddockVarietyAllocation(varietyId: UUID(), percent: 50, name: "Shiraz")
        ]
        XCTAssertEqual(GrowthStageRecordSyncService.primaryVariety(in: equal, varieties: [])?.displayName, "Pinot Noir")
    }
}
