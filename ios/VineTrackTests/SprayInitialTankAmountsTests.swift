import Foundation
import XCTest
@testable import VineTrack

@MainActor
final class SprayInitialTankAmountsTests: XCTestCase {
    private struct Fixture {
        let draft: SprayInitialTankDraft
        let sourceTrip: Trip
        let startedTrip: Trip
        let actual: SprayTankActual
    }

    private func fixture() throws -> Fixture {
        let owner = UUID(), vineyard = UUID(), record = UUID(), tripId = UUID(), session = UUID()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let solid = SprayChemical(name: "Solid", volumePerTank: 700, ratePerHa: 1_400, unit: .kilograms)
        let liquid = SprayChemical(name: "Liquid", volumePerTank: 2_000, ratePerHa: 4_000, unit: .litres)
        let tank = SprayTank(tankNumber: 1, waterVolume: 294.7, chemicals: [solid, liquid])
        let amounts = SprayInitialTankAmounts(tankId: tank.id, tankNumber: 1, waterLitres: 300,
            chemicalBaseAmounts: [solid.id: 750, liquid.id: 0])
        let draft = SprayInitialTankDraft(ownerId: owner, vineyardId: vineyard, tripId: tripId,
            sprayRecordId: record, tank: tank, amounts: amounts)
        let source = Trip(id: tripId, vineyardId: vineyard, paddockName: "Block", startTime: when,
            isActive: true, totalTanks: 2, tripFunction: TripFunction.spraying.rawValue, operatorUserId: owner)
        var started = source
        started.tankSessions = [TankSession(id: session, tankNumber: 1, startTime: when)]
        started.activeTankNumber = 1
        let actual = try SprayTankActual(vineyardId: vineyard, sprayRecordId: record, tripId: tripId,
            tankSessionId: session.uuidString, tankNumber: 1, waterVolumeL: amounts.waterLitres,
            chemicals: tank.chemicals.map { product in
                try SprayTankActualChemical(plannedChemicalId: product.id, savedChemicalId: product.savedChemicalId,
                    name: product.name, actualAmountBase: amounts.chemicalBaseAmounts[product.id]!, unit: product.unit)
            }, confirmedAt: when, confirmedBy: owner)
        return Fixture(draft: draft, sourceTrip: source, startedTrip: started, actual: actual)
    }

