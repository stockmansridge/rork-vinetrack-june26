import Foundation
import Testing
@testable import VineTrack

struct SprayOperationalBundleTests {
    @Test func tankAllocationHasIndependentExpectedValues() {
        let fixtures: [(Double, Double, Int, Int, Double)] = [
            (350, 1000, 1, 0, 350), (1000, 1000, 1, 0, 1000),
            (2000, 1000, 2, 1, 1000), (6250, 2000, 4, 3, 250), (10000, 1, 10000, 9999, 1)
        ]
        for (water, capacity, count, full, last) in fixtures {
            let split = SprayApplicationPlanner.tankSplit(totalLitres: water, tankCapacityLitres: capacity)
            #expect(split.totalTanks == count && split.fullTankCount == full && split.lastTankLitres == last)
            #expect(Double(full) * capacity + last == water)
        }
    }

    @Test func invalidOrUnboundedTankCountsCannotTrapOrAllocate() {
        for (water, capacity) in [(Double.infinity, 1000), (1000, Double.nan), (1000, 0),
                                  (Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude), (10001, 1), (-1, 1000)] {
            #expect(SprayApplicationPlanner.tankSplit(totalLitres: water, tankCapacityLitres: capacity).totalTanks == 0)
        }
    }

    @Test func actualPer100LRateComesFromConfirmedTankNotCatalogueReference() {
        let chemical = SprayChemical(name: "Product", volumePerTank: 6000, ratePer100L: 300, unit: .millilitres, rateBasis: .per100Litres)
        #expect(SprayStartRateReview.actualRate(chemical, waterLitres: 1000) == 600)
        #expect(SprayStartRateReview.actualRate(chemical, waterLitres: 0) == nil)
    }

    @Test func baseAndDisplayUnitRecordsShowTheSameActualRate() {
        var base = SprayChemical(name: "Product", volumePerTank: 6000, ratePer100L: 300, unit: .litres, rateBasis: .per100Litres)
        var display = base
        display.quantityBasis = "display"; display.volumePerTank = 6; display.ratePer100L = 0.3
        #expect(SprayStartRateReview.actualRate(base, waterLitres: 1000) == 0.6)
        #expect(SprayStartRateReview.actualRate(display, waterLitres: 1000) == 0.6)
        base.rateBasis = .treatedArea; base.ratePerHa = 2000
        display.rateBasis = .treatedArea; display.ratePerHa = 2
        #expect(SprayStartRateReview.actualRate(base, waterLitres: 1000) == 2)
        #expect(SprayStartRateReview.actualRate(display, waterLitres: 1000) == 2)
    }

    @Test func confirmationEvidenceIgnoresGeneratedIdsButNotRecipeChanges() {
        let a = SprayTank(waterVolume: 1000, sprayRatePerHa: 500, chemicals: [SprayChemical(name: "Product", volumePerTank: 4000, ratePerHa: 2000)])
        let b = SprayTank(waterVolume: 1000, sprayRatePerHa: 500, chemicals: [SprayChemical(name: "Product", volumePerTank: 4000, ratePerHa: 2000)])
        #expect(SprayStartRateReview.evidence([a]) == SprayStartRateReview.evidence([b]))
        var changed = b; changed.chemicals[0].ratePerHa = 3000
        #expect(SprayStartRateReview.evidence([a]) != SprayStartRateReview.evidence([changed]))
        changed = b; changed.waterVolume = 900
        #expect(SprayStartRateReview.evidence([a]) != SprayStartRateReview.evidence([changed]))
    }

    @Test func advisoryMetadataDoesNotBlockValidRateConfirmation() {
        let tank = SprayTank(waterVolume: 1000, concentrationFactor: 4, chemicals: [
            SprayChemical(name: "Manually entered product", volumePerTank: 12000, ratePer100L: 300, rateBasis: .per100Litres)
        ])
        #expect(SprayStartRateReview.isReviewable([tank]))
        #expect(SprayStartRecipeValidation.blocker([tank]) == nil)
        #expect(!SprayStartRateReview.isReviewable([]))
    }

    @MainActor @Test func oldUploadAcknowledgementCannotEraseANewerLocalEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PersistenceStore(directory: directory)
        let metadata = ManagementSyncMetadata(key: "bundle-ack", persistence: disk)
        let id = UUID(), first = Date(timeIntervalSince1970: 100), second = Date(timeIntervalSince1970: 101)
        metadata.markDirty(id, at: first)
        let sent = metadata.pendingUpserts
        metadata.markDirty(id, at: second)
        metadata.clearDirty([id], acknowledged: sent)
        #expect(metadata.pendingUpserts[id] == second)
        #expect(ManagementSyncMetadata(key: "bundle-ack", persistence: disk).pendingUpserts[id] == second)
        metadata.clearDirty([id], acknowledged: [id: second])
        #expect(metadata.pendingUpserts.isEmpty)
    }
}
