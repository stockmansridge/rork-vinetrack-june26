import Foundation
import Testing
@testable import VineTrack

struct TripEngineHourCaptureTests {
    private let vineyardId = UUID(uuidString: "90000000-0000-4000-8000-000000000001")!
    private let tractorId = UUID(uuidString: "90000000-0000-4000-8000-000000000002")!

    private func trip(start: Double?, end: Double?) -> Trip {
        var trip = Trip(
            vineyardId: vineyardId,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 11_434.2648),
            tractorId: tractorId,
            startEngineHours: start,
            endEngineHours: end
        )
        trip.pauseTimestamps = [Date(timeIntervalSince1970: 3_600)]
        trip.resumeTimestamps = [Date(timeIntervalSince1970: 4_200)]
        return trip
    }

    private func estimate(start: Double?, end: Double?) -> TripCostService.Result {
        TripCostService.estimate(
            trip: trip(start: start, end: end),
            operatorCategory: nil,
            tractor: Tractor(vineyardId: vineyardId, name: "Spray tractor", fuelUsageLPerHour: 6.8),
            fuelPurchases: [FuelPurchase(vineyardId: vineyardId, volumeLitres: 100, totalCost: 152.8)],
            sprayRecord: nil
        )
    }

    @Test("Incomplete and invalid engine-hour pairs use pause-aware duration")
    func invalidPairsUseDuration() {
        for pair in [(nil, 103.0), (100.0, nil), (nil, nil), (100.0, 100.0), (101.0, 100.0)] as [(Double?, Double?)] {
            let result = estimate(start: pair.0, end: pair.1)
            #expect(result.fuel.basis == .duration)
            #expect(abs(result.fuel.fuelHours - 3.009518) < 0.000001)
            #expect(abs(result.fuel.litres - 20.465) < 0.001)
            #expect(abs(result.fuel.cost - 31.28) < 0.01)
        }
    }

    @Test("A finite increasing engine-hour pair uses its delta")
    func validPairUsesDelta() {
        let result = estimate(start: 100, end: 102.5)
        #expect(result.fuel.basis == .engineHours)
        #expect(result.fuel.fuelHours == 2.5)
    }

    @Test("End-hour capture visibility follows the start reading")
    func endVisibility() {
        #expect(!trip(start: nil, end: nil).shouldCaptureEndEngineHours)
        #expect(trip(start: 100, end: nil).shouldCaptureEndEngineHours)
    }

    @Test("Saved spray activation persists start hours in the initial snapshot")
    @MainActor
    func activationPersistsStartHours() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let saved = Trip(vineyardId: vineyardId, isActive: false, tractorId: tractorId)
        store.addInactiveTrip(saved)
        store.addSprayRecord(SprayRecord(tripId: saved.id, vineyardId: vineyardId))
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())

        tracking.activateSavedTrip(saved, startEngineHours: 812.4)

        #expect(store.trips.first { $0.id == saved.id }?.startEngineHours == 812.4)
        #expect(TripRepository(persistence: persistence).load(for: vineyardId).first { $0.id == saved.id }?.startEngineHours == 812.4)
        #expect(saved.startEngineHours == nil)
    }
}
