import Foundation
import XCTest
@testable import VineTrack

@MainActor
final class DeviceTripOwnershipTests: XCTestCase {
    func testOwnedUUIDSurvivesRelaunchAndRemoteRefreshWithoutAdoption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let a = Trip(vineyardId: vineyard, isActive: true)
        let b = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(a)
        store.startTrip(b)
        store.claimDeviceTrip(b.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        XCTAssertEqual(tracking.activeTrip?.id, b.id)
        XCTAssertEqual(store.trips.count, 2)
        store.trips.insert(Trip(vineyardId: vineyard, isActive: true), at: 0)
        XCTAssertEqual(tracking.activeTrip?.id, b.id)

        let relaunched = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        relaunched.selectedVineyardId = vineyard
        relaunched.reloadCurrentVineyardData()
        let resumed = TripTrackingService()
        resumed.configure(store: relaunched, locationService: LocationService())
        XCTAssertEqual(relaunched.deviceActiveTripId, b.id)
        XCTAssertEqual(resumed.activeTrip?.id, b.id)
        XCTAssertTrue(relaunched.trips.contains { $0.id == a.id && $0.isActive })
    }

    func testDifferentSignedInUserCannotControlPersistedTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstUser = UUID()
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.currentUserIdProvider = { firstUser }
        store.selectedVineyardId = vineyard
        let owned = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(owned)
        store.claimDeviceTrip(owned.id)
        let relaunched = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        relaunched.selectedVineyardId = vineyard
        relaunched.reloadCurrentVineyardData()
        relaunched.currentUserIdProvider = { UUID() }
        XCTAssertNil(relaunched.deviceActiveTripId)
        let tracking = TripTrackingService()
        tracking.configure(store: relaunched, locationService: LocationService())
        XCTAssertNil(tracking.activeTrip)
        relaunched.currentUserIdProvider = { firstUser }
        XCTAssertEqual(tracking.activeTrip?.id, owned.id)
    }

    func testRemoteActiveTripDoesNotBlockStartAndOwnedTripBlocksOtherVineyard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID()
        let second = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let remote = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(remote)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        XCTAssertNil(tracking.activeTrip)
        tracking.startTrip(type: .maintenance, primaryPaddockId: nil, paddockIds: [], paddockName: "Local")
        let owned = try XCTUnwrap(tracking.activeTrip)
        XCTAssertNotEqual(owned.id, remote.id)
        XCTAssertTrue(store.trips.contains { $0.id == remote.id && $0.isActive })
        store.selectedVineyardId = second
        store.reloadCurrentVineyardData()
        tracking.startTrip(type: .maintenance, primaryPaddockId: nil, paddockIds: [], paddockName: "Other")
        XCTAssertEqual(store.deviceActiveTripId, owned.id)
        XCTAssertTrue(tracking.errorMessage?.contains("Trip already in progress") == true)
    }

    func testRouteAndEndAffectOnlyOwnedTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let remote = Trip(vineyardId: vineyard, isActive: true)
        let owned = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(remote)
        store.startTrip(owned)
        store.claimDeviceTrip(owned.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        try tracking.changeActiveRoute(pattern: .freeDrive, startPath: 0.5, higherFirst: true)
        XCTAssertTrue(store.trips.first { $0.id == remote.id }?.manualCorrectionEvents.isEmpty == true)
        XCTAssertFalse(store.trips.first { $0.id == owned.id }?.manualCorrectionEvents.isEmpty ?? true)
        XCTAssertEqual(tracking.endTrip(), .ended)
        XCTAssertTrue(store.trips.first { $0.id == remote.id }?.isActive == true)
        XCTAssertFalse(store.trips.first { $0.id == owned.id }?.isActive ?? true)
        XCTAssertNil(store.deviceActiveTripId)
        XCTAssertNil(tracking.activeTrip)
    }

    func testPinLinkageAndDeletedPinsStayOnOwnedTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let remote = Trip(vineyardId: vineyard, isActive: true)
        let owned = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(remote)
        store.startTrip(owned)
        store.claimDeviceTrip(owned.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        store.currentActiveTripIdProvider = { tracking.activeTrip?.id }
        let pin = VinePin(vineyardId: vineyard, latitude: 0, longitude: 0, heading: nil,
                          buttonName: "Repair", buttonColor: "red", side: nil, mode: .repairs)
        let captured = try store.addPinDurably(pin)
        XCTAssertEqual(captured.tripId, owned.id)
        XCTAssertTrue(store.trips.first { $0.id == owned.id }?.pinIds.contains(pin.id) == true)
        XCTAssertTrue(store.trips.first { $0.id == remote.id }?.pinIds.isEmpty == true)
        store.deletePin(pin.id)
        XCTAssertFalse(store.pins.contains { $0.id == pin.id })
    }

    func testLiveMapExistingPinFilterPreservesCurrentTripPins() {
        let vineyard = UUID()
        let trip = UUID()
        func pin(_ completed: Bool, tripId: UUID? = nil, vineyardId: UUID? = nil) -> VinePin {
            VinePin(vineyardId: vineyardId ?? vineyard, latitude: 0, longitude: 0,
                    heading: nil, buttonName: "Repair", buttonColor: "red", side: nil,
                    mode: .repairs, isCompleted: completed, tripId: tripId)
        }
        XCTAssertTrue(ActiveTripView.includesExistingPin(pin(false), tripId: trip, vineyardId: vineyard))
        XCTAssertFalse(ActiveTripView.includesExistingPin(pin(true), tripId: trip, vineyardId: vineyard))
        XCTAssertTrue(ActiveTripView.includesExistingPin(pin(true, tripId: trip), tripId: trip, vineyardId: vineyard))
        XCTAssertFalse(ActiveTripView.includesExistingPin(pin(false, vineyardId: UUID()), tripId: trip, vineyardId: vineyard))
    }
}
