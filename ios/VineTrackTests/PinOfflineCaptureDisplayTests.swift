import CoreLocation
import XCTest
@testable import VineTrack

final class PinOfflineCaptureDisplayTests: XCTestCase {
    func testCircularMeanHandlesNorthWraparound() {
        let now = Date()
        let samples = [
            LocationService.HeadingObservation(degrees: 359, observedAt: now.addingTimeInterval(-2)),
            LocationService.HeadingObservation(degrees: 1, observedAt: now.addingTimeInterval(-1)),
        ]
        let mean = LocationService.circularMean(observations: samples, now: now)
        XCTAssertNotNil(mean)
        XCTAssertTrue((mean ?? 180) < 2 || (mean ?? 180) > 358)
    }

    func testCircularMeanRejectsExpiredDisplaySamples() {
        let now = Date()
        let samples = [LocationService.HeadingObservation(degrees: 90, observedAt: now.addingTimeInterval(-4))]
        XCTAssertNil(LocationService.circularMean(observations: samples, now: now, window: 3))
    }

    func testHeadingHysteresisRetainsBriefBoundaryNoiseThenAcceptsTurn() {
        let retained = LocationService.hystereticHeading(candidate: 16, previous: 0)
        XCTAssertEqual(retained, 0)
        let turned = LocationService.hystereticHeading(candidate: 18, previous: 0)
        XCTAssertEqual(turned, 18)
    }

    func testHeadingHysteresisClearsExpiredGuidance() {
        XCTAssertNil(LocationService.hystereticHeading(candidate: nil, previous: 90))
    }

    func testCaptureIdentityAndGpsTimeRemainFrozen() {
        let pinId = UUID()
        let capturedAt = Date()
        let observedAt = capturedAt.addingTimeInterval(-1)
        let capture = PinCaptureContext(
            pinId: pinId,
            capturedAt: capturedAt,
            locationObservedAt: observedAt,
            vineyardId: UUID(),
            tripId: nil,
            rawCoordinate: .init(latitude: -33.1, longitude: 149.1),
            horizontalAccuracyMetres: 4
        )
        XCTAssertEqual(capture.pinId, pinId)
        XCTAssertEqual(capture.locationObservedAt, observedAt)
    }

    func testConfirmationHeadingUsesCircularNorthMean() {
        let capturedAt = Date()
        let heading = PinCaptureEvidence.confirmationHeading(
            for: makeEvidence(capturedAt: capturedAt, courses: [359, 1, 0])
        )
        XCTAssertNotNil(heading)
        XCTAssertTrue((heading ?? 180) < 2 || (heading ?? 180) > 358)
    }

    func testConfirmationHeadingRejectsContradictoryCourses() {
        let evidence = makeEvidence(capturedAt: Date(), courses: [0, 180, 90])
        XCTAssertNil(PinCaptureEvidence.confirmationHeading(for: evidence))
    }

    func testCompassOppositeTravelCannotChooseConfirmationDirection() {
        let now = Date()
        let evidence = makeEvidence(capturedAt: now, courses: [0, 0, 0], compass: 180)
        XCTAssertEqual(PinCaptureEvidence.confirmationHeading(for: evidence) ?? -1, 0, accuracy: 0.01)
        let compassOnly = makeEvidence(capturedAt: now, courses: [], compass: 180)
        XCTAssertNil(PinCaptureEvidence.confirmationHeading(for: compassOnly))
    }

