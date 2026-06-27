//
//  VineTrackV2Tests.swift
//  VineTrackV2Tests
//
//  Created by Rork on April 27, 2026.
//

import Testing
@testable import VineTrackV2

struct VineTrackV2Tests {

    // MARK: - Every Second Row sequence (multi-block, parity-preserving)

    /// 108 rows, start path 100.5, lower-first:
    /// 100.5 → 98.5 → ... → 0.5, then wrap 108.5 → 106.5 → ... → 102.5
    @Test func everySecondRow_108Rows_start100_5_lowerFirst() {
        let paths = (0...108).map { Double($0) + 0.5 }
        let seq = StartTripSheet.everySecondRowSequence(
            paths: paths,
            startPath: 100.5,
            higherFirst: false
        )

        // Same-parity = halves of even integers (0.5, 2.5, ..., 108.5) → 55 entries.
        #expect(seq.count == 55)
        #expect(seq.first == 100.5)
        #expect(Array(seq.prefix(4)) == [100.5, 98.5, 96.5, 94.5])

        // First run ends at 0.5, then wrap jumps to 108.5.
        let zeroIndex = seq.firstIndex(of: 0.5)
        #expect(zeroIndex != nil)
        if let i = zeroIndex {
            #expect(seq[i + 1] == 108.5)
        }

        // Final entry is 102.5 (just above start, descending).
        #expect(seq.last == 102.5)
    }

    /// 108 rows, start path 100.5, higher-first:
    /// 100.5 → 102.5 → ... → 108.5, then wrap 0.5 → 2.5 → ... → 98.5
    @Test func everySecondRow_108Rows_start100_5_higherFirst() {
        let paths = (0...108).map { Double($0) + 0.5 }
        let seq = StartTripSheet.everySecondRowSequence(
            paths: paths,
            startPath: 100.5,
            higherFirst: true
        )

        #expect(seq.count == 55)
        #expect(Array(seq.prefix(5)) == [100.5, 102.5, 104.5, 106.5, 108.5])

        // Wrap from top back to lowest same-parity.
        let topIndex = seq.firstIndex(of: 108.5)
        #expect(topIndex != nil)
        if let i = topIndex {
            #expect(seq[i + 1] == 0.5)
        }

        #expect(seq.last == 98.5)
    }

    /// Single block, 14 rows, start 0.5 higher-first → walks the same-parity
    /// half of the path range (0.5, 2.5, … 14.5).
    @Test func everySecondRow_singleBlock_14Rows_start0_5() {
        let paths = (0...14).map { Double($0) + 0.5 }
        let seq = StartTripSheet.everySecondRowSequence(
            paths: paths,
            startPath: 0.5,
            higherFirst: true
        )
        #expect(seq == [0.5, 2.5, 4.5, 6.5, 8.5, 10.5, 12.5, 14.5])
    }

    /// Multi-block range no longer collapses to the first block: with 108 rows
    /// the user can pick a high start path like 107.5 and get a valid sequence.
    /// Single block whose actual rows are 69–108: available paths run from
    /// 68.5 to 108.5 (not 0.5–40.5). Verify Every Second Row honours those
    /// actual numbers.
    @Test func everySecondRow_singleBlock_rows69to108_actualNumbers() {
        // Mimic StartTripSheet's availablePaths for a paddock with rows 69–108.
        let rowNumbers = Array(69...108)
        var set = Set<Double>()
        for n in rowNumbers {
            set.insert(Double(n) - 0.5)
            set.insert(Double(n) + 0.5)
        }
        let paths = set.sorted()
        #expect(paths.first == 68.5)
        #expect(paths.last == 108.5)
        #expect(paths.count == 41)

        let seq = StartTripSheet.everySecondRowSequence(
            paths: paths,
            startPath: 100.5,
            higherFirst: false
        )
        #expect(seq.first == 100.5)
        #expect(Array(seq.prefix(3)) == [100.5, 98.5, 96.5])
        // First run descends to 68.5 then wraps to highest same-parity path.
        if let zeroIdx = seq.firstIndex(of: 68.5) {
            #expect(seq[zeroIdx + 1] == 108.5)
        }
        #expect(seq.last == 102.5)
    }

    @Test func everySecondRow_multiBlock_allowsHighStartPath() {
        let paths = (0...108).map { Double($0) + 0.5 }
        let seq = StartTripSheet.everySecondRowSequence(
            paths: paths,
            startPath: 107.5,
            higherFirst: false
        )
        // 107.5 parity = halves of odd integers (1.5, 3.5, …, 107.5) → 54 entries.
        #expect(seq.first == 107.5)
        #expect(Array(seq.prefix(3)) == [107.5, 105.5, 103.5])
        #expect(seq.last == nil ? false : seq.contains(1.5))
    }

    // MARK: - Other patterns still produce sensible sequences against combined rows

    @Test func sequential_combinedRange_108() {
        let seq = TrackingPattern.sequential.generateSequence(startRow: 1, totalRows: 108)
        #expect(seq.count == 109)
        #expect(seq.first == 0.5)
        #expect(seq.last == 108.5)
    }

    @Test func upAndBack_combinedRange_eachPathTwice() {
        let n = 108
        let seq = TrackingPattern.upAndBack.generateSequence(startRow: 1, totalRows: n)
        #expect(seq.count == (n + 1) * 2)
        #expect(Array(seq.prefix(4)) == [0.5, 0.5, 1.5, 1.5])
    }

    @Test func fiveThree_combinedRange_visitsEveryPath() {
        let n = 108
        let seq = TrackingPattern.fiveThree.generateSequence(startRow: 1, totalRows: n)
        let unique = Set(seq)
        #expect(unique.count == n + 1)
        #expect(seq.first == 0.5)
    }

