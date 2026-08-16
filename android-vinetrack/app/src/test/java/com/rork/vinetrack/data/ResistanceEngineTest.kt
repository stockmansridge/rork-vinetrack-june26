package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.resistance.ResistanceApplicationEvent
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEngine
import com.rork.vinetrack.data.resistance.ResistanceEvaluation
import com.rork.vinetrack.data.resistance.ResistanceEvaluationRequest
import com.rork.vinetrack.data.resistance.ResistanceEvaluationStatus
import com.rork.vinetrack.data.resistance.ResistanceEventKind
import com.rork.vinetrack.data.resistance.ResistanceEvidenceQuality
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistanceMixtureRequirement
import com.rork.vinetrack.data.resistance.ResistanceProductLine
import com.rork.vinetrack.data.resistance.ResistanceRuleStatus
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.resistance.ResistanceSeverity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behaviour of the Resistance Rules Engine against the CropLife Australia 2026
 * grape strategies.
 *
 * Mirrored by iOS `ResistanceEngineTests.swift`.
 */
class ResistanceEngineTest {

    private val calendar = ResistanceSeasonCalendar()
    private val season = calendar.seasonStarting(2026)
    private val previousSeason = calendar.previous(season)

    private val blockA = "block-a"
    private val blockB = "block-b"

    private val powdery = listOf(ResistanceDisease.POWDERY_MILDEW)
    private val downy = listOf(ResistanceDisease.DOWNY_MILDEW)

    private fun day(offset: Int): Long = season.startEpochMs + offset * 86_400_000L
    private fun previousSeasonDay(offset: Int): Long =
        previousSeason.startEpochMs + offset * 86_400_000L

    private fun p(
        vararg groups: String,
        availability: ChemicalIntelligenceAvailability =
            ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
        lineId: String = "line-${groups.joinToString("-")}",
    ): ResistanceProductLine = ResistanceProductLine(
        lineId = lineId,
        productName = "Product " + groups.joinToString("+"),
        savedChemicalId = "saved-" + groups.joinToString("-"),
        groups = ResistanceGroupSignature.of(groups.toList()),
        availability = availability,
    )

    /** A product line with no usable chemistry at all — a pre-snapshot record. */
    private fun noChemistry(lineId: String = "line-legacy"): ResistanceProductLine =
        ResistanceProductLine(
            lineId = lineId,
            productName = "Legacy product",
            savedChemicalId = null,
            groups = ResistanceGroupSignature.empty,
            availability = ChemicalIntelligenceAvailability.UNAVAILABLE,
        )

    private fun ev(
        id: String,
        epochMs: Long,
        products: List<ResistanceProductLine>,
        targets: List<ResistanceDisease> = powdery,
        block: String = blockA,
        kind: ResistanceEventKind = ResistanceEventKind.ACTUAL,
        targetsRecorded: Boolean = true,
        mixtureConfirmed: Boolean? = null,
    ): ResistanceApplicationEvent = ResistanceApplicationEvent(
        applicationId = id,
        kind = kind,
        appliedAtEpochMs = epochMs,
        seasonId = calendar.season(epochMs).id,
        vineyardId = "vineyard-1",
        blockId = block,
        targets = targets,
        targetsRecorded = targetsRecorded,
        products = products,
        mixturePartnerAtLabelRate = mixtureConfirmed,
    )

    private fun evaluate(
        events: List<ResistanceApplicationEvent>,
        candidate: ResistanceApplicationEvent? = null,
        disease: ResistanceDisease = ResistanceDisease.POWDERY_MILDEW,
        block: String = blockA,
        jurisdiction: ResistanceJurisdiction = ResistanceJurisdiction.AUSTRALIA,
        includePlanned: Boolean = false,
    ): ResistanceEvaluation = ResistanceEngine.evaluate(
        ResistanceEvaluationRequest(
            jurisdiction = jurisdiction,
            crop = ResistanceCrop.GRAPE,
            disease = disease,
            blockId = block,
            season = season,
            seasonCalendar = calendar,
            events = events,
            candidate = candidate,
            includePlanned = includePlanned,
        ),
    )

    private fun ResistanceEvaluation.rule(id: String) =
        ruleResults.firstOrNull { it.ruleId == id }
            ?: error("rule $id not evaluated. present: ${ruleResults.map { it.ruleId }}")

    // =======================================================================
    // Jurisdiction isolation
    // =======================================================================

    @Test
    fun `New Zealand vineyard returns unsupported ruleset and runs no Australian rules`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val result = evaluate(events, jurisdiction = ResistanceJurisdiction.NEW_ZEALAND)

