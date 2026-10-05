import Foundation
import Testing
@testable import VineTrack

@MainActor
struct YieldAuthoritativeVineCountTests {
    private func block(first: Int? = nil, second: Int? = nil, override: Int? = nil) -> Paddock {
        let lat: Double = -34.5121
        let lon: Double = 138.7128
        let lengths: [Double] = [240, 252, 250]
        let rows: [PaddockRow] = lengths.enumerated().map { index, length in
            PaddockRow(number: index + 1,
                startPoint: CoordinatePoint(latitude: lat, longitude: lon + Double(index) * 0.000027),
                endPoint: CoordinatePoint(latitude: lat + length / 111320, longitude: lon + Double(index) * 0.000027),
                vineCountOverride: index == 0 ? first : index == 1 ? second : nil)
        }
        return Paddock(name: "Yield fixture", polygonPoints: [
            CoordinatePoint(latitude: lat, longitude: lon),
            CoordinatePoint(latitude: lat + 0.003, longitude: lon),
            CoordinatePoint(latitude: lat + 0.003, longitude: lon + 0.001),
            CoordinatePoint(latitude: lat, longitude: lon + 0.001)
        ], rows: rows, vineSpacing: 1.5, vineCountOverride: override)
    }

    private func viewModel(_ paddock: Paddock) -> YieldEstimationViewModel {
        let vm = YieldEstimationViewModel()
        vm.selectedPaddockIds = [paddock.id]
        vm.sampleSites = [SampleSite(paddockId: paddock.id, rowNumber: 1,
            latitude: -34.5121, longitude: 138.7128, siteIndex: 1,
            bunchCountEntry: BunchCountEntry(bunchesPerVine: 10))]
        vm.blockBunchWeightsKg = [paddock.id: 0.12]
        return vm
    }

    private func estimate(_ paddock: Paddock) throws -> BlockYieldEstimate {
        try #require(viewModel(paddock).calculateYieldEstimates(paddocks: [paddock]).first)
    }

    @Test func noOverridePreservesCalculatedCountAndYield() throws {
        let p = block()
        let e = try estimate(p)
        #expect(e.totalVines == 494)
        #expect(p.authoritativeVineCount == p.effectiveVineCount)
        #expect(abs(e.estimatedYieldTonnes - 0.5928) < 1e-10)
    }

    @Test func blockOverrideDrivesYield() throws {
        let p = block(override: 500)
        let e = try estimate(p)
        #expect(e.totalVines == 500)
        #expect(abs(e.estimatedYieldTonnes - 0.6) < 1e-10)
    }

    @Test func oneRowOverrideIncludesUntouchedRows() throws {
        let p = block(first: 158)
        let e = try estimate(p)
        #expect(e.totalVines == 493)
        #expect(p.completeRowEffectiveVineCount == 493)
        #expect(abs(e.estimatedYieldTonnes - 0.5916) < 1e-10)
        #expect(p.vineCountOverride == nil)
        #expect(p.effectiveVineCount == 494)
    }

    @Test func allManualRowsDriveYieldWithoutSpacingOrGeometry() throws {
        var p = block(first: 158, second: 150)
        p.vineSpacing = 0
        p.rows[2].vineCountOverride = 167
        for index in p.rows.indices { p.rows[index].endPoint = p.rows[index].startPoint }
        #expect(try estimate(p).totalVines == 475)
        #expect(p.completeRowEffectiveVineCount == 475)
        #expect(p.hasAuthoritativeVineOverride)
        #expect(abs(p.pruningYieldVinesPerHa(savedDensity: 2200) * p.areaHectares - 475) < 1e-8)
    }

    @Test func incompleteRowsFallBackInsteadOfUsingPartialCount() throws {
        let original = block(first: 158)
        var missingSpacing = original
        missingSpacing.vineSpacing = 0
        var missingGeometry = original
        missingGeometry.rows[1].endPoint = missingGeometry.rows[1].startPoint
        for p in [missingSpacing, missingGeometry] {
            #expect(p.completeRowEffectiveVineCount == nil)
            #expect(p.rowsEffectiveVineCount > 0)
            #expect(p.authoritativeVineCount == p.estimatedVineCount)
            #expect(p.summaryVineCount == p.estimatedVineCount)
            #expect(try estimate(p).totalVines == p.estimatedVineCount)
            #expect(!p.hasAuthoritativeVineOverride)
            #expect(p.pruningYieldVinesPerHa(savedDensity: 2200) == 2200)
            #expect(p.pruningYieldVinesPerHa(savedDensity: 0) == 0)
            var overridden = p
            overridden.vineCountOverride = 500
            #expect(try estimate(overridden).totalVines == 500)
        }
    }

    @Test func repairingMissingRowDataReactivatesRowTotal() throws {
        let original = block(first: 158)
        var p = original
        p.vineSpacing = 0
        #expect(!p.hasAuthoritativeVineOverride)
        p.vineSpacing = 1.5
        #expect(try estimate(p).totalVines == 493)
        p.rows[1].endPoint = p.rows[1].startPoint
        #expect(!p.hasAuthoritativeVineOverride)
        p.rows[1].endPoint = original.rows[1].endPoint
        #expect(try estimate(p).totalVines == 493)
        #expect(abs(p.pruningYieldVinesPerHa(savedDensity: 2200) * p.areaHectares - 493) < 1e-8)
        p.rows[1].endPoint = p.rows[1].startPoint
        p.rows[1].vineCountOverride = 150
        #expect(try estimate(p).totalVines == 475)
        p.rows[1].vineCountOverride = nil
        #expect(!p.hasAuthoritativeVineOverride)
        #expect(p.pruningYieldVinesPerHa(savedDensity: 2200) == 2200)
    }

