import Foundation
import Testing
@testable import VineTrack

@MainActor
struct PanelCountContractTests {
    @Test func preservesPostToPostRawEvidenceAndDoesNotDoubleAdjustMissingVines() throws {
        let m = try #require(PanelCountMeasurement.make(
            totalBunches: 120, plantedPositions: 10, fruitingVines: 8,
            missingPositions: 1, nonproductiveVines: 1, panelLengthMetres: 6.0))
        #expect(m.bunchesPerPlantingPosition == 12)
        #expect(m.totalBunches == 120)
        #expect(m.fruitingVines == 8)
        let roundtrip = try JSONDecoder().decode(PanelCountMeasurement.self, from: JSONEncoder().encode(m))
        #expect(roundtrip == m)
    }

    @Test func rejectsInvalidFootprintsWithoutInventingVines() {
        #expect(PanelCountMeasurement.make(
            totalBunches: 12, plantedPositions: 10, fruitingVines: 8,
            missingPositions: 1, nonproductiveVines: 0, panelLengthMetres: nil) == nil)
        #expect(PanelCountMeasurement.make(
            totalBunches: -1, plantedPositions: 10, fruitingVines: 9,
            missingPositions: 1, nonproductiveVines: 0, panelLengthMetres: nil) == nil)
        #expect(PanelCountMeasurement.make(
            totalBunches: 0, plantedPositions: 0, fruitingVines: 0,
            missingPositions: 0, nonproductiveVines: 0, panelLengthMetres: nil) == nil)
        #expect(PanelCountMeasurement.make(
            totalBunches: 0, plantedPositions: 2, fruitingVines: 2,
            missingPositions: 0, nonproductiveVines: 0, panelLengthMetres: .infinity) == nil)
    }
}
