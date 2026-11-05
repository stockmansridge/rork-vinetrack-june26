import Foundation
import XCTest
@testable import VineTrack

/// Trip start → end closure: every open item (pause, fill timer, tank) is
/// closed on the saved record, and engine-hour readings round-trip.
@MainActor
final class TripFlowClosureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeActiveTrip() -> (MigratedDataStore, TripTrackingService, Trip) {
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, isActive: true)
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        return (store, tracking, trip)
    }

    private func persisted(_ id: UUID, vineyard: UUID) -> Trip? {
        let reloaded = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        reloaded.selectedVineyardId = vineyard
        reloaded.reloadCurrentVineyardData()
        return reloaded.trips.first { $0.id == id }
    }

    func testEndingWhilePausedSavesAClosedTripAndKeepsPausedTimeExcluded() throws {
        let (store, tracking, trip) = makeActiveTrip()
        tracking.pauseTrip()
        XCTAssertEqual(store.trips.first { $0.id == trip.id }?.isPaused, true)
        let durationAtPause = try XCTUnwrap(store.trips.first { $0.id == trip.id }).activeDuration

        XCTAssertEqual(tracking.endTrip(), .ended)

        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertFalse(saved.isActive)
        XCTAssertNotNil(saved.endTime)
        XCTAssertFalse(saved.isPaused, "An ended trip must not be saved as paused")
        XCTAssertEqual(saved.pauseTimestamps.count, 1)
        // Stored timestamps may drop sub-second precision.
        XCTAssertEqual(saved.activeDuration, durationAtPause, accuracy: 2.0)
        XCTAssertNil(store.deviceActiveTripId)
        XCTAssertFalse(tracking.isTracking)
        XCTAssertFalse(tracking.isPaused)
    }

    func testPauseAndResumeArePersistedImmediately() throws {
        let (_, tracking, trip) = makeActiveTrip()
        tracking.pauseTrip()
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId)?.isPaused, true)
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId)?.pauseTimestamps.count, 1)
        tracking.resumeTrip()
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId)?.isPaused, false)
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId)?.resumeTimestamps.count, 1)
    }

    func testRunningFillBlocksPlainEndAndStopFillAndEndClosesItFirst() throws {
        let (_, tracking, trip) = makeActiveTrip()
        tracking.startFillTimer()
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId)?.isFillingTank, true)

        guard case .blocked(.fillingTank) = tracking.endTrip() else {
            return XCTFail("A running fill must still block a plain End Trip")
        }
        XCTAssertTrue(tracking.activeTrip?.isActive == true)

        XCTAssertEqual(tracking.stopFillAndEndTrip(), .ended)
        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertFalse(saved.isActive)
        XCTAssertNotNil(saved.endTime)
        XCTAssertFalse(saved.isFillingTank)
        XCTAssertNil(saved.fillingTankNumber)
        XCTAssertFalse(saved.tankSessions.contains { $0.fillStartTime != nil && $0.fillEndTime == nil },
                       "No fill timer may be left open on an ended trip")
    }

    func testManualCorrectionsAreSavedOnTheEndedTrip() throws {
        let (_, tracking, trip) = makeActiveTrip()
        tracking.recordManualCorrection("end_review_finalised")
        XCTAssertEqual(tracking.endTrip(), .ended)
        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertTrue(saved.manualCorrectionEvents.contains { $0.hasSuffix("end_review_finalised") })
    }

    func testReviewPreviewNeverChangesTheLiveTrip() throws {
        let (store, tracking, trip) = makeActiveTrip()
        let before = try XCTUnwrap(store.trips.first { $0.id == trip.id })
        let diskBefore = persisted(trip.id, vineyard: trip.vineyardId)
        _ = tracking.pendingRowCreditsForReview()
        XCTAssertEqual(store.trips.first { $0.id == trip.id }, before)
        // Compare disk to disk: stored timestamps are second-precision.
        XCTAssertEqual(persisted(trip.id, vineyard: trip.vineyardId), diskBefore)
    }

    private func makeActiveTrip(_ configure: (inout Trip) -> Void) -> (MigratedDataStore, TripTrackingService, Trip) {
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyard
        var trip = Trip(vineyardId: vineyard, isActive: true)
        configure(&trip)
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        return (store, tracking, trip)
    }

    func testEndingWithARunningTankFinishesTheTankThenEndsTheTrip() throws {
        let (store, tracking, trip) = makeActiveTrip { trip in
            trip.tankSessions = [
                TankSession(tankNumber: 1, startTime: Date().addingTimeInterval(-3600),
                            endTime: Date().addingTimeInterval(-1800), startRow: 1.5, endRow: 9.5),
                TankSession(tankNumber: 2, startTime: Date().addingTimeInterval(-1700), startRow: 10.5),
            ]
            trip.activeTankNumber = 2
            trip.totalTanks = 2
        }
        XCTAssertEqual(tracking.endTrip(), .ended)
        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertFalse(saved.isActive)
        XCTAssertNotNil(saved.endTime)
        XCTAssertNil(saved.activeTankNumber)
        XCTAssertTrue(saved.tankSessions.allSatisfy { $0.endTime != nil }, "Every tank must be finished on an ended trip")
        let tank2 = try XCTUnwrap(saved.tankSessions.first { $0.tankNumber == 2 })
        // Tank first, then Trip (allowing for second-precision Trip timestamps).
        XCTAssertLessThanOrEqual(try XCTUnwrap(tank2.endTime), try XCTUnwrap(saved.endTime).addingTimeInterval(1))
        XCTAssertNil(store.deviceActiveTripId)
    }

    func testEndingWithAnOpenTankWhoseActivePointerWasLostStillFinishesIt() throws {
        let (_, tracking, trip) = makeActiveTrip { trip in
            trip.tankSessions = [TankSession(tankNumber: 1, startTime: Date().addingTimeInterval(-600), startRow: 2.5)]
            trip.activeTankNumber = nil
            trip.totalTanks = 1
        }
        XCTAssertEqual(tracking.endTrip(), .ended)
        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertNotNil(saved.endTime)
        XCTAssertNotNil(saved.tankSessions.first?.endTime)
        XCTAssertNil(saved.activeTankNumber)
    }

    func testServerEndedTripStopsTrackingAndClosesItOnTheDevice() throws {
        let (store, tracking, trip) = makeActiveTrip()
        tracking.currentDistance = 250
        tracking.currentPaddockName = "Block B"
        var ended = try XCTUnwrap(store.trips.first { $0.id == trip.id })
        ended.isActive = false
        ended.endTime = Date()
        store.applyRemoteTripUpsert(ended)

        XCTAssertNil(store.deviceActiveTripId, "The device must release a trip the server finished")
        XCTAssertNil(tracking.activeTrip)
        XCTAssertFalse(tracking.isTracking)
        XCTAssertEqual(tracking.currentDistance, 0)
        XCTAssertNil(tracking.currentPaddockName)
        XCTAssertEqual(tracking.lastServerCompletedTripId, trip.id)
        let saved = try XCTUnwrap(persisted(trip.id, vineyard: trip.vineyardId))
        XCTAssertFalse(saved.isActive)
        XCTAssertNotNil(saved.endTime)
    }

    func testEndTripClearsLiveStateForTheNextTrip() throws {
        let (_, tracking, _) = makeActiveTrip()
        tracking.currentDistance = 120
        tracking.currentPaddockName = "Block A"
        tracking.currentRowNumber = 4.5
        XCTAssertEqual(tracking.endTrip(), .ended)
        XCTAssertEqual(tracking.currentDistance, 0)
        XCTAssertNil(tracking.currentPaddockName)
        XCTAssertNil(tracking.currentRowNumber)
        XCTAssertNil(tracking.activeTrip)
    }
}

