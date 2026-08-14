package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierVolumePolicy
import com.rork.vinetrack.data.spray.SprayGeometryQuality
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayHeadTarget
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayTreatedAreaMethod
import com.rork.vinetrack.data.spray.SprayVineyardProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract for the guided Spray Calculator flow — the Kotlin twin of the Swift
 * `SprayGuidedFlowTests`, asserting the SAME fixtures so a user moving between
 * platforms meets identical decisions and identical numbers.
 *
 * Two things are under test:
 *
 *  1. **Guided-state logic** — progressive disclosure. A step unlocks only when
 *     every step before it is complete, and incomplete block geometry stops
 *     progression instead of silently calculating against a guess.
 *  2. **Calculation integration** — every displayed figure comes from ONE
 *     `SprayApplicationPlan` produced by `SprayApplicationPlanner.plan`, and the
 *     snapshot that gets persisted is a projection of that same plan.
 */
class SprayGuidedFlowTest {

    private val tolerance = 0.0001

    // region Fixtures

    /**
     * THE worked example: 10 ha gross, 31,250 m of row, 3.2 m spacing. A 0.8 m
     * band over that geometry treats exactly 2.50 ha.
     */
    private fun block(
        id: String = "block-a",
        grossHectares: Double? = 10.0,
        rowLengthMetres: Double? = 31_250.0,
        rowSpacing: Double? = 3.2,
    ) = SprayBlockInput(
        blockId = id,
        grossAreaHectares = grossHectares,
        mappedRowLengthMetres = rowLengthMetres,
        rowSpacingMetres = rowSpacing,
    )

    private fun product(
        name: String,
        basis: SprayProductRateBasis,
        rate: Double,
        unit: String = "L",
    ) = SprayProductLineInput(
        productId = name.lowercase(),
        name = name,
        unit = unit,
        basis = basis,
        rate = rate,
    )

    /**
     * A flow that satisfies every gated step, so an individual test can break
     * exactly one thing and assert the consequence.
     */
    private fun completeInputs(
        operationType: SprayOperationType = SprayOperationType.FOLIAR_SPRAY,
    ) = SprayGuidedInputs(
        operationType = operationType,
        blocks = listOf(block()),
        targets = setOf(SprayTarget.POWDERY_MILDEW),
        sprayHeadTarget = if (operationType == SprayOperationType.FOLIAR_SPRAY) {
            SprayHeadTarget.FULL_CANOPY
        } else {
            null
        },
        bandWidthTotalMetres = if (operationType == SprayOperationType.BANDED_SPRAY) 0.8 else null,
        isGrowthStageAssigned = true,
        isEquipmentSelected = true,
        tankCapacityLitres = 2_000.0,
        carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
        litresPerHectare = 625.0,
        products = listOf(product("Sulphur", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0)),
    )

    // endregion

    // region 1. Foliar + L/ha

