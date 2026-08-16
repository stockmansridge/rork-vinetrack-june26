package com.rork.vinetrack.data

import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceGroupCode
import com.rork.vinetrack.data.resistance.ResistanceGroupSelector
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistanceRuleKind
import com.rork.vinetrack.data.resistance.ResistanceRuleset
import com.rork.vinetrack.data.resistance.ResistanceRulesetRegistry
import com.rork.vinetrack.data.resistance.ResistanceRulesets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fidelity of the encoded CropLife Australia 2026 strategies to their published
 * source, plus the cross-platform parity assertions.
 *
 * Mirrored by iOS `ResistanceRulesetTests.swift`. Every expectation in this file
 * exists verbatim there; the two suites are the drift detector.
 */
class ResistanceRulesetTest {

    // -----------------------------------------------------------------------
    // Versioned source metadata
    // -----------------------------------------------------------------------

    @Test
    fun `powdery ruleset carries the published CropLife source metadata`() {
        val ruleset = ResistanceRulesets.powdery2026
        assertEquals("AU_GRAPE_POWDERY_2026_07_22", ruleset.id)
        assertEquals(ResistanceJurisdiction.AUSTRALIA, ruleset.jurisdiction)
        assertEquals(ResistanceCrop.GRAPE, ruleset.crop)
        assertEquals(ResistanceDisease.POWDERY_MILDEW, ruleset.disease)
        assertEquals("Grape - Powdery mildew", ruleset.strategyName)
        assertEquals("CropLife Australia", ruleset.sourceOrganisation)
        assertEquals("2026-07-22", ruleset.validFrom)
        assertEquals("2026.07.22", ruleset.rulesetVersion)
        assertTrue(ruleset.sourceReference.contains("croplife.org.au"))
    }

    @Test
    fun `downy ruleset carries the published CropLife source metadata`() {
        val ruleset = ResistanceRulesets.downy2026
        assertEquals("AU_GRAPE_DOWNY_2026_07_22", ruleset.id)
        assertEquals(ResistanceJurisdiction.AUSTRALIA, ruleset.jurisdiction)
        assertEquals(ResistanceDisease.DOWNY_MILDEW, ruleset.disease)
        assertEquals("Grape - Downy mildew", ruleset.strategyName)
        assertEquals("2026-07-22", ruleset.validFrom)
        assertEquals("2026.07.22", ruleset.rulesetVersion)
    }

    @Test
    fun `both 2026 rulesets are valid as at 22 July 2026`() {
        assertEquals("2026-07-22", ResistanceRulesets.CROPLIFE_2026_VALID_FROM)
        assertEquals(
            ResistanceRulesets.CROPLIFE_2026_VALID_FROM,
            ResistanceRulesets.powdery2026.validFrom,
        )
        assertEquals(
            ResistanceRulesets.CROPLIFE_2026_VALID_FROM,
            ResistanceRulesets.downy2026.validFrom,
        )
    }

    @Test
    fun `neither 2026 ruleset is marked superseded`() {
        assertFalse(ResistanceRulesets.powdery2026.isSuperseded)
        assertFalse(ResistanceRulesets.downy2026.isSuperseded)
    }

    // -----------------------------------------------------------------------
    // Jurisdiction selection
    // -----------------------------------------------------------------------

    @Test
    fun `registry selects the Australian grape rulesets`() {
        val registry = ResistanceRulesets.registry
        assertEquals(
            "AU_GRAPE_POWDERY_2026_07_22",
            registry.current(
                ResistanceJurisdiction.AUSTRALIA,
                ResistanceCrop.GRAPE,
                ResistanceDisease.POWDERY_MILDEW,
            )?.id,
        )
        assertEquals(
            "AU_GRAPE_DOWNY_2026_07_22",
            registry.current(
                ResistanceJurisdiction.AUSTRALIA,
                ResistanceCrop.GRAPE,
                ResistanceDisease.DOWNY_MILDEW,
            )?.id,
        )
    }

    @Test
    fun `registry has no ruleset for New Zealand`() {
        val registry = ResistanceRulesets.registry
        assertNull(
            registry.current(
                ResistanceJurisdiction.NEW_ZEALAND,
                ResistanceCrop.GRAPE,
                ResistanceDisease.POWDERY_MILDEW,
            ),
        )
        assertNull(
            registry.current(
                ResistanceJurisdiction.NEW_ZEALAND,
                ResistanceCrop.GRAPE,
                ResistanceDisease.DOWNY_MILDEW,
            ),
        )
    }

