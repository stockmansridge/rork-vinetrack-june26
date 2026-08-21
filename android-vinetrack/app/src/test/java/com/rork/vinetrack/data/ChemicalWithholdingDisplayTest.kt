package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalWithholdingDisplay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
