import Foundation
import Testing
@testable import VineTrack

private final class YieldFixtureBundle: NSObject {}
private struct YieldParityFixture: Decodable {
    struct Planting: Decodable { let key: String; let name: String; let share: Double }
    struct Block: Decodable { let id: UUID; let name: String; let vines: Int; let sideMetres: Double; let counts: [Double]; let remaining: Double; let plantings: [Planting] }
    struct Resolution: Decodable { let block: Int; let key: String; let grams: Double; let source: String }
    let vineyardId: UUID; let tripId: UUID; let blocks: [Block]; let resolutions: [Resolution]
    let expectedWeightsKg: [Double]; let expectedBaseTonnes: [Double]; let expectedAdjustedTonnes: [Double]
    let expectedTotalBase: Double; let expectedTotalAdjusted: Double; let expectedSampledAreaHa: Double; let expectedPerHa: Double
    var paddocks: [Paddock] { blocks.map { b in
        let d = b.sideMetres / 111320
        return Paddock(id: b.id, vineyardId: vineyardId, name: b.name,
            polygonPoints: [CoordinatePoint(latitude: 0, longitude: 0), CoordinatePoint(latitude: d, longitude: 0), CoordinatePoint(latitude: d, longitude: d), CoordinatePoint(latitude: 0, longitude: d)],
            vineCountOverride: b.vines, varietyAllocations: b.plantings.map {
                PaddockVarietyAllocation(varietyId: vineyardId, percent: $0.share, name: $0.name, varietyKey: $0.key)
            })
    } }
    var weights: [String: YieldMasterWeight] { Dictionary(uniqueKeysWithValues: resolutions.map {
        (CurrentYieldEstimate.key(blockId: blocks[$0.block].id, varietyKey: $0.key), YieldMasterWeight(bunchWeightGrams: $0.grams, source: $0.source, recordId: tripId, varietyKey: $0.key))
    }) }
    var session: YieldEstimationSession {
        YieldEstimationSession(id: tripId, vineyardId: vineyardId, createdAt: Date(timeIntervalSince1970: 1792000000),
            selectedPaddockIds: blocks.map(\.id), sampleSites: blocks.flatMap { b in
                b.counts.enumerated().map { i, count in SampleSite(paddockId: b.id, rowNumber: 1, latitude: 0, longitude: 0, siteIndex: i + 1, bunchCountEntry: BunchCountEntry(bunchesPerVine: count)) }
                + [SampleSite(paddockId: b.id, rowNumber: 2, latitude: 0, longitude: 0, siteIndex: 99)]
            }, blockBunchWeightsKg: Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, 0.15) }),
            isCompleted: true, completedAt: Date(timeIntervalSince1970: 1792100000),
            blockVineCounts: Dictionary(uniqueKeysWithValues: blocks.map { ($0.id.uuidString.lowercased(), 1) }))
    }
    func trip(_ session: YieldEstimationSession? = nil, weights: [String: YieldMasterWeight]? = nil) -> CurrentYieldEstimate.Trip {
        CurrentYieldEstimate.trip(session: session ?? self.session, paddocks: paddocks, weights: weights ?? self.weights,
            remaining: { id in blocks.first { $0.id == id }!.remaining })
    }
}

