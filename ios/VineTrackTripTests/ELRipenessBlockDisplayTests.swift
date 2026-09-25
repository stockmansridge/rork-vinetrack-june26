import Foundation
import Testing
@testable import VineTrack

@Suite @MainActor struct ELRipenessBlockDisplayTests {
    private func row(_ id: String, _ el: String, block: String = "A", date: String = "2026-01-20", vineyard: String = "vineyard", deleted: String? = nil) -> ELRipeness.RawRecord {
        ELRipeness.RawRecord(id: id, vineyardId: vineyard, paddockId: block, stageCode: el,
                             latitude: -34.5, longitude: 138.5, date: date, deletedAt: deleted)
    }

    private func block(_ records: [ELRipeness.RawRecord], date: String = "2026-01-25") -> ELRipeness.BlockHeat {
        let normalized = ELRipeness.toObservations(records, selectedVineyardId: "vineyard")
        let season = ELRipeness.filterToVintage(normalized, startISO: "2025-07-01", endISO: "2026-06-30")
        let polygon = [ELRipeness.LatLng(lat: -34.51, lng: 138.49),
                       ELRipeness.LatLng(lat: -34.51, lng: 138.51),
                       ELRipeness.LatLng(lat: -34.49, lng: 138.51),
                       ELRipeness.LatLng(lat: -34.49, lng: 138.49)]
        return ELRipeness.buildHeatModel(observations: season,
                                        blocks: [ELRipeness.BlockInput(id: "A", polygon: polygon)],
                                        atDateISO: date, resolution: 3).blocks[0]
    }

    @Test func labelShowsHighestEligibleRecordedStageOnly() {
        let four = block([row("1", "15"), row("2", "17"), row("3", "18"), row("4", "21")])
        #expect(four.displayEl == 21)
        #expect(ELRipeness.formatEl(four.displayEl) == "E-L 21")
        #expect(four.medianEl == 17.5)
        #expect(block([row("1", "27"), row("2", "27"), row("3", "29")]).displayEl == 29)
        #expect(block([row("1", "23")]).displayEl == 23)
        let empty = block([])
        #expect(empty.displayEl == nil)
        #expect(ELRipenessPinFactory.displayDetail(displayEl: empty.displayEl, mode: empty.mode) == "—")
    }

    @Test func labelRespectsExistingScopingAndCurrentObservationRules() {
        let valid = row("valid", "21")
        #expect(block([valid, row("other-block", "47", block: "B")]).displayEl == 21)
        #expect(block([valid, row("other-vintage", "47", date: "2024-01-20")]).displayEl == 21)
        #expect(block([valid, row("future", "47", date: "2026-01-26")]).displayEl == 21)
        #expect(block([valid, row("deleted", "47", deleted: "2026-01-21")]).displayEl == 21)
        #expect(block([valid, row("invalid", "E-L 99")]).displayEl == 21)
        #expect(block([valid, row("other-vineyard", "47", vineyard: "elsewhere")]).displayEl == 21)
        let stale = block([row("old", "47", date: "2025-09-01")])
        #expect(stale.displayEl == nil)
        #expect(ELRipenessPinFactory.displayDetail(displayEl: stale.displayEl, mode: stale.mode) == "No current data")
    }
}
