import Foundation
import Testing
@testable import VineTrack

/// P6 — Spray Tool calculation parity (iOS).
///
/// These drive the CALCULATION AUTHORITY directly — `SprayGeometryResolver`,
/// `SprayCarrierVolumeCalculator`, `SprayBandedAreaCalculator`,
/// `SprayProductQuantityCalculator` and `SprayApplicationPlanner` — because that
/// is the only place a displayed number may come from. A rule asserted against
/// the view could pass while the persisted record disagrees.
///
/// The eight P6 regression cases are covered end to end:
///   normal foliar L/ha, foliar L/100 m, concentrated L/100 m,
///   banded + treated-ha rate, banded + per-100 L rate, rate range,
///   reference-only `basis:"other"`, unresolved rate.
struct SprayCalculationParityTests {

    // MARK: - Fixtures

    /// A 10.00 ha block, 3.2 m row spacing, 31,250 m of mapped row.
    ///
    /// The numbers are self-consistent on purpose: 10 ha ÷ 3.2 m spacing is
    /// exactly 31,250 m of row, so the derived and mapped paths must agree and
    /// any double-counting shows up as an exact factor rather than a rounding
    /// smudge.
    private func block(
        id: String = "b1",
        areaHa: Double? = 10,
        rowMetres: Double? = 31_250,
        spacing: Double? = 3.2
    ) -> SprayBlockInput {
        SprayBlockInput(
            blockId: id,
            blockName: "Block \(id)",
            grossAreaHectares: areaHa,
            mappedRowLengthMetres: rowMetres,
            rowSpacingMetres: spacing
        )
    }

    private func product(
        _ name: String,
        basis: SprayProductRateBasis,
        rate: Double,
        unit: String = "L"
    ) -> SprayProductLineInput {
        SprayProductLineInput(
            productId: name, name: name, unit: unit, basis: basis, rate: rate
        )
    }

    private func line(
        _ plan: SprayApplicationPlan, _ name: String
    ) throws -> SprayProductLineResult {
        try #require(plan.productLines.first { $0.name == name })
    }

    // MARK: - P6B: L/ha mode is unchanged