@MainActor struct CurrentYieldMasterParityTests {
    private func fixture() throws -> YieldParityFixture {
        let url = try #require(Bundle(for: YieldFixtureBundle.self).url(forResource: "yield-master-parity", withExtension: "json"))
        return try JSONDecoder().decode(YieldParityFixture.self, from: Data(contentsOf: url))
    }
    @Test func sharedOverrideMasterAndMixedWeights() throws {
        let f = try fixture(); let t = f.trip()
        for i in 0..<3 { #expect(abs(try #require(t.blocks[i].weightKg) - f.expectedWeightsKg[i]) < 1e-12) }
        #expect(t.blocks[0].weightSources == ["Renamed Shiraz: Block override"])
        #expect(t.blocks[1].weightSources == ["Merlot: Vineyard variety master"])
    }
    @Test func sharedBaseTonnesAndCurrentAuthoritativeVines() throws {
        let f = try fixture(); let t = f.trip()
        for i in 0..<3 {
            #expect(t.blocks[i].vines == f.blocks[i].vines)
            #expect(abs(try #require(t.blocks[i].baseTonnes) - f.expectedBaseTonnes[i]) < 1e-12)
        }
    }
    @Test func sharedDamageAndTripTotals() throws {
        let f = try fixture(); let t = f.trip()
        for i in 0..<3 { #expect(abs(try #require(t.blocks[i].adjustedTonnes) - f.expectedAdjustedTonnes[i]) < 1e-12) }
        #expect(abs(try #require(t.totalTonnes) - f.expectedTotalAdjusted) < 1e-12)
    }
    @Test func sampledAreaExcludesPlannedBlock() throws {
        let f = try fixture(); let t = f.trip()
        #expect(abs(t.sampledAreaHa - f.expectedSampledAreaHa) < 1e-8)
        #expect(abs(try #require(t.tonnesPerHa) - f.expectedPerHa) < 1e-8)
        #expect(t.blocks[3].sampledAreaHa == 0)
    }
    @Test func missingMixedVarietyWithholdsWholeBlockAndTrip() throws {
        let f = try fixture(); var w = f.weights
        w.removeValue(forKey: CurrentYieldEstimate.key(blockId: f.blocks[2].id, varietyKey: "merlot"))
        let t = f.trip(weights: w)
        #expect(t.blocks[2].weightKg == nil && t.blocks[2].baseTonnes == nil)
        #expect(t.totalTonnes == nil && t.tonnesPerHa == nil)
        #expect(t.blocks[0].displayTonnes != nil)
    }
    @Test func historicalWeightNeverBecomesCurrent() throws {
        let f = try fixture(); let t = f.trip(weights: [:])
        #expect(t.blocks[0].historicalWeightKg == 0.15)
        #expect(t.blocks[0].weightKg == nil && t.totalTonnes == nil)
    }
    @Test func storedKeyWinsOverRenamedDisplay() throws {
        let f = try fixture(); #expect(CurrentYieldEstimate.plantings(f.paddocks[0])[0].key == "shiraz")
    }
    @Test func onlyAbsentStoredKeyUsesNameFallback() throws {
        let f = try fixture(); var p = f.paddocks[0]; p.varietyAllocations[0].varietyKey = nil
        #expect(CurrentYieldEstimate.plantings(p)[0].key == "renamed_shiraz")
    }
    @Test func recordedZeroIsASampleNotMissing() throws {
        let f = try fixture(); var s = f.session
        s.sampleSites = [SampleSite(paddockId: f.blocks[0].id, rowNumber: 1, latitude: 0, longitude: 0, siteIndex: 1, bunchCountEntry: BunchCountEntry(bunchesPerVine: 0))]
        let t = f.trip(s); #expect(t.blocks[0].baseTonnes == 0 && t.sampledAreaHa > 0)
    }
    @Test func noRecordedSamplesHaveNoTonnesOrPerHa() throws {
        let f = try fixture(); var s = f.session; s.sampleSites = []
        let t = f.trip(s); #expect(t.totalTonnes == nil && t.tonnesPerHa == nil && t.sampledAreaHa == 0)
    }
    @Test func damageOffRestoresBaseWithoutChangingEvidence() throws {
        let f = try fixture(); var s = f.session; let originalSites = s.sampleSites; s.applyDamage = false
        #expect(abs(try #require(f.trip(s).totalTonnes) - f.expectedTotalBase) < 1e-12)
        #expect(s.sampleSites == originalSites)
    }
    @Test func unroundedRecordedAverageDrivesTonnes() throws {
        let f = try fixture(); var s = f.session
        s.sampleSites = [1.0, 2.0, 2.0].enumerated().map { i, c in SampleSite(paddockId: f.blocks[0].id, rowNumber: 1, latitude: 0, longitude: 0, siteIndex: i, bunchCountEntry: BunchCountEntry(bunchesPerVine: c)) }
        #expect(abs(try #require(f.trip(s).blocks[0].baseTonnes) - 0.2) < 1e-12)
    }
    @Test func confirmedAbsenceInvalidatesPriorWeight() throws {
        let f = try fixture(); var w = f.weights
        w[CurrentYieldEstimate.key(blockId: f.blocks[0].id, varietyKey: "shiraz")] = YieldMasterWeight(bunchWeightGrams: nil, source: "not_configured", recordId: nil, varietyKey: "shiraz")
        #expect(f.trip(weights: w).blocks[0].weightKg == nil)
    }
    @Test func invalidUnconfirmedOrNonpositiveWeightRejected() {
        for grams in [0.0, -1, Double.infinity] { #expect(YieldMasterWeight(bunchWeightGrams: grams, source: "variety_default", recordId: UUID(), varietyKey: "x").kg == nil) }
        #expect(YieldMasterWeight(bunchWeightGrams: 150, source: "historical", recordId: UUID(), varietyKey: "x").kg == nil)
    }
    @Test func latestCompletedObservationStillWinsWithoutDrafts() throws {
        let f = try fixture(); var draft = f.session; draft.isCompleted = false; draft.createdAt = Date.distantFuture
        let selected = YieldVintageReport.latestCompletedSessionForBlock(sessions: [f.session, draft], paddockId: f.blocks[0].id,
            vintage: YieldVintageReport.sessionVintage(f.session, seasonStartMonth: 7, seasonStartDay: 1), seasonStartMonth: 7, seasonStartDay: 1)
        #expect(selected?.isCompleted == true && selected?.completedAt != nil)
    }
}
