package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalWithholdingDisplay
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The withholding-period display rule (P3A) — the Android mirror of the iOS
 * `ChemicalWithholdingDisplayTests`.
 *
 * The resolver only ever parses a label's "NOT REQUIRED WHEN USED AS
 * DIRECTED" statement to 0 days — it never derives 0 from anything else. So
 * the friendly wording may appear ONLY when that label evidence is present:
 * either the use's own verbatim statements carry the phrase, or the payload
 * cites the manufacturer's approved label as a source. Every other value
 * renders exactly as before, and a missing value stays missing.
 */
class ChemicalWithholdingDisplayTest {

    // ---- Label-backed zero (Sprayseal 80160) ----

    @Test
    fun labelSourcedZeroReadsNotRequired() {
        // Sprayseal 80160: WHP "NOT REQUIRED WHEN USED AS DIRECTED" is served
        // as 0 days with manufacturer_label provenance end to end.
        assertEquals(
            "Not required when used as directed",
            ChemicalWithholdingDisplay.text(
                days = 0,
                restrictions = "Shake or stir container well before use.",
                hasManufacturerLabelSource = true,
            ),
        )
    }

    @Test
    fun cropScopedNotRequiredWordingReadsNotRequired() {
        // A crop-scoped label statement carries the phrase verbatim inside the
        // use's own restrictions, even without checking the source list.
        assertEquals(
            "Not required when used as directed",
            ChemicalWithholdingDisplay.text(
                days = 0,
                restrictions = "ALMONDS: NOT REQUIRED WHEN USED AS DIRECTED.",
                hasManufacturerLabelSource = false,
            ),
        )
    }

    // ---- Zero without label evidence stays a plain count ----

    @Test
    fun unevidencedZeroStaysZeroDays() {
        // An operator-typed manual zero has no label wording behind it: the
        // friendly wording would be fabricated evidence.
        assertEquals(
            "0 days",
            ChemicalWithholdingDisplay.text(
                days = 0,
                restrictions = null,
                hasManufacturerLabelSource = false,
            ),
        )
        assertEquals(
            "0 days",
            ChemicalWithholdingDisplay.text(
                days = 0,
                restrictions = "Shake well before use.",
                hasManufacturerLabelSource = false,
            ),
        )
    }

    // ---- Stated counts are never rewritten (Custodia Forte 91636) ----

    @Test
    fun statedCountStaysCountEvenWithLabelSource() {
        // Custodia Forte's 28-day grape WHP stays 28 days, label source or not.
        assertEquals(
            "28 days",
            ChemicalWithholdingDisplay.text(
                days = 28,
                restrictions = "DO NOT apply more than 2 consecutive sprays.",
                hasManufacturerLabelSource = true,
            ),
        )
    }

    @Test
    fun phraseNeverRewritesAStatedCount() {
        // The phrase appearing in restrictions cannot zero out a real count —
        // the wording is only ever chosen FOR a served zero.
        assertEquals(
            "14 days",
            ChemicalWithholdingDisplay.text(
                days = 14,
                restrictions = "WINE GRAPES: NOT REQUIRED WHEN USED AS DIRECTED for export parcels.",
                hasManufacturerLabelSource = true,
            ),
        )
    }

    // ---- Missing stays missing ----

    @Test
    fun missingStaysMissing() {
        // An unresolved withholding period is never invented, whatever the
        // wording or sources say.
        assertNull(
            ChemicalWithholdingDisplay.text(
                days = null,
                restrictions = "NOT REQUIRED WHEN USED AS DIRECTED.",
                hasManufacturerLabelSource = true,
            ),
        )
    }

    // ---- A6: rows are always drawn — unresolved reads as Not stated ----

    @Test
    fun unresolvedWhpDisplaysAsNotStated() {
        // The row is still drawn: a hidden row reads as "no restriction",
        // while "Not stated" reads as "go and check".
        assertEquals(
            "Not stated",
            ChemicalWithholdingDisplay.display(
                days = null,
                restrictions = null,
                hasManufacturerLabelSource = false,
            ),
        )
    }

    @Test
    fun reEntryHasThreeAnswers() {
        // A countable period...
        assertEquals("24 hours", ChemicalWithholdingDisplay.reEntrySummary(24, null))
        assertEquals("1 hour", ChemicalWithholdingDisplay.reEntrySummary(1, null))
        // ...the label's own verbatim condition (never converted to hours)...
        assertEquals(
            "Do not enter until the spray has dried",
            ChemicalWithholdingDisplay.reEntrySummary(null, "Do not enter until the spray has dried"),
        )
        // ...or silence, which reads as unresolved — never as "no restriction".
        assertEquals("Not stated on label", ChemicalWithholdingDisplay.reEntrySummary(null, null))
        assertEquals("Not stated on label", ChemicalWithholdingDisplay.reEntrySummary(null, "   "))
    }

    @Test
    fun reEntryStatedGatesTheProvenanceBadge() {
        // Provenance capsules render only beside STATED values.
        assertTrue(ChemicalWithholdingDisplay.reEntryIsStated(24, null))
        assertTrue(ChemicalWithholdingDisplay.reEntryIsStated(null, "until dry"))
        assertFalse(ChemicalWithholdingDisplay.reEntryIsStated(null, null))
        assertFalse(ChemicalWithholdingDisplay.reEntryIsStated(null, " "))
    }

    @Test
    fun reEntryStatementDecodesFromTheSharedWire() {
        // iOS writes `re_entry_statement` when a label states a binding
        // re-entry rule without a countable period; Android must read the
        // SAME row identically (P4 cross-platform parity).
        val json = Json { ignoreUnknownKeys = true }
        val use = json.decodeFromString(
            ChemicalRegisteredUse.serializer(),
            """{"crop":"Grapes","target_raw":"Powdery mildew",""" +
                """"re_entry_statement":"Do not enter until the spray has dried"}""",
        )
        assertEquals("Do not enter until the spray has dried", use.reEntryStatement)
        assertNull(use.reEntryPeriodHours)
    }
}
