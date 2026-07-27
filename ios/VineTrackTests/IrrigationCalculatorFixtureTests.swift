import Foundation
import Testing
@testable import VineTrack

/// SHARED IRRIGATION CALCULATION FIXTURE — the same deterministic fixture
/// exists as `IrrigationCalculatorFixtureTest.kt` in the Android unit-test
/// source set, and as the assert block at the end of `sql/125_irrigation_records.sql`
/// (the authoritative implementation). All three must produce these exact
/// values before display formatting.
///
/// Fixture: one valve at 2,000 L/h, 3.5 h (210 min) duration → 7,000 L total.
/// Two connected blocks:
///   Block A — 60%, 20,000 m² (2 ha), 2,000 vines, 90% efficiency
///   Block B — 40%, no area, no vine count, no efficiency
struct IrrigationCalculatorFixtureTests {

    private var fixtureAllocations: [IrrigationAllocationConfig] {
        func config(_ json: [String: Any]) -> IrrigationAllocationConfig {
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(IrrigationAllocationConfig.self, from: data)
        }
        return [
            config([
                "block_id": "00000000-0000-0000-0000-000000000001",
                "block_name": "Block A",
                "allocation_percentage": 60,
                "serviced_area_m2": 20000,
                "serviced_vine_count": 2000,
                "efficiency_percent": 90
            ]),
            config([
                "block_id": "00000000-0000-0000-0000-000000000002",
                "block_name": "Block B",
                "allocation_percentage": 40
            ])
        ]
    }

    // MARK: Total volume