    @Test
    fun `foliar L per ha uses whole-block treated area and hectare carrier`() {
        val flow = SprayGuidedFlow(completeInputs())

        assertEquals(SprayApplicationMode.WHOLE_BLOCK, flow.mode)
        assertTrue(flow.requiresSprayHeadTarget)
        assertFalse(flow.requiresBandWidth)
        assertTrue(flow.isComplete)

        val plan = flow.plan
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        // A foliar pass treats the whole block: treated == gross, never null.
        assertEquals(10.0, plan.treatedAreaHectares!!, tolerance)
        assertEquals(SprayTreatedAreaMethod.WHOLE_BLOCK, plan.treatedArea.method)
        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, plan.carrier.basis)
        // No dilute reference entered, so no concentration.
        assertEquals(1.0, plan.concentrationFactor, tolerance)
        assertEquals(20.0, plan.productLines[0].totalQuantity!!, tolerance)
    }

    @Test
    fun `foliar L per ha dilute reference above applied rate concentrates`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(litresPerHectare = 500.0, diluteLitresPerHectare = 1_000.0),
        )
        assertEquals(2.0, flow.plan.concentrationFactor, tolerance)
        assertEquals(5_000.0, flow.plan.totalCarrierLitres, tolerance)
    }

    // endregion

    // region 2. Foliar + L/100 m

    @Test
    fun `foliar L per 100m spec example gives 2x, 6250 L and 625 L per ha`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                diluteLitresPer100Metres = 40.0,
                appliedLitresPer100Metres = 20.0,
            ),
        )
        assertTrue(flow.isComplete)

        val plan = flow.plan
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, plan.carrier.basis)
        // dilute ÷ applied = 40 ÷ 20
        assertEquals(2.0, plan.concentrationFactor, tolerance)
        // 31,250 m ÷ 100 × 20 L
        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        // 20 L/100 m × 100 ÷ 3.2 m spacing
        assertEquals(625.0, plan.carrier.litresPerHectare!!, tolerance)
        // The operator never types derived L/ha — it comes back from the engine.
        assertEquals(20.0, plan.carrier.appliedLitresPer100Metres!!, tolerance)
        assertEquals(40.0, plan.carrier.diluteLitresPer100Metres!!, tolerance)
    }

    @Test
    fun `L per 100m without row spacing resolves carrier but not derived L per ha`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                blocks = listOf(block(rowSpacing = null)),
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                appliedLitresPer100Metres = 20.0,
            ),
        )
        val plan = flow.plan
        // Mapped rows give the row length, so total litres are known...
        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        // ...but L/ha cannot be derived without a real spacing, and is NOT guessed.
        assertNull(plan.carrier.litresPerHectare)
    }

    // endregion

    // region 3/4/5. Banded product bases

    @Test
    fun `banded whole-block product doses against gross hectares`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                products = listOf(product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0)),
            ),
        )
        assertEquals(SprayApplicationMode.BANDED, flow.mode)
        assertTrue(flow.isComplete)

        val plan = flow.plan
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)
        // 2 L/ha × 10 ha gross
        assertEquals(20.0, plan.productLines[0].totalQuantity!!, tolerance)
    }

    @Test
    fun `banded treated-area product doses against the 2 point 5 ha band`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                products = listOf(product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0)),
            ),
        )
        val plan = flow.plan
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)
        // 2 L/ha × 2.5 ha treated
        assertEquals(5.0, plan.productLines[0].totalQuantity!!, tolerance)
        // Gross survives alongside treated — it is never overwritten.
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
    }

    @Test
    fun `banded per-100 L product doses against carrier litres`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                // 625 L/ha × 10 ha gross = 6,250 L, no concentration.
                products = listOf(
                    product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, "mL"),
                ),
            ),
        )
        val plan = flow.plan
        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        // 100 mL per 100 L × 6,250 L = 6,250 mL = 6.25 L
        assertEquals(6_250.0, plan.productLines[0].totalQuantity!!, tolerance)
    }

    @Test
    fun `per-100 L rates are written against dilute so concentrating keeps the dose`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                diluteLitresPer100Metres = 40.0,
                appliedLitresPer100Metres = 20.0,
                products = listOf(
                    product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, "mL"),
                ),
            ),
        )
        val plan = flow.plan
        assertEquals(2.0, plan.concentrationFactor, tolerance)
        // 100 × 6,250 ÷ 100 × 2.0 — the dilute-equivalent volume.
        assertEquals(12_500.0, plan.productLines[0].totalQuantity!!, tolerance)
    }

    // endregion

    // region 6. Mixed bases in ONE spray

    @Test
    fun `mixed bases in one tank give 20 L, 5 L and 6 point 25 L from a single plan`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                products = listOf(
                    product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
                    product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0),
                    product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, "mL"),
                ),
            ),
        )
        assertTrue(flow.isComplete)

        val plan = flow.plan
        assertEquals(3, plan.productLines.size)
        // All three come out of the SAME plan — no per-line recalculation.
        assertEquals(20.0, plan.productLines[0].totalQuantity!!, tolerance)
        assertEquals(5.0, plan.productLines[1].totalQuantity!!, tolerance)
        assertEquals(6_250.0, plan.productLines[2].totalQuantity!!, tolerance)
        assertTrue(plan.unresolvedProductLines.isEmpty())
        // Each line keeps its own basis; there is no job-level rate basis.
        assertEquals(
            listOf(
                SprayProductRateBasis.WHOLE_BLOCK_AREA,
                SprayProductRateBasis.TREATED_AREA,
                SprayProductRateBasis.PER_100_LITRES,
            ),
            plan.productLines.map { it.basis },
        )
    }

    // endregion

    // region 7. Missing geometry blocks progression

    @Test
    fun `banded with no spacing and no rows blocks progression at the blocks step`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                blocks = listOf(block(rowLengthMetres = null, rowSpacing = null)),
            ),
        )

        val blocker = flow.blocker(SprayGuidedStep.BLOCKS)
        assertTrue(blocker is SprayGuidedBlocker.BlockSetupRequired)
        assertEquals(
            listOf("block-a"),
            (blocker as SprayGuidedBlocker.BlockSetupRequired).blockIds,
        )
        assertTrue(blocker.needsBlockEditor)

        // Progression stops: nothing after Blocks is reachable.
        assertTrue(flow.isUnlocked(SprayGuidedStep.BLOCKS))
        assertFalse(flow.isUnlocked(SprayGuidedStep.TARGET))
        assertFalse(flow.isUnlocked(SprayGuidedStep.CARRIER))
        assertFalse(flow.isUnlocked(SprayGuidedStep.REVIEW))
        assertFalse(flow.isComplete)
        assertEquals(SprayGuidedStep.BLOCKS, flow.activeStep)
        // And no snapshot may be persisted from an incomplete flow.
        assertNull(flow.snapshot)
    }

    @Test
    fun `whole-block L per ha does not require row geometry`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                blocks = listOf(block(rowLengthMetres = null, rowSpacing = null)),
            ),
        )
        assertFalse(flow.requiresCanonicalRowLength)
        assertNull(flow.blocker(SprayGuidedStep.BLOCKS))
        assertTrue(flow.isComplete)
        // 625 L/ha × 10 ha still works without any row metres.
        assertEquals(6_250.0, flow.plan.totalCarrierLitres, tolerance)
    }

    @Test
    fun `switching to L per 100m introduces the geometry requirement`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                blocks = listOf(block(rowLengthMetres = null, rowSpacing = null)),
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                appliedLitresPer100Metres = 20.0,
            ),
        )
        assertTrue(flow.requiresCanonicalRowLength)
        assertTrue(flow.blocker(SprayGuidedStep.BLOCKS)!!.needsBlockEditor)
        assertFalse(flow.isComplete)
    }

    // endregion

    // region 8. Explicit 2.5 m spacing stays valid

    @Test
    fun `an explicitly entered 2 point 5 m spacing is a real measurement`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                // Area + explicit 2.5 m spacing, no mapped rows: row length is DERIVED.
                blocks = listOf(block(rowLengthMetres = null, rowSpacing = 2.5)),
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                appliedLitresPer100Metres = 20.0,
            ),
        )
        assertNull(flow.blocker(SprayGuidedStep.BLOCKS))
        assertTrue(flow.isComplete)

        val plan = flow.plan
        // 10 ha × 10,000 ÷ 2.5 = 40,000 m
        assertEquals(40_000.0, plan.geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING, plan.geometry.source)
        assertEquals(SprayGeometryQuality.DERIVED, plan.geometry.quality)
        // 40,000 ÷ 100 × 20 = 8,000 L
        assertEquals(8_000.0, plan.totalCarrierLitres, tolerance)
        // 20 × 100 ÷ 2.5 = 800 L/ha
        assertEquals(800.0, plan.carrier.litresPerHectare!!, tolerance)
    }

    // endregion

    // region 9. NZ / SWNZ locked L/100 m

    @Test
    fun `SWNZ profile locks carrier entry to L per 100m with no choice offered`() {
        val flow = SprayGuidedFlow(
            inputs = completeInputs().copy(
                litresPerHectare = null,
                appliedLitresPer100Metres = 20.0,
                // The operator's stored preference says L/ha, but the profile forbids it.
                carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
            ),
            profile = SprayVineyardProfile(countryCode = "NZ"),
        )

        assertEquals(SprayCarrierVolumePolicy.LITRES_PER_100_METRES_ONLY, flow.carrierPolicy)
        assertTrue(flow.isCarrierBasisLocked)
        // The forbidden basis is overridden, not obeyed.
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, flow.effectiveCarrierBasis)
        assertTrue(flow.isComplete)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, flow.plan.carrier.basis)
        assertEquals(6_250.0, flow.plan.totalCarrierLitres, tolerance)
    }

    @Test
    fun `australian profile allows either basis and offers the choice`() {
        val flow = SprayGuidedFlow(
            inputs = completeInputs(),
            profile = SprayVineyardProfile(countryCode = "AU"),
        )
        assertEquals(SprayCarrierVolumePolicy.EITHER, flow.carrierPolicy)
        assertFalse(flow.isCarrierBasisLocked)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, flow.effectiveCarrierBasis)
    }

    // endregion

    // region 10. Changing blocks recalculates everything downstream

    @Test
    fun `adding a block recalculates geometry, carrier and every product total`() {
        val base = completeInputs(SprayOperationType.BANDED_SPRAY).copy(
            products = listOf(
                product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
                product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0),
            ),
        )

        val before = SprayGuidedFlow(base).plan
        assertEquals(10.0, before.grossAreaHectares, tolerance)
        assertEquals(2.5, before.treatedAreaHectares!!, tolerance)
        assertEquals(6_250.0, before.totalCarrierLitres, tolerance)

        // Add a second identical block: everything doubles.
        val after = SprayGuidedFlow(
            base.copy(blocks = listOf(block(), block(id = "block-b"))),
        ).plan

        assertEquals(20.0, after.grossAreaHectares, tolerance)
        assertEquals(5.0, after.treatedAreaHectares!!, tolerance)
        assertEquals(62_500.0, after.geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(12_500.0, after.totalCarrierLitres, tolerance)
        assertEquals(40.0, after.productLines[0].totalQuantity!!, tolerance)
        assertEquals(10.0, after.productLines[1].totalQuantity!!, tolerance)
    }

    @Test
    fun `mixed row spacings refuse a uniform spacing rather than averaging`() {
        val flow = SprayGuidedFlow(
            completeInputs().copy(
                blocks = listOf(block(rowSpacing = 3.2), block(id = "block-b", rowSpacing = 2.5)),
            ),
        )
        val plan = flow.plan
        assertNull(plan.geometry.uniformRowSpacingMetres)
        // Row length still totals, because both blocks resolved individually.
        assertEquals(62_500.0, plan.geometry.totalRowLengthMetres!!, tolerance)
    }

    // endregion

    // region 11. Changing band width recalculates treated area + products

    @Test
    fun `changing band width recalculates treated area and treated-area products`() {
        val base = completeInputs(SprayOperationType.BANDED_SPRAY).copy(
            products = listOf(
                product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0),
                product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
            ),
        )

        val narrow = SprayGuidedFlow(base.copy(bandWidthTotalMetres = 0.8)).plan
        assertEquals(2.5, narrow.treatedAreaHectares!!, tolerance)
        assertEquals(5.0, narrow.productLines[0].totalQuantity!!, tolerance)

        // Widen the band: 31,250 × 1.6 ÷ 10,000 = 5.0 ha treated.
        val wide = SprayGuidedFlow(base.copy(bandWidthTotalMetres = 1.6)).plan
        assertEquals(5.0, wide.treatedAreaHectares!!, tolerance)
        assertEquals(10.0, wide.productLines[0].totalQuantity!!, tolerance)
        // The whole-block product is unaffected by band width.
        assertEquals(20.0, wide.productLines[1].totalQuantity!!, tolerance)
        // Gross never moves.
        assertEquals(10.0, wide.grossAreaHectares, tolerance)
    }

    @Test
    fun `banded without a band width blocks the target step and leaves treated area null`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(bandWidthTotalMetres = null),
        )
        assertEquals(SprayGuidedBlocker.BandWidthRequired, flow.blocker(SprayGuidedStep.TARGET))
        assertNull(flow.plan.treatedAreaHectares)
        assertFalse(flow.isUnlocked(SprayGuidedStep.GROWTH_STAGE))
        assertNull(flow.snapshot)
    }

    @Test
    fun `a treated-area product with no band width is unresolved, never silently zero`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                bandWidthTotalMetres = null,
                products = listOf(product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0)),
            ),
        )
        val line = flow.plan.productLines[0]
        assertNull(line.totalQuantity)
        assertTrue(line.isUnresolved)
    }

    // endregion

    // region 12. Changing applied L/100 m recalculates carrier + /100 L products

    @Test
    fun `changing applied L per 100m recalculates carrier, concentration and dose`() {
        val base = completeInputs().copy(
            carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
            litresPerHectare = null,
            diluteLitresPer100Metres = 40.0,
            products = listOf(
                product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, "mL"),
            ),
        )

        val concentrated = SprayGuidedFlow(base.copy(appliedLitresPer100Metres = 20.0)).plan
        assertEquals(6_250.0, concentrated.totalCarrierLitres, tolerance)
        assertEquals(2.0, concentrated.concentrationFactor, tolerance)
        assertEquals(625.0, concentrated.carrier.litresPerHectare!!, tolerance)
        assertEquals(12_500.0, concentrated.productLines[0].totalQuantity!!, tolerance)

        // Spray dilute instead: same water as the reference rate.
        val dilute = SprayGuidedFlow(base.copy(appliedLitresPer100Metres = 40.0)).plan
        assertEquals(12_500.0, dilute.totalCarrierLitres, tolerance)
        assertEquals(1.0, dilute.concentrationFactor, tolerance)
        assertEquals(1_250.0, dilute.carrier.litresPerHectare!!, tolerance)
        // Twice the water, no concentration → same dilute-equivalent dose.
        assertEquals(12_500.0, dilute.productLines[0].totalQuantity!!, tolerance)
    }

    // endregion

    // region 13. Saved snapshot == displayed Review calculation

    @Test
    fun `the persisted snapshot is a projection of the plan Review displays`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
                litresPerHectare = null,
                diluteLitresPer100Metres = 40.0,
                appliedLitresPer100Metres = 20.0,
                products = listOf(
                    product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
                    product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0),
                ),
            ),
        )
        assertTrue(flow.isComplete)

        // What Review displays.
        val plan = flow.plan
        // What gets written.
        val snapshot = flow.snapshot
        assertNotNull(snapshot)
        snapshot!!

        assertEquals(plan.grossAreaHectares, snapshot.grossAreaHa!!, tolerance)
        assertEquals(plan.treatedAreaHectares!!, snapshot.treatedAreaHa!!, tolerance)
        assertEquals(plan.mode, snapshot.applicationMode)
        assertEquals(plan.treatedArea.method, snapshot.treatedAreaMethod)
        assertEquals(0.8, snapshot.bandWidthTotalMetres!!, tolerance)
        assertEquals(
            plan.geometry.totalRowLengthMetres!!,
            snapshot.canonicalRowLengthMetres!!,
            tolerance,
        )
        assertEquals(3.2, snapshot.rowSpacingMetres!!, tolerance)
        assertEquals(plan.geometry.source, snapshot.geometrySource)
        assertEquals(plan.geometry.quality, snapshot.geometryQuality)
        assertEquals(plan.carrier.basis, snapshot.carrierVolumeBasis)
        assertEquals(plan.totalCarrierLitres, snapshot.totalCarrierLitres!!, tolerance)
        assertEquals(
            plan.carrier.litresPerHectare!!,
            snapshot.carrierLitresPerHectare!!,
            tolerance,
        )
        assertEquals(40.0, snapshot.diluteLitresPer100m!!, tolerance)
        assertEquals(20.0, snapshot.appliedLitresPer100m!!, tolerance)
        assertEquals(plan.concentrationFactor, snapshot.concentrationFactor!!, tolerance)
        assertTrue(snapshot.hasGenuineTreatedArea)

        // The snapshot is exactly what projecting the plan produces — the UI never
        // populates the 17 columns from its own state.
        assertEquals(SprayApplicationSnapshot.from(plan), snapshot)
    }

    // endregion

    // region Progressive disclosure gating

    @Test
    fun `steps unlock strictly in order as each decision is made`() {
        var inputs = SprayGuidedInputs()

        // Nothing entered: only Application is satisfied.
        var flow = SprayGuidedFlow(inputs)
        assertEquals(SprayGuidedStep.BLOCKS, flow.activeStep)
        assertTrue(flow.isUnlocked(SprayGuidedStep.BLOCKS))
        assertFalse(flow.isUnlocked(SprayGuidedStep.TARGET))
        assertEquals(SprayGuidedBlocker.NoBlocksSelected, flow.blocker(SprayGuidedStep.BLOCKS))

        // Blocks selected → Target opens.
        inputs = inputs.copy(blocks = listOf(block()))
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.TARGET))
        assertFalse(flow.isUnlocked(SprayGuidedStep.GROWTH_STAGE))
        assertEquals(SprayGuidedBlocker.NoTargetSelected, flow.blocker(SprayGuidedStep.TARGET))

        // Target needs the head target too for a foliar spray.
        inputs = inputs.copy(targets = setOf(SprayTarget.POWDERY_MILDEW))
        flow = SprayGuidedFlow(inputs)
        assertEquals(
            SprayGuidedBlocker.SprayHeadTargetRequired,
            flow.blocker(SprayGuidedStep.TARGET),
        )
        assertFalse(flow.isUnlocked(SprayGuidedStep.GROWTH_STAGE))

        inputs = inputs.copy(sprayHeadTarget = SprayHeadTarget.FULL_CANOPY)
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.GROWTH_STAGE))
        assertFalse(flow.isUnlocked(SprayGuidedStep.EQUIPMENT))

        inputs = inputs.copy(isGrowthStageAssigned = true)
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.EQUIPMENT))
        assertFalse(flow.isUnlocked(SprayGuidedStep.CARRIER))

        inputs = inputs.copy(isEquipmentSelected = true)
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.CARRIER))
        assertFalse(flow.isUnlocked(SprayGuidedStep.PRODUCTS))
        assertEquals(SprayGuidedBlocker.CarrierRateRequired, flow.blocker(SprayGuidedStep.CARRIER))

        inputs = inputs.copy(litresPerHectare = 625.0, tankCapacityLitres = 2_000.0)
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.PRODUCTS))
        assertFalse(flow.isUnlocked(SprayGuidedStep.REVIEW))
        assertEquals(SprayGuidedBlocker.NoProductsAdded, flow.blocker(SprayGuidedStep.PRODUCTS))

        inputs = inputs.copy(
            products = listOf(product("Sulphur", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0)),
        )
        flow = SprayGuidedFlow(inputs)
        assertTrue(flow.isUnlocked(SprayGuidedStep.REVIEW))
        assertTrue(flow.isComplete)
        assertEquals(SprayGuidedStep.REVIEW, flow.activeStep)
    }

    @Test
    fun `completed steps behind the active step collapse to summaries`() {
        val flow = SprayGuidedFlow(completeInputs().copy(products = emptyList()))

        assertEquals(SprayGuidedStep.PRODUCTS, flow.activeStep)
        assertTrue(flow.isCollapsible(SprayGuidedStep.APPLICATION))
        assertTrue(flow.isCollapsible(SprayGuidedStep.BLOCKS))
        assertTrue(flow.isCollapsible(SprayGuidedStep.TARGET))
        assertTrue(flow.isCollapsible(SprayGuidedStep.EQUIPMENT))
        assertTrue(flow.isCollapsible(SprayGuidedStep.CARRIER))
        // The active step itself stays expanded.
        assertFalse(flow.isCollapsible(SprayGuidedStep.PRODUCTS))
    }

    @Test
    fun `spreader shows neither a spray head target nor a band width`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.SPREADER).copy(
                sprayHeadTarget = null,
                bandWidthTotalMetres = null,
            ),
        )
        assertFalse(flow.requiresSprayHeadTarget)
        assertFalse(flow.requiresBandWidth)
        assertFalse(flow.supportsCanopySettings)
        assertEquals(SprayApplicationMode.WHOLE_BLOCK, flow.mode)
        // A target is still required, but nothing canopy- or band-specific.
        assertNull(flow.blocker(SprayGuidedStep.TARGET))
        assertTrue(flow.isComplete)
    }

    @Test
    fun `progress fraction reflects completed gated steps`() {
        assertTrue(SprayGuidedFlow(SprayGuidedInputs()).progressFraction < 0.3)
        assertEquals(1.0, SprayGuidedFlow(completeInputs()).progressFraction, tolerance)
    }

    // endregion

    // region Resistance Check reservation

    @Test
    fun `resistance check applicability is flagged but ships no rules or warnings`() {
        val base = completeInputs()

        assertTrue(
            SprayGuidedFlow(base.copy(targets = setOf(SprayTarget.POWDERY_MILDEW)))
                .isResistanceCheckApplicable,
        )
        assertTrue(
            SprayGuidedFlow(base.copy(targets = setOf(SprayTarget.DOWNY_MILDEW)))
                .isResistanceCheckApplicable,
        )
        assertFalse(
            SprayGuidedFlow(base.copy(targets = setOf(SprayTarget.WEEDS)))
                .isResistanceCheckApplicable,
        )
        assertFalse(
            SprayGuidedFlow(base.copy(targets = setOf(SprayTarget.NUTRITION_BIOSTIMULANT)))
                .isResistanceCheckApplicable,
        )
    }

    // endregion

    // region Stable target identifiers

    @Test
    fun `targets persist as stable identifiers, not display text`() {
        assertEquals("powdery_mildew", SprayTarget.POWDERY_MILDEW.raw)
        assertEquals("downy_mildew", SprayTarget.DOWNY_MILDEW.raw)
        assertEquals("nutrition_biostimulant", SprayTarget.NUTRITION_BIOSTIMULANT.raw)
        assertEquals(SprayTarget.POWDERY_MILDEW, SprayTarget.from("Powdery Mildew"))
        assertEquals(SprayTarget.POWDERY_MILDEW, SprayTarget.from("powdery"))
        assertNull(SprayTarget.from("unknown-target"))
        assertNull(SprayTarget.from(null))
        assertEquals(SprayTarget.entries.size, SprayTarget.presentationOrder.size)

        assertEquals("full_canopy", SprayHeadTarget.FULL_CANOPY.raw)
        assertEquals("bunch_line", SprayHeadTarget.BUNCH_LINE.raw)
        assertEquals(SprayHeadTarget.BUNCH_LINE, SprayHeadTarget.from("Bunch Line"))
        assertNull(SprayHeadTarget.from("nope"))

        // Operation types keep the existing stored strings unchanged.
        assertEquals("Foliar Spray", SprayOperationType.FOLIAR_SPRAY.raw)
        assertEquals("Banded Spray", SprayOperationType.BANDED_SPRAY.raw)
        assertEquals("Spreader", SprayOperationType.SPREADER.raw)
        assertEquals(SprayOperationType.BANDED_SPRAY, SprayOperationType.from("Banded Spray"))
    }

    // endregion

    // region Zero-litre placeholder cannot fabricate a dose

    @Test
    fun `before a carrier exists treated area previews but per-100 L stays unresolved`() {
        val flow = SprayGuidedFlow(
            completeInputs(SprayOperationType.BANDED_SPRAY).copy(
                litresPerHectare = null,
                products = listOf(
                    product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, "mL"),
                ),
            ),
        )
        assertFalse(flow.isCarrierResolved)

        val plan = flow.plan
        // Treated area does not depend on carrier, so it previews correctly.
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        // The per-100 L line is unresolved rather than dosed against zero.
        assertNull(plan.productLines[0].totalQuantity)
        assertNull(flow.snapshot)
    }

    // endregion
}
