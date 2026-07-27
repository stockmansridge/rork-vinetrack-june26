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
}
