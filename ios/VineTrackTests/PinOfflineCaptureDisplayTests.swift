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

    private func makeEvidence(capturedAt: Date, courses: [Double]) -> PinCaptureEvidence {
        let observations = courses.enumerated().map { index, course in
            PinCaptureObservation(
                observedAt: capturedAt.addingTimeInterval(Double(index - courses.count)),
                latitude: -33 + Double(index) * 0.00001,
                longitude: 149,
                horizontalAccuracyM: 0.4,
                courseDegrees: course,
                speedMps: 1
            )
        }
        return PinCaptureEvidence(
            pinId: UUID(), vineyardId: UUID(), evidenceRevision: 1, resolverVersion: "fixture",
            capturedAt: capturedAt, locationObservedAt: capturedAt, rawLatitude: -32.99998,
            rawLongitude: 149, horizontalAccuracyM: 0.4, headingDegrees: nil,
            headingSource: nil, headingObservedAt: nil, pressedSide: "Left", tripId: nil,
            captureUserId: UUID(), captureButtonName: "Fixture", captureMode: "Repairs",
            supportedPaddockId: nil, supportedDrivingRow: nil, supportedPinRow: nil,
            supportedPinSide: nil, supportedSnappedLatitude: nil, supportedSnappedLongitude: nil,
            supportedAlongRowDistanceM: nil, aisleLock: nil, observations: observations,
            captureProvenance: [:], geometryRevision: nil, geometryHash: nil, isUploaded: false
        )
    }
}