    func testMovementRejectsStationaryPoorDuplicateStaleAndShortDisplacement() {
        let now = Date()
        let good = makeEvidence(capturedAt: now, courses: [0, 0, 0]).observations
        func change(_ sample: PinCaptureObservation, latitude: Double? = nil, accuracy: Double? = nil, speed: Double? = nil) -> PinCaptureObservation {
            PinCaptureObservation(observedAt: sample.observedAt, latitude: latitude ?? sample.latitude,
                                  longitude: sample.longitude, horizontalAccuracyM: accuracy ?? sample.horizontalAccuracyM,
                                  courseDegrees: sample.courseDegrees, speedMps: speed ?? sample.speedMps)
        }
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: good.map { change($0, latitude: -33) }, capturedAt: now))
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: good.map { change($0, accuracy: 8) }, capturedAt: now))
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: good.map { change($0, speed: 0.2) }, capturedAt: now))
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: [good[0], good[0], good[2]], capturedAt: now))
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: good, capturedAt: now.addingTimeInterval(20)))
        let justStopped = good + [PinCaptureObservation(observedAt: now, latitude: good.last!.latitude,
            longitude: 149, horizontalAccuracyM: 0.4, courseDegrees: 0, speedMps: 0)]
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: justStopped, capturedAt: now))
        XCTAssertNil(PinCaptureEvidence.qualifiedTravelDirection(observations: good.enumerated().map { change($0.element, latitude: -33 + Double($0.offset) * 0.00001) }, capturedAt: now))
    }

    @MainActor
    func testServerConfirmationMergesLocationWithoutLosingOfflineNotesOrOriginalGps() throws {
        let id = UUID(), vineyard = UUID()
        let data = Data("""
        {"id":"\(id)","vineyard_id":"\(vineyard)","latitude":-33,"longitude":149,"is_completed":false,
         "pin_row_number":33,"driving_row_number":32.5,"pin_side":"Right","snapped_latitude":-33.0001,
         "snapped_longitude":149.00004,"snapped_to_row":true,"sync_version":9,"location_confirmation_revision":2}
        """.utf8)
        let remote = try JSONDecoder().decode(BackendPin.self, from: data)
        let local = VinePin(id: id, vineyardId: vineyard, latitude: -33.1, longitude: 149.1, heading: nil,
                            buttonName: "Repair", buttonColor: "red", side: .right, mode: .repairs,
                            notes: "Offline note", syncVersion: 3)
        let merged = try XCTUnwrap(remote.mergingConfirmedLocation(into: local))
        XCTAssertEqual(merged.notes, "Offline note")
        XCTAssertEqual(merged.latitude, local.latitude)
        XCTAssertEqual(merged.longitude, local.longitude)
        XCTAssertEqual(merged.pinRowNumber, 33)
        XCTAssertEqual(merged.pinSide, .right)
        XCTAssertEqual(merged.drivingRowNumber, 32.5)
        XCTAssertTrue(merged.snappedToRow)
        XCTAssertEqual(merged.locationConfirmationRevision, 2)
        XCTAssertEqual(merged.syncVersion, 9)
        let restored = try JSONDecoder().decode(VinePin.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(restored.locationConfirmationRevision, 2)
        XCTAssertEqual(restored.changingType(buttonName: "Post", buttonColor: "blue", mode: .repairs).locationConfirmationRevision, 2)
        XCTAssertNil(remote.mergingConfirmedLocation(into: restored))
    }

    @MainActor
    func testRowOnlyConfirmationClearsSnapAndCannotBorrowAnotherPinIdentity() throws {
        let id = UUID(), vineyard = UUID()
        let remote = try JSONDecoder().decode(BackendPin.self, from: Data("""
        {"id":"\(id)","vineyard_id":"\(vineyard)","latitude":-33,"longitude":149,"is_completed":false,
         "pin_row_number":34,"snapped_to_row":false,"sync_version":9,"location_confirmation_revision":2}
        """.utf8))
        let local = VinePin(id: id, vineyardId: vineyard, latitude: -33.1, longitude: 149.1, heading: nil,
                            buttonName: "Repair", buttonColor: "red", side: .right, mode: .repairs,
                            drivingRowNumber: 32.5, pinRowNumber: 33, snappedLatitude: -33.01,
                            snappedLongitude: 149.01, snappedToRow: true, syncVersion: 3)
        let merged = try XCTUnwrap(remote.mergingConfirmedLocation(into: local))
        XCTAssertEqual(merged.pinRowNumber, 34)
        XCTAssertNil(merged.drivingRowNumber)
        XCTAssertNil(merged.pinSide)
        XCTAssertNil(merged.snappedLatitude)
        XCTAssertNil(merged.snappedLongitude)
        XCTAssertFalse(merged.snappedToRow)
        XCTAssertEqual(merged.latitude, local.latitude)
        XCTAssertNil(remote.mergingConfirmedLocation(into: VinePin(vineyardId: vineyard,
            latitude: -33, longitude: 149, heading: nil, buttonName: "Other", buttonColor: "red", side: nil, mode: .repairs)))
    }

    func testContentReplayPayloadNeverContainsLocationOrCaptureKeys() throws {
        let pin = VinePin(latitude: -33, longitude: 149, heading: 180, buttonName: "Repair", buttonColor: "red",
                          side: .left, mode: .repairs, rowNumber: 32, notes: "Offline note", drivingRowNumber: 32.5,
                          pinRowNumber: 32, snappedLatitude: -33.1, snappedLongitude: 149.1, snappedToRow: true)
        let patch = BackendPinContentPatch(pin: BackendPin.upsert(from: pin, clientUpdatedAt: Date()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        XCTAssertEqual(object["notes"] as? String, "Offline note")
        for key in ["latitude", "longitude", "heading", "side", "row_number", "paddock_id", "trip_id", "created_at", "created_by",
                    "pin_row_number", "pin_side", "driving_row_number", "snapped_latitude", "snapped_longitude", "snapped_to_row",
                    "sync_version", "location_confirmation_revision", "location_scope"] {
            XCTAssertNil(object[key], key)
        }
    }

    func testEvidenceRoundTripRetainsObservationsAndDiagnosticCompass() throws {
        let original = makeEvidence(capturedAt: Date(), courses: [0, 0, 0], compass: 180)
        let restored = try JSONDecoder().decode(PinCaptureEvidence.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, restored)
        XCTAssertEqual(restored.headingDegrees, 180)
        XCTAssertEqual(PinCaptureEvidence.confirmationHeading(for: restored) ?? -1, 0, accuracy: 0.01)
    }

    @MainActor
    func testImmutableEvidenceSurvivesDurableRestartAndRejectsChangedRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = makeEvidence(capturedAt: Date(timeIntervalSince1970: 1_790_000_000.125), courses: [0, 0, 0], compass: 180)
        let store = PinCaptureEvidenceStore(persistence: PersistenceStore(directory: directory))
        try store.save(original)
        let restarted = PinCaptureEvidenceStore(persistence: PersistenceStore(directory: directory))
        XCTAssertEqual(restarted.evidence(pinId: original.pinId), original)
        XCTAssertNoThrow(try restarted.save(original))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["raw_latitude"] = -34.0
        let changed = try JSONDecoder().decode(PinCaptureEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try restarted.save(changed))
        try restarted.markUploaded([original.id])
        let acknowledged = PinCaptureEvidenceStore(persistence: PersistenceStore(directory: directory))
        XCTAssertTrue(acknowledged.pending.isEmpty)
        XCTAssertNoThrow(try acknowledged.save(original))
        XCTAssertEqual(acknowledged.records.count, 1)
        XCTAssertEqual(acknowledged.evidence(pinId: original.pinId)?.rawLatitude, original.rawLatitude)
    }

    private func makeEvidence(capturedAt: Date, courses: [Double], compass: Double? = nil) -> PinCaptureEvidence {
        let observations = courses.enumerated().map { index, course in
            PinCaptureObservation(
                observedAt: capturedAt.addingTimeInterval(Double(index - courses.count)),
                latitude: -33 + Double(index) * 0.00003,
                longitude: 149,
                horizontalAccuracyM: 0.4,
                courseDegrees: course,
                speedMps: 1
            )
        }
        return PinCaptureEvidence(
            pinId: UUID(), vineyardId: UUID(), evidenceRevision: 1, resolverVersion: "fixture",
            capturedAt: capturedAt, locationObservedAt: capturedAt, rawLatitude: -32.99998,
            rawLongitude: 149, horizontalAccuracyM: 0.4, headingDegrees: compass,
            headingSource: compass == nil ? nil : "device_true_heading", headingObservedAt: compass == nil ? nil : capturedAt, pressedSide: "Left", tripId: nil,
            captureUserId: UUID(), captureButtonName: "Fixture", captureMode: "Repairs",
            supportedPaddockId: nil, supportedDrivingRow: nil, supportedPinRow: nil,
            supportedPinSide: nil, supportedSnappedLatitude: nil, supportedSnappedLongitude: nil,
            supportedAlongRowDistanceM: nil, aisleLock: nil, observations: observations,
            captureProvenance: [:], geometryRevision: nil, geometryHash: nil, isUploaded: false
        )
    }
}
