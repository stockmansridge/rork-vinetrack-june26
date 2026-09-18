package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierAreaBasis
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayCarrierVolumeCalculator
import com.rork.vinetrack.data.spray.SprayGroundTarget
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SprayBandedGroundCarrierTest {
    private val tolerance = 0.0001

    private fun block() = SprayBlockInput(
        blockId = "block-a",
        grossAreaHectares = 9.0,
        mappedRowLengthMetres = 30_000.0,
        rowSpacingMetres = 3.0,
    )

    private fun banded(
        basis: SprayCarrierBasis,
        areaBasis: SprayCarrierAreaBasis,
        rate: Double? = null,
        manualTotal: Double? = null,
        products: List<SprayProductLineInput> = emptyList(),
        groundTarget: SprayGroundTarget = SprayGroundTarget.UNDERVINE,
    ) = SprayGuidedFlow(
        SprayGuidedInputs(
            operationType = SprayOperationType.BANDED_SPRAY,
            blocks = listOf(block()),
            targets = setOf(SprayTarget.WEEDS),
            groundTarget = groundTarget,
            bandWidthTotalMetres = 1.0,
            isGrowthStageAssigned = true,
            isEquipmentSelected = true,
            isEquipmentConfirmed = true,
            carrierBasis = basis,
            carrierAreaBasis = areaBasis,
            litresPerHectare = rate,
            manualTotalLitres = manualTotal,
            products = products,
        ),
    )

    @Test
    fun `Full Canopy carrier regression remains unchanged`() {
        val carrier = SprayCarrierVolumeCalculator.perHectare(625.0, 10.0, 1.5, 31_250.0, 3.2)
        assertEquals(6_250.0, carrier.totalLitres, tolerance)
        assertEquals(1.5, carrier.concentrationFactor, tolerance)
    }

    @Test
    fun `treated-area carrier uses three treated hectares`() {
        val plan = banded(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierAreaBasis.TREATED_AREA, 200.0).plan
        assertEquals(3.0, plan.treatedAreaHectares!!, tolerance)
        assertEquals(600.0, plan.totalCarrierLitres, tolerance)
        assertEquals(1.0, plan.concentrationFactor, tolerance)
    }

    @Test
    fun `manual total derives treated-hectare sprayer rate`() {
        val carrier = banded(SprayCarrierBasis.MANUAL_TOTAL_VOLUME, SprayCarrierAreaBasis.TREATED_AREA, manualTotal = 600.0).plan.carrier
        assertEquals(200.0, carrier.litresPerHectare!!, tolerance)
        assertEquals(600.0, carrier.totalLitres, tolerance)
    }

    @Test
    fun `explicit whole-block basis uses gross hectares`() {
        val plan = banded(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierAreaBasis.WHOLE_BLOCK_AREA, 200.0).plan
        assertEquals(1_800.0, plan.totalCarrierLitres, tolerance)
    }

    @Test
    fun `product rate bases remain independent`() {
        val products = listOf(
            SprayProductLineInput("treated", "Treated", "L", SprayProductRateBasis.TREATED_AREA, 2.0),
            SprayProductLineInput("gross", "Gross", "L", SprayProductRateBasis.WHOLE_BLOCK_AREA, 2.0),
            SprayProductLineInput("water", "Water", "mL", SprayProductRateBasis.PER_100_LITRES, 100.0),
        )
        val lines = banded(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierAreaBasis.TREATED_AREA, 200.0, products = products).plan.productLines
        assertEquals(6.0, lines[0].totalQuantity!!, tolerance)
        assertEquals(18.0, lines[1].totalQuantity!!, tolerance)
        assertEquals(600.0, lines[2].totalQuantity!!, tolerance)
    }

    @Test
    fun `Undervine and Midrow do not require canopy`() {
        SprayGroundTarget.entries.forEach { target ->
            val flow = banded(SprayCarrierBasis.LITRES_PER_HECTARE, SprayCarrierAreaBasis.TREATED_AREA, 200.0, groundTarget = target)
            assertNull(flow.blocker(SprayGuidedStep.CARRIER))
        }
    }
}
