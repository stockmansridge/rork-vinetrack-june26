import XCTest
@testable import VineTrack

final class SpraySaveForLaterTests: XCTestCase {
    @MainActor func testSuccessfulLegacySavePersistsInactiveTripAndRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 100), isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100))
        try store.saveSprayForLater(record: record, trip: trip)
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [record])
        XCTAssertEqual(TripRepository(persistence: persistence).loadAll(), [trip])
        XCTAssertNil(store.deviceActiveTripId)
    }

    @MainActor func testExplicitRecordFailureCreatesNoTripOrSuccessPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        var publications = 0
        store.onSprayRecordChanged = { _ in publications += 1 }
        store.onTripChanged = { _ in publications += 1 }
        persistence.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertThrowsError(try store.saveSprayForLater(record: record, trip: trip))
        XCTAssertFalse(store.addSprayRecord(record))
        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertTrue(store.sprayRecords.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(TripRepository(persistence: persistence).loadAll().isEmpty)
    }

    @MainActor func testUncertainRecordAcknowledgementRetainsExactIdentityForRetry() throws {
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        var stored: [SprayRecord] = []
        var trips: [Trip] = []
        XCTAssertThrowsError(try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: {
            stored = [$0]
            throw SprayTankActualValidationError.localSaveFailed
        }, saveTrip: { trips.append($0) }))
        XCTAssertEqual(stored, [record])
        XCTAssertTrue(trips.isEmpty)
        try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: {
            XCTAssertEqual(stored, [$0])
        }, saveTrip: { trips = [$0] })
        XCTAssertEqual(stored, [record])
        XCTAssertEqual(trips, [trip])
        XCTAssertFalse(trips[0].isActive)
    }

    @MainActor func testTripWriteFailureRetryDoesNotDuplicateDurableRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 100), isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100))
        persistence.durableSaveFailureForTesting = { key in key == TripRepository.storageKey ? SprayTankActualValidationError.localSaveFailed : nil }
        XCTAssertThrowsError(try store.saveSprayForLater(record: record, trip: trip))
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertTrue(store.trips.isEmpty)
        persistence.durableSaveFailureForTesting = nil
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertEqual(store.trips, [trip])
    }

    @MainActor func testEditDiskFailureNeverPublishesSuccessOrChangesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let original = SprayRecord(vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100), notes: "Original")
        XCTAssertTrue(store.addSprayRecord(original))
        var edited = original
        edited.notes = "Edited"
        var publications = 0
        store.onSprayRecordChanged = { _ in publications += 1 }
        persistence.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertFalse(store.updateSprayRecord(edited))
        XCTAssertEqual(store.sprayRecords, [original])
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [original])
        XCTAssertEqual(publications, 0)
        persistence.durableSaveFailureForTesting = nil
        XCTAssertTrue(store.updateSprayRecord(edited))
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [edited])
        XCTAssertEqual(publications, 1)
        store.selectedVineyardId = UUID()
        XCTAssertFalse(store.updateSprayRecord(edited))
        XCTAssertEqual(publications, 1)
    }

    @MainActor func testPlanningGateRefusesBeforeEitherWrite() {
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        var geometry = SprayApplicationSnapshot()
        geometry.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, applicationGeometry: geometry)
        var writes = 0
        XCTAssertThrowsError(try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: { _ in writes += 1 }, saveTrip: { _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }
}
