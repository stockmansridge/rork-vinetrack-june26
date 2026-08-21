package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalProvenanceBadge
import com.rork.vinetrack.data.chemical.ChemicalProvenanceTier
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalUseProvenanceFact
import com.rork.vinetrack.data.chemical.ChemicalUseProvenancePlan
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.provenancePlan
import com.rork.vinetrack.data.chemical.uniformRatesBadge
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3B — provenance preservation through the Saved Chemical record, mirroring
 * the iOS `ChemicalProvenancePersistenceTests`.
 *
 * The server records `field_provenance` (top level) and per-use `provenance`
 * maps. Android must decode them, persist them, and re-encode them without
 * loss — while records saved before provenance existed keep decoding with
 * none, and nothing on device ever derives, upgrades or invents a tier. The
 * per-use maps ride inside the `registered_uses` JSONB column, so they are
 * exercised through the actual SavedChemical row round-trip; the top-level
 * map lives on the intelligence model exactly as it does on iOS.
 */
class ChemicalProvenancePersistenceTest {

    /** Mirrors `SupabaseClient.json` so the round-trip is the real wire shape. */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
        coerceInputValues = true
    }

    private fun decodeLookup(raw: String): ChemicalInfoService.ChemicalStructuredLookup =
        json.decodeFromString(raw)

    private fun roundTrip(chemical: SavedChemical): SavedChemical =
        json.decodeFromString(json.encodeToString(chemical))

    private fun savedChemical(
        name: String,
        intel: ChemicalIntelligence,
    ): SavedChemical = SavedChemical(
        id = "11111111-1111-1111-1111-111111111111",
        vineyardId = "22222222-2222-2222-2222-222222222222",
        name = name,
        activeIngredients = intel.activeIngredients,
        registeredUses = intel.registeredUses,
        verificationSources = intel.verification.sources,
    )

    // ---- Sprayseal 80160: label-backed rate + WHP survive save/reopen ----

    @Test
    fun spraysealKeepsManufacturerLabelProvenanceThroughSaveReopen() {
        val lookup = decodeLookup(
            """
            {
              "product_name": "Sprayseal",
              "product_category": "other",
              "registered_uses": [
                {
                  "crop": "All crops",
                  "target_raw": "Pruning wound dressing",
                  "rates": [
                    { "label": "General", "basis": "per_100_litres", "value": 30, "unit": "mL" }
                  ],
                  "withholding_period_days": 0,
                  "restrictions": "NOT REQUIRED WHEN USED AS DIRECTED.",
                  "provenance": {
                    "claim": "manufacturer_label",
                    "rates": "manufacturer_label",
                    "withholding_period": "manufacturer_label",
                    "restrictions": "manufacturer_label"
                  }
                }
              ],
              "field_provenance": {
                "registered_uses": "manufacturer_label",
                "label_rates": "manufacturer_label",
                "withholding_periods": "manufacturer_label",
                "restrictions": "manufacturer_label",
                "registration": "official_register"
              },
              "schema_version": 1,
              "activity_group_table_version": 1
            }
            """.trimIndent(),
        )
        val intel = lookup.intelligence()
        assertEquals("manufacturer_label", intel.fieldProvenance?.get("label_rates"))
        assertEquals("manufacturer_label", intel.fieldProvenance?.get("withholding_periods"))
        assertEquals("official_register", intel.fieldProvenance?.get("registration"))
        assertEquals("manufacturer_label", intel.registeredUses.first().provenance?.get("rates"))

        val reopened = roundTrip(savedChemical("Sprayseal", intel))
        val use = reopened.registeredUses!!.first()

        assertEquals(0, use.withholdingPeriodDays)
        // Sprayseal's label rate stays exactly 30 mL/100 L.
        assertEquals("30 mL/100 L", use.rates.first().displayRate)
        assertEquals("manufacturer_label", use.provenance?.get("rates"))
        assertEquals("manufacturer_label", use.provenance?.get("withholding_period"))
        assertEquals("manufacturer_label", use.provenance?.get("claim"))
        // The reconstructed intelligence reads the same stored provenance.
        assertEquals(
            "manufacturer_label",
            reopened.storedIntelligence!!.registeredUses.first().provenance?.get("withholding_period"),
        )
    }

    // ---- Custodia Forte: per-use provenance retained, values unchanged ----

    @Test
    fun custodiaKeepsPerUseProvenanceThroughSaveReopen() {
        val labelProvenance = mapOf(
            "claim" to "manufacturer_label",
            "rates" to "manufacturer_label",
            "withholding_period" to "manufacturer_label",
            "re_entry" to "manufacturer_label",
            "restrictions" to "manufacturer_label",
        )
        val lookup = decodeLookup(
            """
            {
              "product_name": "Custodia Forte",
              "product_category": "fungicide",
              "registered_uses": [
                {
                  "crop": "Grapes",
                  "target_raw": "Powdery mildew",
                  "rates": [
                    { "label": "", "basis": "range_per_100_litres", "min_value": 40, "max_value": 50, "unit": "mL" }
                  ],
                  "withholding_period_days": 28,
                  "re_entry_period_hours": 24,
                  "restrictions": "DO NOT apply more than 2 consecutive sprays.",
                  "provenance": {
                    "claim": "manufacturer_label",
                    "rates": "manufacturer_label",
                    "withholding_period": "manufacturer_label",
                    "re_entry": "manufacturer_label",
                    "restrictions": "manufacturer_label"
                  }
                },
                {
                  "crop": "Almonds",
                  "target_raw": "Rust",
                  "withholding_period_days": 14,
                  "provenance": {
                    "claim": "manufacturer_label",
                    "withholding_period": "ai_interpretation"
                  }
                }
              ]
            }
            """.trimIndent(),
        )
        val reopened = roundTrip(savedChemical("Custodia Forte", lookup.intelligence()))
        val uses = reopened.registeredUses!!

        assertEquals(2, uses.size)
        // Rate RANGE and the 28-day WHP stay exactly what the label said.
        assertEquals(28, uses[0].withholdingPeriodDays)
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_100_LITRES, uses[0].rates.first().basis)
        assertEquals("40–50 mL/100 L", uses[0].rates.first().displayRate)
        assertEquals(labelProvenance, uses[0].provenance)
        // The AI-carried WHP on the second claim stays exactly what it was:
        // present, and honestly non-authoritative.
        assertEquals(14, uses[1].withholdingPeriodDays)
        assertEquals("ai_interpretation", uses[1].provenance?.get("withholding_period"))
    }

    // ---- Re-verify: provenance survives both outcomes ----

    @Test
    fun reverifyAcceptCarriesTheLookupProvenanceIntoTheStoredRow() {
        val current = ChemicalIntelligence(
            registeredUses = listOf(
                ChemicalRegisteredUse(crop = "Grapes", targetRaw = "Powdery mildew", withholdingPeriodDays = 21),
            ),
            productCategory = "fungicide",
        )
        val candidateUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Powdery mildew",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 40.0, unit = "mL")),
            withholdingPeriodDays = 28,
            restrictions = "DO NOT graze.",
            provenance = mapOf(
                "rates" to "manufacturer_label",
                "withholding_period" to "manufacturer_label",
                "restrictions" to "manufacturer_label",
            ),
        )
        val candidate = ChemicalIntelligence(
            registeredUses = listOf(candidateUse),
            fieldProvenance = mapOf("withholding_periods" to "manufacturer_label"),
            verification = ChemicalVerification(
                sources = listOf(
                    ChemicalDataSource(kind = ChemicalDataSourceKind.MANUFACTURER_LABEL, name = "Approved label"),
                ),
            ),
            productCategory = "fungicide",
        )

        val outcome = ChemicalReverification.apply(candidate = candidate, current = current)
        // The accepted intelligence carries the lookup's own provenance record.
        assertEquals(
            "manufacturer_label",
            outcome.intelligence.registeredUses.first().provenance?.get("withholding_period"),
        )
        assertEquals("manufacturer_label", outcome.intelligence.fieldProvenance?.get("withholding_periods"))

        // And the row write + reopen keeps the per-use map, verbatim.
        val row = ChemicalReverification.updated(savedChemical("Custodia Forte", current), outcome)
        val reopened = roundTrip(row)
        assertEquals(
            candidateUse.provenance,
            reopened.storedIntelligence!!.registeredUses.first().provenance,
        )
    }

    @Test
    fun reverifyNoChangeLeavesStoredProvenanceUntouched() {
        val storedUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Powdery mildew",
            withholdingPeriodDays = 28,
            provenance = mapOf("withholding_period" to "manufacturer_label"),
        )
        val current = ChemicalIntelligence(registeredUses = listOf(storedUse), productCategory = "fungicide")
        val candidate = ChemicalIntelligence(
            registeredUses = listOf(storedUse),
            verification = ChemicalVerification(
                sources = listOf(
                    ChemicalDataSource(kind = ChemicalDataSourceKind.OFFICIAL_REGISTER, name = "APVMA PUBCRIS"),
                ),
            ),
            productCategory = "fungicide",
        )
        val confirmed = ChemicalReverification.confirmingCurrent(current, candidate)
        assertEquals(listOf(storedUse), confirmed.registeredUses)
    }

    // ---- Prosaro: basis "other" stays reference-only with its source ----

    @Test
    fun otherBasisRateKeepsSourceButStaysReferenceOnly() {
        val lookup = decodeLookup(
            """
            {
              "product_name": "Prosaro",
              "registered_uses": [
                {
                  "crop": "Grapes",
                  "target_raw": "Botrytis",
                  "rates": [
                    { "label": "Directed application", "basis": "other", "unit": "", "raw_text": "Refer to label: mL per 100 m of row" }
                  ],
                  "provenance": { "claim": "manufacturer_label", "rates": "manufacturer_label" }
                }
              ]
            }
            """.trimIndent(),
        )
        val reopened = roundTrip(savedChemical("Prosaro", lookup.intelligence()))
        val use = reopened.registeredUses!!.first()
        val rate = use.rates.first()

        assertEquals("manufacturer_label", use.provenance?.get("rates"))
        assertEquals(ChemicalLabelRateBasis.OTHER, rate.basis)
        assertNull(rate.value)
        assertNull(rate.proposedValue)
        assertEquals("Refer to label: mL per 100 m of row", rate.displayRate)
        assertTrue(rate.basis.compatibleProductRateBases.isEmpty())
    }

    // ---- Legacy records: no provenance in, none invented out ----

    @Test
    fun legacyRecordWithoutProvenanceDecodesAndReencodesClean() {
        val intel = json.decodeFromString<ChemicalIntelligence>(
            """
            {
              "active_ingredients": [],
              "registered_uses": [
                { "crop": "Grapes", "target_raw": "Powdery mildew", "withholding_period_days": 21 }
              ],
              "product_category": "fungicide"
            }
            """.trimIndent(),
        )
        assertNull(intel.fieldProvenance)
        assertNull(intel.registeredUses.first().provenance)

        val reopened = roundTrip(savedChemical("Legacy", intel))
        assertNull(reopened.registeredUses!!.first().provenance)
        assertEquals(21, reopened.registeredUses!!.first().withholdingPeriodDays)

        // The row must not grow fabricated provenance keys on re-save.
        val encoded = json.encodeToString(reopened)
        assertFalse(encoded.contains("field_provenance"))
        assertFalse(encoded.contains("\"provenance\""))
    }

    // ---- Tolerance and losslessness ----

    @Test
    fun unknownTierStringsSurviveVerbatimButNeverReadAsAuthority() {
        val use = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Downy mildew",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "L")),
            provenance = mapOf("rates" to "future_evidence_tier"),
        )
        val reopened = roundTrip(
            savedChemical("Future", ChemicalIntelligence(registeredUses = listOf(use))),
        )
        assertEquals(
            "future_evidence_tier",
            reopened.registeredUses!!.first().provenance?.get("rates"),
        )
        assertNull(ChemicalProvenanceTier.authoritative("future_evidence_tier"))
        assertNull(listOf(use).uniformRatesBadge())
    }

    @Test
    fun malformedProvenanceDegradesToNullWithoutLosingTheRecord() {
        val use = json.decodeFromString<ChemicalRegisteredUse>(
            """{ "crop": "Grapes", "target_raw": "Botrytis", "provenance": 42 }""",
        )
        assertEquals("Grapes", use.crop)
        assertNull(use.provenance)

        // A non-string tier value voids the whole map — mirroring the iOS
        // [String: String] decode — rather than keeping half a record.
        val partial = json.decodeFromString<ChemicalRegisteredUse>(
            """{ "crop": "Grapes", "target_raw": "Botrytis", "provenance": { "rates": 5 } }""",
        )
        assertNull(partial.provenance)

        val intel = json.decodeFromString<ChemicalIntelligence>(
            """{ "registered_uses": [], "field_provenance": "nope" }""",
        )
        assertNull(intel.fieldProvenance)
    }

    @Test
    fun unresolvedProvenanceStaysUnresolvedNeverAuthority() {
        val intel = ChemicalIntelligence(
            fieldProvenance = mapOf(
                "withholding_periods" to "unresolved",
                "label_rates" to "ai_interpretation",
            ),
        )
        val reopened = json.decodeFromString<ChemicalIntelligence>(json.encodeToString(intel))
        assertEquals("unresolved", reopened.fieldProvenance?.get("withholding_periods"))
        assertEquals("ai_interpretation", reopened.fieldProvenance?.get("label_rates"))
        // Neither tier can ever present as authority.
        assertNull(ChemicalProvenanceTier.authoritative("unresolved"))
        assertNull(ChemicalProvenanceTier.authoritative("ai_interpretation"))
    }

    // ---- Display plan: lightweight, honest, never inferred ----

    @Test
    fun uniformLabelBackedFactsShowOneHeaderBadge() {
        val use = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Powdery mildew",
            withholdingPeriodDays = 28,
            restrictions = "Do not graze.",
            provenance = mapOf(
                "withholding_period" to "manufacturer_label",
                "restrictions" to "manufacturer_label",
            ),
        )
        assertEquals(
            ChemicalUseProvenancePlan.Uniform(ChemicalProvenanceTier.MANUFACTURER_LABEL),
            use.provenancePlan,
        )
        assertEquals(
            ChemicalProvenanceBadge.Authoritative(ChemicalProvenanceTier.MANUFACTURER_LABEL),
            use.provenancePlan.headerBadge,
        )
        assertNull(use.provenancePlan.badgeFor(ChemicalUseProvenanceFact.WITHHOLDING_PERIOD))
    }

    @Test
    fun mixedTrustShowsPerFactBadgesWithUnresolved() {
        val use = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Powdery mildew",
            withholdingPeriodDays = 14,
            restrictions = "Do not graze.",
            provenance = mapOf(
                "withholding_period" to "ai_interpretation",
                "restrictions" to "manufacturer_label",
            ),
        )
        val plan = use.provenancePlan
        assertNull(plan.headerBadge)
        assertEquals(
            ChemicalProvenanceBadge.Unresolved,
            plan.badgeFor(ChemicalUseProvenanceFact.WITHHOLDING_PERIOD),
        )
        assertEquals(
            ChemicalProvenanceBadge.Authoritative(ChemicalProvenanceTier.MANUFACTURER_LABEL),
            plan.badgeFor(ChemicalUseProvenanceFact.RESTRICTIONS),
        )
    }

    @Test
    fun recordsWithoutAuthorityShowNothing() {
        // No provenance at all (legacy / manual): nothing to show.
        val legacy = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Botrytis",
            withholdingPeriodDays = 7,
        )
        assertEquals(ChemicalUseProvenancePlan.Hidden, legacy.provenancePlan)

        // All-AI card: the verification banner already says unverified;
        // repeating "Unresolved" on every row is clutter, not information.
        val ai = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Botrytis",
            withholdingPeriodDays = 7,
            restrictions = "Check label.",
            provenance = mapOf(
                "withholding_period" to "ai_interpretation",
                "restrictions" to "ai_interpretation",
            ),
        )
        assertEquals(ChemicalUseProvenancePlan.Hidden, ai.provenancePlan)

        // Provenance present but no displayed facts: nothing to badge.
        val bare = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Botrytis",
            provenance = mapOf("claim" to "manufacturer_label"),
        )
        assertEquals(ChemicalUseProvenancePlan.Hidden, bare.provenancePlan)
    }

    @Test
    fun ratesBadgeRequiresEveryOwnerToProveTheSameTier() {
        val labelUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Powdery mildew",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 40.0, unit = "mL")),
            provenance = mapOf("rates" to "manufacturer_label"),
        )
        val secondLabelUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Downy mildew",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "L")),
            provenance = mapOf("rates" to "manufacturer_label"),
        )
        val unprovenUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Botrytis",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 2.0, unit = "L")),
        )
        val aiUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Rust",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 1.0, unit = "L")),
            provenance = mapOf("rates" to "ai_interpretation"),
        )
        val registerUse = ChemicalRegisteredUse(
            crop = "Grapes",
            targetRaw = "Weeds",
            rates = listOf(ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 3.0, unit = "L")),
            provenance = mapOf("rates" to "official_register"),
        )

        assertEquals(
            ChemicalProvenanceBadge.Authoritative(ChemicalProvenanceTier.MANUFACTURER_LABEL),
            listOf(labelUse, secondLabelUse).uniformRatesBadge(),
        )
        assertNull(listOf(labelUse, unprovenUse).uniformRatesBadge())
        assertNull(listOf(labelUse, aiUse).uniformRatesBadge())
        // Two DIFFERENT authoritative tiers still render nothing — one badge
        // must never speak for evidence it does not describe.
        assertNull(listOf(labelUse, registerUse).uniformRatesBadge())
        assertNull(
            listOf(ChemicalRegisteredUse(crop = "Grapes", targetRaw = "Rust")).uniformRatesBadge(),
        )
    }
}
