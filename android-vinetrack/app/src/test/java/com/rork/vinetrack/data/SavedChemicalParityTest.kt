package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalProvenanceTier
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.ChemicalWithholdingDisplay
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P4 — Saved Chemical cross-platform parity (Android side).
 *
 * Every fixture in this file is the CANONICAL `saved_chemicals` row shape: the
 * exact JSON the portal writes and the exact JSON the iOS
 * `SavedChemicalParityTests` decodes, byte for byte. The two suites assert the
 * same values, so "saved on iOS opens identically on Android" is proven by
 * construction rather than by inspection.
 *
 * What must survive a round trip, per fixture:
 *   master_chemical_id / master_source_revision, registration identity,
 *   actives + FRAC/HRAC/IRAC groups, verification status, registered_uses and
 *   their per-use provenance, every rate with its basis and range, WHP / REI /
 *   restrictions, and the label reference + version.
 *
 * What must NOT happen:
 *   ranges collapsing to a single number, `basis:"other"` gaining a numeric
 *   value, unresolved data resolving itself, unknown provenance gaining
 *   authority, or an ordinary edit clearing the Master link.
 */
class SavedChemicalParityTest {

    /** Mirrors `SupabaseClient.json` so this is the real wire behaviour. */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
        coerceInputValues = true
    }

    private fun decodeRow(raw: String): SavedChemical = json.decodeFromString(raw)

    private fun roundTrip(chemical: SavedChemical): SavedChemical =
        json.decodeFromString(json.encodeToString(chemical))

    // -----------------------------------------------------------------------
    // Canonical fixtures — identical to the iOS suite
    // -----------------------------------------------------------------------

    /**
     * Sprayseal 80160 — label-backed 30 mL/100 L, WHP 0 with the
     * "not required" phrase, master-linked. Deliberately written the way the
     * PORTAL writes it: the legacy `rates` entry carries NO `id` and the
     * `purchase` object is partial.
     */
    private val spraysealRow = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Sprayseal Pruning Wound Treatment",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [ { "label": "Standard", "value": 300, "basis": "per_100_litres" } ],
      "purchase": { "costDollars": 250.0 },
      "active_ingredient": "Tebuconazole 430 g/L",
      "chemical_group": "3",
      "active_ingredients": [
        {
          "name": "Tebuconazole",
          "concentration": 430,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "80160",
      "registrant": "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
      "registered_product_name": "Sprayseal Pruning Wound Treatment",
      "label_reference": "https://elabels.apvma.gov.au/labels/80160.pdf",
      "label_version": "APVMA label approval 113355 (1/07/2025)",
      "verification_status": "partially_verified",
      "verification_sources": [
        {
          "kind": "official_register",
          "name": "APVMA PubCRIS register extract — product 80160",
          "reference": "https://data.gov.au/data/api/3/action/datastore_search",
          "retrieved_at": "2026-08-20T00:00:00Z"
        }
      ],
      "verification_unresolved_fields": ["label_rates:GRAPEVINE"],
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "EUTYPA DIEBACK",
          "rates": [
            {
              "label": "",
              "basis": "per_100_litres",
              "value": 30,
              "unit": "mL",
              "raw_text": "30 mL per 100 L of water"
            }
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
      "label_rate_bases": ["per_100_litres"],
      "activity_group_table_version": 3,
      "intelligence_schema_version": 1,
      "master_chemical_id": "33333333-3333-3333-3333-333333333333",
      "master_source_revision": 7
    }
    """.trimIndent()

    /** Custodia Forte 91636 — rate RANGES on two bases plus a 28-day WHP. */
    private val custodiaForteRow = """
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia Forte Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [
        {
          "name": "Azoxystrobin",
          "concentration": 120,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        },
        {
          "name": "Tebuconazole",
          "concentration": 200,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["11", "3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "91636",
      "registrant": "ADAMA AUSTRALIA PTY LIMITED",
      "registered_product_name": "CUSTODIA FORTE FUNGICIDE",
      "label_reference": "https://elabels.apvma.gov.au/labels/91636.pdf",
      "label_version": "APVMA label approval 120011 (3/03/2026)",
      "verification_status": "partially_verified",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "POWDERY MILDEW",
          "rates": [
            {
              "label": "Dilute",
              "basis": "range_per_100_litres",
              "min_value": 40,
              "max_value": 60,
              "unit": "mL",
              "raw_text": "40–60 mL/100 L"
            },
            {
              "label": "Concentrate",
              "basis": "range_per_hectare",
              "min_value": 0.6,
              "max_value": 0.9,
              "unit": "L",
              "raw_text": "0.6–0.9 L/ha"
            }
          ],
          "withholding_period_days": 28,
          "re_entry_period_hours": 24,
          "restrictions": "DO NOT apply more than two consecutive applications.",
          "provenance": {
            "claim": "manufacturer_label",
            "rates": "manufacturer_label",
            "withholding_period": "manufacturer_label",
            "re_entry": "manufacturer_label",
            "restrictions": "manufacturer_label"
          }
        }
      ],
      "label_rate_bases": ["range_per_100_litres", "range_per_hectare"],
      "activity_group_table_version": 3,
      "intelligence_schema_version": 1
    }
    """.trimIndent()

    /** Prosaro 63243 — contract fixture: `basis:"other"`, reference-only. */
    private val prosaroRow = """
    {
      "id": "55555555-5555-5555-5555-555555555555",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Prosaro 420 SC Fungicide",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [
        {
          "name": "Prothioconazole",
          "concentration": 210,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["3"],
      "activity_group_scheme": "frac",
      "registration_country": "AU",
      "registration_scheme": "apvma",
      "registration_number": "63243",
      "registered_product_name": "PROSARO 420 SC FOLIAR FUNGICIDE",
      "verification_status": "partially_verified",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "BOTRYTIS",
          "rates": [
            {
              "label": "",
              "basis": "other",
              "unit": "",
              "raw_text": "Refer to the approved label for grapevine rates"
            }
          ],
          "provenance": { "claim": "manufacturer_label", "rates": "manufacturer_label" }
        }
      ],
      "label_rate_bases": ["other"],
      "intelligence_schema_version": 1
    }
    """.trimIndent()

    /** Custodia 320SC — identity never resolved; everything stays unresolved. */
    private val custodia320Row = """
    {
      "id": "66666666-6666-6666-6666-666666666666",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Custodia 320SC",
      "unit": "Litres",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [],
      "registration_country": "AU",
      "verification_status": "needs_match",
      "verification_unresolved_fields": [
        "registration_number", "active_ingredients", "registered_uses"
      ],
      "registered_uses": [],
      "intelligence_schema_version": 1
    }
    """.trimIndent()

    /** Ridomil Gold — ambiguous family; fails closed with nothing asserted. */
    private val ridomilRow = """
    {
      "id": "77777777-7777-7777-7777-777777777777",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Ridomil Gold",
      "unit": "Kg",
      "rate_per_ha": 0,
      "rates": [],
      "active_ingredients": [],
      "registration_country": "AU",
      "verification_status": "needs_match",
      "verification_unresolved_fields": ["registration_number", "active_ingredients"],
      "registered_uses": [],
      "intelligence_schema_version": 1
    }
    """.trimIndent()

    // -----------------------------------------------------------------------
    // P4-01 Sprayseal — full structured payload survives decode + re-encode
    // -----------------------------------------------------------------------

    @Test
    fun `P4-01 sprayseal round-trips every structured fact`() {
        val decoded = decodeRow(spraysealRow)
        val reopened = roundTrip(decoded)

        // Master linkage
        assertEquals("33333333-3333-3333-3333-333333333333", reopened.masterChemicalId)
        assertEquals(7, reopened.masterSourceRevision)

        val intel = reopened.storedIntelligence
        assertNotNull(intel)
        requireNotNull(intel)

        // Registration identity + label pointers
        assertEquals("AU", intel.registration?.countryCode)
        assertEquals("80160", intel.registration?.registrationNumber)
        assertEquals("apvma", intel.registration?.scheme?.raw)
        assertEquals(
            "OMNIA SPECIALITIES (AUSTRALIA) PTY LTD",
            intel.registration?.registrant,
        )
        assertEquals(
            "Sprayseal Pruning Wound Treatment",
            intel.registration?.registeredProductName,
        )
        assertEquals(
            "https://elabels.apvma.gov.au/labels/80160.pdf",
            intel.registration?.labelReference,
        )
        assertEquals(
            "APVMA label approval 113355 (1/07/2025)",
            intel.registration?.labelVersion,
        )

        // Actives + groups
        assertEquals(1, intel.activeIngredients.size)
        assertEquals("Tebuconazole", intel.activeIngredients[0].name)
        assertEquals(430.0, intel.activeIngredients[0].concentration!!, 0.0001)
        assertEquals("g/L", intel.activeIngredients[0].concentrationUnit?.raw)
        assertEquals(listOf("3"), intel.activityGroupCodes)
        assertEquals("frac", intel.activityGroups.first().scheme.raw)

        // Verification
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.verification.status)
        assertEquals(1, intel.verification.sources.size)
        assertEquals(
            listOf("label_rates:GRAPEVINE"),
            intel.verification.unresolvedFields,
        )

        // Registered use, rate and label facts
        val use = intel.registeredUses.single()
        assertEquals("GRAPEVINE", use.crop)
        assertEquals("EUTYPA DIEBACK", use.targetRaw)
        assertEquals(0, use.withholdingPeriodDays)
        assertEquals("NOT REQUIRED WHEN USED AS DIRECTED.", use.restrictions)
        val rate = use.rates.single()
        assertEquals(ChemicalLabelRateBasis.PER_100_LITRES, rate.basis)
        assertEquals(30.0, rate.value!!, 0.0001)
        assertEquals("mL", rate.unit)
        assertEquals("30 mL per 100 L of water", rate.rawText)

        // Per-use provenance, verbatim
        assertEquals("manufacturer_label", use.provenance?.get("rates"))
        assertEquals("manufacturer_label", use.provenance?.get("withholding_period"))
        assertEquals(
            ChemicalProvenanceTier.MANUFACTURER_LABEL,
            ChemicalProvenanceTier.authoritative(use.provenance?.get("rates")),
        )

        // The P3 WHP rule still reads the same on a reopened record.
        assertEquals(
            "Not required when used as directed",
            ChemicalWithholdingDisplay.text(use, hasManufacturerLabelSource = true),
        )
    }

    // -----------------------------------------------------------------------
    // P4-02 Custodia Forte — ranges must not collapse
    // -----------------------------------------------------------------------

    @Test
    fun `P4-02 custodia forte keeps both ranges and the 28 day WHP`() {
        val reopened = roundTrip(decodeRow(custodiaForteRow))
        val intel = requireNotNull(reopened.storedIntelligence)

        assertEquals(listOf("11", "3"), intel.activityGroupCodes)
        assertEquals("91636", intel.registration?.registrationNumber)

        val use = intel.registeredUses.single()
        assertEquals(28, use.withholdingPeriodDays)
        assertEquals(24, use.reEntryPeriodHours)
        assertEquals(
            "DO NOT apply more than two consecutive applications.",
            use.restrictions,
        )
        assertEquals(2, use.rates.size)

        val dilute = use.rates[0]
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_100_LITRES, dilute.basis)
        assertEquals(40.0, dilute.minValue!!, 0.0001)
        assertEquals(60.0, dilute.maxValue!!, 0.0001)
        assertNull("a range must never collapse into a single value", dilute.value)
        assertEquals("40–60 mL/100 L", dilute.rawText)
        // A range proposes its LOW end — never inflated on reopen.
        assertEquals(40.0, dilute.proposedValue!!, 0.0001)

        val concentrate = use.rates[1]
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_HECTARE, concentrate.basis)
        assertEquals(0.6, concentrate.minValue!!, 0.0001)
        assertEquals(0.9, concentrate.maxValue!!, 0.0001)
        assertNull(concentrate.value)

        assertEquals(
            listOf(
                ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            ),
            intel.labelRateBases,
        )
        // 28 days is a stated count; the phrase rule can never zero it.
        assertEquals(
            "28 days",
            ChemicalWithholdingDisplay.text(use, hasManufacturerLabelSource = true),
        )
    }

    // -----------------------------------------------------------------------
    // P4-03 Prosaro — basis "other" stays reference-only
    // -----------------------------------------------------------------------

    @Test
    fun `P4-03 prosaro other basis keeps its wording and invents no number`() {
        val reopened = roundTrip(decodeRow(prosaroRow))
        val intel = requireNotNull(reopened.storedIntelligence)

        val rate = intel.registeredUses.single().rates.single()
        assertEquals(ChemicalLabelRateBasis.OTHER, rate.basis)
        assertNull(rate.value)
        assertNull(rate.minValue)
        assertNull(rate.maxValue)
        assertEquals("", rate.unit)
        assertEquals(
            "Refer to the approved label for grapevine rates",
            rate.rawText,
        )
        // Reference-only: nothing for a calculation to start from.
        assertNull(rate.proposedValue)
        assertEquals(rate.rawText, rate.displayRate)

        // WHP was never stated — it must stay unstated, not become "0 days".
        assertNull(intel.registeredUses.single().withholdingPeriodDays)
        assertNull(
            ChemicalWithholdingDisplay.text(
                intel.registeredUses.single(),
                hasManufacturerLabelSource = true,
            ),
        )
    }

    // -----------------------------------------------------------------------
    // P4-04 Unresolved fixtures stay unresolved
    // -----------------------------------------------------------------------

    @Test
    fun `P4-04 custodia 320SC and ridomil gold stay unresolved on reopen`() {
        for (raw in listOf(custodia320Row, ridomilRow)) {
            val reopened = roundTrip(decodeRow(raw))
            val intel = requireNotNull(reopened.storedIntelligence)

            assertTrue(intel.activeIngredients.isEmpty())
            assertTrue(intel.registeredUses.isEmpty())
            assertNull(intel.registration?.registrationNumber)
            assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, intel.resolvedVerificationStatus)
            assertTrue(
                "unresolved fields must survive verbatim",
                intel.verification.unresolvedFields.contains("registration_number"),
            )
            // Nothing about an unresolved record may read as dependable.
            assertTrue(!intel.isResistanceDependable)
            assertTrue(!intel.hasEvidencedRegistration)
        }
    }

    // -----------------------------------------------------------------------
    // P4-05 Portal-written shapes decode without loss
    // -----------------------------------------------------------------------

    @Test
    fun `P4-05 portal row without rate ids and with a partial purchase decodes`() {
        val decoded = decodeRow(spraysealRow)
        // The legacy rates array carried no `id` — before P4 this threw and
        // took the whole chemical out of the store.
        assertEquals(1, decoded.rates.size)
        assertTrue(decoded.rates[0].id.isNotBlank())
        assertEquals(300.0, decoded.rates[0].value, 0.0001)
        assertEquals("per_100_litres", decoded.rates[0].basis)
        // A partial purchase object keeps the value it stated and defaults
        // the rest rather than failing the record.
        assertEquals(250.0, decoded.purchase?.costDollars!!, 0.0001)
        assertEquals("Litres", decoded.purchase?.containerUnit)
        // And the structured payload is untouched by either tolerance.
        assertEquals("80160", decoded.storedIntelligence?.registration?.registrationNumber)
    }

    // -----------------------------------------------------------------------
    // P4-06 Legacy records still open safely
    // -----------------------------------------------------------------------

    @Test
    fun `P4-06 legacy record without any newer fields opens safely`() {
        val legacy = decodeRow(
            """
            {
              "id": "88888888-8888-8888-8888-888888888888",
              "vineyard_id": "22222222-2222-2222-2222-222222222222",
              "name": "Old Bordeaux Mix",
              "unit": "Kg",
              "rate_per_ha": 2.5,
              "active_ingredient": "Copper",
              "chemical_group": "M1"
            }
            """.trimIndent(),
        )
        // No structured payload at all — and that is the honest answer.
        assertNull(legacy.storedIntelligence)
        assertNull(legacy.masterChemicalId)
        assertTrue(legacy.rates.isEmpty())
        // The legacy read is a CANDIDATE, never verified.
        assertEquals(
            ChemicalVerificationStatus.NEEDS_MATCH,
            legacy.resolvedIntelligence.resolvedVerificationStatus,
        )
        assertEquals("Old Bordeaux Mix", roundTrip(legacy).name)
    }

    // -----------------------------------------------------------------------
    // P4-07 Unknown provenance round-trips but never gains authority
    // -----------------------------------------------------------------------

    @Test
    fun `P4-07 unknown provenance survives verbatim without becoming authority`() {
        val reopened = roundTrip(
            decodeRow(
                spraysealRow.replace("\"rates\": \"manufacturer_label\"", "\"rates\": \"stone_tablet\""),
            ),
        )
        val use = requireNotNull(reopened.storedIntelligence).registeredUses.single()
        // Stored verbatim…
        assertEquals("stone_tablet", use.provenance?.get("rates"))
        // …but it proves nothing.
        assertNull(ChemicalProvenanceTier.authoritative(use.provenance?.get("rates")))
        // Neighbouring facts are unaffected.
        assertEquals(
            ChemicalProvenanceTier.MANUFACTURER_LABEL,
            ChemicalProvenanceTier.authoritative(use.provenance?.get("withholding_period")),
        )
    }

    // -----------------------------------------------------------------------
    // P4-08 Ordinary edits never clear the Master link
    // -----------------------------------------------------------------------

    @Test
    fun `P4-08 an ordinary edit leaves master linkage intact`() {
        val decoded = decodeRow(spraysealRow)
        // An inventory/pack edit carries no intelligence and no master fields:
        // explicitNulls=false omits those columns, so the stored link stands.
        val input = SavedChemicalRepository.ChemicalInput(
            name = decoded.name,
            unit = decoded.unit,
            ratePerHa = decoded.ratePerHa,
            rates = decoded.rates,
            activeIngredient = decoded.activeIngredient,
            chemicalGroup = decoded.chemicalGroup,
            use = decoded.use,
            problem = decoded.problem,
            manufacturer = decoded.manufacturer,
            notes = decoded.notes,
            modeOfAction = decoded.modeOfAction,
            labelUrl = decoded.labelUrl,
            productUrl = decoded.productUrl,
            purchase = decoded.purchase,
            inventoryQuantity = 12.0,
        )
        assertNull(input.masterChemicalId)
        assertNull(input.masterSourceRevision)
        assertNull(input.intelligence)

        // The row itself keeps both, so reopening still shows the link.
        val reopened = roundTrip(decoded)
        assertEquals("33333333-3333-3333-3333-333333333333", reopened.masterChemicalId)
        assertEquals(7, reopened.masterSourceRevision)
    }

    // -----------------------------------------------------------------------
    // P4-09 Target vocabulary agrees with iOS
    // -----------------------------------------------------------------------

    @Test
    fun `P4-09 target mapping matches iOS including grass control wording`() {
        assertEquals(SprayTarget.POWDERY_MILDEW, ChemicalRegisteredUse.mapTarget("POWDERY MILDEW"))
        assertEquals(SprayTarget.DOWNY_MILDEW, ChemicalRegisteredUse.mapTarget("Downy mildew"))
        assertEquals(SprayTarget.BOTRYTIS, ChemicalRegisteredUse.mapTarget("Bunch rot"))
        assertEquals(SprayTarget.WEEDS, ChemicalRegisteredUse.mapTarget("Broadleaf weeds"))
        // The P4 fix: iOS has always read this wording as weeds.
        assertEquals(SprayTarget.WEEDS, ChemicalRegisteredUse.mapTarget("GRASS CONTROL"))
        // Still conservative — an unmapped target stays unmapped.
        assertNull(ChemicalRegisteredUse.mapTarget("EUTYPA DIEBACK"))

        // And a stored explicit target survives the row round trip.
        val use = ChemicalRegisteredUse(
            crop = "GRAPEVINE",
            targetRaw = "POWDERY MILDEW",
            target = SprayTarget.POWDERY_MILDEW,
        )
        val encoded = json.encodeToString(use)
        assertTrue(encoded.contains("powdery_mildew"))
        assertEquals(
            SprayTarget.POWDERY_MILDEW,
            json.decodeFromString<ChemicalRegisteredUse>(encoded).resolvedTarget,
        )
    }
}
