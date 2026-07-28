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
                     emitters: Int? = nil, vines: Int? = nil, length: Double? = nil,
                     emitterBasis: String? = nil, vineBasis: String? = nil) -> IrrigationAvailableRow {
        var json: [String: Any] = [
            "row_id": rowId, "block_id": blockId, "block_name": blockName, "row_number": number
        ]
        if let emitters { json["emitter_count"] = emitters }
        if let vines { json["vine_count"] = vines }
        if let length { json["row_length_metres"] = length }
        if let emitterBasis { json["emitter_count_basis"] = emitterBasis }
        if let vineBasis { json["vine_count_basis"] = vineBasis }
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

    // MARK: SQL 127 basis honesty (parity with sql/127 asserts and
    // IrrigationCalculatorFixtureTest.kt)

    @Test func spacingDerivedEmitterEstimatesKeepRowLengthBasis() {
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, emitters: 430, vines: 103, length: 215.01,
                emitterBasis: "row_length_spacing", vineBasis: "row_length_spacing"),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "B",
                number: 1, emitters: 143, vines: 34, length: 71.67,
                emitterBasis: "row_length_spacing", vineBasis: "row_length_spacing")
        ])
        #expect(result.basis == .rowLength)
        #expect(result.blocks[0].percentage == 75)
    }

    @Test func reconciledBlockTotalVinesAreAValidVineBasis() {
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, emitters: 200, vines: 120, length: 100,
                emitterBasis: "row_length_spacing", vineBasis: "block_total_proportional"),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "B",
                number: 1, emitters: 200, vines: 40, length: 100,
                emitterBasis: "row_length_spacing", vineBasis: "block_total_proportional")
        ])
        #expect(result.basis == .vineCount)
        #expect(result.blocks[0].percentage == 75)
    }

    @Test func exactEmitterBasisStillWins() {
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, emitters: 300, length: 100, emitterBasis: "exact"),
            row(rowId: "00000000-0000-0000-0000-00000000B001", blockId: blockB, blockName: "B",
                number: 1, emitters: 100, length: 100, emitterBasis: "exact")
        ])
        #expect(result.basis == .emitterCount)
        #expect(result.blocks[0].percentage == 75)
    }

    @Test func missingRowLengthWithSpacingDerivedDataFallsBackToEqualRows() {
        let result = IrrigationRowWeighting.allocate(rows: [
            row(rowId: "00000000-0000-0000-0000-00000000A001", blockId: blockA, blockName: "A",
                number: 1, emitters: 200, vines: 50, length: 100,
                emitterBasis: "row_length_spacing", vineBasis: "row_length_spacing"),
            row(rowId: "00000000-0000-0000-0000-00000000B069", blockId: blockB, blockName: "B",
                number: 69, emitterBasis: "unavailable", vineBasis: "unavailable")
        ])
        #expect(result.basis == .equalRows)
        #expect(result.blocks[0].percentage == 50)
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

    // MARK: Session start/end times (SQL 130 parity)
    // Mirrors `_irrigation_validate_session_times` (sql/130) and
    // `IrrigationLocalCalc.minutesBetweenTimes` / `endOfSession` on Android.

    @Test func sameDayTimesDeriveDuration() {
        // 08:30 → 11:45 = 3 hr 15 min.
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 8 * 60 + 30, endMinutesOfDay: 11 * 60 + 45) == 195)
    }

    @Test func partialHourTimes() {
        // 10:00 → 11:30 = 90 min.
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 10 * 60, endMinutesOfDay: 11 * 60 + 30) == 90)
    }

    @Test func overnightTimesRollToFollowingDay() {
        // 22:00 → 02:00 next day = 4 hours; never negative.
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 22 * 60, endMinutesOfDay: 2 * 60) == 240)
    }

    @Test func equalTimesAreInvalid() {
        // Zero-minute session must be rejected, not saved as 0 or 1440.
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 8 * 60 + 30, endMinutesOfDay: 8 * 60 + 30) == nil)
    }

    @Test func editingEitherTimeRecalculatesDuration() {
        // Changing the end from 11:45 to 12:15 recalculates 195 → 225;
        // changing the start from 08:30 to 09:00 recalculates 225 → 195.
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 8 * 60 + 30, endMinutesOfDay: 12 * 60 + 15) == 225)
        #expect(IrrigationLocalCalculator.minutesBetweenTimes(
            startMinutesOfDay: 9 * 60, endMinutesOfDay: 12 * 60 + 15) == 195)
    }

    @Test func startPlusDurationCalculatesEnd() {
        // 08:30 + 195 min → 11:45 same day.
        let sameDay = IrrigationLocalCalculator.endOfSession(
            startMinutesOfDay: 8 * 60 + 30, durationMinutes: 195)
        #expect(sameDay.minutesOfDay == 11 * 60 + 45)
        #expect(sameDay.daysLater == 0)

        // 22:00 + 5 h → 03:00 the following day.
        let overnight = IrrigationLocalCalculator.endOfSession(
            startMinutesOfDay: 22 * 60, durationMinutes: 300)
        #expect(overnight.minutesOfDay == 3 * 60)
        #expect(overnight.daysLater == 1)
    }

    // MARK: Configured-flow resolution parity (SQL 131 `_irrigation_resolve_flow`)

    private var w1RowsComponent: IrrigationLocalCalculator.FlowComponent {
        .init(blockName: "Pinot Noir", isRows: true, emitterCount: 7931, flowPerEmitterLph: 1.6)
    }

    @Test func measuredValveFlowIsPriorityOne() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: 9000, configuredValveFlow: 8000, components: [w1RowsComponent])
        #expect(resolved.source == "measured_valve_flow")
        #expect(resolved.flowLitresPerHour == 9000)
        #expect(resolved.isEstimated == false)
    }

    @Test func configuredValveFlowIsPriorityTwo() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: 8000, components: [w1RowsComponent])
        #expect(resolved.source == "configured_valve_flow")
        #expect(resolved.flowLitresPerHour == 8000)
    }

    @Test func rowEmitterFlowW1Example() throws {
        // 7,931 emitters × 1.6 L/h = 12,689.6 L/h; × 3 h = 38,068.8 L.
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [w1RowsComponent])
        #expect(resolved.flowLitresPerHour == 12689.6)
        #expect(resolved.source == "row_emitter_flow")
        #expect(resolved.isEstimated == true)
        #expect(resolved.emitterCount == 7931)
        #expect(try IrrigationLocalCalculator.totalVolume(
            method: .configuredFlow, flowLitresPerHour: resolved.flowLitresPerHour,
            durationMinutes: 180, meterStartLitres: nil, meterFinishLitres: nil,
            totalVolumeLitres: nil) == 38068.8)
    }

    @Test func blocksWithDifferentEmitterOutputsSumSeparately() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [
                .init(blockName: "Pinot Noir", isRows: true, emitterCount: 4000, flowPerEmitterLph: 1.6),
                .init(blockName: "Primitivo", isRows: true, emitterCount: 2000, flowPerEmitterLph: 2.0)
            ])
        #expect(resolved.flowLitresPerHour == 10400)
        #expect(resolved.emitterCount == 6000)
    }

    @Test func missingFlowPerEmitterIsUnavailableNotZero() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [
                .init(blockName: "Pinot Noir", isRows: true, emitterCount: 7931, flowPerEmitterLph: nil)
            ])
        #expect(resolved.flowLitresPerHour == nil)
        #expect(resolved.source == "unavailable")
        #expect(resolved.warning?.contains("Pinot Noir does not have a valid flow-per-emitter value") == true)
    }

    @Test func oneIncompleteBlockNeverYieldsAPartialTotal() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [
                .init(blockName: "Pinot Noir", isRows: true, emitterCount: 4000, flowPerEmitterLph: 1.6),
                .init(blockName: "Primitivo", isRows: true, emitterCount: nil, flowPerEmitterLph: 2.0)
            ])
        #expect(resolved.flowLitresPerHour == nil)
        #expect(resolved.source == "unavailable")
        #expect(resolved.warning?.contains("Primitivo does not have a complete saved emitter count") == true)
    }

    @Test func manualPercentageWithEmitterDataUsesBlockEmitterFlow() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [
                .init(blockName: "Pinot Noir", isRows: false, emitterCount: 5000, flowPerEmitterLph: 1.6)
            ])
        #expect(resolved.flowLitresPerHour == 8000)
        #expect(resolved.source == "block_emitter_flow")
    }

    @Test func blockSpecificConfiguredFlowContributes() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [
                .init(blockName: "Pinot Noir", isRows: false, emitterCount: nil,
                      flowPerEmitterLph: nil, blockConfiguredFlowLph: 5000),
                .init(blockName: "Primitivo", isRows: false, emitterCount: 4000, flowPerEmitterLph: 1.6)
            ])
        #expect(resolved.flowLitresPerHour == 11400)
        // The emitter total only surfaces when EVERY contributing block used emitters.
        #expect(resolved.emitterCount == nil)
    }

    @Test func invalidExplicitFlowsFallThroughToDerivation() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: 0, configuredValveFlow: -5, components: [w1RowsComponent])
        #expect(resolved.source == "row_emitter_flow")
    }

    @Test func noBlockConnectionsIsUnavailable() {
        let resolved = IrrigationLocalCalculator.resolveFlow(
            measuredValveFlow: nil, configuredValveFlow: nil, components: [])
        #expect(resolved.source == "unavailable")
        #expect(resolved.warning?.contains("no active block connections") == true)
    }
}
