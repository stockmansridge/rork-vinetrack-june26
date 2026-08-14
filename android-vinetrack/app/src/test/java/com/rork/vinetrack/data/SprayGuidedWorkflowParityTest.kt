package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierVolumePolicy
import com.rork.vinetrack.data.spray.SprayComplianceProfile
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayHeadTarget
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayProductUnresolvedReason
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayVineyardProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parity contract for the guided Spray Workflow's application INTENT and
 * per-product rate bases — the Kotlin twin of the Swift
 * `SprayGuidedWorkflowParityTests`, asserting the same fixtures and the same
 * numbers.
 *
 * Everything here protects one rule: a figure the operator sees came out of
 * `SprayApplicationPlanner.plan`, and the record that is persisted is a
 * projection of that same plan. Nothing is recomputed by a screen, and nothing
 * about a historical record is silently restated.
 */
class SprayGuidedWorkflowParityTest {

    private val tolerance = 0.0001

    // region Fixtures

    /**
     * THE worked example, shared verbatim with iOS: 10 ha gross, 31,250 m of
     * row, 3.2 m spacing. A 0.8 m band over that geometry treats exactly 2.50 ha,
     * and 20 L/100 m over that row length is exactly 6,250 L of carrier.
     */
    private fun block() = SprayBlockInput(
        blockId = "block-a",
        grossAreaHectares = 10.0,
        mappedRowLengthMetres = 31_250.0,
        rowSpacingMetres = 3.2,
    )

    private fun product(
        name: String,
        basis: SprayProductRateBasis,
        rate: Double,
        unit: String = "L",
        explicit: Boolean = true,
    ) = SprayProductLineInput(
        productId = name.lowercase(),
        name = name,
        unit = unit,
        basis = basis,
        rate = rate,
        isAreaBasisExplicit = explicit,
    )