    @Test func configuredFlowWholeAndPartialHours() throws {
        #expect(try IrrigationLocalCalculator.totalVolume(
            method: .configuredFlow, flowLitresPerHour: 2000, durationMinutes: 210,
            meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: nil) == 7000)
        #expect(try IrrigationLocalCalculator.totalVolume(
            method: .sessionFlow, flowLitresPerHour: 1000, durationMinutes: 90,
            meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: nil) == 1500)
    }

    @Test func meterDifference() throws {
        #expect(try IrrigationLocalCalculator.totalVolume(
            method: .meterReadings, flowLitresPerHour: nil, durationMinutes: 60,
            meterStartLitres: 5000, meterFinishLitres: 8600, totalVolumeLitres: nil) == 3600)
    }

    @Test func manualTotalVolumePreserved() throws {
        #expect(try IrrigationLocalCalculator.totalVolume(
            method: .totalVolume, flowLitresPerHour: nil, durationMinutes: 60,
            meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: 4200) == 4200)
    }

    @Test func invalidInputsRejected() {
        #expect(throws: (any Error).self) {
            try IrrigationLocalCalculator.totalVolume(
                method: .sessionFlow, flowLitresPerHour: 0, durationMinutes: 60,
                meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: nil)
        }
        #expect(throws: (any Error).self) {
            try IrrigationLocalCalculator.totalVolume(
                method: .sessionFlow, flowLitresPerHour: -5, durationMinutes: 60,
                meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: nil)
        }
        #expect(throws: (any Error).self) {
            try IrrigationLocalCalculator.totalVolume(
                method: .configuredFlow, flowLitresPerHour: 2000, durationMinutes: 0,
                meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: nil)
        }
        #expect(throws: (any Error).self) {
            try IrrigationLocalCalculator.totalVolume(
                method: .meterReadings, flowLitresPerHour: nil, durationMinutes: 60,
                meterStartLitres: 8600, meterFinishLitres: 5000, totalVolumeLitres: nil)
        }
    }

    // MARK: Allocation fixture (parity with SQL 125 asserts)

    @Test func twoBlockAllocationFixture() {
        let result = IrrigationLocalCalculator.allocate(
            totalVolumeLitres: 7000, allocations: fixtureAllocations)

        #expect(result.blocks.count == 2)
        let blockA = result.blocks[0]
        let blockB = result.blocks[1]

        #expect(blockA.allocatedVolumeLitres == 4200)
        #expect(blockB.allocatedVolumeLitres == 2800)
        #expect(blockA.waterLitresPerVine == 2.1)
        #expect(blockA.waterLitresPerHectare == 2100)
        #expect(blockA.irrigationDepthMm == 0.21)
        #expect(blockA.effectiveVolumeLitres == 3780)

        // Missing data → NULL, never zero.
        #expect(blockB.waterLitresPerVine == nil)
        #expect(blockB.waterLitresPerHectare == nil)
        #expect(blockB.irrigationDepthMm == nil)
        #expect(blockB.effectiveVolumeLitres == nil)

        // Session effective is nil when any block lacks efficiency.
        #expect(result.effectiveVolumeLitres == nil)
        #expect(result.warnings.count >= 2)
    }

    // MARK: Unit conversions (display only — stored values stay canonical)

    @Test func unitConversions() {
        // Litres → US gallons
        #expect(abs(1000 * IrrigationLocalCalculator.usGallonsPerLitre - 264.172052) < 0.0001)
        // Litres → Imperial gallons
        #expect(abs(1000 * IrrigationLocalCalculator.imperialGallonsPerLitre - 219.969157) < 0.0001)
        // L/ha → US gal/acre
        let galPerAcre = IrrigationLocalCalculator.litresPerHectareToGallonsPerAcre(2100, usGallon: true)
        #expect(abs(galPerAcre - 224.504) < 0.01)
        // mm → inches
        #expect(abs(IrrigationLocalCalculator.millimetresToInches(25.4) - 1.0) < 0.000001)
    }

    // MARK: Row-based weighting fixture (parity with SQL 126 asserts and
    // IrrigationCalculatorFixtureTest.kt)

    private func availableRow(
        _ json: [String: Any]
    ) -> IrrigationAvailableRow {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(IrrigationAvailableRow.self, from: data)
    }

    private func row(rowId: String, blockId: String, blockName: String, number: Int,
                     emitters: Int? = nil, vines: Int? = nil, length: Double? = nil) -> IrrigationAvailableRow {
        var json: [String: Any] = [
            "row_id": rowId, "block_id": blockId, "block_name": blockName, "row_number": number
        ]
        if let emitters { json["emitter_count"] = emitters }
        if let vines { json["vine_count"] = vines }
        if let length { json["row_length_metres"] = length }
        return availableRow(json)
    }

    private let blockA = "00000000-0000-0000-0000-000000000001"
    private let blockB = "00000000-0000-0000-0000-000000000002"

    @Test func rowWeightingEmitterBasisTotalsExactly100() {
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "Block 1A",
                number: 1, emitters: 130, vines: 65, length: 100),
            row(rowId: "00000000-0000-0000-0000-00000000A002", blockId: blockA, blockName: "Block 1A",
                number: 2, emitters: 70, vines: 35, length: 60),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "Block 1B",
                number: 1, emitters: 100, vines: 50, length: 80)
        ])
        #expect(result.basis == .emitterCount)
        #expect(result.blocks.count == 2)
        #expect(result.blocks[0].percentage == 66.6667)
        #expect(result.blocks[1].percentage == 33.3333)
        #expect(result.blocks.reduce(0) { $0 + $1.percentage } == 100)
    }

    @Test func rowWeightingNeverMixesUnits() {
        // One row missing emitters but all rows have vines → vine basis.
        let vines = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, emitters: 130, vines: 60, length: 100),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "B",
                number: 1, vines: 40, length: 80)
        ])
        #expect(vines.basis == .vineCount)
        #expect(vines.blocks[0].percentage == 60)

        // Lengths only → row-length basis.
        let lengths = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, length: 150),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "B",
                number: 1, length: 50)
        ])
        #expect(lengths.basis == .rowLength)
        #expect(lengths.blocks[0].percentage == 75)
    }

    @Test func rowWeightingEqualRowsFallback() {
        // Non-sequential selection 1,2,5 + 8 stays explicit rows; A 3 rows, B 1 row → 75 / 25.
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A", number: 1),
            row(rowId: "00000000-0000-0000-0000-00000000A002", blockId: blockA, blockName: "A", number: 2),
            row(rowId: "00000000-0000-0000-0000-00000000A005", blockId: blockA, blockName: "A", number: 5),
            row(rowId: "00000000-0000-0000-0000-00000000B008", blockId: blockB, blockName: "B", number: 8)
        ])
        #expect(result.basis == .equalRows)
        #expect(result.blocks[0].percentage == 75)
        #expect(result.blocks[0].rowCount == 3)
        #expect(result.blocks[1].percentage == 25)
    }

    @Test func rowRangeSummaryCompressesOnlyContiguousRuns() {
        // 1,2,5,8 must display as "1–2, 5, 8" — never "1–8".
        #expect(IrrigationRowWeighting.rangeSummary([1, 2, 5, 8]) == "1–2, 5, 8")
        #expect(IrrigationRowWeighting.rangeSummary([8, 5, 2, 1]) == "1–2, 5, 8")
        #expect(IrrigationRowWeighting.rangeSummary([1, 2, 3, 4]) == "1–4")
        #expect(IrrigationRowWeighting.rangeSummary([7]) == "7")
        #expect(IrrigationRowWeighting.rangeSummary([1, 10, 13, 14, 15, 18, 22, 23, 24, 25]) == "1, 10, 13–15, 18, 22–25")
        #expect(IrrigationRowWeighting.rangeSummary([]) == "")
        #expect(IrrigationRowWeighting.rangeSummary([3, 3, 4]) == "3–4")
    }
}