final class EngineHoursInputTests: XCTestCase {
    func testParsesGroupedAndLocaleDecimalReadings() {
        XCTAssertEqual(EngineHoursInput.parse("1234.5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("1,234.5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("1.234,5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("1234,5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("1,234"), 1234)
        XCTAssertEqual(EngineHoursInput.parse("1 234,5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("1\u{202F}234.5"), 1234.5)
        XCTAssertEqual(EngineHoursInput.parse("12,345,678"), 12_345_678)
        XCTAssertEqual(EngineHoursInput.parse(" 941 "), 941)
        XCTAssertEqual(EngineHoursInput.parse("0.5"), 0.5)
    }

    func testRejectsUnreadableInput() {
        XCTAssertNil(EngineHoursInput.parse(""))
        XCTAssertNil(EngineHoursInput.parse("   "))
        XCTAssertNil(EngineHoursInput.parse("abc"))
        XCTAssertNil(EngineHoursInput.parse("-5"))
        XCTAssertNil(EngineHoursInput.parse("1.2.3,4,5"))
        XCTAssertNil(EngineHoursInput.parse("12h"))
    }

    func testEditableTextAlwaysParsesBackToTheSameReading() {
        for value in [0, 0.5, 941, 1021.6, 1234.5, 5212, 99_999.9] {
            let text = EngineHoursInput.editableText(value)
            XCTAssertFalse(text.contains(","), "Pre-filled text must not contain grouping: \(text)")
            XCTAssertEqual(EngineHoursInput.parse(text), value, "\(text)")
        }
    }
}