    /** The three-basis banded tank mix from the specification. */
    private fun mixedBasisProducts() = listOf(
        product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
        product("Herbicide", SprayProductRateBasis.TREATED_AREA, 2.0),
        product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, unit = "mL"),
    )

    /**
     * A complete BANDED pass on the worked example, carried on L/100 m so the
     * carrier volume is exactly 6,250 L with no concentration.
     */
    private fun bandedInputs(
        appliedPer100m: Double = 20.0,
        bandWidth: Double = 0.8,
        products: List<SprayProductLineInput> = mixedBasisProducts(),
    ) = SprayGuidedInputs(
        operationType = SprayOperationType.BANDED_SPRAY,
        blocks = listOf(block()),
        targets = setOf(SprayTarget.WEEDS),
        bandWidthTotalMetres = bandWidth,
        isGrowthStageAssigned = true,
        isEquipmentSelected = true,
        tankCapacityLitres = 2_000.0,
        carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
        appliedLitresPer100Metres = appliedPer100m,
        products = products,
    )

    private fun foliarInputs(
        head: SprayHeadTarget? = SprayHeadTarget.FULL_CANOPY,
        targets: Set<SprayTarget> = setOf(SprayTarget.POWDERY_MILDEW),
    ) = SprayGuidedInputs(
        operationType = SprayOperationType.FOLIAR_SPRAY,
        blocks = listOf(block()),
        targets = targets,
        sprayHeadTarget = head,
        isGrowthStageAssigned = true,
        isEquipmentSelected = true,
        tankCapacityLitres = 2_000.0,
        carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
        litresPerHectare = 625.0,
        products = listOf(product("Sulphur", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0)),
    )

    /** A snapshot round trip through the stored columns, exactly as sql/193 holds them. */
    private fun roundTrip(snapshot: SprayApplicationSnapshot): SprayApplicationSnapshot? =
        SprayApplicationSnapshot.fromColumns(
            grossAreaHa = snapshot.grossAreaHa,
            treatedAreaHa = snapshot.treatedAreaHa,
            applicationMode = snapshot.applicationMode?.raw,
            treatedAreaMethod = snapshot.treatedAreaMethod?.raw,
            bandWidthTotalMetres = snapshot.bandWidthTotalMetres,
            bandWidthLeftMetres = snapshot.bandWidthLeftMetres,
            bandWidthRightMetres = snapshot.bandWidthRightMetres,
            canonicalRowLengthMetres = snapshot.canonicalRowLengthMetres,
            rowSpacingMetres = snapshot.rowSpacingMetres,
            geometrySource = snapshot.geometrySource?.raw,
            geometryQuality = snapshot.geometryQuality?.raw,
            carrierVolumeBasis = snapshot.carrierVolumeBasis?.raw,
            totalCarrierLitres = snapshot.totalCarrierLitres,
            carrierLitresPerHectare = snapshot.carrierLitresPerHectare,
            diluteLitresPer100m = snapshot.diluteLitresPer100m,
            appliedLitresPer100m = snapshot.appliedLitresPer100m,
            concentrationFactor = snapshot.concentrationFactor,
            targets = snapshot.targets?.map { it.raw },
            sprayHeadTarget = snapshot.sprayHeadTarget?.raw,
        )

    // endregion

    // region Targets

    @Test
    fun `a single target persists and reloads as the same stable identifier`() {
        val flow = SprayGuidedFlow(foliarInputs(targets = setOf(SprayTarget.BOTRYTIS)))
        val snapshot = flow.snapshot
        assertNotNull(snapshot)

        assertEquals(listOf(SprayTarget.BOTRYTIS), snapshot!!.targets)
        assertEquals(listOf("botrytis"), snapshot.targets?.map { it.raw })

        val reloaded = roundTrip(snapshot)
        assertEquals(listOf(SprayTarget.BOTRYTIS), reloaded?.targets)
    }

    @Test
    fun `multiple targets persist in presentation order regardless of tap order`() {
        val tappedLast = SprayGuidedFlow(
            foliarInputs(
                targets = setOf(SprayTarget.BOTRYTIS, SprayTarget.POWDERY_MILDEW),
            ),
        )
        val tappedFirst = SprayGuidedFlow(
            foliarInputs(
                targets = setOf(SprayTarget.POWDERY_MILDEW, SprayTarget.BOTRYTIS),
            ),
        )

        val expected = listOf(SprayTarget.POWDERY_MILDEW, SprayTarget.BOTRYTIS)
        assertEquals(expected, tappedLast.snapshot?.targets)
        // Two sprays with the same selection must serialise identically, or the
        // Resistance Planner would see two different-looking histories.
        assertEquals(tappedLast.snapshot?.targets, tappedFirst.snapshot?.targets)
        assertEquals(expected, roundTrip(tappedLast.snapshot!!)?.targets)
    }

    @Test
    fun `editing the targets replaces them rather than accumulating`() {
        val before = SprayGuidedFlow(foliarInputs(targets = setOf(SprayTarget.POWDERY_MILDEW)))
        val after = SprayGuidedFlow(
            foliarInputs(targets = setOf(SprayTarget.DOWNY_MILDEW, SprayTarget.BOTRYTIS)),
        )

        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), before.snapshot?.targets)
        assertEquals(
            listOf(SprayTarget.DOWNY_MILDEW, SprayTarget.BOTRYTIS),
            after.snapshot?.targets,
        )
    }

    @Test
    fun `a historical record with no targets column stays null and is never inferred`() {
        // A pre-sql/193 record: geometry present, targets absent entirely.
        val reloaded = SprayApplicationSnapshot.fromColumns(
            grossAreaHa = 10.0,
            treatedAreaHa = 2.5,
            applicationMode = "banded",
            treatedAreaMethod = "canonical_row_length",
            bandWidthTotalMetres = 0.8,
            bandWidthLeftMetres = null,
            bandWidthRightMetres = null,
            canonicalRowLengthMetres = 31_250.0,
            rowSpacingMetres = 3.2,
            geometrySource = "mapped_rows",
            geometryQuality = "authoritative",
            carrierVolumeBasis = "litres_per_100_metres",
            totalCarrierLitres = 6_250.0,
            carrierLitresPerHectare = 625.0,
            diluteLitresPer100m = null,
            appliedLitresPer100m = 20.0,
            concentrationFactor = 1.0,
            targets = null,
            sprayHeadTarget = null,
        )

        assertNotNull(reloaded)
        // null = never recorded. NOT an empty list, and never guessed from the
        // chemistry in the tank: only the operator knew what it was for.
        assertNull(reloaded!!.targets)
        assertFalse(reloaded.hasRecordedTargets)
    }

    @Test
    fun `an unrecognised target identifier degrades without failing the record`() {
        val reloaded = SprayApplicationSnapshot.fromColumns(
            grossAreaHa = 10.0,
            treatedAreaHa = 10.0,
            applicationMode = "whole_block",
            treatedAreaMethod = "whole_block",
            bandWidthTotalMetres = null,
            bandWidthLeftMetres = null,
            bandWidthRightMetres = null,
            canonicalRowLengthMetres = null,
            rowSpacingMetres = null,
            geometrySource = "mapped_rows",
            geometryQuality = "authoritative",
            carrierVolumeBasis = "litres_per_hectare",
            totalCarrierLitres = 6_250.0,
            carrierLitresPerHectare = 625.0,
            diluteLitresPer100m = null,
            appliedLitresPer100m = null,
            concentrationFactor = 1.0,
            // sql/193 puts no value CHECK on `targets`, so a newer build can
            // legitimately write a word this client has never heard of.
            targets = listOf("botrytis", "sooty_blotch_2099"),
            sprayHeadTarget = null,
        )

        assertEquals(listOf(SprayTarget.BOTRYTIS), reloaded?.targets)
    }

    // endregion

    // region Spray head target

    @Test
    fun `each foliar spray head target persists and reloads`() {
        SprayHeadTarget.entries.forEach { head ->
            val snapshot = SprayGuidedFlow(foliarInputs(head = head)).snapshot
            assertNotNull("expected a snapshot for $head", snapshot)
            assertEquals(head, snapshot!!.sprayHeadTarget)
            assertEquals(head, roundTrip(snapshot)?.sprayHeadTarget)
        }
    }

    @Test
    fun `switching foliar to banded clears the spray head target at flow level`() {
        // The screen may still be holding Bunch Line in its own state; the flow
        // must refuse to carry it, so a banded record can never claim the spray
        // was aimed at the bunch line.
        val stale = bandedInputs().copy(sprayHeadTarget = SprayHeadTarget.BUNCH_LINE)
        val flow = SprayGuidedFlow(stale)

        assertNull(flow.effectiveSprayHeadTarget)
        assertNull(flow.snapshot?.sprayHeadTarget)
    }

    @Test
    fun `switching banded to foliar drops the band width and treats the whole block`() {
        val stale = foliarInputs().copy(bandWidthTotalMetres = 0.8)
        val flow = SprayGuidedFlow(stale)

        assertNull(flow.bandWidth)
        assertEquals(10.0, flow.plan.treatedAreaHectares!!, tolerance)
        assertNull(flow.snapshot?.bandWidthTotalMetres)
    }

    // endregion

    // region Vineyard spray profile

    @Test
    fun `a stored AU profile allowing either basis leaves the choice with the operator`() {
        val profile = SprayVineyardProfile(
            storedProfile = SprayComplianceProfile.AUSTRALIA,
            storedPolicy = SprayCarrierVolumePolicy.EITHER,
            countryCode = "AU",
        )
        val flow = SprayGuidedFlow(foliarInputs(), profile)

        assertFalse(flow.isCarrierBasisLocked)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, flow.effectiveCarrierBasis)
        assertTrue(flow.carrierPolicy.allows(SprayCarrierBasis.LITRES_PER_100_METRES))
    }

    @Test
    fun `a stored L per ha only policy locks the basis to hectares`() {
        val profile = SprayVineyardProfile(
            storedPolicy = SprayCarrierVolumePolicy.LITRES_PER_HECTARE_ONLY,
            countryCode = "AU",
        )
        val flow = SprayGuidedFlow(
            foliarInputs().copy(carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES),
            profile,
        )

        assertTrue(flow.isCarrierBasisLocked)
        assertEquals(SprayCarrierBasis.LITRES_PER_HECTARE, flow.effectiveCarrierBasis)
    }

    @Test
    fun `a stored L per 100 m only policy locks the basis to row length`() {
        val profile = SprayVineyardProfile(
            storedPolicy = SprayCarrierVolumePolicy.LITRES_PER_100_METRES_ONLY,
            countryCode = "AU",
        )
        val flow = SprayGuidedFlow(bandedInputs(), profile)

        assertTrue(flow.isCarrierBasisLocked)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, flow.effectiveCarrierBasis)
    }

    @Test
    fun `an NZ SWNZ vineyard cannot be switched onto L per ha`() {
        val profile = SprayVineyardProfile(
            storedProfile = SprayComplianceProfile.NEW_ZEALAND_SWNZ,
            countryCode = "NZ",
        )
        // Even if the screen state says L/ha, the profile overrides it: the UI
        // renders no L/ha option and no "allow either" selector for SWNZ.
        val flow = SprayGuidedFlow(
            bandedInputs().copy(carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE),
            profile,
        )

        assertTrue(flow.isCarrierBasisLocked)
        assertEquals(SprayCarrierBasis.LITRES_PER_100_METRES, flow.effectiveCarrierBasis)
        assertFalse(flow.carrierPolicy.allows(SprayCarrierBasis.LITRES_PER_HECTARE))
        // L/ha is still DERIVED and stored internally — hidden, not discarded.
        assertEquals(625.0, flow.plan.carrier.litresPerHectare!!, tolerance)
    }

    @Test
    fun `country fallback applies only when no profile is stored`() {
        val unset = SprayVineyardProfile(countryCode = "NZ")
        assertEquals(SprayComplianceProfile.NEW_ZEALAND_SWNZ, unset.resolvedProfile)
        assertTrue(unset.isCarrierBasisLocked)

        // A vineyard that has deliberately chosen AU is NOT overridden by its
        // own address — resolution reads the stored value first.
        val stored = SprayVineyardProfile(
            storedProfile = SprayComplianceProfile.AUSTRALIA,
            countryCode = "NZ",
        )
        assertEquals(SprayComplianceProfile.AUSTRALIA, stored.resolvedProfile)
        assertFalse(stored.isCarrierBasisLocked)
    }

    // endregion

    // region Per-product rate basis

    @Test
    fun `one banded mix calculates whole block treated band and per 100 L independently`() {
        val flow = SprayGuidedFlow(bandedInputs())
        assertTrue(flow.isComplete)

        val plan = flow.plan
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)
        assertEquals(6_250.0, plan.totalCarrierLitres, tolerance)
        assertEquals(1.0, plan.concentrationFactor, tolerance)

        val (kelp, herbicide, adjuvant) = Triple(
            plan.productLines[0],
            plan.productLines[1],
            plan.productLines[2],
        )
        // 2 L/ha x 10 ha whole block
        assertEquals(20.0, kelp.totalQuantity!!, tolerance)
        assertEquals(10.0, kelp.basisInput!!, tolerance)
        // 2 L/ha x 2.5 ha treated band
        assertEquals(5.0, herbicide.totalQuantity!!, tolerance)
        assertEquals(2.5, herbicide.basisInput!!, tolerance)
        // 100 mL/100 L x 6,250 L carrier = 6,250 mL = 6.25 L
        assertEquals(6_250.0, adjuvant.totalQuantity!!, tolerance)
        assertEquals(6_250.0, adjuvant.basisInput!!, tolerance)
    }

    @Test
    fun `product quantities and bases survive persist and reload unchanged`() {
        val flow = SprayGuidedFlow(bandedInputs())
        val snapshot = flow.snapshot
        assertNotNull(snapshot)

        val reloaded = roundTrip(snapshot!!)
        assertNotNull(reloaded)
        // The measured inputs each basis multiplies against are what must survive:
        // gross, treated and carrier all reload verbatim, so replaying the record
        // reproduces 20 L, 5 L and 6.25 L exactly.
        assertEquals(10.0, reloaded!!.grossAreaHa!!, tolerance)
        assertEquals(2.5, reloaded.treatedAreaHa!!, tolerance)
        assertEquals(6_250.0, reloaded.totalCarrierLitres!!, tolerance)
        assertEquals(1.0, reloaded.concentrationFactor!!, tolerance)
        assertEquals(listOf(SprayTarget.WEEDS), reloaded.targets)
        assertNull(reloaded.sprayHeadTarget)
    }

    @Test
    fun `a new banded area product will not proceed on an unconfirmed area basis`() {
        val undecided = bandedInputs(
            products = listOf(
                product("Kelp", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0, explicit = false),
            ),
        )
        val flow = SprayGuidedFlow(undecided)

        val blocker = flow.blocker(SprayGuidedStep.PRODUCTS)
        assertTrue(blocker is SprayGuidedBlocker.ProductAreaBasisRequired)
        assertEquals(listOf("Kelp"), (blocker as SprayGuidedBlocker.ProductAreaBasisRequired).names)
        assertFalse(flow.isComplete)
        // Nothing may be frozen into a record until the operator answers.
        assertNull(flow.snapshot)
    }

    @Test
    fun `a per 100 L product is never asked the area question`() {
        val flow = SprayGuidedFlow(
            bandedInputs(
                products = listOf(
                    product("Adjuvant", SprayProductRateBasis.PER_100_LITRES, 100.0, unit = "mL", explicit = false),
                ),
            ),
        )

        // Its basis comes from the product's own label, not from how the block
        // was covered, so there is nothing ambiguous to confirm.
        assertNull(flow.blocker(SprayGuidedStep.PRODUCTS))
        assertTrue(flow.isComplete)
    }

    @Test
    fun `a whole block pass never asks the area question`() {
        val flow = SprayGuidedFlow(
            foliarInputs().copy(
                products = listOf(
                    product("Sulphur", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0, explicit = false),
                ),
            ),
        )

        // Treated and gross are the same thing here, so there is no decision.
        assertNull(flow.blocker(SprayGuidedStep.PRODUCTS))
        assertTrue(flow.isComplete)
    }

    @Test
    fun `a treated area product without band geometry names the missing input`() {
        val flow = SprayGuidedFlow(bandedInputs(bandWidth = 0.0))

        val herbicide = flow.plan.productLines[1]
        assertTrue(herbicide.isUnresolved)
        assertEquals(
            SprayProductUnresolvedReason.TREATED_AREA_UNAVAILABLE,
            herbicide.unresolvedReason,
        )
        // Never dosed against gross hectares as a fallback.
        assertNull(herbicide.totalQuantity)
        assertNull(herbicide.basisInput)
    }

    @Test
    fun `a per 100 L product without a carrier names the carrier step`() {
        val flow = SprayGuidedFlow(bandedInputs(appliedPer100m = 0.0))

        val adjuvant = flow.plan.productLines[2]
        assertTrue(adjuvant.isUnresolved)
        assertEquals(SprayProductUnresolvedReason.CARRIER_UNAVAILABLE, adjuvant.unresolvedReason)
        // Never dosed against zero litres.
        assertNull(adjuvant.totalQuantity)
    }

    // endregion

    // region Recalculation isolation

    @Test
    fun `changing the band width moves only the treated-area product`() {
        val before = SprayGuidedFlow(bandedInputs()).plan
        val after = SprayGuidedFlow(bandedInputs(bandWidth = 1.6)).plan

        // Treated area doubles with the band.
        assertEquals(2.5, before.treatedAreaHectares!!, tolerance)
        assertEquals(5.0, after.treatedAreaHectares!!, tolerance)
        assertEquals(10.0, after.productLines[1].totalQuantity!!, tolerance)

        // Whole block and per-100 L are untouched: the band says nothing about
        // gross hectares, and nothing about how much water went out.
        assertEquals(
            before.productLines[0].totalQuantity!!,
            after.productLines[0].totalQuantity!!,
            tolerance,
        )
        assertEquals(
            before.productLines[2].totalQuantity!!,
            after.productLines[2].totalQuantity!!,
            tolerance,
        )
        assertEquals(before.totalCarrierLitres, after.totalCarrierLitres, tolerance)
    }

    @Test
    fun `changing the applied L per 100 m moves only carrier-dependent quantities`() {
        val before = SprayGuidedFlow(bandedInputs()).plan
        val after = SprayGuidedFlow(bandedInputs(appliedPer100m = 40.0)).plan

        assertEquals(6_250.0, before.totalCarrierLitres, tolerance)
        assertEquals(12_500.0, after.totalCarrierLitres, tolerance)
        assertEquals(12_500.0, after.productLines[2].totalQuantity!!, tolerance)

        // Area-based products do not care how much water carried them.
        assertEquals(20.0, after.productLines[0].totalQuantity!!, tolerance)
        assertEquals(5.0, after.productLines[1].totalQuantity!!, tolerance)
        assertEquals(before.treatedAreaHectares!!, after.treatedAreaHectares!!, tolerance)
    }

    @Test
    fun `changing the selected blocks recalculates every derived figure`() {
        val bigger = bandedInputs().copy(
            blocks = listOf(
                block(),
                SprayBlockInput(
                    blockId = "block-b",
                    grossAreaHectares = 10.0,
                    mappedRowLengthMetres = 31_250.0,
                    rowSpacingMetres = 3.2,
                ),
            ),
        )
        val plan = SprayGuidedFlow(bigger).plan

        assertEquals(20.0, plan.grossAreaHectares, tolerance)
        assertEquals(62_500.0, plan.geometry.totalRowLengthMetres!!, tolerance)
        assertEquals(5.0, plan.treatedAreaHectares!!, tolerance)
        assertEquals(12_500.0, plan.totalCarrierLitres, tolerance)
        assertEquals(40.0, plan.productLines[0].totalQuantity!!, tolerance)
        assertEquals(10.0, plan.productLines[1].totalQuantity!!, tolerance)
        assertEquals(12_500.0, plan.productLines[2].totalQuantity!!, tolerance)
    }

    // endregion

    // region Review parity & progressive disclosure

    @Test
    fun `the review the operator signs off is the record that gets persisted`() {
        val flow = SprayGuidedFlow(bandedInputs())
        val plan = flow.plan
        val snapshot = flow.snapshot
        assertNotNull(snapshot)

        // Review reads `plan`; persistence writes `snapshot`. They must be the
        // same projection — there is no second review-side calculation.
        assertEquals(
            SprayApplicationSnapshot.from(
                plan = plan,
                targets = flow.orderedTargets,
                sprayHeadTarget = flow.effectiveSprayHeadTarget,
            ),
            snapshot,
        )
        assertEquals(plan.grossAreaHectares, snapshot!!.grossAreaHa!!, tolerance)
        assertEquals(plan.treatedAreaHectares!!, snapshot.treatedAreaHa!!, tolerance)
        assertEquals(plan.totalCarrierLitres, snapshot.totalCarrierLitres!!, tolerance)
    }

    @Test
    fun `the decision order is Application Blocks Target Growth Equipment Carrier Products Review`() {
        assertEquals(
            listOf(
                SprayGuidedStep.APPLICATION,
                SprayGuidedStep.BLOCKS,
                SprayGuidedStep.TARGET,
                SprayGuidedStep.GROWTH_STAGE,
                SprayGuidedStep.EQUIPMENT,
                SprayGuidedStep.CARRIER,
                SprayGuidedStep.PRODUCTS,
                SprayGuidedStep.REVIEW,
            ),
            SprayGuidedStep.entries.toList(),
        )

        // Target sits behind Blocks: it cannot be answered before the ground it
        // applies to is known.
        val noBlocks = SprayGuidedFlow(bandedInputs().copy(blocks = emptyList()))
        assertFalse(noBlocks.isUnlocked(SprayGuidedStep.TARGET))
        assertEquals(SprayGuidedStep.BLOCKS, noBlocks.activeStep)

        // And Products sits behind Carrier, so a per-100 L line is never dosed
        // against a carrier volume that does not exist yet.
        val noCarrier = SprayGuidedFlow(bandedInputs(appliedPer100m = 0.0))
        assertFalse(noCarrier.isUnlocked(SprayGuidedStep.PRODUCTS))
        assertEquals(SprayGuidedStep.CARRIER, noCarrier.activeStep)
    }

    // endregion
}
