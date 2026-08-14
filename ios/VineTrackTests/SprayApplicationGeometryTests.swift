import Foundation
import Testing
@testable import VineTrack

/// SPRAY APPLICATION GEOMETRY (sql/191) — the iOS twin of
/// `SprayApplicationGeometryTest.kt`. Both suites assert the SAME fixtures and
/// the SAME expected numbers, so any divergence between the platforms fails a
/// build.
///
/// The shared fixture, used throughout:
/// * a 10 ha block, 31,250 m of mapped row (125 rows × 250 m), 3.2 m spacing;
/// * a 0.8 m total treated band → 2.50 ha treated;
/// * 40 L/100 m dilute, 20 L/100 m applied → 6,250 L carrier, 2.0× concentration.
struct SprayApplicationGeometryTests {

    // MARK: - Shared fixtures

    private let tolerance = 1e-9

    /// 10 ha, fully mapped: 31,250 m of row at 3.2 m spacing.
    private var mappedBlock: SprayBlockInput {
        SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            rowSpacingMetres: 3.2,
            rowCount: 125
        )
    }

    /// 10 ha at 3.2 m spacing with NO mapped rows and no stored length, so the
    /// length has to be derived: 10 × 10,000 / 3.2 = 31,250 m.
    private var derivableBlock: SprayBlockInput {
        SprayBlockInput(blockId: "B", grossAreaHectares: 10, rowSpacingMetres: 3.2)
    }

    private let band = SprayBandWidth.total(0.8)

    // MARK: - Canonical geometry

    @Test func mappedRowGeometryIsAuthoritative() {
        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        #expect(geometry.totalRowLengthMetres == 31_250)
        #expect(geometry.source == .mappedRows)
        #expect(geometry.quality == .authoritative)
        #expect(geometry.grossAreaHectares == 10)
        #expect(geometry.rowCount == 125)
        #expect(geometry.uniformRowSpacingMetres == 3.2)
        #expect(geometry.isUsable)
    }

    @Test func mappedRowGeometryWinsOverAStoredLength() {
        // Real measured geometry outranks a stored figure. This is deliberately
        // the OPPOSITE of the legacy `Paddock.effectiveTotalRowLength`
        // (override-wins), which is left untouched for irrigation/vine counts.
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            mappedRowLengthMetres: 31_250,
            storedRowLengthMetres: 99_999,
            rowSpacingMetres: 3.2
        )
        let geometry = SprayGeometryResolver.resolve([block])
        #expect(geometry.totalRowLengthMetres == 31_250)
        #expect(geometry.source == .mappedRows)
    }

    @Test func storedRowLengthIsUsedWhenNothingIsMapped() {
        let block = SprayBlockInput(
            blockId: "A",
            grossAreaHectares: 10,
            storedRowLengthMetres: 30_000,
            rowSpacingMetres: 3.2
        )
        let geometry = SprayGeometryResolver.resolve([block])
        #expect(geometry.totalRowLengthMetres == 30_000)
        #expect(geometry.source == .storedRowLength)
        #expect(geometry.quality == .authoritative)
    }

    @Test func rowLengthIsDerivedFromAreaAndSpacing() {
        // 10 ha × 10,000 / 3.2 m = 31,250 m — the same figure the mapped block
        // measures, which is why the banded fallback agrees with the primary form.
        let geometry = SprayGeometryResolver.resolve([derivableBlock])
        #expect(abs((geometry.totalRowLengthMetres ?? 0) - 31_250) < tolerance)
        #expect(geometry.source == .derivedFromAreaAndSpacing)
        #expect(geometry.quality == .derived)
        #expect(geometry.isUsable)
    }

    @Test func missingRowSpacingIsIncompleteNotDefaultedTo2Point5() {
        // The whole point of the engine: no silent 2.5 m substitution.
        let block = SprayBlockInput(blockId: "A", grossAreaHectares: 10)
        let geometry = SprayGeometryResolver.resolve([block])
        #expect(geometry.totalRowLengthMetres == nil)
        #expect(geometry.source == .unavailable)
        #expect(geometry.quality == .incomplete)
        #expect(!geometry.isUsable)
        #expect(geometry.blocks.first?.unavailableReason == .missingRowSpacing)

        // Proof it did not quietly fall back to 2.5 m (which would yield 40,000 m).
        let with2Point5 = SprayGeometryResolver.resolve([
            SprayBlockInput(blockId: "A", grossAreaHectares: 10, rowSpacingMetres: 2.5)
        ])
        #expect(with2Point5.totalRowLengthMetres == 40_000)
    }

    @Test func unmappedBlockWithSpacingButNoAreaIsIncomplete() {
        let block = SprayBlockInput(blockId: "A", grossAreaHectares: nil, rowSpacingMetres: 3.2)
        let geometry = SprayGeometryResolver.resolve([block])
        #expect(geometry.totalRowLengthMetres == nil)
        #expect(geometry.blocks.first?.unavailableReason == .missingArea)
    }

    @Test func oneIncompleteBlockInvalidatesTheWholeSelection() {
        // A partial row length would silently under-dose the entire tank mix.
        let geometry = SprayGeometryResolver.resolve([
            mappedBlock,
            SprayBlockInput(blockId: "B", grossAreaHectares: 5)
        ])
        #expect(geometry.totalRowLengthMetres == nil)
        #expect(geometry.quality == .incomplete)
        #expect(geometry.unresolvedBlocks.count == 1)
        #expect(geometry.unavailableMessage != nil)
    }

    @Test func multipleBlocksSumTheirRowLengths() {
        let geometry = SprayGeometryResolver.resolve([
            mappedBlock,
            SprayBlockInput(
                blockId: "B",
                grossAreaHectares: 4,
                mappedRowLengthMetres: 12_500,
                rowSpacingMetres: 3.2,
                rowCount: 50
            )
        ])
        #expect(geometry.totalRowLengthMetres == 43_750)
        #expect(geometry.grossAreaHectares == 14)
        #expect(geometry.rowCount == 175)
        #expect(geometry.uniformRowSpacingMetres == 3.2)
    }

    @Test func mixedRowSpacingsReportNoUniformSpacing() {
        // An averaged spacing would produce a derived L/ha that is wrong for
        // every block in the set, so it is refused rather than approximated.
        let geometry = SprayGeometryResolver.resolve([
            mappedBlock,
            SprayBlockInput(
                blockId: "B",
                grossAreaHectares: 6,
                mappedRowLengthMetres: 20_000,
                rowSpacingMetres: 3.0
            )
        ])
        #expect(geometry.uniformRowSpacingMetres == nil)
        // The total row length is still perfectly usable — it needs no spacing.
        #expect(geometry.totalRowLengthMetres == 51_250)
        #expect(geometry.isUsable)
    }

    @Test func mixedSourcesDegradeQualityToDerived() {
        let geometry = SprayGeometryResolver.resolve([mappedBlock, derivableBlock])
        #expect(geometry.quality == .derived)
        #expect(abs((geometry.totalRowLengthMetres ?? 0) - 62_500) < tolerance)
    }

    // MARK: - Banded treated area

    @Test func bandedTreatedAreaFromCanonicalRowLength() {
        // 31,250 m × 0.8 m ÷ 10,000 = 2.50 ha
        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        let treated = SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: band)
        #expect(abs((treated.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(treated.method == .canonicalRowLength)
        // Gross is RETAINED, not replaced.
        #expect(treated.grossAreaHectares == 10)
        #expect(abs((treated.treatedFraction ?? 0) - 0.25) < tolerance)
    }

    @Test func bandedFallbackFromAreaAndSpacing() {
        // 10 ha × 0.8 m ÷ 3.2 m = 2.50 ha — the documented fallback form.
        let treated = SprayBandedAreaCalculator.treatedAreaFromAreaAndSpacing(
            grossAreaHectares: 10,
            rowSpacingMetres: 3.2,
            bandWidthMetres: 0.8
        )
        #expect(abs((treated ?? 0) - 2.5) < tolerance)
    }

    @Test func bandedFallbackAgreesWithCanonicalForm() {
        // Deriving a row length from area × spacing and then applying the band is
        // algebraically identical to the canonical form, so both routes must give
        // the same 2.50 ha.
        let canonical = SprayBandedAreaCalculator.treatedAreaFromRowLength(
            rowLengthMetres: 31_250,
            bandWidthMetres: 0.8
        )
        let fallback = SprayBandedAreaCalculator.treatedAreaFromAreaAndSpacing(
            grossAreaHectares: 10,
            rowSpacingMetres: 3.2,
            bandWidthMetres: 0.8
        )
        #expect(abs((canonical ?? 0) - (fallback ?? 1)) < tolerance)
    }

    @Test func bandedAreaIsNeverAFixedFractionOfBlockArea() {
        // Without a real row spacing there is nothing to divide by, so the answer
        // is "unknown" — never grossHa / 3 or any other fixed guess.
        let geometry = SprayGeometryResolver.resolve([
            SprayBlockInput(blockId: "A", grossAreaHectares: 10)
        ])
        let treated = SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: band)
        #expect(treated.treatedAreaHectares == nil)
        #expect(treated.method == .unavailable)
        #expect(treated.grossAreaHectares == 10)
    }

    @Test func bandWidthCanBeSplitLeftAndRight() {
        let split = SprayBandWidth.leftRight(left: 0.5, right: 0.3)
        #expect(abs(split.totalMetres - 0.8) < tolerance)
        // The TOTAL is what the arithmetic uses, so a split band gives the
        // identical treated area.
        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        let treated = SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: split)
        #expect(abs((treated.treatedAreaHectares ?? 0) - 2.5) < tolerance)
    }

    @Test func multiBlockBandedAreaIsSummedPerBlock() {
        // Per-block then summed, so different spacings stay correct.
        let geometry = SprayGeometryResolver.resolve([
            mappedBlock,
            SprayBlockInput(
                blockId: "B",
                grossAreaHectares: 4,
                mappedRowLengthMetres: 12_500,
                rowSpacingMetres: 3.0
            )
        ])
        let treated = SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: band)
        // (31,250 + 12,500) × 0.8 / 10,000 = 3.50 ha
        #expect(abs((treated.treatedAreaHectares ?? 0) - 3.5) < tolerance)
        #expect(treated.grossAreaHectares == 14)
    }

    @Test func wholeBlockApplicationTreatsTheEntireBlock() {
        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        let treated = SprayBandedAreaCalculator.wholeBlock(geometry: geometry)
        #expect(treated.treatedAreaHectares == 10)
        #expect(treated.grossAreaHectares == 10)
        #expect(treated.method == .wholeBlock)
    }

    // MARK: - Carrier volume: L/100 m

    @Test func litresPer100MetresTotalCarrier() {
        // 31,250 m ÷ 100 × 20 L = 6,250 L
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 40,
            rowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        #expect(abs((carrier?.totalLitres ?? 0) - 6_250) < tolerance)
        #expect(carrier?.basis == .litresPer100Metres)
    }

    @Test func concentrationFactorFromDiluteAndApplied() {
        // 40 ÷ 20 = 2.0×
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 40,
            rowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        #expect(abs((carrier?.concentrationFactor ?? 0) - 2.0) < tolerance)
        // The dilute-equivalent volume a per-100 L label rate is written against.
        #expect(abs((carrier?.diluteEquivalentLitres ?? 0) - 12_500) < tolerance)
    }

    @Test func derivedLitresPerHectareFromRowSpacing() {
        // 20 L/100 m × 100 ÷ 3.2 m = 625 L/ha
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 40,
            rowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        #expect(abs((carrier?.litresPerHectare ?? 0) - 625) < tolerance)
    }

    @Test func derivedLitresPerHectareIsUnavailableWithoutSpacing() {
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            rowLengthMetres: 31_250,
            rowSpacingMetres: nil
        )
        // The total carrier still works — it never needed a spacing.
        #expect(abs((carrier?.totalLitres ?? 0) - 6_250) < tolerance)
        #expect(carrier?.litresPerHectare == nil)
    }

    @Test func sprayingDiluteGivesAConcentrationFactorOfOne() {
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 40,
            diluteLitresPer100Metres: 40,
            rowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        #expect(carrier?.concentrationFactor == 1.0)
    }

    @Test func carrierVolumeIsRefusedWithoutARowLength() {
        // Never guessed: an unresolved geometry must stop the calculation.
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            rowLengthMetres: nil
        )
        #expect(carrier == nil)
    }

    @Test func carrierVolumeUsesTheSameGeometryAsBandedArea() {
        // The single most important guarantee of this task: ONE row-length source.
        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 40,
            geometry: geometry
        )
        let treated = SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: band)
        #expect(carrier?.rowLengthMetres == treated.rowLengthMetres)
        #expect(carrier?.rowLengthMetres == geometry.totalRowLengthMetres)
    }

    // MARK: - Product rate basis

    /// Gross 10 ha, treated 2.5 ha, 6,250 L carrier, no concentration.
    private var mixedTankContext: SprayQuantityContext {
        SprayQuantityContext(
            grossAreaHectares: 10,
            treatedAreaHectares: 2.5,
            carrierLitres: 6_250,
            concentrationFactor: 1.0,
            rowLengthMetres: 31_250
        )
    }

    @Test func wholeBlockAreaProduct() {
        // Kelp 2 L/block ha × 10 gross ha = 20 L
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .wholeBlockArea, context: mixedTankContext
        )
        #expect(abs((amount ?? 0) - 20) < tolerance)
    }

    @Test func treatedAreaProduct() {
        // Herbicide 2 L/treated ha × 2.5 treated ha = 5 L
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .treatedArea, context: mixedTankContext
        )
        #expect(abs((amount ?? 0) - 5) < tolerance)
    }

    @Test func per100LitresProduct() {
        // Adjuvant 100 mL/100 L × 6,250 L = 6,250 mL = 6.25 L
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 100, basis: .per100Litres, context: mixedTankContext
        )
        #expect(abs((amount ?? 0) - 6_250) < tolerance)
        #expect(abs(((amount ?? 0) / 1_000) - 6.25) < tolerance)
    }

    @Test func per100MetresProduct() {
        // A distance-based label rate: 2 L/100 m × 31,250 m = 625 L
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .per100Metres, context: mixedTankContext
        )
        #expect(abs((amount ?? 0) - 625) < tolerance)
    }

    @Test func allThreeBasesCoexistInTheSameTankMix() {
        // THE critical Phase 4 requirement: one mix, three different bases,
        // each measured against its own quantity.
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 625,
            areaHectares: 10
        )
        let plan = SprayApplicationPlanner.plan(
            blocks: [mappedBlock],
            mode: .banded,
            bandWidth: band,
            carrier: carrier,
            tankCapacityLitres: 6_250,
            productLines: [
                SprayProductLineInput(productId: "kelp", name: "Kelp", unit: "L",
                                      basis: .wholeBlockArea, rate: 2),
                SprayProductLineInput(productId: "herb", name: "Herbicide", unit: "L",
                                      basis: .treatedArea, rate: 2),
                SprayProductLineInput(productId: "adj", name: "Adjuvant", unit: "mL",
                                      basis: .per100Litres, rate: 100)
            ]
        )

        #expect(abs(plan.totalCarrierLitres - 6_250) < tolerance)
        #expect(plan.grossAreaHectares == 10)
        #expect(abs((plan.treatedAreaHectares ?? 0) - 2.5) < tolerance)
        #expect(plan.unresolvedProductLines.isEmpty)
        #expect(abs((plan.productLines[0].totalQuantity ?? 0) - 20) < tolerance)
        #expect(abs((plan.productLines[1].totalQuantity ?? 0) - 5) < tolerance)
        #expect(abs((plan.productLines[2].totalQuantity ?? 0) - 6_250) < tolerance)
    }

    @Test func treatedAreaProductIsUnresolvedWithoutABandWidth() {
        // It must be surfaced, never silently dosed off gross hectares.
        let context = SprayQuantityContext(
            grossAreaHectares: 10,
            treatedAreaHectares: nil,
            carrierLitres: 6_250
        )
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .treatedArea, context: context
        )
        #expect(amount == nil)
    }

    @Test func legacyPerHectareMapsToWholeBlockArea() {
        // Deterministic migration mapping. Existing per-hectare lines — INCLUDING
        // banded ones, which multiplied by gross hectares — must keep their
        // historical quantity.
        #expect(SprayProductRateBasis.legacy("per_hectare") == .wholeBlockArea)
        #expect(SprayProductRateBasis.legacy("per_100_litres") == .per100Litres)
        #expect(SprayProductRateBasis.legacy("PER_HECTARE") == .wholeBlockArea)
        #expect(SprayProductRateBasis.legacy("treated_area") == .treatedArea)
        #expect(SprayProductRateBasis.legacy(nil) == nil)
        #expect(SprayProductRateBasis.legacy("") == nil)
        #expect(SprayProductRateBasis.legacy("nonsense") == nil)
    }

    @Test func legacyPerHectareIsNeverReinterpretedAsTreatedArea() {
        // The one mapping that would silently restate history.
        #expect(SprayProductRateBasis.legacy("per_hectare") != .treatedArea)
        // And a round trip keeps old readers working.
        #expect(SprayProductRateBasis.wholeBlockArea.legacyCompatibleValue == "per_hectare")
        #expect(SprayProductRateBasis.per100Litres.legacyCompatibleValue == "per_100_litres")
        #expect(SprayProductRateBasis.treatedArea.legacyCompatibleValue == "per_hectare")
    }

    // MARK: - Regression: existing L/ha behaviour must not move

    @Test func existingLitresPerHectareFoliarSprayIsUnchanged() {
        // 10 ha × 300 L/ha = 3,000 L, exactly as the legacy calculator produced.
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 300,
            areaHectares: 10
        )
        #expect(carrier.totalLitres == 3_000)
        #expect(carrier.basis == .litresPerHectare)
        #expect(carrier.concentrationFactor == 1.0)
        #expect(carrier.litresPerHectare == 300)
    }

    @Test func existingPer100LitresProductWithConcentrationFactor() {
        // Legacy parity: a per-100 L rate is dosed against the DILUTE volume, so
        // concentrating must NOT reduce the product.
        //   legacy: (totalWater / 100) × rate × CF
        //   3,000 L at CF 2.0 with 50 mL/100 L = 30 × 50 × 2 = 3,000 mL
        let context = SprayQuantityContext(
            grossAreaHectares: 10,
            carrierLitres: 3_000,
            concentrationFactor: 2.0
        )
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 50, basis: .per100Litres, context: context
        )
        #expect(abs((amount ?? 0) - 3_000) < tolerance)
    }

    @Test func existingTankSplitArithmeticIsUnchanged() {
        // 3,000 L into a 2,000 L tank: 1 full tank + a 1,000 L last tank.
        let split = SprayApplicationPlanner.tankSplit(totalLitres: 3_000, tankCapacityLitres: 2_000)
        #expect(split.fullTankCount == 1)
        #expect(split.lastTankLitres == 1_000)
        #expect(split.totalTanks == 2)

        // Exactly one tank.
        let exact = SprayApplicationPlanner.tankSplit(totalLitres: 2_000, tankCapacityLitres: 2_000)
        #expect(exact.fullTankCount == 0)
        #expect(exact.lastTankLitres == 2_000)
        #expect(exact.totalTanks == 1)

        // Under one tank.
        let partial = SprayApplicationPlanner.tankSplit(totalLitres: 500, tankCapacityLitres: 2_000)
        #expect(partial.fullTankCount == 0)
        #expect(partial.lastTankLitres == 500)
        #expect(partial.totalTanks == 1)

        // No water, and no capacity, must not divide by zero.
        #expect(SprayApplicationPlanner.tankSplit(totalLitres: 0, tankCapacityLitres: 2_000).totalTanks == 0)
        #expect(SprayApplicationPlanner.tankSplit(totalLitres: 3_000, tankCapacityLitres: 0).totalTanks == 0)
    }

    @Test func perTankQuantitiesSplitProportionally() {
        // 3,000 L into 2,000 L tanks with 30 L of product: 20 L then 10 L.
        let plan = SprayApplicationPlanner.plan(
            blocks: [mappedBlock],
            mode: .wholeBlock,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 300, areaHectares: 10),
            tankCapacityLitres: 2_000,
            productLines: [
                SprayProductLineInput(productId: "p", name: "Product", unit: "L",
                                      basis: .wholeBlockArea, rate: 3)
            ]
        )
        let line = plan.productLines[0]
        #expect(abs((line.totalQuantity ?? 0) - 30) < tolerance)
        #expect(abs((line.quantityPerFullTank ?? 0) - 20) < tolerance)
        #expect(abs((line.quantityInLastTank ?? 0) - 10) < tolerance)
    }

    @Test func costingUsesGrossAndTreatedHectaresSeparately() {
        let plan = SprayApplicationPlanner.plan(
            blocks: [mappedBlock],
            mode: .banded,
            bandWidth: band,
            carrier: SprayCarrierVolumeCalculator.perHectare(litresPerHectare: 625, areaHectares: 10),
            tankCapacityLitres: 6_250,
            productLines: [
                SprayProductLineInput(productId: "herb", name: "Herbicide", unit: "L",
                                      basis: .treatedArea, rate: 2, costPerUnit: 10)
            ]
        )
        // 5 L × $10 = $50
        #expect(abs((plan.totalProductCost ?? 0) - 50) < tolerance)
        // $50 / 10 gross ha = $5/ha
        #expect(abs((plan.costPerGrossHectare ?? 0) - 5) < tolerance)
        // $50 / 2.5 treated ha = $20/ha
        #expect(abs((plan.costPerTreatedHectare ?? 0) - 20) < tolerance)
    }

    // MARK: - Compliance profile

    @Test func newZealandVineyardDefaultsToSWNZAndLitresPer100Metres() {
        let profile = SprayVineyardProfile(countryCode: "NZ")
        #expect(profile.resolvedProfile == .newZealandSWNZ)
        #expect(profile.resolvedPolicy == .litresPer100MetresOnly)
        #expect(profile.defaultCarrierBasis == .litresPer100Metres)
        #expect(profile.isCarrierBasisLocked)
        #expect(!profile.allows(.litresPerHectare))
        // Nothing was stored — the default is resolved, never written.
        #expect(profile.storedProfile == nil)
        #expect(profile.storedPolicy == nil)
    }

    @Test func australianVineyardDefaultsToEitherBasis() {
        let profile = SprayVineyardProfile(countryCode: "AU")
        #expect(profile.resolvedProfile == .australia)
        #expect(profile.resolvedPolicy == .either)
        #expect(profile.allows(.litresPerHectare))
        #expect(profile.allows(.litresPer100Metres))
        #expect(!profile.isCarrierBasisLocked)
    }

    @Test func unknownOrMissingCountryDefaultsToAustralia() {
        #expect(SprayVineyardProfile(countryCode: nil).resolvedProfile == .australia)
        #expect(SprayVineyardProfile(countryCode: "").resolvedProfile == .australia)
        #expect(SprayVineyardProfile(countryCode: "ZA").resolvedProfile == .australia)
    }

    @Test func storedProfileOverridesTheCountryDefault() {
        // An AU vineyard that opted into SWNZ, and an NZ vineyard explicitly
        // allowed both bases.
        let auOptedIn = SprayVineyardProfile(storedProfile: .newZealandSWNZ, countryCode: "AU")
        #expect(auOptedIn.resolvedPolicy == .litresPer100MetresOnly)

        let nzRelaxed = SprayVineyardProfile(storedPolicy: .either, countryCode: "NZ")
        #expect(nzRelaxed.resolvedProfile == .newZealandSWNZ)
        #expect(nzRelaxed.resolvedPolicy == .either)
        #expect(nzRelaxed.allows(.litresPerHectare))
    }

    @Test func carrierBasisAndProductRateBasisStayIndependent() {
        // An SWNZ vineyard entering carrier volume in L/100 m can still dose a
        // product whose label is authoritative per hectare.
        let profile = SprayVineyardProfile(countryCode: "NZ")
        #expect(profile.defaultCarrierBasis == .litresPer100Metres)

        let geometry = SprayGeometryResolver.resolve([mappedBlock])
        let carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres: 20,
            diluteLitresPer100Metres: 40,
            geometry: geometry
        )
        #expect(carrier != nil)
        // L/ha is still derived and available internally under SWNZ.
        #expect(abs((carrier?.litresPerHectare ?? 0) - 625) < tolerance)

        // And a per-hectare product rate is untouched by the carrier basis.
        let context = SprayQuantityContext(
            geometry: geometry,
            carrier: carrier!,
            treatedAreaHectares: nil
        )
        let amount = SprayProductQuantityCalculator.totalQuantity(
            rate: 2, basis: .wholeBlockArea, context: context
        )
        #expect(abs((amount ?? 0) - 20) < tolerance)
    }
}
