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
}