    @Test func normalFoliarPerHectare() throws {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500, areaHectares: 10
        )
        // 500 L/ha × 10 ha = 5,000 L
        #expect(carrier.totalLitres == 5_000)
        #expect(carrier.litresPerHectare == 500)
        #expect(carrier.concentrationFactor == 1.0)
        // L/ha mode never invents row-length figures.
        #expect(carrier.diluteLitresPer100Metres == nil)
        #expect(carrier.appliedLitresPer100Metres == nil)

        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [product("Fungicide", basis: .wholeBlockArea, rate: 2)]
        )
        #expect(plan.grossAreaHectares == 10)
        // Whole-block foliar: treated area IS gross area.
        #expect(plan.treatedAreaHectares == 10)
        // 2 L/ha × 10 ha = 20 L
        #expect(try line(plan, "Fungicide").totalQuantity == 20)
        #expect(try line(plan, "Fungicide").basisInput == 10)
    }

    // MARK: - P6B: L/100 m mode

    @Test func foliarPer100Metres() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        #expect(geometry.totalRowLengthMetres == 31_250)
        #expect(geometry.uniformRowSpacingMetres == 3.2)

        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10, geometry: geometry
            )
        )
        // total L = (row length ÷ 100) × applied L/100 m
        //         = (31,250 ÷ 100) × 10 = 3,125 L
        #expect(carrier.totalLitres == 3_125)
        // L/ha = applied L/100 m × 100 ÷ row spacing = 10 × 100 ÷ 3.2 = 312.5
        #expect(carrier.litresPerHectare == 312.5)
        #expect(carrier.appliedLitresPer100Metres == 10)
        // No dilute reference given, so this is a dilute application.
        #expect(carrier.concentrationFactor == 1.0)
        #expect(carrier.rowLengthMetres == 31_250)
        // The derived L/ha survives for storage/reporting.
        #expect(carrier.basis == .litresPer100Metres)
    }

    @Test func derivedLitresPerHectareNeedsUniformSpacing() throws {
        // Mixed spacings must NOT be averaged into a derived L/ha: an averaged
        // spacing is wrong for every block in the set.
        let geometry = SprayGeometryResolver.resolve([
            block(id: "a", areaHa: 5, rowMetres: 15_625, spacing: 3.2),
            block(id: "b", areaHa: 5, rowMetres: 12_500, spacing: 4.0),
        ])
        #expect(geometry.uniformRowSpacingMetres == nil)
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10, geometry: geometry
            )
        )
        // Total litres still resolve from summed row metres…
        #expect(carrier.totalLitres == 28_125 / 100 * 10)
        // …but L/ha is refused rather than guessed.
        #expect(carrier.litresPerHectare == nil)
    }

    // MARK: - P6B: concentrated spraying

    @Test func concentratedPer100Metres() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10,
                diluteLitresPer100Metres: 20,
                geometry: geometry
            )
        )
        // The DILUTE reference must never become the applied volume: total
        // carrier is still driven by the 10 L/100 m actually applied.
        #expect(carrier.totalLitres == 3_125)
        #expect(carrier.appliedLitresPer100Metres == 10)
        #expect(carrier.diluteLitresPer100Metres == 20)
        // concentration factor = dilute ÷ applied = 20 ÷ 10 = 2×
        #expect(carrier.concentrationFactor == 2.0)
        // Dilute-equivalent litres are what a per-100 L label is written against.
        #expect(carrier.diluteEquivalentLitres == 6_250)

        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [product("Adjuvant", basis: .per100Litres, rate: 100, unit: "mL")]
        )
        // A per-100 L rate is written against the DILUTE volume, so
        // concentrating must not reduce the dose:
        // 100 mL × 3,125 L ÷ 100 × 2 = 6,250 mL
        #expect(try line(plan, "Adjuvant").totalQuantity == 6_250)
        // The measured half stays the ACTUAL carrier litres.
        #expect(try line(plan, "Adjuvant").basisInput == 3_125)
    }

    @Test func diluteBelowAppliedIsNotAConcentration() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 20,
                diluteLitresPer100Metres: 10,
                geometry: geometry
            )
        )
        // Applying MORE water than dilute/runoff is not a concentration; the
        // factor floors at 1.0 rather than silently reducing product.
        #expect(carrier.concentrationFactor == 1.0)
    }

    @Test func switchingModesDoesNotReinterpretValues() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        // The same geometry, entered each way, produces two clearly-labelled
        // results — neither borrows the other's numbers.
        let perHa = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500,
            areaHectares: geometry.grossAreaHectares,
            rowLengthMetres: geometry.totalRowLengthMetres,
            rowSpacingMetres: geometry.uniformRowSpacingMetres
        )
        let per100m = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10, geometry: geometry
            )
        )
        #expect(perHa.basis == .litresPerHectare)
        #expect(per100m.basis == .litresPer100Metres)
        // A L/ha carrier carries no L/100 m rates…
        #expect(perHa.appliedLitresPer100Metres == nil)
        // …and a L/100 m carrier records no entered hectares.
        #expect(per100m.areaHectaresUsed == nil)
        // The two totals are genuinely different quantities and must not be
        // conflated by a mode switch.
        #expect(perHa.totalLitres == 5_000)
        #expect(per100m.totalLitres == 3_125)
    }

    // MARK: - P6C: banded applications

    @Test func bandedTreatedAreaRate() throws {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500, areaHectares: 10
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .banded,
            bandWidth: .total(0.8),
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [
                product("Herbicide", basis: .treatedArea, rate: 2),
                product("Whole block", basis: .wholeBlockArea, rate: 2),
            ]
        )
        // treated area = row length × total band width ÷ 10,000
        //              = 31,250 × 0.8 ÷ 10,000 = 2.50 ha
        #expect(plan.treatedAreaHectares == 2.5)
        // Gross is RETAINED alongside it, never replaced.
        #expect(plan.grossAreaHectares == 10)
        #expect(plan.treatedArea.method == .canonicalRowLength)
        #expect(plan.treatedArea.treatedFraction == 0.25)

        // Per-treated-ha and per-gross-ha stay distinct quantities.
        #expect(try line(plan, "Herbicide").totalQuantity == 5)   // 2 × 2.5
        #expect(try line(plan, "Whole block").totalQuantity == 20) // 2 × 10
        #expect(try line(plan, "Herbicide").basisInput == 2.5)
        #expect(try line(plan, "Whole block").basisInput == 10)
    }

    @Test func bandedPer100LitresUsesCarrierNotArea() throws {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500, areaHectares: 10
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .banded,
            bandWidth: .total(0.8),
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [product("Adjuvant", basis: .per100Litres, rate: 100, unit: "mL")]
        )
        // 100 mL × 5,000 L ÷ 100 = 5,000 mL. The 2.5 ha treated area is
        // irrelevant to a per-100 L rate and must not scale it.
        #expect(try line(plan, "Adjuvant").totalQuantity == 5_000)
        #expect(try line(plan, "Adjuvant").basisInput == 5_000)
        // The treated area is still calculated and reported for the pass.
        #expect(plan.treatedAreaHectares == 2.5)
    }

    @Test func bandedWithPer100MetresCarrierAppliesRowLengthOnce() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10, geometry: geometry
            )
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .banded,
            bandWidth: .total(0.8),
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [
                product("Adjuvant", basis: .per100Litres, rate: 100, unit: "mL"),
                product("Herbicide", basis: .treatedArea, rate: 2),
                product("Distance", basis: .per100Metres, rate: 1),
            ]
        )
        // Row length is used ONCE in each independent quantity:
        // carrier  = 31,250 ÷ 100 × 10           = 3,125 L
        #expect(plan.totalCarrierLitres == 3_125)
        // treated  = 31,250 × 0.8 ÷ 10,000       = 2.5 ha
        #expect(plan.treatedAreaHectares == 2.5)
        // per-100 L rides the carrier only: 100 × 3,125 ÷ 100 = 3,125 mL
        #expect(try line(plan, "Adjuvant").totalQuantity == 3_125)
        // treated-area rides the band only: 2 × 2.5 = 5 L
        #expect(try line(plan, "Herbicide").totalQuantity == 5)
        // per-100 m rides row metres only: 1 × 31,250 ÷ 100 = 312.5 L
        #expect(try line(plan, "Distance").totalQuantity == 312.5)
    }

    @Test func missingBandWidthFailsClearly() throws {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500, areaHectares: 10
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .banded,
            bandWidth: nil,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [product("Herbicide", basis: .treatedArea, rate: 2)]
        )
        // No band width: treated area is UNAVAILABLE, never quietly gross.
        #expect(plan.treatedAreaHectares == nil)
        #expect(plan.treatedArea.method == .unavailable)
        #expect(plan.grossAreaHectares == 10)
        // The product line fails loudly rather than dosing against gross.
        let herbicide = try line(plan, "Herbicide")
        #expect(herbicide.totalQuantity == nil)
        #expect(herbicide.isUnresolved)
        #expect(herbicide.unresolvedReason == .treatedAreaUnavailable)
    }

    @Test func bandedFallsBackToAreaAndSpacingWithoutRowLength() throws {
        // No mapped rows and no override, but area and spacing are known:
        // 10 ha × 0.8 m ÷ 3.2 m = 2.5 ha — the same answer the canonical form
        // gives, because the derived row length is 31,250 m.
        let treated = SprayBandedAreaCalculator.banded(
            geometry: SprayGeometryResolver.resolve(
                [block(rowMetres: nil, spacing: 3.2)]
            ),
            bandWidth: .total(0.8)
        )
        #expect(treated.treatedAreaHectares == 2.5)
        // Derived geometry still resolves a row length, so this is the
        // canonical path rather than the fallback.
        #expect(treated.method == .canonicalRowLength)

        // With NO spacing at all there is nothing to derive from, and the
        // calculator refuses rather than applying a fixed fraction.
        let unusable = SprayBandedAreaCalculator.banded(
            geometry: SprayGeometryResolver.resolve(
                [block(rowMetres: nil, spacing: nil)]
            ),
            bandWidth: .total(0.8)
        )
        #expect(unusable.treatedAreaHectares == nil)
        #expect(unusable.method == .unavailable)
    }

    // MARK: - P6A: product rate handling

    @Test func rateRangeIsPreservedAndProposesTheLowEnd() throws {
        let range = ChemicalLabelRate(
            label: "Dilute",
            basis: .rangePer100Litres,
            minValue: 40,
            maxValue: 60,
            unit: "mL",
            rawText: "40–60 mL/100 L"
        )
        // A range keeps BOTH bounds — it never collapses to one number.
        #expect(range.minValue == 40)
        #expect(range.maxValue == 60)
        #expect(range.value == nil)
        #expect(range.displayRate == "40–60 mL/100 L")
        // A calculation starts from the LOW end so an automatic suggestion can
        // never inflate a dose on the operator's behalf.
        #expect(range.proposedValue == 40)
        // A range still maps onto exactly one spray-side basis.
        #expect(range.basis.compatibleProductRateBases == [.per100Litres])
        #expect(range.basis.isVolumeBased)
    }

    @Test func referenceOnlyOtherBasisInventsNothing() throws {
        let other = ChemicalLabelRate(
            label: "",
            basis: .other,
            unit: "",
            rawText: "Refer to the approved label for grapevine rates"
        )
        // Reference-only: no number is invented in any field.
        #expect(other.value == nil)
        #expect(other.minValue == nil)
        #expect(other.maxValue == nil)
        #expect(other.proposedValue == nil)
        #expect(other.displayRate == "Refer to the approved label for grapevine rates")
        // And it offers NO spray-side basis, so it can never be applied.
        #expect(other.basis.compatibleProductRateBases.isEmpty)
        #expect(!other.basis.isAreaBased)
        #expect(!other.basis.isVolumeBased)
    }

    @Test func labelBasesMapOntoTheSprayBasesTheyAllow() throws {
        // An area label is exactly the whole-block vs treated-band ambiguity
        // the banded picker exists to resolve.
        #expect(ChemicalLabelRateBasis.perHectare.compatibleProductRateBases
            == [.wholeBlockArea, .treatedArea])
        #expect(ChemicalLabelRateBasis.rangePerHectare.compatibleProductRateBases
            == [.wholeBlockArea, .treatedArea])
        // A per-100 L label maps to one option, so no picker is warranted.
        #expect(ChemicalLabelRateBasis.per100Litres.compatibleProductRateBases
            == [.per100Litres])
    }

    @Test func registeredUseRatesStayTiedToTheirCropAndTarget() throws {
        let powdery = ChemicalRegisteredUse(
            crop: "GRAPEVINE",
            targetRaw: "POWDERY MILDEW",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 1.5, unit: "L")]
        )
        let downy = ChemicalRegisteredUse(
            crop: "GRAPEVINE",
            targetRaw: "DOWNY MILDEW",
            rates: [ChemicalLabelRate(basis: .perHectare, value: 2.5, unit: "L")]
        )
        let intel = ChemicalIntelligence(registeredUses: [powdery, downy])

        // Each rate belongs to ONE crop/target pair; the rates are never
        // pooled into an anonymous list the calculator could pick from.
        #expect(powdery.rates.first?.value == 1.5)
        #expect(downy.rates.first?.value == 2.5)
        #expect(powdery.target == .powderyMildew)
        #expect(downy.target == .downyMildew)
        #expect(powdery.id != downy.id)
        // Distinct bases are summarised without losing that ownership.
        #expect(intel.labelRateBases == [.perHectare])
        #expect(intel.registeredUses.count == 2)
    }

    // MARK: - P6A: an unresolved rate is never a zero dose

    @Test func unresolvedRateIsUnresolvedNotZero() throws {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 500, areaHectares: 10
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .wholeBlock,
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: [
                product("Unrated", basis: .wholeBlockArea, rate: 0),
                product("Rated", basis: .wholeBlockArea, rate: 2),
            ]
        )
        let unrated = try line(plan, "Unrated")
        // A product with no rate is UNRESOLVED — not a product applied at zero.
        #expect(unrated.totalQuantity == nil)
        #expect(unrated.isUnresolved)
        // And the reason names the PRODUCT, not the block geometry, so the
        // operator is not sent to the wrong screen.
        #expect(unrated.unresolvedReason == .rateUnavailable)
        #expect(plan.unresolvedProductLines.map(\.name) == ["Unrated"])
        // The rest of the mix is unaffected.
        #expect(try line(plan, "Rated").totalQuantity == 20)
    }

    @Test func unresolvedRateIsRejectedOnEveryBasis() throws {
        let geometry = SprayGeometryResolver.resolve([block()])
        let carrier = try #require(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres: 10, geometry: geometry
            )
        )
        let bases: [SprayProductRateBasis] =
            [.wholeBlockArea, .treatedArea, .per100Litres, .per100Metres]
        let plan = SprayApplicationPlanner.plan(
            blocks: [block()],
            mode: .banded,
            bandWidth: .total(0.8),
            carrier: carrier,
            tankCapacityLitres: 2_000,
            productLines: bases.map {
                product("Zero \($0.rawValue)", basis: $0, rate: 0)
            }
        )
        // Every basis has a real measured input available here — only the RATE
        // is missing, and that alone is enough to refuse a quantity.
        #expect(plan.unresolvedProductLines.count == bases.count)
        for result in plan.productLines {
            #expect(result.totalQuantity == nil)
            #expect(result.unresolvedReason == .rateUnavailable)
        }
    }

    @Test func negativeAndNonFiniteRatesAreRefused() throws {
        let context = SprayQuantityContext(grossAreaHectares: 10, carrierLitres: 5_000)
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: -2, basis: .wholeBlockArea, context: context) == nil)
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: .nan, basis: .wholeBlockArea, context: context) == nil)
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: .infinity, basis: .wholeBlockArea, context: context) == nil)
        // A real rate still calculates.
        #expect(SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .wholeBlockArea, context: context) == 20)
    }

    // MARK: - Geometry precedence feeding the calculations

    @Test func operatorOverrideOutranksMappedGeometry() throws {
        let resolved = SprayGeometryResolver.resolve(
            SprayBlockInput(
                blockId: "b1",
                grossAreaHectares: 10,
                mappedRowLengthMetres: 31_250,
                operatorRowLengthOverrideMetres: 30_000,
                rowSpacingMetres: 3.2
            )
        )
        #expect(resolved.rowLengthMetres == 30_000)
        #expect(resolved.source == .operatorOverride)
        #expect(resolved.quality == .authoritative)
    }

    @Test func partialGeometryRefusesATotal() throws {
        // One unusable block makes the whole selection unusable: a silently
        // short row length under-doses the entire tank mix.
        let geometry = SprayGeometryResolver.resolve([
            block(id: "good"),
            block(id: "bad", areaHa: 5, rowMetres: nil, spacing: nil),
        ])
        #expect(geometry.totalRowLengthMetres == nil)
        #expect(!geometry.isUsable)
        #expect(geometry.unavailableMessage != nil)
        // A L/100 m carrier cannot be built on it.
        #expect(SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 10, geometry: geometry) == nil)
    }
}
