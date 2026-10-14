import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayStartPresentationTests {
    @Test func advisoryRecipeCanBeDurablySavedAndAdmittedForStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", startTime: time, isActive: false)
        let tank = SprayTank(concentrationFactor: 2, chemicals: [SprayChemical(name: "Unverified sulphur", ratePer100L: 100)])
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: time, startTime: time, tanks: [tank])
        try store.saveSprayForLater(record: record, trip: trip)
        #expect(SprayRepository(persistence: persistence).loadAllRecords() == [record])
        #expect(TripRepository(persistence: persistence).loadAll() == [trip])
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: record, captured: record) == nil)
        #expect(BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: time).operationalPlanningBlocker == nil)
        #expect(record.tanks == [tank])
    }

    @Test func numericFirstRateDetailsRetainDistinctUsesAndRestrictions() {
        let use = ChemicalRegisteredUse(crop: "Wine grapevines", targetRaw: "Powdery mildew",
            withholdingPeriodDays: 7, reEntryPeriodHours: 12,
            reEntryStatement: "Do not enter until dry.", restrictions: "Apply from budburst onwards. Do not exceed the seasonal maximum.")
        let rate = SpraySelectableRate(id: UUID(), origin: .registeredUse, crop: use.crop, targetRaw: use.targetRaw,
            label: "Dilute", basis: .per100Litres, seed: .range(minimum: 200, maximum: 600),
            displayText: "200–600 g/100 L", labelUnit: "g", condition: "Apply from budburst onwards.", registeredUse: use)
        #expect(rate.displayText == "200–600 g/100 L")
        #expect(rate.requiresOperatorRate)
        #expect(rate.seed.seedableValue == nil)
        #expect(rate.selectionDetails.contains(use.restrictions!))
        #expect(rate.selectionDetails.contains("Do not enter until dry."))
        #expect(rate.selectionDetails.contains("Withholding period: 7 days"))
        #expect(rate.selectionDetails.contains("Re-entry interval: 12 hours"))
        #expect(Set(rate.selectionDetails).count == rate.selectionDetails.count)
        #expect(rate.labelUnit == "g")
    }
}
