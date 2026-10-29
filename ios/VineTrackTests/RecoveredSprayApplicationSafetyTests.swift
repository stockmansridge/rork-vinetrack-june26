import XCTest
import Foundation
@testable import VineTrack

final class RecoveredSprayApplicationSafetyTests: XCTestCase {
    func testBaseMillilitresLitresAndRateDenominatorsRemainDistinctWithoutRewritingOriginal() throws {
        let chemical = SprayChemical(name: "Spotlight Plus", volumePerTank: 1000, ratePerHa: 125, ratePer100L: 50,
            unit: .litres, rateBasis: .per100Litres)
        var record = SprayRecord(tripId: UUID(), vineyardId: UUID(), tanks: [SprayTank(tankNumber: 1,
            waterVolume: 2000, sprayRatePerHa: 250, chemicals: [chemical,
                SprayChemical(name: "SPRAY.SEED", volumePerTank: 2500, ratePer100L: 125, unit: .millilitres)])])
        record.recoveredFromServerOrphan = true
        let original = record
        XCTAssertEqual(ChemicalUnit.litres.fromBase(1000), 1)
        XCTAssertEqual(ChemicalUnit.litres.toBase(1), 1000)
        XCTAssertEqual(ChemicalUnit.millilitres.fromBase(1000), 1000)
        XCTAssertFalse(ChemicalUnit.litres.isDimensionallyCompatible(with: .grams))
        XCTAssertNotNil(RecoveredSprayApplicationSafety.blocker(record))
        let diagnostic = RecoveredSprayApplicationSafety.diagnostic(record)
        XCTAssertTrue(diagnostic.contains("amountBase=1000.0 mL"))
        XCTAssertTrue(diagnostic.contains("display=1.0 Litres"))
        XCTAssertTrue(diagnostic.contains("per100LBase=50.0; perHaBase=125.0"))
        XCTAssertEqual(record, original)
        record.recoveredFromServerOrphan = false
        XCTAssertNil(RecoveredSprayApplicationSafety.blocker(record), "Unrelated ordinary workflows remain unchanged")
    }

    @MainActor func testReviewOrAcceptedIdentityReceiptCannotActivateUnverifiedMixOrConsumeOriginalJournal() throws {
        for linkAccepted in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let persistence = PersistenceStore(directory: root), owner = UUID(), vineyard = UUID()
            let store = MigratedDataStore(persistence: persistence)
            let blocks = (0..<8).map { _ in UUID() }
            let coverage = try TripOccurrencePlanner.commit((0..<116).map { index in
                .init(vineyardId: vineyard, blockId: blocks[index % 8], blockName: "Original retained fixture", label: Double(index) + 0.5, rows: [])
            }, vineyardId: vineyard)
            let trip = Trip(vineyardId: vineyard, paddockName: "Original retained fixture", paddockIds: blocks,
                isActive: false, rowSequence: (0..<116).map { Double($0) + 0.5 }, occurrenceCoverage: coverage)
            var record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: (1...2).map { number in
                SprayTank(tankNumber: number, waterVolume: 400, sprayRatePerHa: 200,
                    chemicals: [SprayChemical(name: "Spotlight Plus", volumePerTank: 1000, ratePer100L: 250, unit: .litres),
                        SprayChemical(name: "SPRAY.SEED", volumePerTank: 4000, ratePer100L: 1000, unit: .millilitres)])
            })
            record.recoveredFromServerOrphan = true; record.recoveredOrphanLinkAccepted = linkAccepted
            store.trips = [trip]; store.sprayRecords = [record]; store.selectedVineyardId = vineyard
            store.currentUserIdProvider = { owner }
            let journal = try TripOccurrenceJournal(scope: .init(ownerId: owner.uuidString.lowercased(),
                vineyardId: vineyard.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
            try SupabaseTripSyncRepository().prepareOccurrenceCreation(
                BackendTrip.upsert(from: trip, createdBy: owner, clientUpdatedAt: trip.startTime), ownerId: owner)
            let before = try journal.load()
            let tracking = TripTrackingService(); tracking.configure(store: store, locationService: LocationService())
            var callbacks: [Bool] = [], publications = 0
            store.onTripChanged = { _ in publications += 1 }
            tracking.activateSavedTrip(trip) { callbacks.append($0) }
            XCTAssertEqual(callbacks, [false])
            XCTAssertEqual(tracking.errorMessage, RecoveredSprayApplicationSafety.blocker(record))
            XCTAssertTrue(tracking.lastSprayStartDiagnostic?.contains(RecoveredSprayApplicationSafety.reasonCode) == true)
            XCTAssertEqual(store.trips, [trip]); XCTAssertEqual(store.sprayRecords, [record])
            XCTAssertNil(store.deviceActiveTripId); XCTAssertEqual(publications, 0)
            XCTAssertEqual(try journal.load(), before, "No replacement/acknowledgement/activation fabricated")
        }
    }
}
