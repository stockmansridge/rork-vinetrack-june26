package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayGuidedTankBuilder
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Banded Spray persistence contract: the product preview, the review, and the
 * persisted `tanks` JSON all read the ONE `SprayApplicationPlan`, and each
 * persisted line carries the basis its quantity was actually calculated on.
 *
 * THE worked example throughout: 10 ha gross, 31,250 m of row, a 0.8 m band —
 * 31,250 × 0.8 ÷ 10,000 = 2.50 treated ha. At 625 L/ha over gross the carrier
 * is 6,250 L, splitting a 2,000 L tank into 3 full tanks + 250 L.
 */
class SprayBandedTankPersistenceTest {

    private val tolerance = 0.0001

    // region Fixtures

    private fun block() = SprayBlockInput(
        blockId = "block-a",
        grossAreaHectares = 10.0,
        mappedRowLengthMetres = 31_250.0,
        rowSpacingMetres = 3.2,
    )

    private fun product(
        basis: SprayProductRateBasis,
        explicit: Boolean = true,
        name: String = "Herbicide",
    ) = SprayProductLineInput(
        productId = name.lowercase(),
        name = name,
        unit = "g",
        basis = basis,
        rate = 560.0,
        isAreaBasisExplicit = explicit,
    )

    private fun bandedFlow(products: List<SprayProductLineInput>) = SprayGuidedFlow(
        SprayGuidedInputs(
            operationType = SprayOperationType.BANDED_SPRAY,
            blocks = listOf(block()),
            targets = setOf(SprayTarget.WEEDS),
            bandWidthTotalMetres = 0.8,
            isGrowthStageAssigned = true,
            isEquipmentSelected = true,
            isEquipmentConfirmed = true,
            tankCapacityLitres = 2_000.0,
            carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
            litresPerHectare = 625.0,
            products = products,
        ),
    )