        assertEquals(ResistanceEvaluationStatus.UNSUPPORTED_RULESET, result.status)
        // Three consecutive Group 3 sprays would breach the AU strategy. No AU
        // rule may run for a New Zealand vineyard.
        assertTrue(result.ruleResults.isEmpty())
        assertNull(result.rulesetId)
        assertFalse(result.isCleanResult)
        assertTrue(result.summary.contains("not yet configured for this jurisdiction"))
    }

    @Test
    fun `unknown jurisdiction returns unsupported ruleset`() {
        val result = evaluate(
            listOf(ev("s1", day(1), listOf(p("3")))),
            jurisdiction = ResistanceJurisdiction.UNKNOWN,
        )
        assertEquals(ResistanceEvaluationStatus.UNSUPPORTED_RULESET, result.status)
        assertTrue(result.ruleResults.isEmpty())
    }

    @Test
    fun `unsupported jurisdiction applies to downy as well as powdery`() {
        val result = evaluate(
            listOf(ev("s1", day(1), listOf(p("40")), targets = downy)),
            disease = ResistanceDisease.DOWNY_MILDEW,
            jurisdiction = ResistanceJurisdiction.NEW_ZEALAND,
        )
        assertEquals(ResistanceEvaluationStatus.UNSUPPORTED_RULESET, result.status)
    }

    // =======================================================================
    // Ruleset attribution on every result
    // =======================================================================

    @Test
    fun `evaluation records which ruleset and version judged the sequence`() {
        val result = evaluate(listOf(ev("s1", day(1), listOf(p("3")))))
        assertEquals("AU_GRAPE_POWDERY_2026_07_22", result.rulesetId)
        assertEquals("2026.07.22", result.rulesetVersion)
        assertEquals("2026-07-22", result.rulesetValidFrom)
        assertEquals(season.id, result.seasonId)
        result.ruleResults.forEach {
            assertEquals("AU_GRAPE_POWDERY_2026_07_22", it.rulesetId)
            assertEquals("2026.07.22", it.rulesetVersion)
        }
    }

    @Test
    fun `downy evaluation records the downy ruleset`() {
        val result = evaluate(
            listOf(ev("s1", day(1), listOf(p("40")), targets = downy)),
            disease = ResistanceDisease.DOWNY_MILDEW,
        )
        assertEquals("AU_GRAPE_DOWNY_2026_07_22", result.rulesetId)
    }

    // =======================================================================
    // Powdery: consecutive rules
    // =======================================================================

    @Test
    fun `two consecutive group 3 powdery sprays reach the consecutive maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(2.0, rule.threshold)
        assertEquals(2.0, rule.observedValue)
        assertEquals(ResistanceSeverity.WARNING, rule.severity)
        assertEquals(listOf("s1", "s2"), rule.contributingApplicationIds)
    }

    @Test
    fun `a third consecutive group 3 candidate would exceed the consecutive maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
        )
        val candidate = ev("candidate", day(15), listOf(p("3")))
        val result = evaluate(events, candidate)
        val rule = result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")

        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, rule.status)
        assertEquals(3.0, rule.observedValue)
        assertEquals(ResistanceSeverity.CRITICAL, rule.severity)
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
        assertEquals("candidate", result.candidateApplicationId)
        assertTrue(rule.explanation.contains("consecutive Group 3 application number 3"))
    }

    @Test
    fun `three group 3 sprays in existing history exceed the consecutive maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val result = evaluate(events)
        val rule = result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(3.0, rule.observedValue)
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
    }

    @Test
    fun `an intervening different group resets the consecutive run`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("13"))),
            ev("s4", day(22), listOf(p("3"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // Longest run is still 2, not 3.
        assertEquals(2.0, rule.observedValue)
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
    }

    @Test
    fun `every group carrying the two-consecutive restriction is enforced`() {
        listOf("3" to "FRAC3", "5" to "FRAC5", "13" to "FRAC13", "19" to "FRAC19", "21" to "FRAC21", "50" to "FRAC50", "U6" to "FRACU6")
            .forEach { (code, fragment) ->
                val events = listOf(
                    ev("s1", day(1), listOf(p(code))),
                    ev("s2", day(8), listOf(p(code))),
                    ev("s3", day(15), listOf(p(code))),
                )
                val rule = evaluate(events).rule("AU_GRAPE_POWDERY_${fragment}_MAX_CONSECUTIVE")
                assertEquals(
                    "group $code should exceed at three consecutive",
                    ResistanceRuleStatus.LIMIT_EXCEEDED,
                    rule.status,
                )
            }
    }

    @Test
    fun `legacy U8 spelling is enforced as group 50`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("U8"))),
            ev("s2", day(8), listOf(p("50"))),
            ev("s3", day(15), listOf(p("Group 50 (U8)"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC50_MAX_CONSECUTIVE")
        // All three spellings must meet, or the run would never be detected.
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(3.0, rule.observedValue)
    }

    // =======================================================================
    // Powdery: cross-season consecutive handling
    // =======================================================================

    @Test
    fun `powdery consecutive runs continue from the end of one season into the next`() {
        // Two Group 3 sprays late in the previous season, then one early this
        // season. CropLife counts that as three consecutive.
        val events = listOf(
            ev("prev1", previousSeasonDay(300), listOf(p("3"))),
            ev("prev2", previousSeasonDay(310), listOf(p("3"))),
        )
        val candidate = ev("candidate", day(5), listOf(p("3")))
        val rule = evaluate(events, candidate).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")

        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, rule.status)
        assertEquals(3.0, rule.observedValue)
        assertTrue(
            "explanation must say the run crosses the season boundary",
            rule.explanation.contains("continues from the previous season"),
        )
    }

    @Test
    fun `seasonal counts do not include the previous season`() {
        val events = listOf(
            ev("prev1", previousSeasonDay(300), listOf(p("21"))),
            ev("prev2", previousSeasonDay(310), listOf(p("21"))),
            ev("prev3", previousSeasonDay(320), listOf(p("21"))),
            ev("s1", day(5), listOf(p("21"))),
        )
        val result = evaluate(events)
        // Three Group 21 sprays last season must not consume this season's crop
        // allowance.
        assertEquals(1, result.totalDiseaseSpraysInSeason)
        val crop = result.rule("AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP")
        assertEquals(1.0, crop.observedValue)
        assertEquals(listOf("s1"), result.consideredApplicationIds)
    }

    @Test
    fun `a non-cross-season rule ignores the previous season entirely`() {
        val events = listOf(
            ev("prev1", previousSeasonDay(300), listOf(p("5", "3"))),
            ev("s1", day(5), listOf(p("5", "3"))),
        )
        // Group 5+3 is one application per season, and last season's use does not
        // carry over.
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(1.0, rule.observedValue)
    }

    // =======================================================================
    // Powdery: group 5+3
    // =======================================================================

    @Test
    fun `a single group 5 plus 3 application reaches its one-application maximum`() {
        val rule = evaluate(listOf(ev("s1", day(1), listOf(p("5", "3")))))
            .rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(1.0, rule.threshold)
    }

    @Test
    fun `a second group 5 plus 3 candidate would exceed the one-application maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("5", "3"))),
            ev("s2", day(8), listOf(p("13"))),
        )
        val candidate = ev("candidate", day(15), listOf(p("5", "3")))
        val result = evaluate(events, candidate)
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            result.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON").status,
        )
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
    }

    @Test
    fun `a tank mix of separate group 5 and group 3 products is not a group 5 plus 3 product`() {
        // The published Group 5+3 restriction addresses the co-formulation. A tank
        // mix of two solo products is a mixture, not that product, and must not
        // silently consume the co-formulation's single-application allowance.
        val event = ev("s1", day(1), listOf(p("5"), p("3")))
        val result = evaluate(listOf(event))
        assertEquals(
            ResistanceRuleStatus.NOT_TRIGGERED,
            result.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON").status,
        )
        // It still counts against both component groups.
        assertEquals(1.0, result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE").observedValue)
        assertEquals(1.0, result.rule("AU_GRAPE_POWDERY_FRAC5_MAX_FROM_TOTAL_TABLE").observedValue)
    }

    @Test
    fun `group 5 plus 3 counts toward the shared table column with group 7 plus 12`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("5", "3"))),
            ev("s2", day(8), listOf(p("13"))),
            ev("s3", day(15), listOf(p("7", "12"))),
        )
        val result = evaluate(events)
        val shared = result.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE")
        // The published table gives 5+3 and 7+12 ONE shared column with a maximum
        // of 1, so two applications between them exceeds it.
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, shared.status)
        assertEquals(2.0, shared.observedValue)
        assertEquals(1.0, shared.threshold)
    }

    @Test
    fun `group 7 plus 12 also counts within the group 7 table column`() {
        val result = evaluate(listOf(ev("s1", day(1), listOf(p("7", "12")))))
        // Contains Group 7, so it counts in "7 (inc. 7+3)" as well as the shared
        // 5+3/7+12 column. Both ceilings apply; the stricter governs.
        assertEquals(1.0, result.rule("AU_GRAPE_POWDERY_FRAC7_MAX_FROM_TOTAL_TABLE").observedValue)
        assertEquals(
            1.0,
            result.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE").observedValue,
        )
    }

    // =======================================================================
    // Powdery: combination products contribute to component groups
    // =======================================================================

    @Test
    fun `group 11 plus 3 contributes to both group 11 and group 3 rules`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11", "3"))),
            ev("s2", day(8), listOf(p("11", "3"))),
        )
        val result = evaluate(events)
        // Guideline 4 restricts Group 3 "including mixture formulations".
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status,
        )
        // And the table's "11 (inc. 11+3)" column counts it as Group 11.
        assertEquals(2.0, result.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue)
    }

    @Test
    fun `a combination product is not reduced to one arbitrary primary group`() {
        val event = ev("s1", day(1), listOf(p("11", "3")))
        assertEquals(setOf("3", "11"), event.componentGroups)
        assertEquals(listOf("3+11"), event.coformulationSignatures.map { it.key })
    }

    // =======================================================================
    // Powdery: group 21 crop maximum and percentage
    // =======================================================================

    @Test
    fun `group 21 reaches its three-per-crop maximum`() {
        // Nine powdery sprays so the table also permits three Group 21.
        val events = (1..9).map { index ->
            val groups = if (index % 3 == 1) p("21") else p("13")
            ev("s$index", day(index * 7), listOf(groups))
        }
        val result = evaluate(events)
        val crop = result.rule("AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, crop.status)
        assertEquals(3.0, crop.observedValue)
        assertEquals(3.0, crop.threshold)
    }

    @Test
    fun `group 21 percentage restriction binds before the crop maximum in a short season`() {
        // Three powdery sprays, two of them Group 21. The crop maximum of 3 is not
        // reached, but 2 of 3 is above 33%, and CropLife says whichever is lower
        // governs.
        val events = listOf(
            ev("s1", day(1), listOf(p("21"))),
            ev("s2", day(8), listOf(p("13"))),
            ev("s3", day(15), listOf(p("21"))),
        )
        val result = evaluate(events)
        val crop = result.rule("AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP")
        val fraction = result.rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        assertEquals(ResistanceRuleStatus.APPROACHING_LIMIT, crop.status)
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, fraction.status)
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
    }

    @Test
    fun `group 21 at exactly one third of sprays reaches but does not exceed`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("21"))),
            ev("s2", day(8), listOf(p("13"))),
            ev("s3", day(15), listOf(p("19"))),
        )
        val fraction = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        // Exact rational comparison: 1 x 3 == 3 x 1. Not "33.33% > 33%".
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, fraction.status)
        assertEquals(1.0, fraction.observedValue)
        assertEquals(1.0, fraction.threshold)
    }

    @Test
    fun `two group 21 sprays in six is exactly one third and does not exceed`() {
        val events = (1..6).map { index ->
            ev("s$index", day(index * 7), listOf(if (index <= 2) p("21") else p("13")))
        }
        val fraction = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        // 2 of 6 compares as 2 x 3 <= 6 x 1. A rounded display percentage would
        // read 33.33% and wrongly exceed a 33% cap.
        assertEquals(2.0, fraction.observedValue)
        assertEquals(2.0, fraction.threshold)
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, fraction.status)
    }

    @Test
    fun `percentage denominator counts disease applications not products or tank lines`() {
        // One spray, three products. The denominator is 1 application, not 3 lines.
        val events = listOf(
            ev("s1", day(1), listOf(p("21"), p("13"), p("19"))),
        )
        val result = evaluate(events)
        assertEquals(1, result.totalDiseaseSpraysInSeason)
        val fraction = result.rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        assertEquals(1.0, fraction.observedValue)
        // 1 of 1 is 100%, above the 33% maximum.
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, fraction.status)
    }

    @Test
    fun `percentage denominator excludes other diseases and other blocks`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("21"))),
            ev("s2", day(8), listOf(p("40")), targets = downy),
            ev("s3", day(15), listOf(p("13")), block = blockB),
            ev("s4", day(22), listOf(p("13"))),
            ev("s5", day(29), listOf(p("13"))),
        )
        val result = evaluate(events)
        // Only s1, s4, s5 are powdery sprays on block A.
        assertEquals(3, result.totalDiseaseSpraysInSeason)
        assertEquals(listOf("s1", "s4", "s5"), result.consideredApplicationIds)
    }

    // =======================================================================
    // Powdery: the total-spray-count table
    // =======================================================================

    @Test
    fun `table ceiling moves with the season total spray count`() {
        // At 2 total sprays the table permits only 1 Group 11.
        val twoSprays = listOf(
            ev("s1", day(1), listOf(p("11"))),
            ev("s2", day(8), listOf(p("11"))),
        )
        val short = evaluate(twoSprays).rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        assertEquals(1.0, short.threshold)
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, short.status)

        // At 3 total sprays the table permits 2 Group 11, so the same two sprays
        // no longer exceed anything. The ceiling MOVED.
        val threeSprays = twoSprays + ev("s3", day(15), listOf(p("13")))
        val longer = evaluate(threeSprays).rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        assertEquals(2.0, longer.threshold)
        assertFalse(longer.status.isBreach)
    }

    @Test
    fun `a provisional table ceiling reports no maximum reached mid-season`() {
        // The published table permits one application of every group when only one
        // spray targets the disease. Reporting "maximum reached" after a single
        // spray would be misleading, because the ceiling rises as the season grows.
        val result = evaluate(listOf(ev("s1", day(1), listOf(p("13")))))
        val table = result.rule("AU_GRAPE_POWDERY_FRAC13_MAX_FROM_TOTAL_TABLE")
        assertEquals(1.0, table.threshold)
        assertEquals(1.0, table.observedValue)
        assertEquals(ResistanceRuleStatus.WITHIN_LIMIT, table.status)
        assertTrue(table.explanation.contains("ceiling rises"))
    }

    @Test
    fun `a table ceiling at or above the open-ended row is final and can be reached`() {
        // At nine or more powdery sprays the table stops moving, so "reached" is
        // real information rather than an artefact of a short season.
        val events = (1..9).map { index ->
            ev("s$index", day(index * 7), listOf(if (index <= 2) p("11") else p("13")))
        }
        val result = evaluate(events)
        val table = result.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        assertEquals(2.0, table.threshold)
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, table.status)
    }

    @Test
    fun `a table ceiling is still exceeded while provisional`() {
        // Suppressing "reached" must never suppress a genuine exceedance: more
        // sprays cannot undo two Group 11 applications in a two-spray season.
        val events = listOf(
            ev("s1", day(1), listOf(p("11"))),
            ev("s2", day(8), listOf(p("11"))),
        )
        val table = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, table.status)
    }

    @Test
    fun `table threshold for a candidate uses the total the engine can actually see`() {
        // Three applied powdery sprays plus a candidate is a known total of 4, so
        // the Group 3 ceiling is the table's value at 4. The engine never invents
        // future sprays to unlock a higher ceiling.
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("13"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val candidate = ev("candidate", day(22), listOf(p("3")))
        val result = evaluate(events, candidate)
        val table = result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE")
        assertEquals(4, result.totalDiseaseSpraysInSeason)
        assertEquals(2.0, table.threshold)
        assertEquals(3.0, table.observedValue)
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, table.status)
    }

    @Test
    fun `table describes the total it used in the threshold text`() {
        val events = (1..6).map { ev("s$it", day(it * 7), listOf(p("13"))) }
        val table = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC13_MAX_FROM_TOTAL_TABLE")
        assertEquals(3.0, table.threshold)
        assertTrue(table.thresholdDescription.contains("6 Powdery Mildew sprays"))
    }

    // =======================================================================
    // Powdery: mixture when consecutive (groups 7 and 11)
    // =======================================================================

    @Test
    fun `consecutive solo group 7 sprays fail the mixture requirement`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("7"))),
            ev("s2", day(8), listOf(p("7"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.REQUIREMENT_NOT_MET, rule.status)
        assertEquals(ResistanceMixtureRequirement.NOT_SATISFIED, rule.mixtureRequirement)
        assertEquals(ResistanceSeverity.CRITICAL, rule.severity)
    }

    @Test
    fun `a single group 7 spray carries no mixture requirement`() {
        val rule = evaluate(listOf(ev("s1", day(1), listOf(p("7")))))
            .rule("AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        // The published requirement applies only to consecutive use.
        assertEquals(ResistanceRuleStatus.NOT_TRIGGERED, rule.status)
        assertNull(rule.mixtureRequirement)
    }

    @Test
    fun `consecutive group 7 with an unconfirmed partner returns unknown not satisfied`() {
        // Six powdery sprays so the table permits the two Group 7 applications and
        // the only outstanding question is the mixture itself.
        val events = listOf(
            ev("s1", day(1), listOf(p("7"), p("13"))),
            ev("s2", day(8), listOf(p("7"), p("13"))),
            ev("s3", day(15), listOf(p("19"))),
            ev("s4", day(22), listOf(p("50"))),
            ev("s5", day(29), listOf(p("19"))),
            ev("s6", day(36), listOf(p("50"))),
        )
        val result = evaluate(events)
        val rule = result.rule("AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        // A second FRAC code does not prove the partner was applied at an
        // effective rate, so the requirement is unproven, never satisfied.
        assertEquals(ResistanceRuleStatus.REQUIREMENT_UNPROVEN, rule.status)
        assertEquals(ResistanceMixtureRequirement.UNKNOWN, rule.mixtureRequirement)
        assertEquals(ResistanceSeverity.INDETERMINATE, rule.severity)
        // And an unproven requirement can never present as a clean pass.
        assertEquals(ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS, result.status)
        assertFalse(result.isCleanResult)
    }

    @Test
    fun `consecutive group 7 with a confirmed label-rate partner satisfies the mixture rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("7"), p("13")), mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("7"), p("13")), mixtureConfirmed = true),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.WITHIN_LIMIT, rule.status)
        assertEquals(ResistanceMixtureRequirement.SATISFIED, rule.mixtureRequirement)
    }

    @Test
    fun `consecutive group 11 sprays fail the mixture requirement`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11"))),
            ev("s2", day(8), listOf(p("11"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC11_MIXTURE_WHEN_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.REQUIREMENT_NOT_MET, rule.status)
    }

    @Test
    fun `a co-formulated group 11 plus 3 satisfies presence of an alternative mode of action`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11", "3")), mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11", "3")), mixtureConfirmed = true),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC11_MIXTURE_WHEN_CONSECUTIVE")
        // The co-formulation itself carries the alternative mode of action.
        assertEquals(ResistanceMixtureRequirement.SATISFIED, rule.mixtureRequirement)
    }

    // =======================================================================
    // Application-event grouping
    // =======================================================================

    @Test
    fun `one spray with two groups is one event contributing to each group once`() {
        val events = listOf(ev("s1", day(1), listOf(p("3"), p("11"))))
        val result = evaluate(events)
        assertEquals(1, result.totalDiseaseSpraysInSeason)
        assertEquals(1.0, result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE").observedValue)
        assertEquals(1.0, result.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue)
    }

    @Test
    fun `two products of the same group in one tank count as one application`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11", lineId = "a"), p("11", lineId = "b"))),
        )
        val result = evaluate(events)
        val table = result.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        // Resistance counting happens at application-event level, not per line.
        assertEquals(1.0, table.observedValue)
        assertEquals(1, result.totalDiseaseSpraysInSeason)
    }

    @Test
    fun `two products of the same group in one tank are not a consecutive pair`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3", lineId = "a"), p("3", lineId = "b"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(1.0, rule.observedValue)
        assertNotEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
    }

    @Test
    fun `same-day sprays remain distinct application events`() {
        // A morning job and an afternoon job are two applications. Date is not
        // event identity.
        val events = listOf(
            ev("morning", day(1), listOf(p("3"))),
            ev("afternoon", day(1), listOf(p("3"))),
            ev("next", day(2), listOf(p("3"))),
        )
        val result = evaluate(events)
        assertEquals(3, result.totalDiseaseSpraysInSeason)
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status,
        )
    }

    // =======================================================================
    // Deterministic ordering
    // =======================================================================

    @Test
    fun `results are identical regardless of input array ordering`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("13"))),
            ev("s3", day(15), listOf(p("3"))),
            ev("s4", day(22), listOf(p("21"))),
        )
        val forward = evaluate(events)
        val reversed = evaluate(events.reversed())
        val shuffled = evaluate(listOf(events[2], events[0], events[3], events[1]))

        listOf(reversed, shuffled).forEach { other ->
            assertEquals(forward.status, other.status)
            assertEquals(forward.consideredApplicationIds, other.consideredApplicationIds)
            assertEquals(forward.totalDiseaseSpraysInSeason, other.totalDiseaseSpraysInSeason)
            assertEquals(
                forward.ruleResults.map { it.ruleId to it.status },
                other.ruleResults.map { it.ruleId to it.status },
            )
            assertEquals(
                forward.ruleResults.map { it.observedValue },
                other.ruleResults.map { it.observedValue },
            )
        }
    }

    @Test
    fun `same-date events order deterministically by application id`() {
        val a = ev("aaa", day(1), listOf(p("3")))
        val b = ev("bbb", day(1), listOf(p("13")))
        val forward = evaluate(listOf(a, b))
        val backward = evaluate(listOf(b, a))
        assertEquals(listOf("aaa", "bbb"), forward.consideredApplicationIds)
        assertEquals(forward.consideredApplicationIds, backward.consideredApplicationIds)
    }

    // =======================================================================
    // Per-disease separation
    // =======================================================================

    @Test
    fun `a group 11 downy spray does not increase the powdery group 11 count`() {
        val events = listOf(
            ev("powderySpray", day(1), listOf(p("11"))),
            ev("downySpray", day(8), listOf(p("11")), targets = downy),
        )
        val powderyResult = evaluate(events)
        val downyResult = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)

        assertEquals(listOf("powderySpray"), powderyResult.consideredApplicationIds)
        assertEquals(listOf("downySpray"), downyResult.consideredApplicationIds)
        assertEquals(
            1.0,
            powderyResult.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE").observedValue,
        )
        assertEquals(1.0, downyResult.rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").observedValue)
    }

    @Test
    fun `a spray targeting both diseases contributes to both histories independently`() {
        val both = listOf(ResistanceDisease.POWDERY_MILDEW, ResistanceDisease.DOWNY_MILDEW)
        val events = listOf(ev("s1", day(1), listOf(p("11")), targets = both))
        assertEquals(1, evaluate(events).totalDiseaseSpraysInSeason)
        assertEquals(
            1,
            evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW).totalDiseaseSpraysInSeason,
        )
    }

    @Test
    fun `a spray targeting neither disease enters no resistance history`() {
        val events = listOf(
            ev("weeds", day(1), listOf(p("11")), targets = emptyList()),
        )
        val result = evaluate(events)
        // Recorded as targeting nothing is a FACT, so it is not an unknown.
        assertEquals(ResistanceEvaluationStatus.NOT_APPLICABLE, result.status)
        assertTrue(result.unattributedApplicationIds.isEmpty())
    }

    @Test
    fun `disease target is never inferred from the chemical group`() {
        // A Group 40 product is a downy fungicide, but the operator recorded this
        // spray as targeting powdery mildew only. The engine honours the record.
        val events = listOf(ev("s1", day(1), listOf(p("40")), targets = powdery))
        val downyResult = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        assertEquals(ResistanceEvaluationStatus.NOT_APPLICABLE, downyResult.status)
    }

    // =======================================================================
    // Per-block separation
    // =======================================================================

    @Test
    fun `the same candidate produces different results on different blocks`() {
        val events = listOf(
            ev("a1", day(1), listOf(p("11")), targets = downy, block = blockA),
            ev("a2", day(8), listOf(p("21")), targets = downy, block = blockA),
            ev("a3", day(15), listOf(p("11")), targets = downy, block = blockA),
            ev("a4", day(22), listOf(p("21")), targets = downy, block = blockA),
            ev("b1", day(1), listOf(p("11")), targets = downy, block = blockB),
            ev("b2", day(8), listOf(p("21")), targets = downy, block = blockB),
        )
        val candidateA = ev("cand", day(29), listOf(p("11")), targets = downy, block = blockA)
        val candidateB = ev("cand", day(29), listOf(p("11")), targets = downy, block = blockB)

        val resultA = evaluate(events, candidateA, ResistanceDisease.DOWNY_MILDEW, blockA)
        val resultB = evaluate(events, candidateB, ResistanceDisease.DOWNY_MILDEW, blockB)

        // Block A already has two Group 11 sprays; block B has one.
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            resultA.rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").status,
        )
        assertEquals(
            ResistanceRuleStatus.WOULD_REACH_LIMIT,
            resultB.rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON").status,
        )
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, resultA.status)
        assertEquals(ResistanceEvaluationStatus.LIMIT_REACHED, resultB.status)
    }

    @Test
    fun `one spray across three blocks contributes one event to each block history`() {
        // The adapter fans a multi-block spray into one event per block, all
        // sharing the spray's own ID.
        val blocks = listOf("b1", "b2", "b3")
        val events = blocks.map { ev("shared", day(1), listOf(p("11")), block = it) }
        blocks.forEach { block ->
            val result = evaluate(events, block = block)
            assertEquals(1, result.totalDiseaseSpraysInSeason)
            assertEquals(listOf("shared"), result.consideredApplicationIds)
        }
    }

    @Test
    fun `the vineyard is never evaluated as one homogeneous history`() {
        val events = listOf(
            ev("a1", day(1), listOf(p("3")), block = blockA),
            ev("a2", day(8), listOf(p("3")), block = blockA),
            ev("b1", day(15), listOf(p("3")), block = blockB),
        )
        // Three Group 3 sprays across the vineyard, but no block had three.
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            evaluate(events, block = blockA).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status,
        )
        val blockBRule = evaluate(events, block = blockB)
            .rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(1.0, blockBRule.observedValue)
        assertFalse(blockBRule.status.isBreach)
        assertFalse(blockBRule.status.isAtLimit)
    }

    // =======================================================================
    // Downy: group 4
    // =======================================================================

    @Test
    fun `solo group 4 fails the always-mix requirement`() {
        val events = listOf(ev("s1", day(1), listOf(p("4")), targets = downy))
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        val rule = result.rule("AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED")
        assertEquals(ResistanceRuleStatus.REQUIREMENT_NOT_MET, rule.status)
        assertEquals(ResistanceMixtureRequirement.NOT_SATISFIED, rule.mixtureRequirement)
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
    }

    @Test
    fun `three consecutive group 4 sprays exceed the consecutive maximum`() {
        val events = (1..3).map {
            ev("s$it", day(it * 7), listOf(p("4"), p("21")), targets = downy, mixtureConfirmed = true)
        }
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
    }

    @Test
    fun `a fifth group 4 spray would exceed the four-per-season maximum`() {
        val events = (1..8).map { index ->
            val products = if (index % 2 == 1) listOf(p("4"), p("11")) else listOf(p("21"))
            ev("s$index", day(index * 7), products, targets = downy, mixtureConfirmed = true)
        }
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        val rule = result.rule("AU_GRAPE_DOWNY_FRAC4_MAX_SEASON")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(4.0, rule.observedValue)

        val candidate = ev(
            "cand", day(70), listOf(p("4"), p("21")),
            targets = downy, mixtureConfirmed = true,
        )
        val withCandidate = evaluate(events, candidate, ResistanceDisease.DOWNY_MILDEW)
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            withCandidate.rule("AU_GRAPE_DOWNY_FRAC4_MAX_SEASON").status,
        )
    }

    // =======================================================================
    // Downy: group 11
    // =======================================================================

    @Test
    fun `consecutive group 11 downy sprays breach the non-consecutive rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11")), targets = downy),
            ev("s2", day(8), listOf(p("11")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(1.0, rule.threshold)
        assertTrue(rule.thresholdDescription.contains("must not be applied consecutively"))
    }

    @Test
    fun `a group 11 candidate immediately after group 11 would breach non-consecutive use`() {
        val events = listOf(ev("s1", day(1), listOf(p("11")), targets = downy))
        val candidate = ev("cand", day(8), listOf(p("11")), targets = downy)
        val rule = evaluate(events, candidate, ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, rule.status)
    }

    @Test
    fun `group 11 plus 3 counts as group 11 for the downy non-consecutive rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11")), targets = downy),
            ev("s2", day(8), listOf(p("11", "3")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")
        // "including mixture formulations".
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
    }

    @Test
    fun `a third group 11 downy spray exceeds the two-per-season maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11")), targets = downy),
            ev("s2", day(8), listOf(p("21")), targets = downy),
            ev("s3", day(15), listOf(p("11", "3")), targets = downy),
            ev("s4", day(22), listOf(p("21")), targets = downy),
            ev("s5", day(29), listOf(p("11")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(3.0, rule.observedValue)
    }

    // =======================================================================
    // Downy: group 21
    // =======================================================================

    @Test
    fun `group 21 downy reaches three per season and exceeds at four`() {
        val threeEvents = listOf(
            ev("s1", day(1), listOf(p("21")), targets = downy),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("21")), targets = downy),
            ev("s4", day(22), listOf(p("11")), targets = downy),
            ev("s5", day(29), listOf(p("21")), targets = downy),
        )
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            evaluate(threeEvents, disease = ResistanceDisease.DOWNY_MILDEW)
                .rule("AU_GRAPE_DOWNY_FRAC21_MAX_SEASON").status,
        )
        val candidate = ev("cand", day(36), listOf(p("21")), targets = downy)
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            evaluate(threeEvents, candidate, ResistanceDisease.DOWNY_MILDEW)
                .rule("AU_GRAPE_DOWNY_FRAC21_MAX_SEASON").status,
        )
    }

    @Test
    fun `group 21 downy allows two consecutive and breaches at three`() {
        val events = (1..3).map { ev("s$it", day(it * 7), listOf(p("21")), targets = downy) }
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
                .rule("AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE").status,
        )
    }

    // =======================================================================
    // Downy: group 40
    // =======================================================================

    @Test
    fun `group 40 exceeds fifty percent of downy sprays`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40")), targets = downy),
            ev("s2", day(8), listOf(p("40")), targets = downy),
            ev("s3", day(15), listOf(p("11")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION")
        // 2 of 3 sprays is above 50%.
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(2.0, rule.observedValue)
        assertEquals(1.0, rule.threshold)
    }

    @Test
    fun `group 40 at exactly half of downy sprays reaches but does not exceed`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40")), targets = downy),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("40")), targets = downy),
            ev("s4", day(22), listOf(p("11")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(2.0, rule.observedValue)
        assertEquals(2.0, rule.threshold)
    }

    @Test
    fun `group 40 exceeds its two solo application maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40")), targets = downy),
            ev("s2", day(8), listOf(p("21")), targets = downy),
            ev("s3", day(15), listOf(p("40")), targets = downy),
            ev("s4", day(22), listOf(p("21")), targets = downy),
            ev("s5", day(29), listOf(p("40")), targets = downy),
            ev("s6", day(36), listOf(p("11")), targets = downy),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        val solo = result.rule("AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, solo.status)
        assertEquals(3.0, solo.observedValue)
        assertEquals(2.0, solo.threshold)
        // 3 of 6 is exactly 50%, so the percentage rule is reached, not exceeded.
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").status,
        )
    }

    @Test
    fun `a mixed group 40 spray is not a solo application`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40"), p("11")), targets = downy),
            ev("s2", day(8), listOf(p("21")), targets = downy),
            ev("s3", day(15), listOf(p("40"), p("11")), targets = downy),
            ev("s4", day(22), listOf(p("21")), targets = downy),
        )
        val solo = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON")
        assertEquals(0.0, solo.observedValue)
        assertEquals(ResistanceRuleStatus.NOT_TRIGGERED, solo.status)
    }

    @Test
    fun `group 40 as the currently final downy spray is reported as guidance`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("11")), targets = downy),
            ev("s2", day(8), listOf(p("40")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY")
        // Whether a spray is the LAST of a season is unknowable mid-season, so
        // this is advice, not a breach.
        assertEquals(ResistanceRuleStatus.GUIDANCE, rule.status)
        assertEquals(ResistanceSeverity.INFORMATIONAL, rule.severity)
    }

    @Test
    fun `group 40 not followed by the season end passes the last-spray rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40")), targets = downy),
            ev("s2", day(8), listOf(p("11")), targets = downy),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY")
        assertEquals(ResistanceRuleStatus.WITHIN_LIMIT, rule.status)
    }

    @Test
    fun `three consecutive group 40 sprays exceed the consecutive maximum`() {
        val events = (1..3).map { ev("s$it", day(it * 7), listOf(p("40")), targets = downy) }
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
                .rule("AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE").status,
        )
    }

    // =======================================================================
    // Downy: combination products 45+40 and 40+49
    // =======================================================================

    @Test
    fun `group 45 plus 40 is capped at two per season as its own combination`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("45", "40")), targets = downy),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("45", "40")), targets = downy),
            ev("s4", day(22), listOf(p("11")), targets = downy),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON").status,
        )
        // And its Group 40 component still counts toward Group 40 rules.
        assertEquals(2.0, result.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").observedValue)
    }

    @Test
    fun `group 40 plus 49 has a thirty-three percent cap distinct from group 40's fifty percent`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("21")), targets = downy),
            ev("s4", day(22), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        val combination = result.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION")
        // 2 of 4 is 50%, above the combination's 33% ceiling.
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, combination.status)
        assertEquals(1.0, combination.threshold)
        // The Group 40 component ceiling is 50%, which 2 of 4 exactly reaches.
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").status,
        )
    }

    @Test
    fun `group 40 plus 49 requires two intervening different-group applications`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, rule.status)
        assertEquals(1.0, rule.observedValue)
        assertEquals(2.0, rule.threshold)
    }

    @Test
    fun `group 40 plus 49 with two intervening applications satisfies the reuse rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("21")), targets = downy),
            ev("s4", day(22), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
        )
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING")
        assertEquals(ResistanceRuleStatus.WITHIN_LIMIT, rule.status)
        assertEquals(2.0, rule.observedValue)
    }

    @Test
    fun `a combination product is recognised by signature and by component groups`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("40", "49")), targets = downy, mixtureConfirmed = true),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        // Its own combination identity.
        assertEquals(1.0, result.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON").observedValue)
        // And both component groups.
        assertEquals(1.0, result.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION").observedValue)
        assertEquals(1.0, result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").observedValue)
    }

    // =======================================================================
    // Downy: group 49 one-in-three vs percentage
    // =======================================================================

    @Test
    fun `two adjacent group 49 sprays breach one-in-three even though two of six is thirty-three percent`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("49"), p("21")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("49"), p("21")), targets = downy, mixtureConfirmed = true),
            ev("s3", day(15), listOf(p("11")), targets = downy),
            ev("s4", day(22), listOf(p("21")), targets = downy),
            ev("s5", day(29), listOf(p("11")), targets = downy),
            ev("s6", day(36), listOf(p("21")), targets = downy),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        // Spacing rule: two Group 49 inside one window of three.
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE").status,
        )
        // Seasonal count of 2 is exactly the maximum, NOT exceeded. This is why
        // one-in-three and a 33% cap cannot be treated as the same rule.
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").status,
        )
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            result.rule("AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE").status,
        )
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING").status,
        )
    }

    @Test
    fun `two properly spaced group 49 sprays satisfy one-in-three and reach the season maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("49"), p("21")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("21")), targets = downy),
            ev("s4", day(22), listOf(p("49"), p("11")), targets = downy, mixtureConfirmed = true),
            ev("s5", day(29), listOf(p("21")), targets = downy),
            ev("s6", day(36), listOf(p("11")), targets = downy),
        )
        val result = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
        assertEquals(
            ResistanceRuleStatus.WITHIN_LIMIT,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE").status,
        )
        assertEquals(
            ResistanceRuleStatus.WITHIN_LIMIT,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING").status,
        )
        assertEquals(
            ResistanceRuleStatus.LIMIT_REACHED,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").status,
        )
    }

    @Test
    fun `a third group 49 candidate would exceed the two-per-season maximum`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("49"), p("21")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
            ev("s3", day(15), listOf(p("21")), targets = downy),
            ev("s4", day(22), listOf(p("49"), p("11")), targets = downy, mixtureConfirmed = true),
            ev("s5", day(29), listOf(p("21")), targets = downy),
            ev("s6", day(36), listOf(p("11")), targets = downy),
        )
        val candidate = ev(
            "cand", day(43), listOf(p("49"), p("21")),
            targets = downy, mixtureConfirmed = true,
        )
        val result = evaluate(events, candidate, ResistanceDisease.DOWNY_MILDEW)
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            result.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON").status,
        )
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
    }

    @Test
    fun `solo group 49 fails its mixture requirement`() {
        val events = listOf(ev("s1", day(1), listOf(p("49")), targets = downy))
        val rule = evaluate(events, disease = ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED")
        assertEquals(ResistanceRuleStatus.REQUIREMENT_NOT_MET, rule.status)
        assertEquals(ResistanceMixtureRequirement.NOT_SATISFIED, rule.mixtureRequirement)
    }

    @Test
    fun `group 49 reuse after only one intervening spray breaches the intervening rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("49"), p("21")), targets = downy, mixtureConfirmed = true),
            ev("s2", day(8), listOf(p("11")), targets = downy),
        )
        val candidate = ev(
            "cand", day(15), listOf(p("49"), p("21")),
            targets = downy, mixtureConfirmed = true,
        )
        val rule = evaluate(events, candidate, ResistanceDisease.DOWNY_MILDEW)
            .rule("AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING")
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, rule.status)
        assertEquals(1.0, rule.observedValue)
        assertTrue(rule.explanation.contains("different group"))
    }

    // =======================================================================
    // Chemical Intelligence availability
    // =======================================================================

    @Test
    fun `verified chemistry with no breach returns a clean result`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("13"))),
            ev("s2", day(8), listOf(p("19"))),
        )
        val result = evaluate(events)
        assertEquals(ResistanceEvaluationStatus.COMPLIANT, result.status)
        assertEquals(ResistanceEvidenceQuality.HIGH, result.evidenceQuality)
        assertTrue(result.isCleanResult)
        assertTrue(result.summary.contains("No Powdery Mildew resistance strategy limit is reached"))
    }

    @Test
    fun `partially verified chemistry qualifies the result and blocks a clean pass`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("13", availability = ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED))),
            ev("s2", day(8), listOf(p("19"))),
        )
        val result = evaluate(events)
        assertEquals(ResistanceEvaluationStatus.COMPLIANT, result.status)
        assertEquals(ResistanceEvidenceQuality.QUALIFIED, result.evidenceQuality)
        assertFalse(result.isCleanResult)
    }

    @Test
    fun `unverified chemistry with no breach is qualified never reported as all good`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("13", availability = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED))),
            ev("s2", day(8), listOf(p("19"))),
        )
        val result = evaluate(events)
        assertEquals(ResistanceEvaluationStatus.COMPLIANT, result.status)
        assertEquals(ResistanceEvidenceQuality.QUALIFIED, result.evidenceQuality)
        assertFalse(result.isCleanResult)
        assertEquals(
            "No strategy limit detected using the recorded groups; one or more chemical " +
                "records are unverified.",
            result.summary,
        )
    }

    @Test
    fun `an unverified sequence that appears to exceed a maximum still warns`() {
        val unverified = ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED
        val events = listOf(
            ev("s1", day(1), listOf(p("11", availability = unverified))),
            ev("s2", day(8), listOf(p("11", availability = unverified))),
        )
        val result = evaluate(events)
        val table = result.rule("AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE")
        assertEquals(ResistanceRuleStatus.LIMIT_EXCEEDED, table.status)
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
        assertEquals(ResistanceEvidenceQuality.QUALIFIED, table.evidenceQuality)
        // The warning must be qualified by the quality of its evidence.
        assertTrue(table.explanation.contains("not been independently verified"))
    }

    @Test
    fun `conflicting chemistry cannot be treated as reliable`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("13", availability = ChemicalIntelligenceAvailability.CONFLICT))),
            ev("s2", day(8), listOf(p("19"))),
        )
        val result = evaluate(events)
        assertEquals(ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS, result.status)
        assertEquals(ResistanceEvidenceQuality.INDETERMINATE, result.evidenceQuality)
        assertFalse(result.isCleanResult)
        assertTrue(result.unassessableApplicationIds.contains("s1"))
    }

    @Test
    fun `unavailable chemistry can never produce a clean pass`() {
        val events = listOf(
            ev("s1", day(1), listOf(noChemistry())),
            ev("s2", day(8), listOf(p("19"))),
        )
        val result = evaluate(events)
        assertEquals(ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS, result.status)
        assertFalse(result.isCleanResult)
        assertNotEquals(ResistanceEvaluationStatus.COMPLIANT, result.status)
        assertTrue(result.unassessableApplicationIds.contains("s1"))
    }

    @Test
    fun `a historical spray with no chemical snapshot stays in the chronology`() {
        // The pre-Chemical-Intelligence record. It must not vanish, and it must
        // not be read as a no-group application.
        val events = listOf(
            ev("legacy", day(1), listOf(noChemistry())),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val result = evaluate(events)
        assertEquals(3, result.totalDiseaseSpraysInSeason)
        assertTrue(result.consideredApplicationIds.contains("legacy"))

        val consecutive = result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        // The legacy spray might have been Group 3, which would make this three in
        // a row. The engine refuses to say.
        assertEquals(ResistanceRuleStatus.UNABLE_TO_ASSESS, consecutive.status)
        assertEquals(ResistanceEvidenceQuality.INDETERMINATE, consecutive.evidenceQuality)
        assertTrue(consecutive.contributingApplicationIds.contains("legacy"))
        assertTrue(consecutive.explanation.contains("cannot be assessed"))
    }

    @Test
    fun `missing chemistry suppresses a clean result but not a proven breach`() {
        val events = listOf(
            ev("legacy", day(1), listOf(noChemistry())),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
            ev("s4", day(22), listOf(p("3"))),
        )
        val result = evaluate(events)
        // Three known Group 3 sprays in a row is a breach regardless of the
        // unknown one, so the warning survives.
        assertEquals(
            ResistanceRuleStatus.LIMIT_EXCEEDED,
            result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status,
        )
        assertEquals(ResistanceEvaluationStatus.STRATEGY_EXCEEDED, result.status)
        assertTrue(result.summary.contains("may be worse"))
    }

    @Test
    fun `an application whose chemistry is unavailable is never a no-group application`() {
        val event = ev("legacy", day(1), listOf(noChemistry()))
        assertEquals(ChemicalIntelligenceAvailability.UNAVAILABLE, event.availability)
        assertFalse(event.canAssessChemistry)
        assertTrue(event.componentGroups.isEmpty())
        // Empty groups plus UNAVAILABLE is the honest encoding: nothing is known,
        // as opposed to "known to contain nothing".
        assertFalse(event.availability.permitsCleanResult)
    }

    @Test
    fun `the weakest product line governs a tank's availability`() {
        val event = ev(
            "s1", day(1),
            listOf(
                p("3"),
                p("11", availability = ChemicalIntelligenceAvailability.CONFLICT),
            ),
        )
        assertEquals(ChemicalIntelligenceAvailability.CONFLICT, event.availability)
    }

    // =======================================================================
    // Unrecorded targets
    // =======================================================================

    @Test
    fun `applications with no recorded target suppress a clean result`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("13"))),
            ev("legacy", day(8), listOf(p("3")), targets = emptyList(), targetsRecorded = false),
        )
        val result = evaluate(events)
        // The unattributed spray cannot be counted against powdery mildew, and it
        // must not be silently dropped either.
        assertEquals(ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS, result.status)
        assertEquals(listOf("legacy"), result.unattributedApplicationIds)
        assertFalse(result.isCleanResult)
        assertTrue(result.summary.contains("no recorded target disease"))
    }

    @Test
    fun `recorded-as-no-target differs from never-recorded`() {
        val recordedNone = evaluate(
            listOf(
                ev("s1", day(1), listOf(p("13"))),
                ev("none", day(8), listOf(p("3")), targets = emptyList(), targetsRecorded = true),
            ),
        )
        val neverRecorded = evaluate(
            listOf(
                ev("s1", day(1), listOf(p("13"))),
                ev("unknown", day(8), listOf(p("3")), targets = emptyList(), targetsRecorded = false),
            ),
        )
        assertTrue(recordedNone.unattributedApplicationIds.isEmpty())
        assertEquals(ResistanceEvaluationStatus.COMPLIANT, recordedNone.status)
        assertEquals(listOf("unknown"), neverRecorded.unattributedApplicationIds)
        assertEquals(ResistanceEvaluationStatus.UNABLE_TO_FULLY_ASSESS, neverRecorded.status)
    }

    // =======================================================================
    // Candidate evaluation
    // =======================================================================

    @Test
    fun `history can be evaluated with no candidate at all`() {
        val result = evaluate(listOf(ev("s1", day(1), listOf(p("13")))))
        assertNull(result.candidateApplicationId)
        assertFalse(result.hasCandidate)
        assertEquals(ResistanceEvaluationStatus.COMPLIANT, result.status)
    }

    @Test
    fun `a candidate needs no saved spray record`() {
        // A Guided Spray plan that has never been persisted.
        val candidate = ResistanceApplicationEvent(
            applicationId = "temp-candidate-1",
            kind = ResistanceEventKind.CANDIDATE,
            appliedAtEpochMs = day(10),
            seasonId = season.id,
            vineyardId = "vineyard-1",
            blockId = blockA,
            targets = powdery,
            targetsRecorded = true,
            products = listOf(p("3")),
        )
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
        )
        val result = evaluate(events, candidate)
        assertEquals("temp-candidate-1", result.candidateApplicationId)
        assertEquals(
            ResistanceRuleStatus.WOULD_EXCEED_LIMIT,
            result.rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE").status,
        )
    }

    @Test
    fun `reaching a limit and exceeding it are distinct candidate outcomes`() {
        val oneSpray = listOf(ev("s1", day(1), listOf(p("3"))))
        val reach = evaluate(oneSpray, ev("cand", day(8), listOf(p("3"))))
            .rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.WOULD_REACH_LIMIT, reach.status)
        assertEquals(ResistanceSeverity.WARNING, reach.severity)
        assertTrue(reach.explanation.contains("would reach the strategy maximum"))

        val twoSprays = oneSpray + ev("s2", day(8), listOf(p("3")))
        val exceed = evaluate(twoSprays, ev("cand", day(15), listOf(p("3"))))
            .rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.WOULD_EXCEED_LIMIT, exceed.status)
        assertEquals(ResistanceSeverity.CRITICAL, exceed.severity)
    }

    @Test
    fun `a candidate for a different disease does not affect this disease`() {
        val events = listOf(ev("s1", day(1), listOf(p("3"))))
        val downyCandidate = ev("cand", day(8), listOf(p("3")), targets = downy)
        val result = evaluate(events, downyCandidate)
        assertNull(result.candidateApplicationId)
        assertEquals(1, result.totalDiseaseSpraysInSeason)
    }

    @Test
    fun `a candidate for a different block does not affect this block`() {
        val events = listOf(ev("s1", day(1), listOf(p("3")), block = blockA))
        val candidate = ev("cand", day(8), listOf(p("3")), block = blockB)
        val result = evaluate(events, candidate, block = blockA)
        // The candidate is scoped to block B, so block A's total is unchanged.
        assertEquals(1, result.totalDiseaseSpraysInSeason)
    }

    // =======================================================================
    // Planned events
    // =======================================================================

    @Test
    fun `planned events are excluded from counting but reported`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("planned", day(8), listOf(p("3")), kind = ResistanceEventKind.PLANNED),
        )
        val result = evaluate(events)
        assertEquals(1, result.totalDiseaseSpraysInSeason)
        assertEquals(listOf("planned"), result.excludedPlannedApplicationIds)
    }

    @Test
    fun `planned events can be opted into without an engine change`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("planned", day(8), listOf(p("3")), kind = ResistanceEventKind.PLANNED),
        )
        val result = evaluate(events, includePlanned = true)
        assertEquals(2, result.totalDiseaseSpraysInSeason)
        assertTrue(result.excludedPlannedApplicationIds.isEmpty())
    }

    // =======================================================================
    // Explainability
    // =======================================================================

    @Test
    fun `every finding traces to a specific published rule`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val result = evaluate(events)
        assertTrue(result.findings.isNotEmpty())
        result.findings.forEach { finding ->
            assertTrue("rule id missing", finding.ruleId.isNotBlank())
            assertTrue("ruleset id missing", finding.rulesetId.isNotBlank())
            assertTrue("source reference missing", finding.sourceReference.isNotBlank())
            assertTrue("published text missing", finding.sourceText.length > 20)
            assertTrue("explanation missing", finding.explanation.length > 20)
            assertTrue("groups missing", finding.groups.isNotEmpty())
            assertTrue("threshold description missing", finding.thresholdDescription.isNotBlank())
        }
    }

    @Test
    fun `a breach names the contributing applications and their dates`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(listOf("s1", "s2", "s3"), rule.contributingApplicationIds)
        assertEquals(listOf(day(1), day(8), day(15)), rule.contributingDatesEpochMs)
    }

    @Test
    fun `engine wording never claims illegality`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
            ev("s3", day(15), listOf(p("3"))),
        )
        val result = evaluate(events)
        val text = (result.summary + result.ruleResults.joinToString(" ") {
            it.explanation + it.thresholdDescription + it.observedDescription
        }).lowercase()
        listOf("illegal", "unlawful", "unsafe", "prohibited by law", "non-compliant with law")
            .forEach { forbidden ->
                assertFalse("engine must not say '$forbidden'", text.contains(forbidden))
            }
        assertTrue(result.summary.startsWith("Resistance strategy warning"))
    }

    @Test
    fun `there is no opaque composite score anywhere in the result`() {
        val result = evaluate(listOf(ev("s1", day(1), listOf(p("3")))))
        // Every number in the result is a published threshold or an observed
        // count, each attached to a named rule.
        result.ruleResults.forEach { rule ->
            if (rule.threshold != null) {
                assertTrue(rule.thresholdDescription.isNotBlank())
                assertTrue(rule.sourceReference.isNotBlank())
            }
        }
    }

    @Test
    fun `severity is separate from rule status and carries no presentation detail`() {
        val events = listOf(
            ev("s1", day(1), listOf(p("3"))),
            ev("s2", day(8), listOf(p("3"))),
        )
        val rule = evaluate(events).rule("AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE")
        assertEquals(ResistanceRuleStatus.LIMIT_REACHED, rule.status)
        assertEquals(ResistanceSeverity.WARNING, rule.severity)
        // Severity is an enum of meanings, not colours.
        ResistanceSeverity.entries.forEach { severity ->
            assertFalse(severity.raw.contains("#"))
        }
    }

    // =======================================================================
    // Season handling
    // =======================================================================

    @Test
    fun `season identity spans the new year rather than resetting at 31 December`() {
        val julySpray = calendar.season(day(5))
        val februarySpray = calendar.season(day(230))
        assertEquals(julySpray.id, februarySpray.id)
        assertEquals("2026/27", julySpray.id)
    }

    @Test
    fun `a spray before the season start belongs to the previous season`() {
        val beforeStart = season.startEpochMs - 86_400_000L
        assertEquals("2025/26", calendar.season(beforeStart).id)
        assertEquals("2026/27", calendar.season(season.startEpochMs).id)
    }

    @Test
    fun `a custom vineyard season start is honoured`() {
        val aprilCalendar = ResistanceSeasonCalendar(startMonth = 4, startDay = 1)
        val marchSeason = aprilCalendar.season(aprilCalendar.seasonStarting(2026).startEpochMs - 86_400_000L)
        assertEquals("2025/26", marchSeason.id)
        assertEquals("2026/27", aprilCalendar.seasonStarting(2026).id)
    }

    @Test
    fun `no applications targeting the disease returns not applicable`() {
        val result = evaluate(emptyList())
        assertEquals(ResistanceEvaluationStatus.NOT_APPLICABLE, result.status)
        assertTrue(result.ruleResults.isEmpty())
        assertFalse(result.isCleanResult)
    }
}