    @Test func twoRowUpBack_combinedRange_visitsEveryPath() {
        let n = 108
        let seq = TrackingPattern.twoRowUpBack.generateSequence(startRow: 1, totalRows: n)
        let unique = Set(seq)
        #expect(unique.count == n + 1)
    }

    @Test func custom_combinedRange_isSequential() {
        let seq = TrackingPattern.custom.generateSequence(startRow: 1, totalRows: 108)
        #expect(seq.count == 109)
        #expect(seq.first == 0.5)
        #expect(seq.last == 108.5)
    }

    // MARK: - Detail / summary use rowSequence.first

    /// Sanity: the start-midrow surfaced in TripDetailView / TripSummarySheet is
    /// the first element of rowSequence, which must equal the chosen start path.
    @Test func everySecondRow_firstElementIsStartPath() {
        let paths = (0...108).map { Double($0) + 0.5 }
        let lower = StartTripSheet.everySecondRowSequence(paths: paths, startPath: 100.5, higherFirst: false)
        let higher = StartTripSheet.everySecondRowSequence(paths: paths, startPath: 100.5, higherFirst: true)
        #expect(lower.first == 100.5)
        #expect(higher.first == 100.5)
    }

    // MARK: - Soil-Aware Irrigation v2

    private static func forecast(days: Int, etoPerDay: Double, rainPerDay: Double = 0) -> [ForecastDay] {
        let base = Date(timeIntervalSince1970: 0)
        return (0..<days).map { i in
            ForecastDay(
                date: Calendar.current.date(byAdding: .day, value: i, to: base) ?? base,
                forecastEToMm: etoPerDay,
                forecastRainMm: rainPerDay
            )
        }
    }

    private static func settings(rate: Double = 4.0) -> IrrigationSettings {
        IrrigationSettings(
            irrigationApplicationRateMmPerHour: rate,
            cropCoefficientKc: 0.7,
            irrigationEfficiencyPercent: 90,
            rainfallEffectivenessPercent: 80,
            replacementPercent: 100,
            soilMoistureBufferMm: 0
        )
    }

    /// Sandy soil with low AWC / shallow root depth → RAW cap + split suggested.
    @Test func v2_sandySoil_capsAtRawAndSuggestsSplit() {
        let soil = SoilProfileInputs(
            irrigationSoilClass: "sand_loamy_sand",
            availableWaterCapacityMmPerM: 70,
            effectiveRootDepthM: 0.4,
            managementAllowedDepletionPercent: 40,
            modelVersion: "test"
        )
        let r = IrrigationCalculator.calculate(
            forecastDays: Self.forecast(days: 7, etoPerDay: 8),
            settings: Self.settings(),
            soil: soil,
            soilAwareV2Enabled: true
        )
        #expect(r != nil)
        let v2 = r?.v2
        #expect(v2 != nil)
        #expect(v2?.splitSuggested == true)
        // RAW = 70 * 0.4 * 0.4 = 11.2 mm — adjusted event should equal that.
        if let adj = v2?.soilAdjustedGrossMm, let base = v2?.baseGrossIrrigationMm {
            #expect(adj < base)
            #expect(abs(adj - 11.2) < 0.5)
        }
    }

    /// Heavy clay + heavy forecast rain → delay urgency + caution.
    @Test func v2_clayWithForecastRain_delays() {
        let soil = SoilProfileInputs(
            irrigationSoilClass: "clay_heavy_clay",
            availableWaterCapacityMmPerM: 180,
            effectiveRootDepthM: 0.8,
            managementAllowedDepletionPercent: 50,
            modelVersion: "test"
        )
        let r = IrrigationCalculator.calculate(
            forecastDays: Self.forecast(days: 5, etoPerDay: 6, rainPerDay: 4),
            settings: Self.settings(),
            soil: soil,
            soilAwareV2Enabled: true
        )
        #expect(r?.v2?.urgency == .delayRainLikely)
        #expect(r?.v2?.cautionText != nil)
        #expect(r?.v2?.splitSuggested == false)
    }

    /// Deep loam with good RAW → close to base recommendation, no split.
    @Test func v2_deepLoam_matchesBaseRecommendation() {
        let soil = SoilProfileInputs(
            irrigationSoilClass: "loam",
            availableWaterCapacityMmPerM: 150,
            effectiveRootDepthM: 1.0,
            managementAllowedDepletionPercent: 50,
            modelVersion: "test"
        )
        let r = IrrigationCalculator.calculate(
            forecastDays: Self.forecast(days: 7, etoPerDay: 7),
            settings: Self.settings(),
            soil: soil,
            soilAwareV2Enabled: true
        )
        let v2 = r?.v2
        #expect(v2?.splitSuggested == false)
        if let adj = v2?.soilAdjustedGrossMm, let base = v2?.baseGrossIrrigationMm {
            #expect(abs(adj - base) < 0.5)
        }
    }

    /// Missing soil profile → v2 still produces a result with a caution.
    @Test func v2_missingSoil_fallsBackWithWarning() {
        let r = IrrigationCalculator.calculate(
            forecastDays: Self.forecast(days: 5, etoPerDay: 6),
            settings: Self.settings(),
            soil: .empty,
            soilAwareV2Enabled: true
        )
        #expect(r?.v2 != nil)
        #expect(r?.v2?.cautionText != nil)
        #expect(r?.v2?.splitSuggested == false)
    }

    /// v2 flag OFF → v1-only result (no v2 payload).
    @Test func v2_flagOff_returnsNilV2() {
        let r = IrrigationCalculator.calculate(
            forecastDays: Self.forecast(days: 5, etoPerDay: 6),
            settings: Self.settings(),
            soil: .empty,
            soilAwareV2Enabled: false
        )
        #expect(r?.v2 == nil)
    }
}
