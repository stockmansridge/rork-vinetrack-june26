package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayApplicationPlanner
import com.rork.vinetrack.data.spray.SprayBandWidth
import com.rork.vinetrack.data.spray.SprayBandedAreaCalculator
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierVolumeCalculator
import com.rork.vinetrack.data.spray.SprayCarrierVolumePolicy
import com.rork.vinetrack.data.spray.SprayComplianceProfile
import com.rork.vinetrack.data.spray.SprayGeometryQuality
import com.rork.vinetrack.data.spray.SprayGeometryResolver
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayGeometryUnavailable
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductQuantityCalculator
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayQuantityContext
import com.rork.vinetrack.data.spray.SprayTreatedAreaMethod
import com.rork.vinetrack.data.spray.SprayVineyardProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SPRAY APPLICATION GEOMETRY (sql/191) — the Android twin of
 * `SprayApplicationGeometryTests.swift`. Both suites assert the SAME fixtures
 * and the SAME expected numbers, so any divergence between the platforms fails a
 * build.
 *
 * The shared fixture, used throughout:
 * * a 10 ha block, 31,250 m of mapped row (125 rows × 250 m), 3.2 m spacing;
 * * a 0.8 m total treated band → 2.50 ha treated;
 * * 40 L/100 m dilute, 20 L/100 m applied → 6,250 L carrier, 2.0× concentration.
 */
class SprayApplicationGeometryTest {

    private val tolerance = 1e-9

    /** 10 ha, fully mapped: 31,250 m of row at 3.2 m spacing. */
    private val mappedBlock = SprayBlockInput(
        blockId = "A",
        grossAreaHectares = 10.0,
        mappedRowLengthMetres = 31_250.0,
        rowSpacingMetres = 3.2,
        rowCount = 125,
    )

    /**
     * 10 ha at 3.2 m spacing with NO mapped rows and no stored length, so the
     * length has to be derived: 10 × 10,000 / 3.2 = 31,250 m.
     */
    private val derivableBlock = SprayBlockInput(
        blockId = "B",
        grossAreaHectares = 10.0,
        rowSpacingMetres = 3.2,
    )

    private val band = SprayBandWidth.total(0.8)

    // ------------------------------------------------------- canonical geometry