    @Test func multipleRowOverridesDriveYield() throws {
        let e = try estimate(block(first: 158, second: 150))
        #expect(e.totalVines == 475)
        #expect(abs(e.estimatedYieldTonnes - 0.57) < 1e-10)
    }

    @Test func blockOverrideWinsOverRows() throws {
        let e = try estimate(block(first: 158, second: 150, override: 500))
        #expect(e.totalVines == 500)
        #expect(abs(e.estimatedYieldTonnes - 0.6) < 1e-10)
    }

    @Test func clearingRowsRestoresPreviousFallback() throws {
        var p = block(first: 158, second: 150)
        #expect(try estimate(p).totalVines == 475)
        for index in p.rows.indices { p.rows[index].vineCountOverride = nil }
        let e = try estimate(p)
        #expect(e.totalVines == 494)
        #expect(abs(e.estimatedYieldTonnes - 0.5928) < 1e-10)
    }

    @Test func bunchCountTonnesChangeProportionally() throws {
        var p = block(override: 10000)
        let before = try estimate(p)
        p.vineCountOverride = nil
        p.rows[0].vineCountOverride = 9265 // 9265 + 168 + 167 = 9600
        let after = try estimate(p)
        #expect(after.totalVines == 9600)
        #expect(abs(after.estimatedYieldTonnes - 11.52) < 1e-10)
        #expect(abs(after.estimatedYieldTonnes / before.estimatedYieldTonnes - 0.96) < 1e-10)
    }

    @Test func displayedCountMatchesFormulaAndDamageIsUnchanged() throws {
        let p = block(first: 158)
        let vm = viewModel(p)
        let e = try #require(vm.calculateYieldEstimates(paddocks: [p], remainingYieldMultiplierProvider: { _ in 0.8 }).first)
        #expect(e.totalVines == p.summaryVineCount)
        #expect(e.totalBunches == Double(e.totalVines) * e.averageBunchesPerVine)
        #expect(e.estimatedYieldKg == e.totalBunches * e.averageBunchWeightKg * 0.8)
        #expect(e.remainingYieldMultiplier == 0.8)
    }

    @Test func invalidAndZeroOverridesAreIgnored() throws {
        for invalid in [0, -1, 100001] {
            let p = block(first: invalid, override: invalid == 100001 ? 0 : invalid)
            #expect(p.authoritativeVineCount == 494)
            #expect(p.summaryVineCount == 494)
            #expect(!p.hasAuthoritativeVineOverride)
            #expect(try estimate(p).totalVines == 494)
        }
        #expect(block(first: 158, override: 0).authoritativeVineCount == 493)
    }

    @Test func historicalStoredResultsAreNotRewritten() throws {
        var p = block()
        let stored = HistoricalBlockResult(paddockId: p.id, paddockName: p.name, yieldTonnes: 12, totalVines: 10000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(stored)
        p.rows[0].vineCountOverride = 158
        _ = try estimate(p)
        let restored = try JSONDecoder().decode(HistoricalBlockResult.self, from: data)
        #expect(restored.totalVines == 10000)
        #expect(restored.yieldTonnes == 12)
        #expect(try encoder.encode(stored) == data)
    }

    @Test func savedPruningDensityIsPreservedWithoutOverrides() {
        let p = block()
        #expect(p.pruningYieldVinesPerHa(savedDensity: 2200) == 2200)
        #expect(p.pruningYieldVinesPerHa(savedDensity: 0) == 0)
    }

    @Test func physicalOverridesSupersedeSavedPruningDensity() {
        for p in [block(first: 158), block(first: 158, override: 500)] {
            let density = p.pruningYieldVinesPerHa(savedDensity: 2200)
            #expect(abs(density * p.areaHectares - Double(p.authoritativeVineCount)) < 1e-8)
        }
        var p = block(first: 158)
        let settings = PruningYieldSettings(vineyardId: p.vineyardId, paddockId: p.id, vinesPerHa: 2200)
        _ = p.pruningYieldVinesPerHa(savedDensity: settings.vinesPerHa ?? 0)
        p.rows[0].vineCountOverride = nil
        #expect(p.pruningYieldVinesPerHa(savedDensity: settings.vinesPerHa ?? 0) == 2200)
        #expect(settings.vinesPerHa == 2200)
    }

    @Test func newlyCompletedTripsKeepCapturedVineCount() throws {
        var p = block(first: 158)
        let vm = viewModel(p)
        vm.markCompleted(paddocks: [p])
        let session = vm.toSession(vineyardId: p.vineyardId, samplesPerHectare: 20)
        let roundTripped = try JSONDecoder().decode(YieldEstimationSession.self, from: JSONEncoder().encode(session))
        p.vineCountOverride = 500
        vm.loadSession(roundTripped)
        let e = try #require(vm.calculateYieldEstimates(paddocks: [p]).first)
        #expect(e.totalVines == 493)
        #expect(roundTripped.vineCount(for: p) == 493)
        #expect(abs(e.estimatedYieldTonnes - 0.5916) < 1e-10)
    }

    @Test func legacyCompletedTripsRetainPreviousCalculation() throws {
        let p = block(first: 158)
        let vm = viewModel(p)
        vm.isCompleted = true
        let e = try #require(vm.calculateYieldEstimates(paddocks: [p]).first)
        #expect(e.totalVines == p.effectiveVineCount)
        #expect(e.totalVines == 494)
    }
}
