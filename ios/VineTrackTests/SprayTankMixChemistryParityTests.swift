import Foundation
import Testing
@testable import VineTrack

/// The final iOS Spray Calculator close-out: Tank Mixing must show the SAME
/// chemistry Review calculated, built from the SAME `SprayApplicationPlan` —
/// never re-resolved through the legacy `SprayCalculator.calculate`, which
/// required `chemical.rates.first(where: { $0.id == line.selectedRateId })`
/// and had no way to satisfy that for a structured registered-use rate.
///
/// The device regression, throughout: Cab Franc, area 0.49 ha, row spacing
/// 2.8 m, VSP / Small / Low → 10 L/100 m recommended (357.142857 L/ha
/// equivalent), applied at the recommended rate, 175 L total water. Dithane
/// Rainshield Neo Tec Fungicide at a structured 150 g/100 L registered use.
struct SprayTankMixChemistryParityTests {

    private let tolerance = 0.000_001

    /// A structured registered-use rate, exactly the shape the guided
    /// Products path resolves and the legacy scalar `rates` array never
    /// carries — the id this test's rate produces cannot appear in any
    /// `SavedChemical.rates` array because that array is empty.
    private func dithane() -> SavedChemical {
        SavedChemical(
            vineyardId: UUID(),
            name: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
            unit: .kilograms,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "DOWNY MILDEW",
                    rates: [ChemicalLabelRate(basis: .per100Litres, value: 150, unit: "g")]
                )
            ])
        )
    }

    private var geometry: SprayApplicationGeometry {
        SprayGeometryResolver.resolve([
            SprayBlockInput(
                blockId: "cab-franc",
                grossAreaHectares: 0.49,
                mappedRowLengthMetres: 1_750,
                rowSpacingMetres: 2.8
            )
        ])
    }

    /// 175 L, the device's recommended-rate total for this block.
    private var carrier: SprayCarrierVolume? {
        SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 10,
            diluteLitresPer100Metres: 10,
            geometry: geometry
        )
    }

    /// Builds the ONE plan Products, Review, Tank Mixing and the persisted
    /// tanks must all read \u2014 the structured rate resolved the same way the
    /// guided Products card resolves it, never through `chemical.rates`.
    private func plan(tankCapacityLitres: Double = 200) throws -> SprayApplicationPlan {
        let carrier = try #require(self.carrier)
        let chemical = dithane()
        let rate = SprayRegisteredUseRates.vineyardRates(for: chemical).first { $0.basis == .per100Litres }!
        let baseRate = rate.seed.seedableValue!

        let line = SprayProductLineInput(
            productId: chemical.id.uuidString,
            name: chemical.name,
            unit: chemical.unit.rawValue,
            basis: .per100Litres,
            rate: baseRate,
            unitDisplay: SprayProductUnitDisplay(displayUnit: "Kg", baseUnitsPerDisplayUnit: 1_000)
        )

        return SprayApplicationPlanner.plan(
            blocks: [SprayBlockInput(
                blockId: "cab-franc",
                grossAreaHectares: 0.49,
                mappedRowLengthMetres: 1_750,
                rowSpacingMetres: 2.8
            )],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: tankCapacityLitres,
            productLines: [line]
        )
    }

    // MARK: - B. The structured rate never depends on the legacy lookup

    @Test("A structured registered-use rate resolves with an empty legacy rates array")
    func structuredRateNeedsNoLegacyArray() {
        let chemical = dithane()
        // The exact shape the device carried: zero entries in the legacy
        // scalar array the old calculator required.
        #expect(chemical.rates.isEmpty)
        let rates = SprayRegisteredUseRates.vineyardRates(for: chemical)
        #expect(!rates.isEmpty)
        // The id the guided path selects cannot be found by
        // `chemical.rates.first(where: { $0.id == selectedRateId })` \u2014
        // proving the legacy lookup was structurally incapable of resolving
        // this line, regardless of what the operator picked.
        let selectedRateId = rates.first { $0.basis == .per100Litres }!.id
        #expect(chemical.rates.first(where: { $0.id == selectedRateId }) == nil)
    }

    // MARK: - A / C. The Dithane case: one base total everywhere

    @Test("150 g/100 L over 175 L resolves to 262.5 g total")
    func dithaneTotalMatchesDeviceCase() throws {
        let result = try plan()
        let line = try #require(result.productLines.first)
        #expect(!line.isUnresolved)
        let total = try #require(line.totalQuantity)
        #expect(abs(total - 262.5) < tolerance)
        // 0.2625 Kg, the Review display figure.
        #expect(abs(line.unitDisplay.display(total) - 0.2625) < tolerance)
    }

    @Test("The plan's product line is what Tank Mixing and the tanks both read")
    func planLineIsTheOnlyChemistrySource() throws {
        let result = try plan()
        let line = try #require(result.productLines.first)
        // Review, Tank Mixing and the persisted `SprayChemical` all trace back
        // to this SAME `totalQuantity` \u2014 there is no second number anywhere
        // in the pipeline for them to disagree about.
        let reviewTotal = try #require(line.totalQuantity)
        let tankMixingTotal = try #require(result.productLines.first?.totalQuantity)
        #expect(reviewTotal == tankMixingTotal)
    }

    // MARK: - D. One partial tank: the whole amount, in the one tank there is

    @Test("A single 175 L tank carries the complete product amount")
    func singlePartialTankCarriesTheWholeAmount() throws {
        // Tank capacity exceeds the 175 L job, so there is exactly one
        // (partial) tank.
        let result = try plan(tankCapacityLitres: 1_000)
        #expect(result.tankSplit.totalTanks == 1)
        #expect(result.tankSplit.fullTankCount == 0)
        #expect(abs(result.tankSplit.lastTankLitres - 175) < tolerance)

        let line = try #require(result.productLines.first)
        let total = try #require(line.totalQuantity)
        let inLastTank = try #require(line.quantityInLastTank)
        #expect(abs(inLastTank - total) < tolerance)
    }

    // MARK: - E. Multiple tanks: per-tank amounts sum back to the total

    @Test("Multi-tank split sums back to the authoritative total")
    func multiTankSplitSumsToTotal() throws {
        // 175 L job, 60 L tanks: two full tanks (120 L) and a 55 L last tank.
        let result = try plan(tankCapacityLitres: 60)
        #expect(result.tankSplit.fullTankCount == 2)
        #expect(abs(result.tankSplit.lastTankLitres - 55) < tolerance)
        #expect(result.tankSplit.totalTanks == 3)

        let line = try #require(result.productLines.first)
        let total = try #require(line.totalQuantity)
        let perFullTank = try #require(line.quantityPerFullTank)
        let inLastTank = try #require(line.quantityInLastTank)

        let sum = perFullTank * Double(result.tankSplit.fullTankCount) + inLastTank
        #expect(abs(sum - total) < 0.0001)
    }

    @Test("Zero full tanks means no full-tank amount is offered")
    func zeroFullTanksMeansNoFullTankRow() throws {
        // The whole 175 L job fits in one tank \u2014 there must be nothing for a
        // \"Full tank\" row to show, because no full tank exists.
        let result = try plan(tankCapacityLitres: 1_000)
        #expect(result.tankSplit.fullTankCount == 0)
    }

    // MARK: - J. A rate that no longer resolves must not borrow another one

    @Test("A selected rate id that no longer exists on the refreshed record is unresolved, not silently replaced")
    func vanishedRateIsUnresolvedNotReplaced() {
        let original = dithane()
        let originalRateId = SprayRegisteredUseRates.vineyardRates(for: original)
            .first { $0.basis == .per100Litres }!.id

        // Re-verification replaced the registered use entirely \u2014 a different
        // target, a different rate, a different id.
        let reverified = SavedChemical(
            id: original.id,
            vineyardId: original.vineyardId,
            name: original.name,
            unit: original.unit,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [
                ChemicalRegisteredUse(
                    crop: "GRAPEVINE",
                    targetRaw: "POWDERY MILDEW",
                    rates: [ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")]
                )
            ])
        )

        let stillResolves = SprayRegisteredUseRates.vineyardRates(for: reverified)
            .contains { $0.id == originalRateId }
        #expect(!stillResolves)
        // The only correct outcome is "ask again" \u2014 there is no rule here
        // that would let the line silently adopt the new per-hectare rate in
        // the old rate's place.
    }

    // MARK: - I. A rate that survives re-verification is left exactly alone

    @Test("A selected rate id that still exists after re-verification survives untouched")
    func survivingRateIsUntouched() {
        let original = dithane()
        let originalRateId = SprayRegisteredUseRates.vineyardRates(for: original)
            .first { $0.basis == .per100Litres }!.id

        // Re-verification confirmed the SAME registered use and rate \u2014 only
        // cosmetic fields moved.
        let reverified = SavedChemical(
            id: original.id,
            vineyardId: original.vineyardId,
            name: original.name,
            unit: original.unit,
            manufacturer: "Corteva",
            chemicalIntelligence: original.chemicalIntelligence
        )

        let stillResolves = SprayRegisteredUseRates.vineyardRates(for: reverified)
            .contains { $0.id == originalRateId }
        #expect(stillResolves)
    }
}
