import Foundation
import Testing
@testable import VineTrack

@MainActor
struct YieldPanelCountObservationTests {
    @Test func rawPanelObservationPersistsAndNeverBecomesAutomaticPerVineEstimate() throws {
        let vineyard = UUID(), block = UUID(), site = SampleSite(
            paddockId: block, rowNumber: 12, latitude: -34, longitude: 149, siteIndex: 1,
            yieldRowReference: "12A", yieldPanelReference: "E-4")
        let measurement = try #require(PanelCountMeasurement.make(
            totalBunches: 120, plantedPositions: 10, fruitingVines: 8,
            missingPositions: 1, nonproductiveVines: 1, panelLengthMetres: 6))
        let vm = YieldEstimationViewModel()
        vm.startNewTrip()
        vm.countMethod = "panel"
        vm.sampleSites = [site]
        #expect(!vm.savePanelCount(siteId: site.id, measurement: measurement, recordedBy: "fixture", persist: { false }))
        #expect(!vm.sampleSites[0].isRecorded)
        #expect(vm.savePanelCount(siteId: site.id, measurement: measurement, recordedBy: "fixture", persist: { true }))
        let draft = vm.toSession(vineyardId: vineyard, samplesPerHectare: 20)
        #expect(draft.isPanelCount && draft.countMethodName == "Panel Count")
        #expect(draft.sampleSites[0].panelCountEntry?.measurement.totalBunches == 120)
        #expect(draft.sampleSites[0].bunchCountEntry == nil)
        #expect(draft.sampleSites[0].isRecorded)
        let rebuilt = try JSONDecoder().decode(YieldEstimationSession.self, from: JSONEncoder().encode(draft))
        #expect(rebuilt.sampleSites[0].panelCountEntry?.measurement == measurement)
        #expect(rebuilt.sampleSites[0].yieldRowReference == "12A")
        #expect(rebuilt.sampleSites[0].yieldPanelReference == "E-4")
        var completed = rebuilt
        completed.isCompleted = true
        completed.completedAt = Date()
        let vintage = YieldVintageReport.sessionVintage(completed, seasonStartMonth: 7, seasonStartDay: 1)
        #expect(YieldVintageReport.latestCompletedSessionForBlock(
            sessions: [completed], paddockId: block, vintage: vintage,
            seasonStartMonth: 7, seasonStartDay: 1) == nil)
        #expect(YieldVintageReport.estimateRows(sessions: [completed], paddocks: [],
            remainingYieldMultiplier: { _ in 1 }, vintage: vintage,
            seasonStartMonth: 7, seasonStartDay: 1).isEmpty)
    }
}
