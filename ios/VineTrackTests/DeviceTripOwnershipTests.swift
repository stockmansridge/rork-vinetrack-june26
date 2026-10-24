import Foundation
import XCTest
import CoreLocation
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
        let secondUser = UUID()
        relaunched.currentUserIdProvider = { secondUser }
        XCTAssertEqual(relaunched.deviceActiveTripId, owned.id)
        let tracking = TripTrackingService()
        tracking.configure(store: relaunched, locationService: LocationService())
        XCTAssertNil(tracking.activeTrip)
        XCTAssertNil(relaunched.deviceOwnedTrip)
        tracking.startTrip(type: .maintenance, primaryPaddockId: nil, paddockIds: [], paddockName: "Second")
        XCTAssertTrue(tracking.errorMessage?.contains("Trip already in progress") == true)
        relaunched.claimDeviceTrip(UUID())
        XCTAssertEqual(relaunched.deviceActiveTripId, owned.id)
        relaunched.clearInMemoryState()
        XCTAssertEqual(relaunched.deviceActiveTripId, owned.id)
        let persisted = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        persisted.currentUserIdProvider = { firstUser }
        XCTAssertEqual(persisted.deviceActiveTripId, owned.id)
        persisted.selectedVineyardId = vineyard
        persisted.reloadCurrentVineyardData()
        XCTAssertEqual(persisted.deviceOwnedTrip?.id, owned.id)
        let originalTracking = TripTrackingService()
        originalTracking.configure(store: persisted, locationService: LocationService())
        XCTAssertEqual(originalTracking.activeTrip?.id, owned.id)
    }

    func testAuthoritativeInactiveOwnedTripReleasesOnlyMatchingOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstVineyard = UUID()
        let otherVineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = firstVineyard
        let a = Trip(vineyardId: firstVineyard, isActive: true)
        let b = Trip(vineyardId: otherVineyard, isActive: true)
        store.startTrip(a)
        store.claimDeviceTrip(a.id)
        store.selectedVineyardId = otherVineyard
        store.reloadCurrentVineyardData()
        XCTAssertEqual(store.deviceActiveTripId, a.id)
        var endedB = b
        endedB.isActive = false
        store.applyRemoteTripUpsert(endedB)
        store.applyRemoteTripDelete(b.id)
        XCTAssertEqual(store.deviceActiveTripId, a.id)
        var endedA = a
        endedA.isActive = false
        store.applyRemoteTripUpsert(endedA)
        XCTAssertEqual(store.deviceActiveTripId, a.id) // Unstarted placeholder cannot release ownership.
        endedA.endTime = Date()
        store.applyRemoteTripUpsert(endedA)
        XCTAssertNil(store.deviceActiveTripId)
        XCTAssertNil(MigratedDataStore(persistence: PersistenceStore(directory: directory)).deviceActiveTripId)
    }

    func testAuthoritativeOwnedTripDeleteReleasesOnlyMatchingOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let a = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(a)
        store.claimDeviceTrip(a.id)
        store.applyRemoteTripDelete(UUID())
        XCTAssertEqual(store.deviceActiveTripId, a.id)
        store.applyRemoteTripDelete(a.id)
        XCTAssertNil(store.deviceActiveTripId)
        XCTAssertNil(MigratedDataStore(persistence: PersistenceStore(directory: directory)).deviceActiveTripId)
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

    func testExpiredActiveCommandsPreserveTripDiskOwnershipAndRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "active-trip-held-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID(), vineyard = UUID()
        let gate = VineyardWriteAuthority(defaults: defaults)
        gate.bind(userId: user)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        store.selectedVineyardId = vineyard
        var trip = Trip(vineyardId: vineyard, isActive: true)
        trip.rowSequence = [0.5, 1.5, 2.5]
        trip.sequenceIndex = 1
        trip.currentRowNumber = 1.5
        trip.completedPaths = [0.5]
        trip.tankSessions = [TankSession(tankNumber: 1, startTime: Date(timeIntervalSince1970: 1_700_000_000))]
        trip.activeTankNumber = 1
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(store.trips)
        let diskSnapshot: () throws -> [String: Data] = {
            let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
            return try Dictionary(uniqueKeysWithValues: urls.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.map { ($0.path, try Data(contentsOf: $0)) })
        }
        let disk = try diskSnapshot()
        let corrections = tracking.diagManualCorrectionEvents
        let distance = tracking.currentDistance
        let wasTracking = tracking.isTracking
        let wasPaused = tracking.isPaused
        XCTAssertTrue(wasTracking) // configure resumes the writable active Trip before expiry.
        gate.hold(vineyardId: vineyard.uuidString, reason: VineyardWriteAuthority.holdReason)
        tracking.pauseTrip()
        tracking.resumeTrip()
        XCTAssertEqual(tracking.endTrip(), .persistenceFailed("Your trial has ended. VineTrack is currently read-only. Purchase a subscription to make changes."))
        XCTAssertThrowsError(try tracking.changeActiveRoute(pattern: .freeDrive, startPath: 2.5, higherFirst: true))
        tracking.startTankWithoutRecordedMix(expectedTripId: trip.id)
        tracking.endTank()
        tracking.startFillTimer()
        tracking.stopFillTimer()
        tracking.resetFillTimer()
        tracking.snapPlannedSequenceToCurrentLivePath()
        tracking.markCurrentPlannedPathComplete()
        tracking.skipCurrentPlannedPath()
        tracking.confirmCurrentLockedPath(2.5)
        tracking.recordManualCorrection("must not be recorded")
        tracking.advanceToNextPlannedPath()
        tracking.goBackOnePlannedPath()
        tracking.acceptAutoRealign()
        XCTAssertFalse(tracking.addPaddocksToActiveTrip([UUID()]))
        tracking.finalizePendingRowsForReview()
        tracking.selectOccurrence(UUID().uuidString)
        tracking.reorderOccurrences([])
        tracking.reviewOccurrence(UUID().uuidString, status: "done")
        tracking.processLocation(CLLocation(latitude: -33, longitude: 149), force: true)
        tracking.resumeIfNeeded()
        XCTAssertEqual(try encoder.encode(store.trips), original)
        XCTAssertEqual(try diskSnapshot(), disk)
        XCTAssertEqual(store.deviceActiveTripId, trip.id)
        XCTAssertEqual(tracking.activeTrip?.id, trip.id)
        XCTAssertEqual(tracking.diagManualCorrectionEvents, corrections)
        XCTAssertEqual(tracking.currentDistance, distance)
        XCTAssertEqual(tracking.isTracking, wasTracking)
        XCTAssertEqual(tracking.isPaused, wasPaused)
    }

    func testRestartHeldTankPreviewDoesNotRepairAndOtherVineyardCannotRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "restart-trip-held-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID(), vineyard = UUID(), paidVineyard = UUID()
        let gate = VineyardWriteAuthority(defaults: defaults)
        gate.bind(userId: user)
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        store.selectedVineyardId = vineyard
        var trip = Trip(vineyardId: vineyard, isActive: true)
        trip.rowSequence = [0.5, 1.5]
        trip.currentRowNumber = 0.5
        var endedTank = TankSession(tankNumber: 1, startTime: Date(timeIntervalSince1970: 1_700_000_000))
        endedTank.endTime = Date(timeIntervalSince1970: 1_700_000_060)
        trip.tankSessions = [endedTank]
        trip.activeTankNumber = 1 // Recovery would ordinarily reconcile this stale pointer.
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        gate.hold(vineyardId: vineyard.uuidString, reason: VineyardWriteAuthority.holdReason)
        let resumedGate = VineyardWriteAuthority(defaults: defaults)
        resumedGate.bind(userId: user)
        let resumed = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        resumed.operationalWriteAuthority = resumedGate
        resumed.currentUserIdProvider = { user }
        resumed.selectedVineyardId = vineyard
        resumed.reloadCurrentVineyardData()
        let tracking = TripTrackingService()
        tracking.configure(store: resumed, locationService: LocationService())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(resumed.trips)
        tracking.resumeIfNeeded()
        _ = tracking.pendingTankStart()
        resumedGate.verified(vineyardId: paidVineyard.uuidString, access: .init(legacyCanEnter: true, canWrite: true), explicitlyWritable: true)
        tracking.markCurrentPlannedPathComplete()
        XCTAssertEqual(try encoder.encode(resumed.trips), original)
        XCTAssertEqual(resumed.trips.first?.activeTankNumber, 1)
        XCTAssertEqual(resumed.deviceActiveTripId, trip.id)
        XCTAssertFalse(tracking.isTracking)
        resumedGate.verified(vineyardId: vineyard.uuidString, access: .init(legacyCanEnter: true, canWrite: true), explicitlyWritable: true)
        tracking.markCurrentPlannedPathComplete()
        XCTAssertTrue(resumed.trips.first?.completedPaths.contains(0.5) == true)
        XCTAssertEqual(resumed.trips.first?.id, trip.id)
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
