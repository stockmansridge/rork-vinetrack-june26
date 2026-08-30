package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalGrapevineCrop
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.viticultural
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The vineyard-only partition rule.
 *
 * The Chemical Store must contain the grapevine label and nothing else. That
 * depends entirely on one predicate answering "is this crop grapevines?", and
 * the predicate must give the SAME answer as the server, which is what decides
 * which directions land in `grapevine_uses`.
 *
 * The rule that matters most is the negative one. `"GRAPEFRUIT"` contains
 * `"grape"`, so a substring test classifies a citrus as a grapevine and offers
 * its rate as a vineyard default — a wrong dose wearing a plausible name, which
 * is far worse than a visible gap.
 */
class ChemicalGrapevineCropTest {

    @Test
    fun `grapefruit is never a grapevine`() {
        listOf(
            "GRAPEFRUIT",
            "Grapefruit",
            "Grapefruit trees",
            "Citrus (grapefruit)",
            "grapefruit, oranges and lemons",
        ).forEach { crop ->
            assertFalse("$crop must not be grapevine", ChemicalGrapevineCrop.matches(crop))
        }
    }

    @Test
    fun `genuine grapevine wordings are recognised`() {
        listOf(
            "Grapes",
            "GRAPES",
            "Grapevine",
            "Grapevines",
            "Vines",
            "Vineyard",
            "Wine grapes",
            "Table grapes",
            "Dried grapes",
            "Grape vines",
            "Winegrapes",
            "Grapes (wine)",
        ).forEach { crop ->
            assertTrue("$crop must be grapevine", ChemicalGrapevineCrop.matches(crop))
        }
    }

    @Test
    fun `other crops are not grapevines`() {
        listOf(
            "Apples",
            "Pome fruit",
            "Citrus",
            "Almonds",
            "Peaches",
            "Stone fruit",
            "Bananas",
            "",
            "   ",
        ).forEach { crop ->
            assertFalse("$crop must not be grapevine", ChemicalGrapevineCrop.matches(crop))
        }
    }

    /**
     * A bare "wine" or "dried" must not pass on its own — only the adjacent pair
     * with "grape"/"grapes" does.
     */
    @Test
    fun `phrase halves do not match alone`() {
        assertFalse(ChemicalGrapevineCrop.matches("Wine"))
        assertFalse(ChemicalGrapevineCrop.matches("Dried fruit"))
        assertFalse(ChemicalGrapevineCrop.matches("Table olives"))
    }

    /**
     * The registered-use partition is what the whole vineyard-only workflow
     * rests on, so it is asserted through the real model, not just the helper.
     */
    @Test
    fun `a grapefruit direction never enters the grapevine partition`() {
        val grapefruit = ChemicalRegisteredUse(
            crop = "Grapefruit",
            targetRaw = "Scale",
            rates = listOf(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    value = 2.0,
                    unit = "L",
                    rateId = "rate_v1_citrus",
                ),
            ),
        )
        val grapevine = ChemicalRegisteredUse(
            crop = "Grapevines",
            targetRaw = "Powdery mildew",
            rates = listOf(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    value = 1.0,
                    unit = "L",
                    rateId = "rate_v1_vine",
                ),
            ),
        )
        assertFalse(grapefruit.isViticultural)
        assertTrue(grapevine.isViticultural)

        val partition = listOf(grapefruit, grapevine).viticultural()
        assertEquals(1, partition.size)
        assertEquals("Grapevines", partition.first().crop)
    }

    /**
     * A citrus rate must never be offered as a vineyard default, which is the
     * operational consequence of the rule above.
     */
    @Test
    fun `a citrus rate is never a vineyard default option`() {
        val grapefruit = ChemicalRegisteredUse(
            crop = "Grapefruit",
            targetRaw = "Scale",
            rates = listOf(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    value = 99.0,
                    unit = "L",
                    rateId = "rate_v1_citrus",
                ),
            ),
        )
        val grapevineOnly = listOf(grapefruit).viticultural()
        assertTrue(ChemicalDefaultRate.options(ChemicalDefaultRateBasis.PER_HECTARE, grapevineOnly).isEmpty())
    }
}