    @Test
    fun `mapped row geometry is authoritative`() {
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        assertEquals(31_250.0, geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(SprayGeometrySource.MAPPED_ROWS, geometry.source)
        assertEquals(SprayGeometryQuality.AUTHORITATIVE, geometry.quality)
        assertEquals(10.0, geometry.grossAreaHectares, tolerance)
        assertEquals(125, geometry.rowCount)
        assertEquals(3.2, geometry.uniformRowSpacingMetres!!, tolerance)
        assertTrue(geometry.isUsable)
    }

    @Test
    fun `mapped row geometry wins over a stored length`() {
        // Real measured geometry outranks a stored figure. This is deliberately
        // the OPPOSITE of the legacy `Paddock.effectiveTotalRowLength`
        // (override-wins), which is left untouched for irrigation/vine counts.
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            mappedRowLengthMetres = 31_250.0,
            storedRowLengthMetres = 99_999.0,
            rowSpacingMetres = 3.2,
        )
        val geometry = SprayGeometryResolver.resolve(listOf(block))
        assertEquals(31_250.0, geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(SprayGeometrySource.MAPPED_ROWS, geometry.source)
    }

    @Test
    fun `stored row length is used when nothing is mapped`() {
        val block = SprayBlockInput(
            blockId = "A",
            grossAreaHectares = 10.0,
            storedRowLengthMetres = 30_000.0,
            rowSpacingMetres = 3.2,
        )
        val geometry = SprayGeometryResolver.resolve(listOf(block))
        assertEquals(30_000.0, geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(SprayGeometrySource.STORED_ROW_LENGTH, geometry.source)
        assertEquals(SprayGeometryQuality.AUTHORITATIVE, geometry.quality)
    }

    @Test
    fun `row length is derived from area and spacing`() {
        // 10 ha × 10,000 / 3.2 m = 31,250 m — the same figure the mapped block
        // measures, which is why the banded fallback agrees with the primary form.
        val geometry = SprayGeometryResolver.resolve(listOf(derivableBlock))
        assertEquals(31_250.0, geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING, geometry.source)
        assertEquals(SprayGeometryQuality.DERIVED, geometry.quality)
        assertTrue(geometry.isUsable)
    }

    @Test
    fun `missing row spacing is incomplete not defaulted to 2 point 5`() {
        // The whole point of the engine: no silent 2.5 m substitution.
        val geometry = SprayGeometryResolver.resolve(
            listOf(SprayBlockInput(blockId = "A", grossAreaHectares = 10.0)),
        )
        assertNull(geometry.totalRowLengthMetres)
        assertEquals(SprayGeometrySource.UNAVAILABLE, geometry.source)
        assertEquals(SprayGeometryQuality.INCOMPLETE, geometry.quality)
        assertFalse(geometry.isUsable)
        assertEquals(
            SprayGeometryUnavailable.MISSING_ROW_SPACING,
            geometry.blocks.first().unavailableReason,
        )

        // Proof it did not quietly fall back to 2.5 m (which would yield 40,000 m).
        val with2Point5 = SprayGeometryResolver.resolve(
            listOf(SprayBlockInput(blockId = "A", grossAreaHectares = 10.0, rowSpacingMetres = 2.5)),
        )
        assertEquals(40_000.0, with2Point5.totalRowLengthMetres!!, tolerance)
    }

    @Test
    fun `unmapped block with spacing but no area is incomplete`() {
        val geometry = SprayGeometryResolver.resolve(
            listOf(SprayBlockInput(blockId = "A", grossAreaHectares = null, rowSpacingMetres = 3.2)),
        )
        assertNull(geometry.totalRowLengthMetres)
        assertEquals(
            SprayGeometryUnavailable.MISSING_AREA,
            geometry.blocks.first().unavailableReason,
        )
    }

    @Test
    fun `one incomplete block invalidates the whole selection`() {
        // A partial row length would silently under-dose the entire tank mix.
        val geometry = SprayGeometryResolver.resolve(
            listOf(mappedBlock, SprayBlockInput(blockId = "B", grossAreaHectares = 5.0)),
        )
        assertNull(geometry.totalRowLengthMetres)
        assertEquals(SprayGeometryQuality.INCOMPLETE, geometry.quality)
        assertEquals(1, geometry.unresolvedBlocks.size)
        assertTrue(geometry.unavailableMessage != null)
    }

    @Test
    fun `multiple blocks sum their row lengths`() {
        val geometry = SprayGeometryResolver.resolve(
            listOf(
                mappedBlock,
                SprayBlockInput(
                    blockId = "B",
                    grossAreaHectares = 4.0,
                    mappedRowLengthMetres = 12_500.0,
                    rowSpacingMetres = 3.2,
                    rowCount = 50,
                ),
            ),
        )
        assertEquals(43_750.0, geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(14.0, geometry.grossAreaHectares, tolerance)
        assertEquals(175, geometry.rowCount)
        assertEquals(3.2, geometry.uniformRowSpacingMetres!!, tolerance)
    }

    @Test
    fun `mixed row spacings report no uniform spacing`() {
        // An averaged spacing would produce a derived L/ha that is wrong for every
        // block in the set, so it is refused rather than approximated.
        val geometry = SprayGeometryResolver.resolve(
            listOf(
                mappedBlock,
                SprayBlockInput(
                    blockId = "B",
                    grossAreaHectares = 6.0,
                    mappedRowLengthMetres = 20_000.0,
                    rowSpacingMetres = 3.0,
                ),
            ),
        )
        assertNull(geometry.uniformRowSpacingMetres)
        // The total row length is still perfectly usable — it needs no spacing.
        assertEquals(51_250.0, geometry.totalRowLengthMetres!!, tolerance)
        assertTrue(geometry.isUsable)
    }

    @Test
    fun `mixed sources degrade quality to derived`() {
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock, derivableBlock))
        assertEquals(SprayGeometryQuality.DERIVED, geometry.quality)
        assertEquals(62_500.0, geometry.totalRowLengthMetres!!, tolerance)
    }

    // ---------------------------------------------------- banded treated area

    @Test
    fun `banded treated area from canonical row length`() {
        // 31,250 m × 0.8 m ÷ 10,000 = 2.50 ha
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        val treated = SprayBandedAreaCalculator.banded(geometry, band)
        assertEquals(2.5, treated.treatedAreaHectares!!, tolerance)
        assertEquals(SprayTreatedAreaMethod.CANONICAL_ROW_LENGTH, treated.method)
        // Gross is RETAINED, not replaced.
        assertEquals(10.0, treated.grossAreaHectares, tolerance)
        assertEquals(0.25, treated.treatedFraction!!, tolerance)
    }

    @Test
    fun `banded fallback from area and spacing`() {
        // 10 ha × 0.8 m ÷ 3.2 m = 2.50 ha — the documented fallback form.
        val treated = SprayBandedAreaCalculator.treatedAreaFromAreaAndSpacing(
            grossAreaHectares = 10.0,
            rowSpacingMetres = 3.2,
            bandWidthMetres = 0.8,
        )
        assertEquals(2.5, treated!!, tolerance)
    }

    @Test
    fun `banded fallback agrees with canonical form`() {
        // Deriving a row length from area × spacing and then applying the band is
        // algebraically identical to the canonical form, so both routes must give
        // the same 2.50 ha.
        val canonical = SprayBandedAreaCalculator.treatedAreaFromRowLength(31_250.0, 0.8)
        val fallback = SprayBandedAreaCalculator.treatedAreaFromAreaAndSpacing(10.0, 3.2, 0.8)
        assertEquals(canonical!!, fallback!!, tolerance)
    }

    @Test
    fun `banded area is never a fixed fraction of block area`() {
        // Without a real row spacing there is nothing to divide by, so the answer
        // is "unknown" — never grossHa / 3 or any other fixed guess.
        val geometry = SprayGeometryResolver.resolve(
            listOf(SprayBlockInput(blockId = "A", grossAreaHectares = 10.0)),
        )
        val treated = SprayBandedAreaCalculator.banded(geometry, band)
        assertNull(treated.treatedAreaHectares)
        assertEquals(SprayTreatedAreaMethod.UNAVAILABLE, treated.method)
        assertEquals(10.0, treated.grossAreaHectares, tolerance)
    }

    @Test
    fun `band width can be split left and right`() {
        val split = SprayBandWidth.leftRight(left = 0.5, right = 0.3)
        assertEquals(0.8, split.totalMetres, tolerance)
        // The TOTAL is what the arithmetic uses, so a split band gives the
        // identical treated area.
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        val treated = SprayBandedAreaCalculator.banded(geometry, split)
        assertEquals(2.5, treated.treatedAreaHectares!!, tolerance)
    }

    @Test
    fun `multi block banded area is summed per block`() {
        // Per-block then summed, so different spacings stay correct.
        val geometry = SprayGeometryResolver.resolve(
            listOf(
                mappedBlock,
                SprayBlockInput(
                    blockId = "B",
                    grossAreaHectares = 4.0,
                    mappedRowLengthMetres = 12_500.0,
                    rowSpacingMetres = 3.0,
                ),
            ),
        )
        val treated = SprayBandedAreaCalculator.banded(geometry, band)
        // (31,250 + 12,500) × 0.8 / 10,000 = 3.50 ha
        assertEquals(3.5, treated.treatedAreaHectares!!, tolerance)
        assertEquals(14.0, treated.grossAreaHectares, tolerance)
    }

    @Test
    fun `whole block application treats the entire block`() {
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        val treated = SprayBandedAreaCalculator.wholeBlock(geometry)
        assertEquals(10.0, treated.treatedAreaHectares!!, tolerance)
        assertEquals(10.0, treated.grossAreaHectares, tolerance)
        assertEquals(SprayTreatedAreaMethod.WHOLE_BLOCK, treated.method)
    }

    // ------------------------------------------------- carrier volume: L/100 m

    @Test
    fun `litres per 100 metres total carrier`() {
        // 31,250 m ÷ 100 × 20 L = 6,250 L
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            diluteLitresPer100Metres = 40.0,
            rowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        assertEquals(6_250.0, carrier!!.totalLitres, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, carrier.basis)
    }

    @Test
    fun `concentration factor from dilute and applied`() {
        // 40 ÷ 20 = 2.0×
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            diluteLitresPer100Metres = 40.0,
            rowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        assertEquals(2.0, carrier!!.concentrationFactor, tolerance)
        // The dilute-equivalent volume a per-100 L label rate is written against.
        assertEquals(12_500.0, carrier.diluteEquivalentLitres, tolerance)
    }

    @Test
    fun `derived litres per hectare from row spacing`() {
        // 20 L/100 m × 100 ÷ 3.2 m = 625 L/ha
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            diluteLitresPer100Metres = 40.0,
            rowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        assertEquals(625.0, carrier!!.litresPerHectare!!, tolerance)
    }

    @Test
    fun `derived litres per hectare is unavailable without spacing`() {
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            rowLengthMetres = 31_250.0,
            rowSpacingMetres = null,
        )
        // The total carrier still works — it never needed a spacing.
        assertEquals(6_250.0, carrier!!.totalLitres, tolerance)
        assertNull(carrier.litresPerHectare)
    }

