package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Herbicide classification v2 — current numeric groups + legacy equivalence.
 *
 * ## What this pins
 *
 * Australia replaced the alphabetical herbicide mode-of-action codes with the
 * globally aligned NUMERIC system. Labels began carrying numbers in 2022 and the
 * transition completed in 2024, so the code a grower reads on a current
 * Australian herbicide label is "Group 14", not "Group E" and not "Group G".
 *
 * The table held the OLD global HRAC letters, which produced a FALSE CONFLICT on
 * every herbicide: the label and the lookup said the same thing in two different
 * alphabets and the app reported them as sources that disagreed. A false alarm
 * about a resistance group is the most expensive kind of wrong answer this app
 * can give.
 *
 * These assertions are deliberately written against the RULE rather than one
 * product, and are mirrored test-for-test in the `chemical-info-lookup` edge
 * function (`activity_groups_v2_test.ts`) and on iOS
 * (`AuthoritativeActivityGroupsV2Tests.swift`). All three must agree — the whole
 * point is that a product's activity group has one answer, not three.
 */
class AuthoritativeActivityGroupsV2Test {

    private fun hrac(code: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.HRAC, code, null)

    private fun reconcile(active: String, code: String) =
        AuthoritativeActivityGroups.reconcile(
            activeName = active,
            extracted = hrac(code),
            extractedSource = ChemicalDataSourceKind.AI_INTERPRETATION,
        )

    /** Every herbicide the shared table classifies, by active name. */
    private val herbicides: List<String>
        get() = AuthoritativeActivityGroups.HERBICIDE_ACTIVE_NAMES

    @Test
    fun `table version is bumped so a re-verification can tell which revision judged a product`() {
        assertEquals(2, AuthoritativeActivityGroups.TABLE_VERSION)
    }

    @Test
    fun `every herbicide classifies to a CURRENT numeric group - no letters survive`() {
        assertTrue("the table must still classify herbicides", herbicides.isNotEmpty())
        for (active in herbicides) {
            val code = AuthoritativeActivityGroups.groupForActive(active)?.code
            assertNotNull(active, code)
            assertTrue(
                "$active still carries a legacy alphabetical code \"$code\" — " +
                    "current Australian labels print numbers",
                code!!.all { it.isDigit() },
            )
        }
    }

    @Test
    fun `every herbicide agrees with each of its own legacy codes, and none is served as the answer`() {
        for (active in herbicides) {
            val current = AuthoritativeActivityGroups.groupForActive(active)!!.code
            val legacy = AuthoritativeActivityGroups.legacyCodesForActive(active)
            assertTrue("$active records no legacy code to reconcile against", legacy.isNotEmpty())

            for (code in legacy) {
                val outcome = reconcile(active, code)
                assertNull(
                    "$active: legacy code \"$code\" must not read as a source disagreement",
                    outcome.conflict,
                )
                // The CURRENT group is what a grower sees — never the historical code.
                assertEquals(
                    "$active: the current numeric group must be served",
                    current,
                    outcome.group?.code,
                )
            }
        }
    }

    @Test
    fun `the current value agrees with itself, however the source decorates it`() {
        for (active in herbicides) {
            val current = AuthoritativeActivityGroups.groupForActive(active)!!.code
            for (written in listOf(current, "Group $current", "$current (whatever)")) {
                assertNull(
                    "$active: \"$written\" is the current group written differently, not a conflict",
                    reconcile(active, written).conflict,
                )
            }
        }
    }

    @Test
    fun `a genuinely different group still conflicts - the check is not simply switched off`() {
        for (active in herbicides) {
            val current = AuthoritativeActivityGroups.groupForActive(active)!!.code
            val wrong = if (current == "2") "9" else "2"
            if (AuthoritativeActivityGroups.legacyCodesForActive(active).contains(wrong)) continue

            val outcome = reconcile(active, wrong)
            assertNotNull(
                "$active: group $wrong is a real disagreement and must be reported",
                outcome.conflict,
            )
            assertEquals(
                "the authoritative group is served even while the conflict stands",
                current,
                outcome.group?.code,
            )
        }
    }

    @Test
    fun `a PPO inhibitor is Group 14, and its legacy E and G codes raise no conflict`() {
        // The two legacy alphabets disagree with each other about the letter:
        // "E" was PPO globally, "G" was PPO in Australia. Both mean Group 14,
        // which is exactly why equivalence is decided per ACTIVE, not per letter.
        val ppo = herbicides.filter {
            AuthoritativeActivityGroups.groupForActive(it)?.code == "14"
        }
        assertTrue("the table must classify PPO inhibitors", ppo.isNotEmpty())

        for (active in ppo) {
            for (legacy in listOf("E", "G", "Group E", "HRAC E")) {
                assertNull(
                    "$active: legacy \"$legacy\" must not create a Group 14-versus-letter conflict",
                    reconcile(active, legacy).conflict,
                )
            }
        }
    }

    @Test
    fun `legacy letters are not decodable across actives - equivalence never leaks between chemistries`() {
        // "E" is a legacy code for flumioxazin (PPO / 14). It is NOT a legacy
        // code for an ALS inhibitor, so offering it there is still a real
        // disagreement. A per-LETTER mapping would silently accept it.
        val als = herbicides.first { AuthoritativeActivityGroups.groupForActive(it)?.code == "2" }

        assertTrue(
            "an ALS inhibitor must not inherit a PPO inhibitor's legacy letter",
            !AuthoritativeActivityGroups.legacyCodesForActive(als).contains("E"),
        )
        assertNotNull(
            "a legacy letter belonging to another chemistry is a genuine conflict",
            reconcile(als, "E").conflict,
        )
    }

    @Test
    fun `equivalence requires the same scheme - FRAC 14 is not HRAC 14`() {
        assertTrue(
            "a bare number is meaningless without its scheme",
            !AuthoritativeActivityGroups.groupsAreEquivalent(
                activeName = "flumioxazin",
                a = hrac("14"),
                b = ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, "14", null),
            ),
        )
    }

    @Test
    fun `a formulation suffix inherits both the current group and its legacy codes`() {
        assertEquals(
            "9",
            AuthoritativeActivityGroups.groupForActive("Glyphosate isopropylamine salt")?.code,
        )
        assertTrue(
            "a salt form must reconcile against its parent's legacy codes too",
            AuthoritativeActivityGroups
                .legacyCodesForActive("Glyphosate isopropylamine salt")
                .contains("G"),
        )
        assertNull(
            "the old Australian letter for glyphosate is not a disagreement",
            reconcile("Glyphosate isopropylamine salt", "M").conflict,
        )
    }
}