    @Test
    fun `registry has no ruleset for an unknown jurisdiction`() {
        assertNull(
            ResistanceRulesets.registry.current(
                ResistanceJurisdiction.UNKNOWN,
                ResistanceCrop.GRAPE,
                ResistanceDisease.POWDERY_MILDEW,
            ),
        )
    }

    @Test
    fun `vineyard country maps onto jurisdiction and never defaults to Australia`() {
        assertEquals(ResistanceJurisdiction.AUSTRALIA, ResistanceJurisdiction.fromCountryCode("AU"))
        assertEquals(ResistanceJurisdiction.AUSTRALIA, ResistanceJurisdiction.fromCountryCode("australia"))
        assertEquals(ResistanceJurisdiction.NEW_ZEALAND, ResistanceJurisdiction.fromCountryCode("NZ"))
        assertEquals(ResistanceJurisdiction.NEW_ZEALAND, ResistanceJurisdiction.fromCountryCode("New Zealand"))
        assertEquals(ResistanceJurisdiction.UNKNOWN, ResistanceJurisdiction.fromCountryCode(null))
        assertEquals(ResistanceJurisdiction.UNKNOWN, ResistanceJurisdiction.fromCountryCode(""))
        assertEquals(ResistanceJurisdiction.UNKNOWN, ResistanceJurisdiction.fromCountryCode("US"))
        assertEquals(ResistanceJurisdiction.UNKNOWN, ResistanceJurisdiction.fromCountryCode("FR"))
    }

    // -----------------------------------------------------------------------
    // Superseding architecture
    // -----------------------------------------------------------------------

    @Test
    fun `a future ruleset supersedes without deleting the 2026 definition`() {
        val future = ResistanceRulesets.powdery2026.copy(
            id = "AU_GRAPE_POWDERY_2027_07_20",
            validFrom = "2027-07-20",
            validFromEpochMs = ResistanceRulesets.CROPLIFE_2026_VALID_FROM_EPOCH_MS + 365L * 86_400_000L,
            rulesetVersion = "2027.07.20",
            supersedes = ResistanceRulesets.POWDERY_ID,
        )
        val retired = ResistanceRulesets.powdery2026.copy(supersededBy = future.id)
        val registry = ResistanceRulesetRegistry(listOf(retired, future, ResistanceRulesets.downy2026))

        // Current planning uses the newest non-superseded strategy.
        assertEquals(
            future.id,
            registry.current(
                ResistanceJurisdiction.AUSTRALIA,
                ResistanceCrop.GRAPE,
                ResistanceDisease.POWDERY_MILDEW,
            )?.id,
        )
        // The 2026 definition is retained, not deleted.
        assertNotNull(registry.byId(ResistanceRulesets.POWDERY_ID))
        assertTrue(registry.byId(ResistanceRulesets.POWDERY_ID)!!.isSuperseded)
    }

    @Test
    fun `historical reconstruction selects the ruleset in force at the time`() {
        val future = ResistanceRulesets.powdery2026.copy(
            id = "AU_GRAPE_POWDERY_2027_07_20",
            validFrom = "2027-07-20",
            validFromEpochMs = ResistanceRulesets.CROPLIFE_2026_VALID_FROM_EPOCH_MS + 365L * 86_400_000L,
            supersedes = ResistanceRulesets.POWDERY_ID,
        )
        val registry = ResistanceRulesetRegistry(
            listOf(ResistanceRulesets.powdery2026.copy(supersededBy = future.id), future),
        )
        // A spray in the 2026/27 season is explained by the 2026 strategy even
        // after 2027 supersedes it.
        val during2026 = ResistanceRulesets.CROPLIFE_2026_VALID_FROM_EPOCH_MS + 30L * 86_400_000L
        assertEquals(
            ResistanceRulesets.POWDERY_ID,
            registry.inForce(
                ResistanceJurisdiction.AUSTRALIA,
                ResistanceCrop.GRAPE,
                ResistanceDisease.POWDERY_MILDEW,
                during2026,
            )?.id,
        )
    }

