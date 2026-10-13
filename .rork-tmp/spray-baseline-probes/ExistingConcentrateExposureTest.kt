package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCanopySelection
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayHeadTarget
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayVolumeChoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Baseline-only characterization: a pass establishes exposure, not safety acceptance. */
class ExistingConcentrateExposureTest {
    @Test
    fun customFoliarRateExposesConcentratedPersistablePlanWithoutLabelAuthority() {
        val inputs = SprayGuidedInputs(
            operationType = SprayOperationType.FOLIAR_SPRAY,
            blocks = listOf(SprayBlockInput(blockId = "synthetic-block", grossAreaHectares = 10.0,
                mappedRowLengthMetres = 31_250.0, rowSpacingMetres = 3.2)),
            targets = setOf(SprayTarget.POWDERY_MILDEW),
            sprayHeadTarget = SprayHeadTarget.FULL_CANOPY,
            isGrowthStageAssigned = true,
            isEquipmentSelected = true,
            isEquipmentConfirmed = true,
            isCanopyConfirmed = true,
            tankCapacityLitres = 2_000.0,
            canopy = SprayCanopySelection(type = SprayCalculator.CanopyType.VSP,
                size = SprayCalculator.CanopySize.MEDIUM, density = SprayCalculator.CanopyDensity.LOW,
                isSizeAndDensityConfirmed = true),
            sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
            customSprayerRate = 300.0,
            customSprayerBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
            carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
            products = listOf(SprayProductLineInput(productId = "synthetic-dilute", name = "Synthetic dilute product",
                unit = "L", basis = SprayProductRateBasis.PER_100_LITRES, rate = 0.5)),
        )
        val flow = SprayGuidedFlow(inputs)
        assertTrue("The original guided decisions all complete without concentrate authority", flow.isComplete)
        val plan = flow.persistablePlan
        assertNotNull("Original flow exposes a plan suitable for persistence", plan)
        assertEquals(3_000.0, plan!!.carrier.totalLitres, 0.000001)
        assertTrue("Custom output below the canopy reference creates CF > 1", plan.concentrationFactor > 1.0)
        assertNotNull("Original flow projects a persistence snapshot", flow.snapshot)
        assertEquals(plan.concentrationFactor, flow.snapshot!!.concentrationFactor!!, 0.000001)
    }
}
