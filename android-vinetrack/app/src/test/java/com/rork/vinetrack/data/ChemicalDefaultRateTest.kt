package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateRecommendation
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRateJurisdiction
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The vineyard default-rate decision (A7) — the Android mirror of the iOS
 * `ChemicalDefaultRateTests`.
 *
 * The registered label rates are the authority: a default only records which
 * registered option this vineyard doses by (plus an exact authorised figure
 * inside a label band). Nothing here may narrow a range, merge two different
 * numbers, convert between bases, or recommend another state's rate.
 */
class ChemicalDefaultRateTest {

    private fun use(
        target: String = "Powdery mildew",
        vararg rates: ChemicalLabelRate,
    ) = ChemicalRegisteredUse(
        crop = "Grapes (winegrapes)",
        targetRaw = target,
        rates = rates.toList(),
    )

    private fun single(
        value: Double,
        unit: String = "L",
        label: String = "",
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.PER_100_LITRES,
    ) = ChemicalLabelRate(label = label, basis = basis, value = value, unit = unit)

    private fun range(
        min: Double,
        max: Double,
        unit: String = "g",
        label: String = "",
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
    ) = ChemicalLabelRate(label = label, basis = basis, minValue = min, maxValue = max, unit = unit)

    // ---- Options: what merges, what never does ----