    // -----------------------------------------------------------------------
    // Rule ID stability
    // -----------------------------------------------------------------------

    @Test
    fun `every rule id is unique within its ruleset`() {
        listOf(ResistanceRulesets.powdery2026, ResistanceRulesets.downy2026).forEach { ruleset ->
            val ids = ruleset.rules.map { it.id }
            assertEquals(
                "duplicate rule id in ${ruleset.id}",
                ids.size,
                ids.distinct().size,
            )
        }
    }

    @Test
    fun `every rule id is globally unique and systematically named`() {
        val all = ResistanceRulesets.registry.rulesets.flatMap { it.rules }.map { it.id }
        assertEquals(all.size, all.distinct().size)
        all.forEach { id ->
            assertTrue("$id must be namespaced by jurisdiction and crop", id.startsWith("AU_GRAPE_"))
            assertEquals("$id must be upper snake case", id.uppercase(), id)
        }
    }

    @Test
    fun `every rule cites a published clause and its verbatim text`() {
        ResistanceRulesets.registry.rulesets.flatMap { it.rules }.forEach { rule ->
            assertTrue("${rule.id} has no source reference", rule.sourceReference.isNotBlank())
            assertTrue("${rule.id} has no source text", rule.sourceText.length > 20)
        }
    }

    // -----------------------------------------------------------------------
    // Powdery: the exact published rule inventory
    // -----------------------------------------------------------------------

    @Test
    fun `powdery rule inventory matches the published strategy exactly`() {
        val expected = listOf(
            "AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE",
            "AU_GRAPE_POWDERY_FRAC11_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC11_MIXTURE_WHEN_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC13_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC13_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC19_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC19_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION",
            "AU_GRAPE_POWDERY_FRAC21_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP",
            "AU_GRAPE_POWDERY_FRAC3_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC3_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC50_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC50_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRAC5_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_PLUS_3_AND_7_PLUS_12_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON",
            "AU_GRAPE_POWDERY_FRAC7_MAX_FROM_TOTAL_TABLE",
            "AU_GRAPE_POWDERY_FRAC7_MIXTURE_WHEN_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRACU6_MAX_CONSECUTIVE",
            "AU_GRAPE_POWDERY_FRACU6_MAX_FROM_TOTAL_TABLE",
        )
        assertEquals(expected, ResistanceRulesets.powdery2026.rules.map { it.id }.sorted())
    }

    @Test
    fun `powdery groups 3 5 13 19 21 50 and U6 each carry a two-consecutive rule`() {
        listOf("FRAC3", "FRAC5", "FRAC13", "FRAC19", "FRAC21", "FRAC50", "FRACU6").forEach { fragment ->
            val rule = ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_${fragment}_MAX_CONSECUTIVE")
            assertNotNull("missing consecutive rule for $fragment", rule)
            assertEquals(
                ResistanceRuleKind.MaxConsecutiveApplications(2),
                rule!!.kind,
            )
            assertEquals("Guideline 4", rule.sourceReference)
            // Guideline 2: consecutive applications include from the end of one
            // season to the start of the next.
            assertTrue("$fragment consecutive rule must cross the season boundary", rule.crossSeason)
        }
    }

    @Test
    fun `powdery group 5 plus 3 is limited to one application`() {
        val rule = ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC5_PLUS_3_MAX_SEASON")
        assertNotNull(rule)
        assertEquals(ResistanceRuleKind.MaxApplicationsPerSeason(1), rule!!.kind)
        assertEquals("Guideline 3", rule.sourceReference)
        assertEquals(
            ResistanceGroupSelector.Coformulation(ResistanceGroupSignature.of("3", "5")),
            rule.selector,
        )
    }

    @Test
    fun `powdery groups 7 and 11 require mixtures only when used consecutively`() {
        listOf("FRAC7" to "7", "FRAC11" to "11").forEach { (fragment, code) ->
            val rule = ResistanceRulesets.powdery2026
                .rule("AU_GRAPE_POWDERY_${fragment}_MIXTURE_WHEN_CONSECUTIVE")
            assertNotNull(rule)
            assertEquals(ResistanceRuleKind.MixtureRequiredWhenConsecutive, rule!!.kind)
            assertEquals(ResistanceGroupSelector.ContainsGroup(code), rule.selector)
            assertEquals("Guideline 2", rule.sourceReference)
        }
    }

