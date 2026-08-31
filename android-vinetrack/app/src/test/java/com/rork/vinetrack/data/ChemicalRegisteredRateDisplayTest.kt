package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRateDisplay
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUseCompactDisplay
import com.rork.vinetrack.data.model.SavedChemical
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Chemical Store's registered-rate DISPLAY projection, and the compact
 * registered-use review selection.
 *
 * The customer outcome pinned here: CHATEAU registers `560–700 g/ha` on
 * grapevines. That band is a complete, saveable record of the registration, so
 * the store card states it — clearly named as the LABEL's figure — instead of
 * demanding "Rate confirmation required" for a record with nothing wrong with
 * it. Everything asserted is display-only: nothing writes `default_rates`, and
 * `registered_uses` is never altered.
 */
class ChemicalRegisteredRateDisplayTest {

    private fun chateauRange() = ChemicalLabelRate(
        label = "Broadleaf weeds",
        basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
        minValue = 560.0,
        maxValue = 700.0,
        unit = "g",
    )

    private fun exactRate() = ChemicalLabelRate(
        label = "Powdery mildew",
        basis = ChemicalLabelRateBasis.PER_HECTARE,
        value = 2.0,
        unit = "L",
    )

    private fun verbatimOnly() = ChemicalLabelRate(
        label = "Directed",
        basis = ChemicalLabelRateBasis.OTHER,
        rawText = "Apply as directed by an agronomist",
        unit = "",
    )

    private fun grapeUse(
        target: String,
        rates: List<ChemicalLabelRate>,
    ) = ChemicalRegisteredUse(crop = "Grapes", targetRaw = target, rates = rates)

    // ---- Registered rate summary ----

    @Test
    fun `a registered band is summarised as a label range, byte for byte`() {
        val summaries = ChemicalDefaultRateDisplay.registeredRateSummaries(
            listOf(grapeUse("Broadleaf weeds", listOf(chateauRange()))),
        )
        assertEquals(listOf("Registered label range: 560–700 g/ha"), summaries)
    }

    @Test
    fun `an exact registered rate is summarised as a label rate`() {
        val summaries = ChemicalDefaultRateDisplay.registeredRateSummaries(
            listOf(grapeUse("Powdery mildew", listOf(exactRate()))),
        )
        assertEquals(listOf("Registered label rate: 2 L/ha"), summaries)
    }

    @Test
    fun `a usable registered range suppresses the confirmation warning`() {
        val chemical = SavedChemical(
            id = "c1",
            vineyardId = "v1",
            name = "CHATEAU",
            registeredUses = listOf(grapeUse("Broadleaf weeds", listOf(chateauRange()))),
        )
        // The card line is the registration's own figure, never the prompt.
        assertEquals(
            "Registered label range: 560–700 g/ha",
            ChemicalDefaultRateDisplay.line(chemical),
        )
        // And it is not an attention state: nothing about this record is wrong.
        assertFalse(ChemicalDefaultRateDisplay.needsConfirmation(chemical))
    }

    @Test
    fun `a structured record with no usable rate retains the attention state`() {
        val chemical = SavedChemical(
            id = "c2",
            vineyardId = "v1",
            name = "Mystery Mix",
            registeredUses = listOf(grapeUse("Weeds", listOf(verbatimOnly()))),
        )
        assertEquals(
            ChemicalDefaultRateDisplay.CONFIRMATION_REQUIRED,
            ChemicalDefaultRateDisplay.line(chemical),
        )
        assertTrue(ChemicalDefaultRateDisplay.needsConfirmation(chemical))
    }

    // ---- Compact registered-use selection ----

    @Test
    fun `target names deduplicate case-insensitively preserving label order`() {
        val uses = listOf(
            grapeUse("Powdery mildew", listOf(chateauRange())),
            grapeUse("POWDERY MILDEW", listOf(chateauRange())),
            grapeUse("Downy mildew", listOf(chateauRange())),
            grapeUse("downy Mildew", listOf(chateauRange())),
            grapeUse("Botrytis", listOf(chateauRange())),
        )
        // The FIRST spelling wins, so the list reads as the label printed it.
        assertEquals(
            listOf("Powdery mildew", "Downy mildew", "Botrytis"),
            ChemicalRegisteredUseCompactDisplay.dedupedTargets(uses),
        )
    }

    @Test
    fun `the collapsed review shows exactly the first five targets`() {
        val targets = listOf(
            "Amaranthus", "Barnyard grass", "Capeweed", "Deadnettle",
            "Fat hen", "Marshmallow", "Wireweed",
        )
        assertEquals(
            listOf("Amaranthus", "Barnyard grass", "Capeweed", "Deadnettle", "Fat hen"),
            ChemicalRegisteredUseCompactDisplay.collapsedTargets(targets),
        )
        // The controls name the full count, so "Show all 25 uses" is literal.
        assertEquals(
            "Registered grapevine uses (25)",
            ChemicalRegisteredUseCompactDisplay.heading(25),
        )
        assertEquals("Show all 25 uses", ChemicalRegisteredUseCompactDisplay.showAllLabel(25))
        assertEquals("Show fewer", ChemicalRegisteredUseCompactDisplay.SHOW_FEWER_LABEL)
    }
}