    @Test
    fun `identical numbers across different conditions are one option with both conditions`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(
                use("European red mite", single(3.0, label = "NSW, Vic, SA")),
                use("Grapevine scale", single(3.0, label = "NSW, Vic, Qld, SA, WA")),
            ),
        )
        val group = plan.per100Litres
        assertEquals(1, group.options.size)
        assertEquals(2, group.options.first().conditions.size)
        // One distinct rate on the basis -> recommended even without a state.
        assertEquals(ChemicalDefaultRateRecommendation.OnlyRegisteredRate, group.recommendation)
        assertEquals("Recommended", group.recommendation.badge)
    }

    @Test
    fun `two different numbers never become a synthetic range`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(use("Powdery mildew", single(2.0), single(3.0))),
        )
        val group = plan.per100Litres
        assertEquals(2, group.options.size)
        // Neither option gained bounds it never had.
        assertTrue(group.options.all { !it.isLabelRange })
        // Several distinct rates -> the operator decides; nothing is recommended.
        assertEquals(ChemicalDefaultRateRecommendation.OperatorMustChoose, group.recommendation)
        assertNull(group.recommendedOptionId)
        assertNull(group.recommendation.badge)
    }

    @Test
    fun `a true label range stays one selectable rate with both bounds`() {
        val plan = ChemicalDefaultRate.plan(listOf(use(rates = arrayOf(range(100.0, 200.0)))))
        val option = plan.per100Litres.options.single()
        assertTrue(option.isLabelRange)
        assertEquals(100.0 to 200.0, option.authorisedBounds)
        // Inclusive of both printed ends, and everything between.
        assertTrue(option.authorises(100.0))
        assertTrue(option.authorises(150.0))
        assertTrue(option.authorises(200.0))
        assertFalse(option.authorises(99.9))
        assertFalse(option.authorises(200.1))
        // A range starts at its LOWER bound, never the top.
        assertEquals(100.0, option.startingValue)
    }

    // ---- Recommendation steps ----

    @Test
    fun `step 1 - the vineyard state resolves a state-conditioned label`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(
                use("Powdery mildew", single(2.0, label = "NSW only")),
                use("Powdery mildew", single(3.0, label = "Tas only")),
            ),
            jurisdiction = ChemicalRateJurisdiction.NSW,
        )
        val group = plan.per100Litres
        assertEquals(
            ChemicalDefaultRateRecommendation.Jurisdiction(ChemicalRateJurisdiction.NSW),
            group.recommendation,
        )
        assertEquals("Recommended for NSW", group.recommendation.badge)
        assertEquals(2.0, group.recommendedOption?.rate?.value)
        // The other state's rate is retained for inspection, never hidden.
        assertEquals(2, group.options.size)
    }

    @Test
    fun `a jurisdiction no rate covers does not fall back to another state's rate`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(
                use("Powdery mildew", single(2.0, label = "Tas only")),
            ),
            jurisdiction = ChemicalRateJurisdiction.NSW,
        )
        val group = plan.per100Litres
        // One rate exists but it is registered for somewhere else: step 2 must
        // NOT resurrect it. The refusal is the answer.
        assertEquals(ChemicalDefaultRateRecommendation.OperatorMustChoose, group.recommendation)
        assertNull(group.recommendedOptionId)
    }

    @Test
    fun `step 2 - one distinct rate is recommended when the state is unknown`() {
        val plan = ChemicalDefaultRate.plan(listOf(use(rates = arrayOf(single(2.0)))))
        assertEquals(
            ChemicalDefaultRateRecommendation.OnlyRegisteredRate,
            plan.per100Litres.recommendation,
        )
    }

    @Test
    fun `an unconditioned rate applies in every jurisdiction`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(use(rates = arrayOf(single(2.0)))),
            jurisdiction = ChemicalRateJurisdiction.WA,
        )
        // No condition names a state -> unrestricted -> applies in WA.
        assertEquals(
            ChemicalDefaultRateRecommendation.Jurisdiction(ChemicalRateJurisdiction.WA),
            plan.per100Litres.recommendation,
        )
    }

    // ---- Never invented, never converted ----

    @Test
    fun `no per-hectare rate is invented from a per-100L label`() {
        val plan = ChemicalDefaultRate.plan(listOf(use(rates = arrayOf(single(2.0)))))
        assertTrue(plan.perHectare.isEmpty)
        assertEquals(
            "No registered per-hectare rate on this label",
            plan.perHectare.emptyStatement,
        )
        assertEquals(
            ChemicalDefaultRateRecommendation.NoRegisteredRate,
            plan.perHectare.recommendation,
        )
    }

    @Test
    fun `the two bases are decided independently`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(
                use(
                    rates = arrayOf(
                        single(2.0),
                        single(1.5, unit = "L", basis = ChemicalLabelRateBasis.PER_HECTARE),
                        single(2.5, unit = "L", basis = ChemicalLabelRateBasis.PER_HECTARE),
                    ),
                ),
            ),
        )
        assertEquals(
            ChemicalDefaultRateRecommendation.OnlyRegisteredRate,
            plan.per100Litres.recommendation,
        )
        assertEquals(
            ChemicalDefaultRateRecommendation.OperatorMustChoose,
            plan.perHectare.recommendation,
        )
    }

    @Test
    fun `a verbatim other rate can never become a default`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(
                use(
                    rates = arrayOf(
                        ChemicalLabelRate(
                            basis = ChemicalLabelRateBasis.OTHER,
                            rawText = "Apply as directed by an agronomist",
                        ),
                    ),
                ),
            ),
        )
        assertTrue(plan.per100Litres.isEmpty)
        assertTrue(plan.perHectare.isEmpty)
    }

    @Test
    fun `the distinctness key excludes the condition and the use`() {
        val a = single(3.0, label = "NSW, Vic")
        val b = single(3.0, label = "Qld, WA")
        val c = single(2.0, label = "NSW, Vic")
        assertEquals(ChemicalDefaultRate.distinctnessKey(a), ChemicalDefaultRate.distinctnessKey(b))
        assertTrue(ChemicalDefaultRate.distinctnessKey(a) != ChemicalDefaultRate.distinctnessKey(c))
    }

    // ---- The operator's selection ----

    @Test
    fun `an exact dose inside the band is accepted and outside is refused`() {
        val plan = ChemicalDefaultRate.plan(listOf(use(rates = arrayOf(range(100.0, 200.0)))))
        val selection = ChemicalDefaultRateSelection(plan)

        // 150 lies inside 100-200: accepted, and the recommendation becomes an
        // explicit selection so the number and the option cannot disagree.
        val accepted = selection.settingValue(150.0, ChemicalDefaultRateBasis.PER_100_LITRES)
        assertNotNull(accepted)
        assertEquals(150.0, accepted?.resolvedValue(ChemicalDefaultRateBasis.PER_100_LITRES))

        // 250 lies outside: refused, nothing changes.
        assertNull(selection.settingValue(250.0, ChemicalDefaultRateBasis.PER_100_LITRES))

        // The authoritative range itself was never narrowed.
        val option = plan.per100Litres.options.single()
        assertEquals(100.0, option.rate.minValue)
        assertEquals(200.0, option.rate.maxValue)
    }

    @Test
    fun `an unnamed dose resolves to the bottom of the band never the top`() {
        val plan = ChemicalDefaultRate.plan(listOf(use(rates = arrayOf(range(100.0, 200.0)))))
        val selection = ChemicalDefaultRateSelection(plan)
        assertEquals(100.0, selection.resolvedValue(ChemicalDefaultRateBasis.PER_100_LITRES))
    }

    @Test
    fun `switching options retires the exact dose taken from the old one`() {
        val plan = ChemicalDefaultRate.plan(
            listOf(use("Powdery mildew", range(100.0, 200.0), range(200.0, 600.0))),
        )
        val basis = ChemicalDefaultRateBasis.PER_100_LITRES
        assertEquals(2, plan.per100Litres.options.size)

        var selection = ChemicalDefaultRateSelection(plan)
            .selecting(plan.per100Litres.options[0], basis)
        selection = selection.settingValue(150.0, basis)!!
        assertEquals(150.0, selection.resolvedValue(basis))

        // Choosing the second registered direction: 150 is not a dose it
        // authorises, so the figure is retired with the option.
        selection = selection.selecting(plan.per100Litres.options[1], basis)
        assertEquals(200.0, selection.resolvedValue(basis))
    }

    @Test
    fun `two legal directions for one target never collapse into one`() {
        // A5: 100-200 g/100 L and 200-600 g/100 L remain two distinct
        // registered directions; no synthetic 100-600 is ever produced.
        val plan = ChemicalDefaultRate.plan(
            listOf(use("Powdery mildew", range(100.0, 200.0), range(200.0, 600.0))),
        )
        val options = plan.per100Litres.options
        assertEquals(2, options.size)
        assertEquals(100.0 to 200.0, options[0].authorisedBounds)
        assertEquals(200.0 to 600.0, options[1].authorisedBounds)
        assertEquals(ChemicalDefaultRateRecommendation.OperatorMustChoose, plan.per100Litres.recommendation)
    }

    // ---- Jurisdiction parsing ----

    @Test
    fun `state abbreviations are matched as whole tokens only`() {
        assertTrue(ChemicalRateJurisdiction.mentioned("Use plenty of WATER each SEASON").isEmpty())
        assertEquals(
            listOf(
                ChemicalRateJurisdiction.NSW,
                ChemicalRateJurisdiction.VIC,
                ChemicalRateJurisdiction.QLD,
                ChemicalRateJurisdiction.SA,
                ChemicalRateJurisdiction.WA,
            ),
            ChemicalRateJurisdiction.mentioned("NSW, Vic, Qld / SA & WA"),
        )
    }

    @Test
    fun `an unrecognised vineyard jurisdiction resolves to null never a guess`() {
        assertNull(ChemicalRateJurisdiction.parse("Somewhere"))
        assertNull(ChemicalRateJurisdiction.parse(""))
        assertNull(ChemicalRateJurisdiction.parse(null))
        assertEquals(ChemicalRateJurisdiction.TAS, ChemicalRateJurisdiction.parse("Tasmania"))
        assertEquals(ChemicalRateJurisdiction.NSW, ChemicalRateJurisdiction.parse("nsw"))
        assertEquals(ChemicalRateJurisdiction.NSW, ChemicalRateJurisdiction.parse("New South Wales"))
    }
}
