import XCTest
import CoreLocation
@testable import VineTrack

@MainActor
final class InTripPinDuplicateTests: XCTestCase {
    func testTypeScopedWarningAndOneAttemptBypass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trip-pin-duplicate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vineyardId = UUID()
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        store.startTrip(Trip(vineyardId: vineyardId, isActive: true))

        let coordinate = CLLocationCoordinate2D(latitude: -34.0, longitude: 138.0)
        let existing = VinePin(
            vineyardId: vineyardId,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            heading: nil,
            buttonName: "Broken Post",
            buttonColor: "brown",
            side: nil,
            mode: .repairs
        )
        store.addPin(existing)

        let locationService = LocationService()
        func setFreshLocation() {
            locationService.location = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: 2,
                verticalAccuracy: 2,
                timestamp: Date()
            )
        }
        setFreshLocation()
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: locationService)

        let irrigation = ButtonConfig(
            vineyardId: vineyardId,
            name: "Irrigation",
            color: "blue",
            index: 0,
            mode: .repairs
        )
        let countBeforeDifferentType = store.pins.count
        setFreshLocation()
        guard case .created = tracking.dropPinDuringTrip(button: irrigation) else {
            XCTFail("A nearby different pin type must be created without warning")
            return
        }
        XCTAssertEqual(store.pins.count, countBeforeDifferentType + 1)

        let broken = ButtonConfig(
            vineyardId: vineyardId,
            name: "Broken Post",
            color: "brown",
            index: 1,
            mode: .repairs
        )
        let countBeforeWarning = store.pins.count
        setFreshLocation()
        guard case let .duplicateNearby(matched, _, _) = tracking.dropPinDuringTrip(button: broken) else {
            XCTFail("A nearby open Broken Post must warn; diagnostic=\(tracking.diagDuplicateCheckResult ?? "nil")")
            return
        }
        XCTAssertEqual(matched.id, existing.id)
        XCTAssertEqual(store.pins.count, countBeforeWarning)

        setFreshLocation()
        guard case .created = tracking.dropPinDuringTrip(button: broken, force: true) else {
            XCTFail("Create anyway must create the requested pin")
            return
        }
        XCTAssertEqual(store.pins.count, countBeforeWarning + 1)

        setFreshLocation()
        guard case .duplicateNearby = tracking.dropPinDuringTrip(button: broken) else {
            XCTFail("Create anyway must not disable future duplicate checks")
            return
        }
        XCTAssertEqual(store.pins.count, countBeforeWarning + 1)
    }
}