    private fun source(relative: String): String {
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android-vinetrack/app/$relative"),
        )
        val found = candidates.firstOrNull { it.exists() }
            ?: error("source not found: $relative")
        return found.readText()
    }

    private val screenPath =
        "src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt"

    // endregion

    // region 1. Treated area geometry

    @Test
    fun `1 - 10 ha gross with 31250 m of row and a 0_8 m band treats 2_5 ha`() {
        val flow = bandedFlow(listOf(product(SprayProductRateBasis.TREATED_AREA)))
        val plan = flow.plan

        assertEquals(SprayApplicationMode.BANDED, flow.mode)
        assertEquals(10.0, plan.grossAreaHectares, tolerance)
        // treatedAreaHa = 31,250 m × 0.8 m ÷ 10,000
        assertEquals(2.5, plan.treatedAreaHectares!!, tolerance)

        // The persisted snapshot carries the SAME treated area — gross is
        // retained alongside, never replaced.
        val snapshot = flow.snapshot
        assertNotNull(snapshot)
        assertEquals(2.5, snapshot!!.treatedAreaHa!!, tolerance)
        assertEquals(10.0, snapshot.grossAreaHa!!, tolerance)
        assertEquals(0.8, snapshot.bandWidthTotalMetres!!, tolerance)
    }

    // endregion

    // region 2-3. Product totals per chosen basis

    @Test
    fun `2 - a treated-band 560 g per ha product totals 1400 g`() {
        val plan = bandedFlow(listOf(product(SprayProductRateBasis.TREATED_AREA))).plan
        val line = plan.productLines.single()

        // 560 g/ha × 2.5 treated ha — never gross.
        assertEquals(1_400.0, line.totalQuantity!!, tolerance)
        assertEquals(2.5, line.basisInput!!, tolerance)
        assertEquals(SprayProductRateBasis.TREATED_AREA, line.basis)
    }

    @Test
    fun `3 - the same product on whole block totals 5600 g`() {
        val plan = bandedFlow(listOf(product(SprayProductRateBasis.WHOLE_BLOCK_AREA))).plan
        val line = plan.productLines.single()

        // 560 g/ha × 10 gross ha.
        assertEquals(5_600.0, line.totalQuantity!!, tolerance)
        assertEquals(10.0, line.basisInput!!, tolerance)
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA, line.basis)
    }

    // endregion

    // region 4. Undecided area basis blocks Review / Create / Save

    @Test
    fun `4 - an unanswered area basis blocks the flow and yields nothing to persist`() {
        val flow = bandedFlow(
            listOf(product(SprayProductRateBasis.WHOLE_BLOCK_AREA, explicit = false)),
        )

        val blocker = flow.blocker(SprayGuidedStep.PRODUCTS)
        assertTrue(blocker is SprayGuidedBlocker.ProductAreaBasisRequired)
        assertFalse(flow.isComplete)
        // Nothing may be frozen into a record while the question is open.
        assertNull(flow.persistablePlan)
        assertNull(flow.snapshot)

        // Answering the question unblocks the SAME inputs.
        val decided = bandedFlow(
            listOf(product(SprayProductRateBasis.WHOLE_BLOCK_AREA, explicit = true)),
        )
        assertNull(decided.blocker(SprayGuidedStep.PRODUCTS))
        assertTrue(decided.isComplete)
    }

    @Test
    fun `4b - the screen wires explicitness and gates every action on it`() {
        val screen = source(screenPath)

        // The engine input is explicit ONLY for a per-100 L label or a line
        // whose Whole Block / Treated Band question was actually answered.
        assertTrue(
            "the screen must pass the required explicitness expression",
            screen.contains(
                "isAreaBasisExplicit = line.basis == SprayCalculator.RateBasis.PER_100L ||",
            ) && screen.contains("productAreaBasis[line.uid] != null,"),
        )
        // Create and Save share formIsValid, which must refuse an undecided
        // banded line; Review is opened by runCalculation, which the banded
        // branch blocks through the flow's own blockers.
        assertTrue(
            "formIsValid must gate on the undecided banded basis",
            screen.contains("chemLines.isNotEmpty() && !bandedBasisUndecided"),
        )
        assertTrue(
            screen.contains("guidedProducts.any { it.needsAreaBasisDecision }"),
        )
    }

    @Test
    fun `4c - the banded save path never reaches the legacy calculator`() {
        val screen = source(screenPath)

        // runCalculation resolves a banded pass from the guided plan and
        // RETURNS before the legacy engine is consulted.
        val runCalculation = screen
            .substringAfter("fun runCalculation")
            .substringBefore("fun buildInput")
        val bandedGuard = runCalculation.indexOf(
            "if (guidedFlow.mode == SprayApplicationMode.BANDED)",
        )
        val legacyCall = runCalculation.indexOf("SprayCalculator.calculate(")
        assertTrue("runCalculation must branch on BANDED", bandedGuard >= 0)
        assertTrue("legacy engine must remain for whole-block", legacyCall >= 0)
        assertTrue("the BANDED branch must precede the legacy engine", bandedGuard < legacyCall)
        assertTrue(
            "the banded review result must be a projection of the plan",
            runCalculation.contains("SprayGuidedTankBuilder.reviewResult(guidedPlan)"),
        )

        // The persisted tanks for a banded job come from the plan builder.
        val buildInput = screen
            .substringAfter("fun buildInput")
            .substringBefore("fun buildRowPlan")
        assertTrue(
            "banded tanks must be built from the guided plan",
            buildInput.contains("SprayGuidedTankBuilder.build("),
        )
        assertTrue(
            "whole-block tanks must keep the established builder",
            buildInput.contains("SprayCalculator.buildTanks("),
        )
    }

    // endregion

    // region 5. Review equals what is persisted

    @Test
    fun `5 - the review total equals the sum persisted across tanks`() {
        val flow = bandedFlow(
            listOf(
                product(SprayProductRateBasis.TREATED_AREA, name = "Herbicide"),
                product(SprayProductRateBasis.WHOLE_BLOCK_AREA, name = "Kelp"),
            ),
        )
        val plan = flow.plan
        val review = SprayGuidedTankBuilder.reviewResult(plan)
        val tanks = SprayGuidedTankBuilder.build(plan, chosenSprayRate = 625.0)

        // 6,250 L over 2,000 L tanks: 3 full + 250 L last.
        assertEquals(4, tanks.size)
        assertEquals(6_250.0, tanks.sumOf { it.waterVolume }, tolerance)
        assertEquals(3, review.fullTankCount)
        assertEquals(250.0, review.lastTankLitres, tolerance)

        review.chemicalResults.forEach { cr ->
            val persistedSum = tanks.sumOf { tank ->
                tank.chemicals.filter { it.savedChemicalId == cr.savedChemicalId }
                    .sumOf { it.volumePerTank }
            }
            assertEquals(
                "review and persisted quantities must be one number (${cr.name})",
                cr.totalAmount,
                persistedSum,
                tolerance,
            )
        }
        // And the review shows the plan's own totals: 1,400 g and 5,600 g.
        assertEquals(
            1_400.0,
            review.chemicalResults.first { it.savedChemicalId == "herbicide" }.totalAmount,
            tolerance,
        )
        assertEquals(
            5_600.0,
            review.chemicalResults.first { it.savedChemicalId == "kelp" }.totalAmount,
            tolerance,
        )
    }

    // endregion

    // region 6. Round trip preserves basis and quantities

    @Test
    fun `6 - each line persists the basis it was calculated on`() {
        val plan = bandedFlow(
            listOf(
                product(SprayProductRateBasis.TREATED_AREA, name = "Herbicide"),
                product(SprayProductRateBasis.WHOLE_BLOCK_AREA, name = "Kelp"),
            ),
        ).plan
        val firstTank = SprayGuidedTankBuilder.build(plan, chosenSprayRate = 625.0).first()

        val treated = firstTank.chemicals.first { it.savedChemicalId == "herbicide" }
        val whole = firstTank.chemicals.first { it.savedChemicalId == "kelp" }

        assertEquals("treated_area", treated.rateBasis)
        assertEquals("whole_block_area", whole.rateBasis)
        // A quantity calculated against GROSS hectares is never stamped
        // treated_area — the stamp comes from the plan line itself, the only
        // thing that knows which hectares it multiplied.
        assertNotEquals("treated_area", whole.rateBasis)
        // Rates keep their legacy columns: area rates in ratePerHa.
        assertEquals(560.0, treated.ratePerHa, tolerance)
        assertEquals(0.0, treated.ratePer100L, tolerance)
    }

    @Test
    fun `6b - reopening the saved job reproduces treated area and quantities`() {
        val savedFlow = bandedFlow(
            listOf(
                product(SprayProductRateBasis.TREATED_AREA, name = "Herbicide"),
                product(SprayProductRateBasis.WHOLE_BLOCK_AREA, name = "Kelp"),
            ),
        )
        val savedPlan = savedFlow.plan
        val savedSnapshot = savedFlow.snapshot!!
        val savedTanks = SprayGuidedTankBuilder.build(savedPlan, chosenSprayRate = 625.0)

        // Reopen: rebuild the inputs exclusively from what was PERSISTED —
        // the snapshot's band width and each line's stored basis + rate. This
        // is the same reconstruction the prefill performs.
        val restoredProducts = savedTanks.first().chemicals.map { chem ->
            val basis = SprayProductRateBasis.legacy(chem.rateBasis)!!
            SprayProductLineInput(
                productId = chem.savedChemicalId!!,
                name = chem.name,
                unit = chem.unit,
                basis = basis,
                rate = if (basis == SprayProductRateBasis.PER_100_LITRES) {
                    chem.ratePer100L
                } else {
                    chem.ratePerHa
                },
                isAreaBasisExplicit = true,
            )
        }
        val reopened = SprayGuidedFlow(
            SprayGuidedInputs(
                operationType = SprayOperationType.BANDED_SPRAY,
                blocks = listOf(block()),
                targets = setOf(SprayTarget.WEEDS),
                bandWidthTotalMetres = savedSnapshot.bandWidthTotalMetres,
                isGrowthStageAssigned = true,
                isEquipmentSelected = true,
            isEquipmentConfirmed = true,
                tankCapacityLitres = 2_000.0,
                carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
                litresPerHectare = 625.0,
                products = restoredProducts,
            ),
        )
        val reopenedPlan = reopened.plan

        // treated_area survives the round trip…
        assertEquals(2.5, reopenedPlan.treatedAreaHectares!!, tolerance)
        assertEquals(
            savedSnapshot.treatedAreaHa!!,
            reopened.snapshot!!.treatedAreaHa!!,
            tolerance,
        )
        // …and every quantity re-derives to exactly what was saved.
        savedPlan.productLines.forEach { savedLine ->
            val reopenedLine = reopenedPlan.productLines
                .first { it.productId == savedLine.productId }
            assertEquals(savedLine.basis, reopenedLine.basis)
            assertEquals(savedLine.totalQuantity!!, reopenedLine.totalQuantity!!, tolerance)
        }
    }

    @Test
    fun `6c - the prefill reinstates band width and each line's stored basis`() {
        val screen = source(screenPath)
        assertTrue(
            "reopening must restore the persisted band width",
            screen.contains("r.applicationGeometry?.bandWidthTotalMetres"),
        )
        assertTrue(
            "reopening must reinstate each line's stored area basis",
            screen.contains("SprayProductRateBasis.legacy(chem.rateBasis)"),
        )
    }

    // endregion
}
