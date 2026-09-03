import XCTest
@testable import VineTrack

final class GrowthStageLiveDecodingTests: XCTestCase {
    private let vineyardId = "11111111-1111-1111-1111-111111111111"
    private let paddockId = "22222222-2222-2222-2222-222222222222"

    private func productionJSON(count: Int = 3) -> Data {
        let rows = (1...count).map { index in
            """
            {"id":"00000000-0000-0000-0000-00000000000\(index)","vineyard_id":"\(vineyardId)","paddock_id":"\(paddockId)","pin_id":null,"stage_code":"EL2","stage_label":"E-L 2","variety":"Grüner Veltliner","variety_id":null,"observed_at":"2026-09-02T00:56:19.668Z","latitude":-33.312,"longitude":149.102,"row_number":null,"side":null,"notes":null,"photo_paths":[],"recorded_by_name":"Operator","created_by":null,"updated_by":null,"created_at":"2026-09-02T00:56:19.668Z","updated_at":"2026-09-02T00:56:19.668Z","source":"growth_stage_records"}
            """
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    func testProductionViewJSONDecodesObservedAtAndNullPinIdentity() throws {
        let rows = try JSONDecoder().decode([RipenessObservationRow].self, from: productionJSON())
        let sources = rows.map(\.sourceRecord)
        let observations = ELRipenessObservationAdapter.observations(from: sources, selectedVineyardId: vineyardId)

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.pinId == nil && $0.stageCode == "EL2" })
        XCTAssertEqual(Set(sources.map(\.dedupeKey)).count, 3)
        XCTAssertEqual(observations.count, 3)
        XCTAssertTrue(observations.allSatisfy { $0.el == 2 && $0.dateISO == "2026-09-02T00:56:19.668Z" })
        XCTAssertTrue(observations.allSatisfy { $0.assigned && $0.paddockId == paddockId })
        XCTAssertEqual(ELRipenessSeason.vintage(forDayKey: observations[0].dateISO, month: 7, day: 1), 2027)
    }

    func testStockmansFixtureAcceptanceCountsAndSurface() throws {
        let sources = try JSONDecoder().decode([RipenessObservationRow].self, from: productionJSON()).map(\.sourceRecord)
        let observations = ELRipenessObservationAdapter.observations(from: sources, selectedVineyardId: vineyardId)
        let mainPolygon = [
            ELRipeness.LatLng(lat: -33.313, lng: 149.101),
            ELRipeness.LatLng(lat: -33.313, lng: 149.103),
            ELRipeness.LatLng(lat: -33.311, lng: 149.103),
            ELRipeness.LatLng(lat: -33.311, lng: 149.101),
        ]
        let blocks = (0..<8).map { index in
            ELRipeness.BlockInput(
                id: index == 0 ? paddockId : "block-\(index)",
                name: index == 0 ? "Grüner Veltliner" : "Block \(index)",
                polygon: index == 0 ? mainPolygon : mainPolygon.map { .init(lat: $0.lat + Double(index), lng: $0.lng) }
            )
        }
        let heat = ELRipeness.buildHeatModel(observations: observations, blocks: blocks, atDateISO: "2026-09-02")
        let diagnostics = ELRipenessObservationAdapter.diagnosticCounts(
            sources: sources,
            selectedVineyardId: vineyardId,
            remoteRowsReturned: 3,
            atDateISO: "2026-09-02"
        )

        XCTAssertEqual(heat.qualifying.count, 3)
        XCTAssertEqual(heat.influencing.count, 3)
        XCTAssertEqual(heat.stale.count, 0)
        XCTAssertEqual(heat.medianEl, 2)
        XCTAssertEqual(heat.blocks.first?.mode, .surface)
        XCTAssertEqual(heat.blocks.first?.observations.count, 3)
        XCTAssertEqual(blocks.filter { $0.polygon.count >= 3 }.count, 8)
        XCTAssertEqual(diagnostics.remoteRowsDecoded, 3)
        XCTAssertEqual(diagnostics.qualifyingObservations, 3)
    }

    func testVintageIdentifierNeverUsesGrouping() {
        XCTAssertEqual(VintageYearText.format(2027), "2027")
        XCTAssertEqual(VintageYearText.format(2026), "2026")
        XCTAssertEqual(VintageYearText.label(2027), "Vintage 2027")
        XCTAssertFalse(VintageYearText.label(2027).contains(","))
    }
}