    @Test
    fun `powdery group 21 carries both a crop maximum and a percentage restriction`() {
        val crop = ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC21_MAX_PER_CROP")
        assertEquals(ResistanceRuleKind.MaxApplicationsPerCrop(3), crop!!.kind)
        val fraction = ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_FRAC21_MAX_FRACTION")
        assertEquals(ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 3), fraction!!.kind)
        assertEquals("Guideline 5", crop.sourceReference)
        assertEquals("Guideline 5", fraction.sourceReference)
    }

    @Test
    fun `powdery preventative-use guidance is encoded`() {
        val rule = ResistanceRulesets.powdery2026.rule("AU_GRAPE_POWDERY_ALL_PREVENTATIVE_USE")
        assertNotNull(rule)
        assertEquals(ResistanceRuleKind.PreventativeApplicationGuidance, rule!!.kind)
        assertEquals("Apply all these fungicides preventatively.", rule.sourceText)
    }

    @Test
    fun `powdery lists all thirteen published groups and combinations`() {
        val names = ResistanceRulesets.powdery2026.groups.map { it.displayName }
        assertEquals(
            listOf(
                "Group 11", "Group 11 + 3", "Group 13", "Group 19", "Group 21", "Group 3",
                "Group 5", "Group 5 + 3", "Group 50 (U8)", "Group 7", "Group 7 + 12",
                "Group 7 + 3", "Group U6",
            ),
            names.sorted(),
        )
    }

    // -----------------------------------------------------------------------
    // Powdery: the maximum-use table, cell for cell
    // -----------------------------------------------------------------------

    @Test
    fun `powdery maximum-use table reproduces every published cell`() {
        val table = ResistanceRulesets.powderyMaxUseTable
        // Published column order:
        // 3 | 5 | 5+3, 7+12 | 7 (inc. 7+3) | 11 (inc. 11+3) | 13 | 19 | 21 | 50 (U8) | U6
        val columns = listOf("3", "5", "5+3,7+12", "7", "11", "13", "19", "21", "50", "U6")
        assertEquals(columns, table.columns.map { it.key })

        val expected = mapOf(
            1 to listOf(1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
            2 to listOf(2, 1, 1, 1, 1, 2, 2, 1, 1, 1),
            3 to listOf(2, 2, 1, 1, 2, 2, 2, 1, 1, 1),
            4 to listOf(2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            5 to listOf(2, 2, 1, 1, 2, 2, 2, 1, 2, 2),
            6 to listOf(3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            7 to listOf(3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            8 to listOf(3, 3, 1, 2, 2, 3, 3, 2, 2, 2),
            9 to listOf(3, 3, 1, 2, 2, 3, 3, 3, 2, 2),
        )
        assertEquals(9, table.rows.size)
        expected.forEach { (total, maxima) ->
            columns.forEachIndexed { index, key ->
                assertEquals(
                    "total=$total column=$key",
                    maxima[index],
                    table.maxFor(key, total),
                )
            }
        }
    }

    @Test
    fun `powdery table final row is open-ended and governs above nine sprays`() {
        val table = ResistanceRulesets.powderyMaxUseTable
        assertTrue(table.rows.last().isOrMore)
        assertEquals(9, table.rows.last().totalSprays)
        // 9+ means 9 or more: 12 and 20 sprays use the same published ceilings.
        listOf(9, 10, 12, 20, 40).forEach { total ->
            assertEquals(3, table.maxFor("3", total))
            assertEquals(2, table.maxFor("11", total))
            assertEquals(3, table.maxFor("21", total))
            assertEquals(1, table.maxFor("5+3,7+12", total))
        }
    }

    @Test
    fun `powdery table is silent when no sprays target the disease`() {
        assertNull(ResistanceRulesets.powderyMaxUseTable.maxFor("3", 0))
        assertNull(ResistanceRulesets.powderyMaxUseTable.maxFor("3", -1))
    }

    @Test
    fun `powdery table group 5 plus 3 column never exceeds one application`() {
        // Reinforces Guideline 3 from the table side.
        (1..15).forEach { total ->
            assertEquals(1, ResistanceRulesets.powderyMaxUseTable.maxFor("5+3,7+12", total))
        }
    }

    @Test
    fun `powdery table has a rule for every published column`() {
        val columnKeys = ResistanceRulesets.powderyMaxUseTable.columns.map { it.key }.toSet()
        val ruleColumnKeys = ResistanceRulesets.powdery2026.rules
            .mapNotNull { (it.kind as? ResistanceRuleKind.MaxFromTotalSprayCountTable)?.columnKey }
            .toSet()
        assertEquals(columnKeys, ruleColumnKeys)
    }

    // -----------------------------------------------------------------------
    // Downy: the exact published rule inventory
    // -----------------------------------------------------------------------

    @Test
    fun `downy rule inventory matches the published strategy exactly`() {
        val expected = listOf(
            "AU_GRAPE_DOWNY_FRAC11_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC21_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION",
            "AU_GRAPE_DOWNY_FRAC40_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING",
            "AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE",
            "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING",
            "AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED",
            "AU_GRAPE_DOWNY_FRAC49_NO_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE",
            "AU_GRAPE_DOWNY_FRAC4_MAX_SEASON",
            "AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED",
            "AU_GRAPE_DOWNY_PROGRAM_PREVENTATIVE_START",
        )
        assertEquals(expected, ResistanceRulesets.downy2026.rules.map { it.id }.sorted())
    }

    @Test
    fun `downy group 4 must always be mixed and is capped at two consecutive and four per season`() {
        val ruleset = ResistanceRulesets.downy2026
        assertEquals(
            ResistanceRuleKind.MixtureRequired,
            ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MIXTURE_REQUIRED")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxConsecutiveApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MAX_CONSECUTIVE")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(4),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC4_MAX_SEASON")!!.kind,
        )
    }

    @Test
    fun `downy group 11 must not be consecutive and is capped at two per season`() {
        val ruleset = ResistanceRulesets.downy2026
        val consecutive = ruleset.rule("AU_GRAPE_DOWNY_FRAC11_NO_CONSECUTIVE")!!
        assertEquals(ResistanceRuleKind.NoConsecutiveApplications, consecutive.kind)
        assertEquals("Guideline 6", consecutive.sourceReference)
        // "including mixture formulations" -> a component-group selector, so 11+3
        // counts.
        assertEquals(ResistanceGroupSelector.ContainsGroup("11"), consecutive.selector)
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC11_MAX_SEASON")!!.kind,
        )
    }

    @Test
    fun `downy group 21 is capped at three per season and two consecutive`() {
        val ruleset = ResistanceRulesets.downy2026
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(3),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC21_MAX_SEASON")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxConsecutiveApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC21_MAX_CONSECUTIVE")!!.kind,
        )
    }

    @Test
    fun `downy group 40 carries consecutive, fifty percent, solo, season and last-spray rules`() {
        val ruleset = ResistanceRulesets.downy2026
        assertEquals(
            ResistanceRuleKind.MaxConsecutiveApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_CONSECUTIVE")!!.kind,
        )
        // Table footnote * refers to point 8: Group 40 at 50%.
        assertEquals(
            ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_FRACTION")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxSoloApplicationsPerSeason(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_SOLO_SEASON")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(4),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_MAX_SEASON")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.NotLastSprayOfSeason,
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_NOT_LAST_SPRAY")!!.kind,
        )
    }

    @Test
    fun `downy group 40 plus 49 is a distinct combination with a thirty-three percent cap`() {
        val ruleset = ResistanceRulesets.downy2026
        val signature = ResistanceGroupSignature.of("40", "49")
        val fraction = ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_FRACTION")!!
        // Table footnote ** refers to point 3: Group 40+49 at 33%, NOT 50%.
        assertEquals(ResistanceRuleKind.MaxFractionOfDiseaseSprays(1, 3), fraction.kind)
        assertEquals(ResistanceGroupSelector.Coformulation(signature), fraction.selector)
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MAX_SEASON")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MinInterveningDifferentGroupApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_MIN_INTERVENING")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.NoConsecutiveApplications,
            ruleset.rule("AU_GRAPE_DOWNY_FRAC40_PLUS_49_NO_CONSECUTIVE")!!.kind,
        )
    }

    @Test
    fun `downy group 45 plus 40 is a distinct combination capped at two per season`() {
        val ruleset = ResistanceRulesets.downy2026
        val signature = ResistanceGroupSignature.of("45", "40")
        val season = ruleset.rule("AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_SEASON")!!
        assertEquals(ResistanceRuleKind.MaxApplicationsPerSeason(2), season.kind)
        assertEquals(ResistanceGroupSelector.Coformulation(signature), season.selector)
        assertEquals(
            ResistanceRuleKind.MaxConsecutiveApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC45_PLUS_40_MAX_CONSECUTIVE")!!.kind,
        )
    }

    @Test
    fun `downy group 49 carries mixture, season, one-in-three and intervening rules`() {
        val ruleset = ResistanceRulesets.downy2026
        assertEquals(
            ResistanceRuleKind.MixtureRequired,
            ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MIXTURE_REQUIRED")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MaxApplicationsPerSeason(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MAX_SEASON")!!.kind,
        )
        // One-in-three is a SPACING rule, deliberately not a 33% fraction.
        assertEquals(
            ResistanceRuleKind.MaxOneInEveryNSprays(3),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MAX_ONE_IN_THREE")!!.kind,
        )
        assertEquals(
            ResistanceRuleKind.MinInterveningDifferentGroupApplications(2),
            ruleset.rule("AU_GRAPE_DOWNY_FRAC49_MIN_INTERVENING")!!.kind,
        )
    }

    @Test
    fun `downy lists all eight published groups and combinations`() {
        val names = ResistanceRulesets.downy2026.groups.map { it.displayName }
        assertEquals(
            listOf(
                "Group 11", "Group 11 + 3", "Group 21", "Group 4", "Group 40",
                "Group 40 + 49", "Group 45 + 40", "Group 49",
            ),
            names.sorted(),
        )
    }

    @Test
    fun `downy has no total-spray-count table because the published strategy has none`() {
        assertNull(ResistanceRulesets.downy2026.maxUseTable)
        assertNotNull(ResistanceRulesets.powdery2026.maxUseTable)
    }

    @Test
    fun `source ambiguities are recorded rather than silently resolved`() {
        val notes = ResistanceRulesets.downy2026.sourceNotes.joinToString(" ")
        assertTrue(notes.contains("SOURCE AMBIGUITY"))
        // The 33% vs 50% Group 40 conflict between Guideline 3 and Guideline 8.
        assertTrue(notes.contains("33%") && notes.contains("50%"))
        // The Group 45+40 "solo: None" cell with no supporting guideline.
        assertTrue(notes.contains("45+40"))
    }

    // -----------------------------------------------------------------------
    // Group code canonicalisation
    // -----------------------------------------------------------------------

    @Test
    fun `group codes normalise across the spellings that reach the engine`() {
        assertEquals("11", ResistanceGroupCode.normalize("11"))
        assertEquals("11", ResistanceGroupCode.normalize(" 11 "))
        assertEquals("11", ResistanceGroupCode.normalize("Group 11"))
        assertEquals("11", ResistanceGroupCode.normalize("FRAC 11"))
        assertEquals("11", ResistanceGroupCode.normalize("frac11"))
        assertEquals("U6", ResistanceGroupCode.normalize("u6"))
        assertNull(ResistanceGroupCode.normalize(null))
        assertNull(ResistanceGroupCode.normalize(""))
        assertNull(ResistanceGroupCode.normalize("   "))
    }

    @Test
    fun `legacy code U8 normalises to Group 50 so both spellings meet`() {
        // CropLife prints "Group 50 (U8)". A product label may print either. If
        // they did not collapse onto one key, a rotation could look compliant
        // purely because the two spellings never met.
        assertEquals("50", ResistanceGroupCode.normalize("U8"))
        assertEquals("50", ResistanceGroupCode.normalize("Group U8"))
        assertEquals("50", ResistanceGroupCode.normalize("50 (U8)"))
        assertEquals("50", ResistanceGroupCode.normalize("50"))
    }

    @Test
    fun `signatures are canonically ordered so recording order never matters`() {
        assertEquals("3+11", ResistanceGroupSignature.of("11", "3").key)
        assertEquals("3+11", ResistanceGroupSignature.of("3", "11").key)
        assertEquals("40+49", ResistanceGroupSignature.of("49", "40").key)
        assertEquals("40+45", ResistanceGroupSignature.of("45", "40").key)
        // Numeric groups first, alphanumeric after.
        assertEquals("3+U6", ResistanceGroupSignature.of("U6", "3").key)
    }

    @Test
    fun `signatures de-duplicate repeated codes`() {
        val signature = ResistanceGroupSignature.of("11", "11", "Group 11")
        assertEquals(listOf("11"), signature.codes)
        assertFalse(signature.isCoformulation)
    }

    // -----------------------------------------------------------------------
    // Cross-platform parity
    // -----------------------------------------------------------------------

    @Test
    fun `ruleset fingerprints are stable and deterministic`() {
        val powdery = ResistanceRulesets.powdery2026
        assertEquals(powdery.fingerprint(), powdery.fingerprint())
        assertEquals(16, powdery.fingerprint().length)
        assertTrue(powdery.fingerprint().all { it.isDigit() || it in 'a'..'f' })
    }

    @Test
    fun `fingerprints differ between the two strategies`() {
        assertFalse(
            ResistanceRulesets.powdery2026.fingerprint() ==
                ResistanceRulesets.downy2026.fingerprint(),
        )
    }

    @Test
    fun `fingerprint changes when any threshold changes`() {
        val original = ResistanceRulesets.downy2026
        val tampered = original.copy(
            rules = original.rules.map { rule ->
                if (rule.id == "AU_GRAPE_DOWNY_FRAC49_MAX_SEASON") {
                    rule.copy(kind = ResistanceRuleKind.MaxApplicationsPerSeason(3))
                } else {
                    rule
                }
            },
        )
        assertFalse(original.fingerprint() == tampered.fingerprint())
    }

    @Test
    fun `fingerprint changes when a table cell changes`() {
        val original = ResistanceRulesets.powdery2026
        val table = ResistanceRulesets.powderyMaxUseTable
        val tamperedRows = table.rows.map { row ->
            if (row.totalSprays == 3) {
                row.copy(maxByColumn = row.maxByColumn + ("3" to 3))
            } else {
                row
            }
        }
        val tampered = original.copy(maxUseTable = table.copy(rows = tamperedRows))
        assertFalse(original.fingerprint() == tampered.fingerprint())
    }

    @Test
    fun `fingerprint ignores rule declaration order`() {
        val original = ResistanceRulesets.downy2026
        val shuffled = original.copy(rules = original.rules.reversed())
        assertEquals(original.fingerprint(), shuffled.fingerprint())
    }

    @Test
    fun `fnv1a digest matches the shared reference vectors used by iOS`() {
        // Fixed vectors so a divergence in the hash arithmetic itself is caught,
        // rather than being mistaken for a ruleset difference.
        assertEquals(
            ResistanceRuleset.fnv1a64Hex(""),
            ResistanceRuleset.fnv1a64Hex(""),
        )
        assertEquals("af63dc4c8601ec8c", ResistanceRuleset.fnv1a64Hex("a"))
        assertEquals("cbf29ce484222325", ResistanceRuleset.fnv1a64Hex(""))
        assertEquals("85944171f73967e8", ResistanceRuleset.fnv1a64Hex("foobar"))
    }

    @Test
    fun `canonical parity fingerprints are recorded for both platforms`() {
        // These constants are asserted identically in iOS
        // `ResistanceRulesetTests.swift`. If either platform's encoding of the
        // 2026 strategies drifts, that platform's test fails here rather than a
        // grower discovering it as contradictory advice on two phones.
        assertEquals(
            ResistanceParityFixture.POWDERY_2026_FINGERPRINT,
            ResistanceRulesets.powdery2026.fingerprint(),
        )
        assertEquals(
            ResistanceParityFixture.DOWNY_2026_FINGERPRINT,
            ResistanceRulesets.downy2026.fingerprint(),
        )
    }
}

/**
 * Canonical fingerprints of the CropLife Australia 2026 rulesets.
 *
 * Duplicated verbatim in iOS `ResistanceRulesetTests.swift`. Regenerate BOTH
 * only when a genuine strategy revision is encoded, never to make a red test go
 * green.
 */
object ResistanceParityFixture {
    const val POWDERY_2026_FINGERPRINT: String = "14148a7c4d4682a1"
    const val DOWNY_2026_FINGERPRINT: String = "3bcc71d77397e116"
}