    @Test
    fun `spraying dilute gives a concentration factor of one`() {
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 40.0,
            diluteLitresPer100Metres = 40.0,
            rowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
        )
        assertEquals(1.0, carrier!!.concentrationFactor, tolerance)
    }

    @Test
    fun `carrier volume is refused without a row length`() {
        // Never guessed: an unresolved geometry must stop the calculation.
        assertNull(
            SprayCarrierVolumeCalculator.per100Metres(
                appliedLitresPer100Metres = 20.0,
                rowLengthMetres = null,
            ),
        )
    }

    @Test
    fun `carrier volume uses the same geometry as banded area`() {
        // The single most important guarantee of this task: ONE row-length source.
        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            diluteLitresPer100Metres = 40.0,
            geometry = geometry,
        )
        val treated = SprayBandedAreaCalculator.banded(geometry, band)
        assertEquals(treated.rowLengthMetres, carrier!!.rowLengthMetres)
        assertEquals(geometry.totalRowLengthMetres, carrier.rowLengthMetres)
    }

    // ---------------------------------------------------- product rate basis

    /** Gross 10 ha, treated 2.5 ha, 6,250 L carrier, no concentration. */
    private val mixedTankContext = SprayQuantityContext(
        grossAreaHectares = 10.0,
        treatedAreaHectares = 2.5,
        carrierLitres = 6_250.0,
        concentrationFactor = 1.0,
        rowLengthMetres = 31_250.0,
    )

    @Test
    fun `whole block area product`() {
        // Kelp 2 L/block ha × 10 gross ha = 20 L
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 2.0,
            basis = SprayProductRateBasis.WHOLE_BLOCK_AREA,
            context = mixedTankContext,
        )
        assertEquals(20.0, amount!!, tolerance)
    }

    @Test
    fun `treated area product`() {
        // Herbicide 2 L/treated ha × 2.5 treated ha = 5 L
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 2.0,
            basis = SprayProductRateBasis.TREATED_AREA,
            context = mixedTankContext,
        )
        assertEquals(5.0, amount!!, tolerance)
    }

    @Test
    fun `per 100 litres product`() {
        // Adjuvant 100 mL/100 L × 6,250 L = 6,250 mL = 6.25 L
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 100.0,
            basis = SprayProductRateBasis.PER_100_LITRES,
            context = mixedTankContext,
        )
        assertEquals(6_250.0, amount!!, tolerance)
        assertEquals(6.25, amount / 1_000.0, tolerance)
    }

    @Test
    fun `per 100 metres product`() {
        // A distance-based label rate: 2 L/100 m × 31,250 m = 625 L
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 2.0,
            basis = SprayProductRateBasis.PER_100_METRES,
            context = mixedTankContext,
        )
        assertEquals(625.0, amount!!, tolerance)
    }

    @Test
    fun `all three bases coexist in the same tank mix`() {
        // THE critical Phase 4 requirement: one mix, three different bases, each
        // measured against its own quantity.
        val carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare = 625.0,
            areaHectares = 10.0,
        )
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(mappedBlock),
            mode = SprayApplicationMode.BANDED,
            bandWidth = band,
            carrier = carrier,
            tankCapacityLitres = 6_250.0,
            productLines = listOf(
                SprayProductLineInput("kelp", "Kelp", "L", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
                SprayProductLineInput("herb", "Herbicide", "L", SprayProductRateBasis.TREATED_AREA, 2.0),
                SprayProductLineInput("adj", "Adjuvant", "mL", SprayProductRateBasis.PER_100_LITRES, 100.0),
            ),
        )

        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)
        assertTrue(plan.unresolvedProductLines.isEmpty())
        assertEquals(20.0, plan.productLines[0].totalQuantity!!, tolerance)
        assertEquals(5.0, plan.productLines[1].totalQuantity!!, tolerance)
        assertEquals(6_250.0, plan.productLines[2].totalQuantity!!, tolerance)
    }

    @Test
    fun `treated area product is unresolved without a band width`() {
        // It must be surfaced, never silently dosed off gross hectares.
        val context = SprayQuantityContext(
            grossAreaHectares = 10.0,
            treatedAreaHectares = null,
            carrierLitres = 6_250.0,
        )
        assertNull(
            SprayProductQuantityCalculator.totalQuantity(
                rate = 2.0,
                basis = SprayProductRateBasis.TREATED_AREA,
                context = context,
            ),
        )
    }

    @Test
    fun `legacy per hectare maps to whole block area`() {
        // Deterministic migration mapping. Existing per-hectare lines — INCLUDING
        // banded ones, which multiplied by gross hectares — must keep their
        // historical quantity.
        assertEquals(
            SprayProductRateBasis.WHOLE_BLOCK_AREA,
            SprayProductRateBasis.legacy("per_hectare"),
        )
        assertEquals(
            SprayProductRateBasis.PER_100_LITRES,
            SprayProductRateBasis.legacy("per_100_litres"),
        )
        assertEquals(
            SprayProductRateBasis.WHOLE_BLOCK_AREA,
            SprayProductRateBasis.legacy("PER_HECTARE"),
        )
        assertEquals(
            SprayProductRateBasis.TREATED_AREA,
            SprayProductRateBasis.legacy("treated_area"),
        )
        assertNull(SprayProductRateBasis.legacy(null))
        assertNull(SprayProductRateBasis.legacy(""))
        assertNull(SprayProductRateBasis.legacy("nonsense"))
    }

    @Test
    fun `legacy per hectare is never reinterpreted as treated area`() {
        // The one mapping that would silently restate history.
        assertNotEquals(
            SprayProductRateBasis.TREATED_AREA,
            SprayProductRateBasis.legacy("per_hectare"),
        )
        // And a round trip keeps old readers working.
        assertEquals("per_hectare", SprayProductRateBasis.WHOLE_BLOCK_AREA.legacyCompatibleValue)
        assertEquals("per_100_litres", SprayProductRateBasis.PER_100_LITRES.legacyCompatibleValue)
        assertEquals("per_hectare", SprayProductRateBasis.TREATED_AREA.legacyCompatibleValue)
    }

    // ------------------------------- regression: existing L/ha must not move

    @Test
    fun `existing litres per hectare foliar spray is unchanged`() {
        // 10 ha × 300 L/ha = 3,000 L, exactly as the legacy calculator produced.
        val carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare = 300.0,
            areaHectares = 10.0,
        )
        assertEquals(3_000.0, carrier.totalLitres, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, carrier.basis)
        assertEquals(1.0, carrier.concentrationFactor, tolerance)
        assertEquals(300.0, carrier.litresPerHectare!!, tolerance)
    }

    @Test
    fun `existing per 100 litres product with concentration factor`() {
        // Legacy parity: a per-100 L rate is dosed against the DILUTE volume, so
        // concentrating must NOT reduce the product.
        //   legacy: (totalWater / 100) × rate × CF
        //   3,000 L at CF 2.0 with 50 mL/100 L = 30 × 50 × 2 = 3,000 mL
        val context = SprayQuantityContext(
            grossAreaHectares = 10.0,
            carrierLitres = 3_000.0,
            concentrationFactor = 2.0,
        )
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 50.0,
            basis = SprayProductRateBasis.PER_100_LITRES,
            context = context,
        )
        assertEquals(3_000.0, amount!!, tolerance)
    }

    @Test
    fun `existing tank split arithmetic is unchanged`() {
        // 3,000 L into a 2,000 L tank: 1 full tank + a 1,000 L last tank.
        val split = SprayApplicationPlanner.tankSplit(3_000.0, 2_000.0)
        assertEquals(1, split.fullTankCount)
        assertEquals(1_000.0, split.lastTankLitres, tolerance)
        assertEquals(2, split.totalTanks)

        // Exactly one tank.
        val exact = SprayApplicationPlanner.tankSplit(2_000.0, 2_000.0)
        assertEquals(0, exact.fullTankCount)
        assertEquals(2_000.0, exact.lastTankLitres, tolerance)
        assertEquals(1, exact.totalTanks)

        // Under one tank.
        val partial = SprayApplicationPlanner.tankSplit(500.0, 2_000.0)
        assertEquals(0, partial.fullTankCount)
        assertEquals(500.0, partial.lastTankLitres, tolerance)
        assertEquals(1, partial.totalTanks)

        // No water, and no capacity, must not divide by zero.
        assertEquals(0, SprayApplicationPlanner.tankSplit(0.0, 2_000.0).totalTanks)
        assertEquals(0, SprayApplicationPlanner.tankSplit(3_000.0, 0.0).totalTanks)
    }

    @Test
    fun `per tank quantities split proportionally`() {
        // 3,000 L into 2,000 L tanks with 30 L of product: 20 L then 10 L.
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(mappedBlock),
            mode = SprayApplicationMode.WHOLE_BLOCK,
            carrier = SprayCarrierVolumeCalculator.perHectare(300.0, 10.0),
            tankCapacityLitres = 2_000.0,
            productLines = listOf(
                SprayProductLineInput("p", "Product", "L", SprayProductRateBasis.WHOLE_BLOCK_AREA, 3.0),
            ),
        )
        val line = plan.productLines[0]
        assertEquals(30.0, line.totalQuantity!!, tolerance)
        assertEquals(20.0, line.quantityPerFullTank!!, tolerance)
        assertEquals(10.0, line.quantityInLastTank!!, tolerance)
    }

    @Test
    fun `costing uses gross and treated hectares separately`() {
        val plan = SprayApplicationPlanner.plan(
            blocks = listOf(mappedBlock),
            mode = SprayApplicationMode.BANDED,
            bandWidth = band,
            carrier = SprayCarrierVolumeCalculator.perHectare(625.0, 10.0),
            tankCapacityLitres = 6_250.0,
            productLines = listOf(
                SprayProductLineInput(
                    "herb", "Herbicide", "L", SprayProductRateBasis.TREATED_AREA, 2.0, 10.0,
                ),
            ),
        )
        // 5 L × $10 = $50
        assertEquals(50.0, plan.totalProductCost!!, tolerance)
        // $50 / 10 gross ha = $5/ha
        assertEquals(5.0, plan.costPerGrossHectare!!, tolerance)
        // $50 / 2.5 treated ha = $20/ha
        assertEquals(20.0, plan.costPerTreatedHectare!!, tolerance)
    }

    // ------------------------------------------------------ compliance profile

    @Test
    fun `new zealand vineyard defaults to SWNZ and litres per 100 metres`() {
        val profile = SprayVineyardProfile(countryCode = "NZ")
        assertEquals(SprayComplianceProfile.NEW_ZEALAND_SWNZ, profile.resolvedProfile)
        assertEquals(SprayCarrierVolumePolicy.LITRES_PER_100_METRES_ONLY, profile.resolvedPolicy)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, profile.defaultCarrierBasis)
        assertTrue(profile.isCarrierBasisLocked)
        assertFalse(profile.allows(SprayCarrierBasis.LITRES_PER_HECTARE))
        // Nothing was stored — the default is resolved, never written.
        assertNull(profile.storedProfile)
        assertNull(profile.storedPolicy)
    }

    @Test
    fun `australian vineyard defaults to either basis`() {
        val profile = SprayVineyardProfile(countryCode = "AU")
        assertEquals(SprayComplianceProfile.AUSTRALIA, profile.resolvedProfile)
        assertEquals(SprayCarrierVolumePolicy.EITHER, profile.resolvedPolicy)
        assertTrue(profile.allows(SprayCarrierBasis.LITRES_PER_HECTARE))
        assertTrue(profile.allows(SprayCarrierBasis.LITRES_PER_100_METRES))
        assertFalse(profile.isCarrierBasisLocked)
    }

    @Test
    fun `unknown or missing country defaults to australia`() {
        assertEquals(
            SprayComplianceProfile.AUSTRALIA,
            SprayVineyardProfile(countryCode = null).resolvedProfile,
        )
        assertEquals(
            SprayComplianceProfile.AUSTRALIA,
            SprayVineyardProfile(countryCode = "").resolvedProfile,
        )
        assertEquals(
            SprayComplianceProfile.AUSTRALIA,
            SprayVineyardProfile(countryCode = "ZA").resolvedProfile,
        )
    }

    @Test
    fun `stored profile overrides the country default`() {
        // An AU vineyard that opted into SWNZ, and an NZ vineyard explicitly
        // allowed both bases.
        val auOptedIn = SprayVineyardProfile(
            storedProfile = SprayComplianceProfile.NEW_ZEALAND_SWNZ,
            countryCode = "AU",
        )
        assertEquals(SprayCarrierVolumePolicy.LITRES_PER_100_METRES_ONLY, auOptedIn.resolvedPolicy)

        val nzRelaxed = SprayVineyardProfile(
            storedPolicy = SprayCarrierVolumePolicy.EITHER,
            countryCode = "NZ",
        )
        assertEquals(SprayComplianceProfile.NEW_ZEALAND_SWNZ, nzRelaxed.resolvedProfile)
        assertEquals(SprayCarrierVolumePolicy.EITHER, nzRelaxed.resolvedPolicy)
        assertTrue(nzRelaxed.allows(SprayCarrierBasis.LITRES_PER_HECTARE))
    }

    @Test
    fun `carrier basis and product rate basis stay independent`() {
        // An SWNZ vineyard entering carrier volume in L/100 m can still dose a
        // product whose label is authoritative per hectare.
        val profile = SprayVineyardProfile(countryCode = "NZ")
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, profile.defaultCarrierBasis)

        val geometry = SprayGeometryResolver.resolve(listOf(mappedBlock))
        val carrier = SprayCarrierVolumeCalculator.per100Metres(
            appliedLitresPer100Metres = 20.0,
            diluteLitresPer100Metres = 40.0,
            geometry = geometry,
        )
        assertTrue(carrier != null)
        // L/ha is still derived and available internally under SWNZ.
        assertEquals(625.0, carrier!!.litresPerHectare!!, tolerance)

        // And a per-hectare product rate is untouched by the carrier basis.
        val context = SprayQuantityContext.of(geometry, carrier, treatedAreaHectares = null)
        val amount = SprayProductQuantityCalculator.totalQuantity(
            rate = 2.0,
            basis = SprayProductRateBasis.WHOLE_BLOCK_AREA,
            context = context,
        )
        assertEquals(20.0, amount!!, tolerance)
    }
}
