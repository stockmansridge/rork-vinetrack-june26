package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayCanopyReferenceImages
import com.rork.vinetrack.data.spray.SprayCanopyRequirement
import com.rork.vinetrack.data.spray.SprayCanopySelection
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGuidedBlocker
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayOperationType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SprayCanopyParityTest {
    private val rates = CanopyWaterRates.defaults
    private val blocks = listOf("block-a")

    @Test
    fun `rule 1 fresh canopy shows Medium Low and remains unconfirmed`() {
        val initial = SprayCanopySelection.unconfirmed
        assertNull(initial.type)
        assertEquals(SprayCalculator.CanopySize.MEDIUM, initial.size)
        assertEquals(SprayCalculator.CanopyDensity.LOW, initial.density)
        assertFalse(initial.isConfirmed)
    }

    @Test
    fun `rule 2 choosing VSP or Sprawl alone does not confirm displayed pair`() {
        assertFalse(SprayCanopySelection.unconfirmed.chooseType(SprayCalculator.CanopyType.VSP).isConfirmed)
        assertFalse(SprayCanopySelection.unconfirmed.chooseType(SprayCalculator.CanopyType.SPRAWL).isConfirmed)
    }

    @Test
    fun `rule 3 touching either size or density confirms the displayed pair`() {
        val typed = SprayCanopySelection.unconfirmed.chooseType(SprayCalculator.CanopyType.VSP)
        assertTrue(typed.chooseSize(SprayCalculator.CanopySize.MEDIUM).isConfirmed)
        assertTrue(typed.chooseDensity(SprayCalculator.CanopyDensity.LOW).isConfirmed)
        assertTrue(typed.confirm().isConfirmed)
    }

    @Test
    fun `all VSP bands match iOS`() {
        assertBand(SprayCalculator.CanopyType.VSP, SprayCalculator.CanopySize.SMALL, 10.0, 20.0)
        assertBand(SprayCalculator.CanopyType.VSP, SprayCalculator.CanopySize.MEDIUM, 20.0, 40.0)
        assertBand(SprayCalculator.CanopyType.VSP, SprayCalculator.CanopySize.LARGE, 30.0, 45.0)
        assertBand(SprayCalculator.CanopyType.VSP, SprayCalculator.CanopySize.FULL, 45.0, 75.0)
    }

    @Test
    fun `all Sprawl bands match iOS`() {
        assertBand(SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.SMALL, 10.0, 20.0)
        assertBand(SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.MEDIUM, 20.0, 40.0)
        assertBand(SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.LARGE, 45.0, 60.0)
        assertBand(SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.FULL, 60.0, 90.0)
    }

    @Test
    fun `density selects the same low and high endpoints as iOS`() {
        assertEquals(45.0, SprayCalculator.litresPer100m(rates, SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.LARGE, SprayCalculator.CanopyDensity.LOW), 0.0)
        assertEquals(60.0, SprayCalculator.litresPer100m(rates, SprayCalculator.CanopyType.SPRAWL, SprayCalculator.CanopySize.LARGE, SprayCalculator.CanopyDensity.HIGH), 0.0)
    }

    @Test
    fun `legacy VSP preferences survive while missing Sprawl receives defaults`() {
        val stored = mapOf(
            CanopyWaterRatePreferences.KEY_SMALL_LOW to 11f,
            CanopyWaterRatePreferences.KEY_SMALL_HIGH to 22f,
            CanopyWaterRatePreferences.KEY_MEDIUM_LOW to 33f,
            CanopyWaterRatePreferences.KEY_MEDIUM_HIGH to 44f,
            CanopyWaterRatePreferences.KEY_LARGE_LOW to 55f,
            CanopyWaterRatePreferences.KEY_LARGE_HIGH to 66f,
            CanopyWaterRatePreferences.KEY_FULL_LOW to 77f,
            CanopyWaterRatePreferences.KEY_FULL_HIGH to 88f,
        )
        val decoded = CanopyWaterRatePreferences.decode { key, fallback -> stored[key] ?: fallback }
        assertEquals(listOf(11.0, 22.0, 33.0, 44.0, 55.0, 66.0, 77.0, 88.0), listOf(decoded.smallLow, decoded.smallHigh, decoded.mediumLow, decoded.mediumHigh, decoded.largeLow, decoded.largeHigh, decoded.fullLow, decoded.fullHigh))
        assertEquals(10.0, decoded.sprawlSmallLow, 0.0)
        assertEquals(40.0, decoded.sprawlMediumHigh, 0.0)
        assertEquals(45.0, decoded.sprawlLargeLow, 0.0)
        assertEquals(90.0, decoded.sprawlFullHigh, 0.0)
    }

    @Test
    fun `every canopy type and size has the correct local image mapping`() {
        SprayCalculator.CanopyType.entries.forEach { type ->
            SprayCalculator.CanopySize.entries.forEach { size ->
                assertEquals(
                    "canopy_${type.name.lowercase()}_${size.name.lowercase()}",
                    SprayCanopyReferenceImages.drawableName(type, size),
                )
                assertTrue(SprayCanopyReferenceImages.accessibilityDescription(type, size).contains(type.label))
                assertTrue(SprayCanopyReferenceImages.accessibilityDescription(type, size).contains(size.label.lowercase()))
            }
        }
    }

    @Test
    fun `both foliar carrier bases use one shared canopy model`() {
        assertTrue(SprayCanopyRequirement.usesSharedModel(SprayCarrierBasis.LITRES_PER_100_METRES))
        assertTrue(SprayCanopyRequirement.usesSharedModel(SprayCarrierBasis.LITRES_PER_HECTARE))
    }

    @Test
    fun `calculator renders one shared selector before the carrier basis branches`() {
        val candidates = listOf(
            File("src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt"),
            File("app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt"),
            File("android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt"),
        )
        val source = candidates.firstOrNull(File::exists)?.readText()
            ?: error("SprayCalculatorScreen source not found")
        val invocation = "SprayCanopySelector("
        assertEquals(1, Regex(Regex.escape(invocation)).findAll(source).count())
        assertTrue(source.indexOf(invocation) < source.indexOf("if (guidedFlow.effectiveCarrierBasis =="))
    }

    @Test
    fun `rule 4 Program Step and repeated job prefills arrive confirmed`() {
        val program = SprayCanopySelection.prefilled(
            type = SprayCalculator.CanopyType.SPRAWL,
            size = SprayCalculator.CanopySize.LARGE,
            density = SprayCalculator.CanopyDensity.HIGH,
        )
        val repeated = program.copy()
        assertTrue(program.isConfirmed)
        assertTrue(repeated.isConfirmed)
    }

    @Test
    fun `rule 5 historical pair without a stored type resolves to confirmed VSP`() {
        val historical = SprayCanopySelection.prefilledVsp(
            SprayCalculator.CanopySize.LARGE,
            SprayCalculator.CanopyDensity.HIGH,
        )
        assertEquals(SprayCalculator.CanopyType.VSP, historical.type)
        assertTrue(historical.isConfirmed)
    }

    @Test
    fun `rule 6 changing carrier basis does not invalidate canopy`() {
        val confirmed = SprayCanopySelection.prefilled(
            SprayCalculator.CanopySize.MEDIUM,
            SprayCalculator.CanopyDensity.LOW,
        )
        val perHectare = SprayGuidedFlow(confirmedFoliarInputs(confirmed, 2.8).copy(carrierBasis = SprayCarrierBasis.LITRES_PER_HECTARE))
        val perRow = SprayGuidedFlow(confirmedFoliarInputs(confirmed, 2.8).copy(carrierBasis = SprayCarrierBasis.LITRES_PER_100_METRES))
        assertTrue(confirmed.isConfirmed)
        assertEquals(20.0, perHectare.volumeDecision?.recommendedLitresPer100Metres ?: -1.0, 0.0)
        assertEquals(20.0, perRow.volumeDecision?.recommendedLitresPer100Metres ?: -1.0, 0.0)
    }

    @Test
    fun `rule 7 block spacing recalculates equivalent without erasing confirmation`() {
        val confirmed = SprayCanopySelection.prefilled(
            SprayCalculator.CanopySize.SMALL,
            SprayCalculator.CanopyDensity.LOW,
        )
        val at28 = SprayGuidedFlow(confirmedFoliarInputs(confirmed, 2.8)).volumeDecision
        val at30 = SprayGuidedFlow(confirmedFoliarInputs(confirmed, 3.0)).volumeDecision
        assertTrue(confirmed.isConfirmed)
        assertEquals(357.14285714285717, at28?.recommendedLitresPerHectare ?: -1.0, 0.000001)
        assertEquals(333.3333333333333, at30?.recommendedLitresPerHectare ?: -1.0, 0.000001)
    }

    @Test
    fun `rule 8 changing confirmed canopy type preserves confirmed pair`() {
        val confirmedVsp = SprayCanopySelection.prefilled(
            SprayCalculator.CanopySize.LARGE,
            SprayCalculator.CanopyDensity.HIGH,
        )
        val sprawl = confirmedVsp.chooseType(SprayCalculator.CanopyType.SPRAWL)
        assertEquals(confirmedVsp.size, sprawl.size)
        assertEquals(confirmedVsp.density, sprawl.density)
        assertTrue(sprawl.isConfirmed)
    }

    @Test
    fun `rule 9 confirmed prefill leaves volume undecided and Carrier incomplete`() {
        val confirmed = SprayCanopySelection.prefilled(
            SprayCalculator.CanopySize.SMALL,
            SprayCalculator.CanopyDensity.LOW,
        )
        val inputs = confirmedFoliarInputs(confirmed, 2.8)
        assertSame(SprayGuidedBlocker.SprayVolumeChoiceRequired, SprayGuidedFlow(inputs).blocker(SprayGuidedStep.CARRIER))
        assertEquals(com.rork.vinetrack.data.spray.SprayVolumeChoice.UNDECIDED, inputs.sprayVolumeChoice)
    }

    @Test
    fun `foliar is gated but banded and spreader remain unchanged`() {
        val foliar = SprayGuidedFlow(SprayGuidedInputs(operationType = SprayOperationType.FOLIAR_SPRAY))
        assertTrue(foliar.requiresCanopyConfirmation)
        assertEquals(SprayGuidedBlocker.CanopyConfirmationRequired, foliar.blocker(SprayGuidedStep.CARRIER))

        val banded = SprayGuidedFlow(SprayGuidedInputs(operationType = SprayOperationType.BANDED_SPRAY))
        val spreader = SprayGuidedFlow(SprayGuidedInputs(operationType = SprayOperationType.SPREADER))
        assertFalse(banded.requiresCanopyConfirmation)
        assertFalse(spreader.requiresCanopyConfirmation)
        assertEquals(SprayGuidedBlocker.CarrierRateRequired, banded.blocker(SprayGuidedStep.CARRIER))
        assertEquals(SprayGuidedBlocker.CarrierRateRequired, spreader.blocker(SprayGuidedStep.CARRIER))
    }

    @Test
    fun `existing VSP lookup and carrier result stay numerically unchanged`() {
        val legacy = SprayCalculator.litresPer100m(rates, SprayCalculator.CanopySize.FULL, SprayCalculator.CanopyDensity.HIGH)
        val explicit = SprayCalculator.litresPer100m(rates, SprayCalculator.CanopyType.VSP, SprayCalculator.CanopySize.FULL, SprayCalculator.CanopyDensity.HIGH)
        assertEquals(75.0, legacy, 0.0)
        assertEquals(legacy, explicit, 0.0)
        assertEquals(2_500.0, CanopyWaterRates.litresPerHa(legacy, 3.0), 0.0)
    }

    private fun confirmedFoliarInputs(
        canopy: SprayCanopySelection,
        rowSpacing: Double,
    ): SprayGuidedInputs = SprayGuidedInputs(
        operationType = SprayOperationType.FOLIAR_SPRAY,
        blocks = listOf(
            com.rork.vinetrack.data.spray.SprayBlockInput(
                blockId = "block-a",
                grossAreaHectares = 10.0,
                mappedRowLengthMetres = 35_714.2857142857,
                rowSpacingMetres = rowSpacing,
            ),
        ),
        canopy = canopy,
        isCanopyConfirmed = canopy.isConfirmed,
    )

    private fun assertBand(
        type: SprayCalculator.CanopyType,
        size: SprayCalculator.CanopySize,
        low: Double,
        high: Double,
    ) {
        val selection = SprayCanopySelection(type = type, size = size)
        val band = selection.referenceBand(rates)
        assertEquals(low, band?.low ?: -1.0, 0.0)
        assertEquals(high, band?.high ?: -1.0, 0.0)
    }
}
