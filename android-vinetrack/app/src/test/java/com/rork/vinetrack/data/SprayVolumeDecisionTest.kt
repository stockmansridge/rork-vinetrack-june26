package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCanopySelection
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayVolumeChoice
import com.rork.vinetrack.data.spray.SprayVolumeDecisionResolver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SprayVolumeDecisionTest {
    private val tolerance = 0.000001
    private val canopy = SprayCanopySelection(
        type = SprayCalculator.CanopyType.VSP,
        size = SprayCalculator.CanopySize.SMALL,
        density = SprayCalculator.CanopyDensity.LOW,
    )

    private fun decision(
        rates: CanopyWaterRates = CanopyWaterRates.defaults,
        spacing: Double? = 2.8,
        choice: SprayVolumeChoice = SprayVolumeChoice.UNDECIDED,
        custom: Double? = null,
        customBasis: SprayCarrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
    ) = SprayVolumeDecisionResolver.decide(
        canopy = canopy,
        isCanopyConfirmed = true,
        rates = rates,
        rowSpacingMetres = spacing,
        choice = choice,
        customRate = custom,
        customBasis = customBasis,
    )

    @Test
    fun `exact 2 point 8 metre custom fixture uses actual water not dilute equivalent`() {
        val flow = SprayGuidedFlow(
            SprayGuidedInputs(
                operationType = SprayOperationType.FOLIAR_SPRAY,
                blocks = listOf(SprayBlockInput(blockId = "a", grossAreaHectares = 10.0, mappedRowLengthMetres = 35_714.2857142857, rowSpacingMetres = 2.8)),
                isCanopyConfirmed = true,
                canopy = canopy,
                sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
                customSprayerRate = 300.0,
                customSprayerBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
                carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
            ),
        )
        val d = flow.volumeDecision!!
        assertEquals(10.0, d.recommendedLitresPer100Metres!!, tolerance)
        assertEquals(357.14285714285717, d.recommendedLitresPerHectare!!, tolerance)
        assertEquals(300.0, d.actualLitresPerHectare!!, tolerance)
        assertEquals(8.4, d.actualLitresPer100Metres!!, tolerance)
        assertEquals(1.1904761904761905, d.concentrationFactor, tolerance)
        assertEquals(3_000.0, flow.plan.totalCarrierLitres, tolerance)
        assertTrue(flow.plan.totalCarrierLitres != 10_714.3)
    }

    @Test
    fun `600 litres per hectare equals 16 point 8 litres per 100m`() {
        val d = decision(choice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, custom = 600.0)
        assertEquals(16.8, d.actualLitresPer100Metres!!, tolerance)
    }

    @Test
    fun `recommended choice tracks canopy and is always CF one`() {
        val first = decision(choice = SprayVolumeChoice.USE_RECOMMENDED)
        val changed = SprayVolumeDecisionResolver.decide(
            canopy = canopy.copy(size = SprayCalculator.CanopySize.MEDIUM),
            isCanopyConfirmed = true,
            rates = CanopyWaterRates.defaults,
            rowSpacingMetres = 2.8,
            choice = SprayVolumeChoice.USE_RECOMMENDED,
            customRate = null,
            customBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
        )
        assertEquals(10.0, first.actualLitresPer100Metres!!, tolerance)
        assertEquals(20.0, changed.actualLitresPer100Metres!!, tolerance)
        assertEquals(1.0, first.concentrationFactor, tolerance)
        assertEquals(1.0, changed.concentrationFactor, tolerance)
    }

    @Test
    fun `custom above recommendation clamps CF to one`() {
        assertEquals(1.0, decision(choice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, custom = 600.0).concentrationFactor, tolerance)
    }

    @Test
    fun `L per 100m recommendation remains available without row spacing`() {
        val d = decision(spacing = null, choice = SprayVolumeChoice.USE_RECOMMENDED)
        assertEquals(10.0, d.recommendedLitresPer100Metres!!, tolerance)
        assertNull(d.recommendedLitresPerHectare)
        assertEquals(10.0, d.actualLitresPer100Metres!!, tolerance)
    }

    @Test
    fun `switching display basis does not create a second custom rate`() {
        val inputs = SprayGuidedInputs(
            operationType = SprayOperationType.FOLIAR_SPRAY,
            blocks = listOf(SprayBlockInput(blockId = "a", grossAreaHectares = 10.0, mappedRowLengthMetres = 35_714.2857142857, rowSpacingMetres = 2.8)),
            isCanopyConfirmed = true,
            canopy = canopy,
            sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
            customSprayerRate = 300.0,
            customSprayerBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
        )
        val hectare = SprayGuidedFlow(inputs.copy(carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE))
        val row = SprayGuidedFlow(inputs.copy(carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES))
        assertEquals(300.0, hectare.volumeDecision!!.customRate!!, tolerance)
        assertEquals(300.0, row.volumeDecision!!.customRate!!, tolerance)
        assertEquals(8.4, row.volumeDecision!!.actualLitresPer100Metres!!, tolerance)
    }

    @Test
    fun `custom survives canopy change and recalculates CF`() {
        val first = decision(choice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE, custom = 300.0)
        val changed = SprayVolumeDecisionResolver.decide(
            canopy = canopy.copy(size = SprayCalculator.CanopySize.MEDIUM),
            isCanopyConfirmed = true,
            rates = CanopyWaterRates.defaults,
            rowSpacingMetres = 2.8,
            choice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
            customRate = first.customRate,
            customBasis = first.customBasis,
        )
        assertEquals(300.0, changed.actualLitresPerHectare!!, tolerance)
        assertEquals(2.380952380952381, changed.concentrationFactor, tolerance)
    }

    @Test
    fun `choice and custom blockers are explicit`() {
        val base = SprayGuidedInputs(
            operationType = SprayOperationType.FOLIAR_SPRAY,
            blocks = listOf(SprayBlockInput(blockId = "a", grossAreaHectares = 10.0, mappedRowLengthMetres = 35_714.2857142857, rowSpacingMetres = 2.8)),
            isCanopyConfirmed = true,
            canopy = canopy,
        )
        assertSame(SprayGuidedBlocker.SprayVolumeChoiceRequired, SprayGuidedFlow(base).blocker(SprayGuidedStep.CARRIER))
        listOf(null, 0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY).forEach { invalid ->
            assertSame(
                SprayGuidedBlocker.CustomSprayerRateRequired,
                SprayGuidedFlow(
                    base.copy(
                        sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
                        customSprayerRate = invalid,
                    ),
                ).blocker(SprayGuidedStep.CARRIER),
            )
        }
    }

    @Test
    fun `conversion blocker requires canonical spacing`() {
        val flow = SprayGuidedFlow(
            SprayGuidedInputs(
                operationType = SprayOperationType.FOLIAR_SPRAY,
                blocks = listOf(SprayBlockInput(blockId = "a", grossAreaHectares = 10.0, mappedRowLengthMetres = 35_714.2857142857, rowSpacingMetres = null)),
                isCanopyConfirmed = true,
                canopy = canopy,
                sprayVolumeChoice = SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE,
                customSprayerRate = 300.0,
                customSprayerBasis = SprayCarrierBasis.LITRES_PER_HECTARE,
                carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES,
            ),
        )
        assertSame(SprayGuidedBlocker.CarrierConversionRequired, flow.blocker(SprayGuidedStep.CARRIER))
    }
}