    private func persistence() throws -> (URL, PersistenceStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, PersistenceStore(directory: directory))
    }

    private func amounts(_ original: SprayInitialTankAmounts, tankId: UUID? = nil, number: Int? = nil,
                         water: Double? = nil, chemicals: [UUID: Double]? = nil) -> SprayInitialTankAmounts {
        SprayInitialTankAmounts(tankId: tankId ?? original.tankId, tankNumber: number ?? original.tankNumber,
            waterLitres: water ?? original.waterLitres, chemicalBaseAmounts: chemicals ?? original.chemicalBaseAmounts)
    }

    func testActualAmountsAreDistinctFromPlanAndExplicitZeroIsValid() throws {
        let f = try fixture()
        XCTAssertTrue(f.draft.amounts.isValid(for: f.draft.tank))
        XCTAssertEqual(f.draft.tank.waterVolume, 294.7)
        XCTAssertEqual(f.draft.amounts.waterLitres, 300)
        XCTAssertEqual(f.draft.amounts.chemicalBaseAmounts[f.draft.tank.chemicals[0].id], 750)
        XCTAssertEqual(f.draft.amounts.chemicalBaseAmounts[f.draft.tank.chemicals[1].id], 0)
        XCTAssertEqual(f.draft.tank.chemicals[1].volumePerTank, 2_000)
    }

    func testFirstTankUsesLifecycleOrderAndRejectsAmbiguousTankIdentity() throws {
        let first = try fixture().draft.tank
        let second = SprayTank(tankNumber: 2, waterVolume: 500, chemicals: first.chemicals)
        XCTAssertEqual(SprayInitialTankAmounts.firstTank(in: [second, first]), first)
        XCTAssertNil(SprayInitialTankAmounts.firstTank(in: [first, first]))
        var duplicateNumber = second
        duplicateNumber.tankNumber = first.tankNumber
        XCTAssertNil(SprayInitialTankAmounts.firstTank(in: [first, duplicateNumber]))
        var invalidNumber = second
        invalidNumber.tankNumber = 0
        XCTAssertNil(SprayInitialTankAmounts.firstTank(in: [first, invalidNumber]))
        XCTAssertNil(SprayInitialTankAmounts.firstTank(in: []))
    }

    func testMissingExtraAndDuplicateChemicalIdentitiesCannotBecomeActuals() throws {
        let f = try fixture(), original = f.draft.amounts
        var missing = original.chemicalBaseAmounts
        missing.removeValue(forKey: f.draft.tank.chemicals[0].id)
        XCTAssertFalse(amounts(original, chemicals: missing).isValid(for: f.draft.tank))
        var extra = original.chemicalBaseAmounts
        extra[UUID()] = 10
        XCTAssertFalse(amounts(original, chemicals: extra).isValid(for: f.draft.tank))
        var duplicate = f.draft.tank
        duplicate.chemicals.append(duplicate.chemicals[0])
        XCTAssertFalse(original.isValid(for: duplicate))
    }

    func testWaterAndChemicalValidationRejectsInvalidAndWrongTankValues() throws {
        let f = try fixture(), original = f.draft.amounts
        for invalid in [0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(amounts(original, water: invalid).isValid(for: f.draft.tank))
        }
        for invalid in [-1, Double.nan, Double.infinity] {
            var bad = original.chemicalBaseAmounts
            bad[f.draft.tank.chemicals[0].id] = invalid
            XCTAssertFalse(amounts(original, chemicals: bad).isValid(for: f.draft.tank))
        }
        XCTAssertFalse(amounts(original, tankId: UUID()).isValid(for: f.draft.tank))
        XCTAssertFalse(amounts(original, number: 2).isValid(for: f.draft.tank))
    }

    func testOnlyExactActualAndRealTankSessionAcknowledgeInput() throws {
        let f = try fixture()
        XCTAssertTrue(f.draft.isRecorded(in: [f.actual], trip: f.startedTrip))
        XCTAssertFalse(f.draft.isRecorded(in: [], trip: f.startedTrip))
        XCTAssertFalse(f.draft.isRecorded(in: [f.actual], trip: f.sourceTrip))
        var wrongSession = f.startedTrip
        wrongSession.tankSessions = [TankSession(tankNumber: 1, startTime: f.actual.confirmedAt)]
        XCTAssertFalse(f.draft.isRecorded(in: [f.actual], trip: wrongSession))
        var duplicateSession = f.startedTrip
        duplicateSession.tankSessions.append(duplicateSession.tankSessions[0])
        XCTAssertFalse(f.draft.isRecorded(in: [f.actual], trip: duplicateSession))
    }

    func testAnotherOwnerRecordOrEnteredQuantityDoesNotConsumeOriginalDraft() throws {
        let f = try fixture()
        let otherOwner = SprayInitialTankDraft(ownerId: UUID(), vineyardId: f.draft.vineyardId,
            tripId: f.draft.tripId, sprayRecordId: f.draft.sprayRecordId, tank: f.draft.tank, amounts: f.draft.amounts)
        XCTAssertFalse(otherOwner.isRecorded(in: [f.actual], trip: f.startedTrip))
        let otherRecord = SprayInitialTankDraft(ownerId: f.draft.ownerId, vineyardId: f.draft.vineyardId,
            tripId: f.draft.tripId, sprayRecordId: UUID(), tank: f.draft.tank, amounts: f.draft.amounts)
        XCTAssertFalse(otherRecord.isRecorded(in: [f.actual], trip: f.startedTrip))
        let otherQuantity = SprayInitialTankDraft(ownerId: f.draft.ownerId, vineyardId: f.draft.vineyardId,
            tripId: f.draft.tripId, sprayRecordId: f.draft.sprayRecordId, tank: f.draft.tank,
            amounts: amounts(f.draft.amounts, water: 301))
        XCTAssertFalse(otherQuantity.isRecorded(in: [f.actual], trip: f.startedTrip))
    }

    func testJournalTimestampPrecisionDoesNotOverrideExactSessionIdentity() throws {
        let f = try fixture()
        var restored = f.startedTrip
        // The journal is encoded to ISO8601 seconds while the current actual
        // may still have an in-memory subsecond confirmation timestamp.
        restored.tankSessions[0].startTime = f.actual.confirmedAt.addingTimeInterval(-0.25)
        XCTAssertTrue(f.draft.isRecorded(in: [f.actual], trip: restored))
    }

    func testOldActualsCacheWithoutDraftFieldStillLoadsExactly() throws {
        struct OldCache: Encodable { let records: [SprayTankActual]; let pendingIds: Set<UUID> }
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        try disk.saveOrThrow(OldCache(records: [f.actual], pendingIds: [f.actual.id]), key: "vinetrack_spray_tank_actuals_v1")
        let store = SprayTankActualStore(persistence: disk)
        XCTAssertEqual(store.records, [f.actual])
        XCTAssertEqual(store.pendingIds, [f.actual.id])
        XCTAssertTrue(store.initialMixDrafts.isEmpty)
    }

    func testDraftSurvivesRelaunchAndOrdinaryActualSaveAndRemoval() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SprayTankActualStore(persistence: disk)
        try store.stageInitialMix(f.draft)
        try store.stageInitialMix(f.draft)
        XCTAssertEqual(store.initialMixDrafts.count, 1)
        XCTAssertTrue(store.hasPending(tripId: f.draft.tripId))
        XCTAssertEqual(store.pendingCount(tripId: f.draft.tripId), 1)
        try store.saveLocally(f.actual)
        try store.removeLocal(id: f.actual.id)
        let reloaded = SprayTankActualStore(persistence: disk)
        XCTAssertEqual(reloaded.initialMix(tripId: f.draft.tripId), f.draft)
        XCTAssertTrue(reloaded.records.isEmpty)
        XCTAssertTrue(reloaded.hasPending(tripId: f.draft.tripId))
    }

    func testConflictingRetryKeepsOriginalEnteredAmounts() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SprayTankActualStore(persistence: disk)
        try store.stageInitialMix(f.draft)
        let edited = SprayInitialTankDraft(ownerId: f.draft.ownerId, vineyardId: f.draft.vineyardId,
            tripId: f.draft.tripId, sprayRecordId: f.draft.sprayRecordId, tank: f.draft.tank,
            amounts: amounts(f.draft.amounts, water: 301))
        XCTAssertThrowsError(try store.stageInitialMix(edited))
        XCTAssertEqual(SprayTankActualStore(persistence: disk).initialMix(tripId: f.draft.tripId), f.draft)
    }

    func testWriteFailureDoesNotAdvertiseDurableDraft() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SprayTankActualStore(persistence: disk)
        disk.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertThrowsError(try store.stageInitialMix(f.draft))
        XCTAssertNil(store.initialMix(tripId: f.draft.tripId))
        XCTAssertTrue(SprayTankActualStore(persistence: disk).initialMixDrafts.isEmpty)
    }

    func testDraftClearsOnlyAfterBothActualAndTripSessionAreDurable() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SprayTankActualStore(persistence: disk)
        try store.stageInitialMix(f.draft)
        XCTAssertThrowsError(try store.clearInitialMix(f.draft, trip: f.startedTrip))
        try store.saveLocally(f.actual)
        XCTAssertThrowsError(try store.clearInitialMix(f.draft, trip: f.sourceTrip))
        XCTAssertEqual(store.initialMix(tripId: f.draft.tripId), f.draft)
        try store.clearInitialMix(f.draft, trip: f.startedTrip)
        XCTAssertNoThrow(try store.clearInitialMix(f.draft, trip: f.startedTrip))
        XCTAssertNil(SprayTankActualStore(persistence: disk).initialMix(tripId: f.draft.tripId))
        XCTAssertEqual(store.records, [f.actual])
        XCTAssertTrue(store.hasPending(tripId: f.draft.tripId)) // Actual still needs server acknowledgement.
    }

    func testFailedDraftClearRetainsExactEvidenceAcrossRelaunch() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SprayTankActualStore(persistence: disk)
        try store.stageInitialMix(f.draft)
        try store.saveLocally(f.actual)
        disk.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertThrowsError(try store.clearInitialMix(f.draft, trip: f.startedTrip))
        let reloaded = SprayTankActualStore(persistence: disk)
        XCTAssertEqual(reloaded.initialMix(tripId: f.draft.tripId), f.draft)
        XCTAssertEqual(reloaded.records, [f.actual])
        disk.durableSaveFailureForTesting = nil
        try reloaded.clearInitialMix(f.draft, trip: f.startedTrip)
        XCTAssertTrue(reloaded.initialMixDrafts.isEmpty)
    }

    func testInterruptedTankCommitRecoversOriginalActualThenClearsDraft() throws {
        let f = try fixture()
        let (directory, disk) = try persistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: disk)
        store.selectedVineyardId = f.draft.vineyardId
        store.trips = [f.sourceTrip]
        store.sprayRecords = [SprayRecord(id: f.draft.sprayRecordId, tripId: f.draft.tripId,
            vineyardId: f.draft.vineyardId, tanks: [f.draft.tank])]
        let actuals = SprayTankActualStore(persistence: disk)
        try actuals.stageInitialMix(f.draft)
        let interrupted = StartTankCommitCoordinator(persistence: disk, actualStore: actuals, failurePoint: .afterActual)
        XCTAssertThrowsError(try interrupted.commit(sourceTrip: f.sourceTrip, updatedTrip: f.startedTrip,
            actual: f.actual, store: store))
        let reloaded = SprayTankActualStore(persistence: disk)
        XCTAssertEqual(reloaded.initialMix(tripId: f.draft.tripId), f.draft)
        XCTAssertFalse(f.draft.isRecorded(in: reloaded.records, trip: store.trips[0]))
        let recovery = StartTankCommitCoordinator(persistence: disk, actualStore: reloaded)
        XCTAssertTrue(recovery.recover(store: store))
        XCTAssertFalse(recovery.recover(store: store))
        XCTAssertEqual(reloaded.records.map(\.id), [f.actual.id])
        XCTAssertEqual(store.trips[0].tankSessions, f.startedTrip.tankSessions)
        try reloaded.clearInitialMix(f.draft, trip: store.trips[0])
        XCTAssertTrue(reloaded.initialMixDrafts.isEmpty)
    }
}
