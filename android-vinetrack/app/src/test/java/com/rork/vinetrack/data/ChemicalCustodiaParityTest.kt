package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The permanent cross-platform Chemical Intelligence lookup regression —
 * pinned to a REAL product with a REAL country-scoped registration.
 *
 * Custodia (Adama Australia, APVMA 66541) is the canonical fixture because it
 * exercises every defect class the lookup audit hunts at once:
 *
 *  * a two-active mixture (Azoxystrobin 120 g/L + Tebuconazole 200 g/L) that
 *    must stay two actives with two groups (FRAC 11 + FRAC 3), never a merged
 *    string;
 *  * a sibling product with a near-identical name ("Custodia Forte",
 *    APVMA 91636, DIFFERENT concentrations 222/370 g/L) that must never be
 *    auto-matched by name similarity;
 *  * the same brand name registered separately overseas (UK MAPP 16393),
 *    proving registration identity is country-scoped;
 *  * label uses with different rates, bases and withholding periods that must
 *    stay attached to their own use;
 *  * a label whose re-entry statement is narrative ("until spray has dried"),
 *    so no numeric re-entry hours may ever be invented.
 *
 * `ChemicalCustodiaParityTests.swift` on iOS decodes the byte-identical JSON
 * fixture and asserts the same outcomes. The fixture is documented for the web
 * portal in `docs/chemical-custodia-parity-fixture.md`. If this file and that
 * document ever disagree, fix the document.
 */
class ChemicalCustodiaParityTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun decodeLookup(): ChemicalInfoService.ChemicalStructuredLookup =
        json.decodeFromString(CUSTODIA_FIXTURE_JSON)

    private fun intelligence(): ChemicalIntelligence = decodeLookup().intelligence()

    /**
     * Custodia Forte — a REAL sibling registration (APVMA 91636) with
     * different concentrations. Similar name, different product.
     */
    private fun forteIntelligence() = ChemicalIntelligence(
        activeIngredients = listOf(
            ChemicalActiveIngredient(
                name = "Azoxystrobin",
                concentration = 222.0,
                concentrationUnit = ChemicalConcentrationUnit.GRAMS_PER_LITRE,
                activityGroup = ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, "11"),
                groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                identitySource = ChemicalDataSourceKind.AI_INTERPRETATION,
            ),
            ChemicalActiveIngredient(
                name = "Tebuconazole",
                concentration = 370.0,
                concentrationUnit = ChemicalConcentrationUnit.GRAMS_PER_LITRE,
                activityGroup = ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, "3"),
                groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                identitySource = ChemicalDataSourceKind.AI_INTERPRETATION,
            ),
        ),
        registration = ChemicalRegistration.of(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "91636",
            registrant = "Adama Australia Pty Ltd",
            registeredProductName = "Custodia Forte",
        ),
        verification = ChemicalVerification(status = ChemicalVerificationStatus.PARTIALLY_VERIFIED),
        productCategory = "fungicide",
    )

    private fun savedChemical(
        id: String,
        name: String,
        intelligence: ChemicalIntelligence,
    ): SavedChemical = SavedChemical(
        id = id,
        vineyardId = "vineyard-1",
        name = name,
        activeIngredients = intelligence.activeIngredients,
        activityGroups = intelligence.activityGroupCodes,
        registrationCountry = intelligence.registration?.countryCode,
        registrationScheme = intelligence.registration?.scheme?.raw,
        registrationNumber = intelligence.registration?.registrationNumber,
        registrant = intelligence.registration?.registrant,
        registeredProductName = intelligence.registration?.registeredProductName,
        verificationStatusRaw = intelligence.verification.status.raw,
        verificationSources = intelligence.verification.sources,
        registeredUses = intelligence.registeredUses,
        activityGroupTableVersion = intelligence.activityGroupTableVersion,
        intelligenceSchemaVersion = intelligence.schemaVersion,
    )

    // ---- Transport ----------------------------------------------------------

    @Test
    fun `the shared payload decodes with the standard lookup json`() {
        val lookup = decodeLookup()
        assertEquals("Custodia 320 SC", lookup.productName)
        assertEquals(2, lookup.verification.sources.size)
        // `retrieved_at` arrives as an ISO-8601 string from the edge function
        // and must decode without any bespoke configuration.
        assertNotNull(lookup.verification.sources[0].retrievedAt)
        assertNull(lookup.verification.verifiedAt)
        assertEquals(1, lookup.schemaVersion)
        assertEquals(1, lookup.activityGroupTableVersion)
    }

    // ---- Actives ------------------------------------------------------------

    @Test
    fun `two actives stay separate each owning its concentration and group`() {
        val intel = intelligence()
        assertEquals(2, intel.activeIngredients.size)

        val azoxy = intel.activeIngredients[0]
        assertEquals("Azoxystrobin", azoxy.name)
        assertEquals(120.0, azoxy.concentration!!, 0.0)
        assertEquals(ChemicalConcentrationUnit.GRAMS_PER_LITRE, azoxy.concentrationUnit)
        assertEquals("11", azoxy.activityGroup?.code)
        assertTrue(azoxy.hasAuthoritativeGroup)

        val tebu = intel.activeIngredients[1]
        assertEquals("Tebuconazole", tebu.name)
        assertEquals(200.0, tebu.concentration!!, 0.0)
        assertEquals(ChemicalConcentrationUnit.GRAMS_PER_LITRE, tebu.concentrationUnit)
        assertEquals("3", tebu.activityGroup?.code)
        assertTrue(tebu.hasAuthoritativeGroup)

        // Never a merged display string masquerading as an active.
        assertTrue(intel.activeIngredients.none { it.name.contains("+") })
    }

    @Test
    fun `group codes are canonical and independent of server entry order`() {
        val intel = intelligence()
        // Server sent ["11", "3"] (active order); the model canonicalises.
        assertEquals(listOf("3", "11"), intel.activityGroupCodes)
        assertTrue(intel.activityGroups.all { it.scheme == ChemicalActivityGroupScheme.FRAC })
    }

    // ---- Identity -----------------------------------------------------------

    @Test
    fun `registration identity is exact and country scoped`() {
        val intel = intelligence()
        assertEquals("AU:apvma:66541", intel.registration?.identityKey)
        assertTrue(intel.registration?.isAuthoritativeIdentity == true)

        // The SAME brand name registered in the UK is a DIFFERENT identity.
        val ukCustodia = ChemicalRegistration.of(
            countryCode = "GB",
            scheme = ChemicalRegistrationScheme.OTHER,
            registrationNumber = "16393",
        )
        assertEquals("GB:other:16393", ukCustodia.identityKey)
        assertNotEquals(intel.registration?.identityKey, ukCustodia.identityKey)
    }

    // ---- Verification honesty ------------------------------------------------

    @Test
    fun `an AI lookup can never come back verified`() {
        val intel = intelligence()
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.resolvedVerificationStatus)
        assertFalse(intel.isResistanceDependable)

        // Even a stored 'verified' claim cannot survive unresolved fields:
        // the evidence gate lowers it back down.
        val flipped = intel.verification.copy(status = ChemicalVerificationStatus.VERIFIED)
        assertEquals(
            ChemicalVerificationStatus.PARTIALLY_VERIFIED,
            flipped.resolvedStatus(
                actives = intel.activeIngredients,
                hasRegistration = intel.hasEvidencedRegistration,
            ),
        )
    }

    // ---- Registered uses ------------------------------------------------------

    @Test
    fun `uses keep their own rates bases and WHP and re-entry is never invented`() {
        val intel = intelligence()
        assertEquals(2, intel.registeredUses.size)

        val grapes = intel.registeredUses[0]
        assertEquals("Grapevines", grapes.crop)
        assertEquals("Powdery mildew", grapes.targetRaw)
        assertEquals(SprayTarget.POWDERY_MILDEW, grapes.target)
        assertEquals(2, grapes.rates.size)
        assertEquals(ChemicalLabelRateBasis.PER_100_LITRES, grapes.rates[0].basis)
        assertEquals(65.0, grapes.rates[0].value!!, 0.0)
        assertEquals("mL", grapes.rates[0].unit)
        assertEquals(ChemicalLabelRateBasis.PER_HECTARE, grapes.rates[1].basis)
        assertEquals(1.0, grapes.rates[1].value!!, 0.0)
        assertEquals("L", grapes.rates[1].unit)
        assertEquals(28, grapes.withholdingPeriodDays)
        // The label says "until the spray has dried" — narrative, not hours.
        assertNull(grapes.reEntryPeriodHours)
        assertTrue(grapes.restrictions?.contains("80% capfall") == true)

        val wheat = intel.registeredUses[1]
        assertEquals("Wheat", wheat.crop)
        assertEquals(1, wheat.rates.size)
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_HECTARE, wheat.rates[0].basis)
        assertEquals(315.0, wheat.rates[0].minValue!!, 0.0)
        assertEquals(630.0, wheat.rates[0].maxValue!!, 0.0)
        assertEquals(42, wheat.withholdingPeriodDays)
        assertNull(wheat.reEntryPeriodHours)

        // The grape WHP and the wheat WHP must never bleed into each other.
        assertNotEquals(grapes.withholdingPeriodDays, wheat.withholdingPeriodDays)
        assertTrue(intel.labelRateBases.contains(ChemicalLabelRateBasis.PER_100_LITRES))
        assertTrue(intel.labelRateBases.contains(ChemicalLabelRateBasis.PER_HECTARE))
        assertTrue(intel.labelRateBases.contains(ChemicalLabelRateBasis.RANGE_PER_HECTARE))
    }

    // ---- Legacy projections ----------------------------------------------------

    @Test
    fun `legacy projections derive from the structured actives never the reverse`() {
        val intel = intelligence()
        assertEquals("Azoxystrobin 120 g/L + Tebuconazole 200 g/L", intel.legacyActiveIngredient)
        assertEquals("3 + 11", intel.legacyChemicalGroup)
    }

    // ---- Similar product names --------------------------------------------------

    @Test
    fun `custodia forte is a different registration and never auto-matches custodia`() {
        val custodiaIntel = intelligence()
        val custodia = savedChemical("chem-custodia", "Custodia", custodiaIntel)
        val forte = savedChemical("chem-forte", "Custodia Forte", forteIntelligence())

        // Store duplicate gate: identity key only, never name similarity.
        assertNull(
            ChemicalStoreMatching.findByRegistrationIdentity(
                chemicals = listOf(custodia),
                registration = forteIntelligence().registration,
            ),
        )
        assertEquals(
            custodia.id,
            ChemicalStoreMatching.findByRegistrationIdentity(
                chemicals = listOf(custodia, forte),
                registration = custodiaIntel.registration,
            )?.id,
        )
        assertNull(
            ChemicalStoreMatching.findByRegistrationIdentity(
                chemicals = listOf(custodia),
                registration = custodiaIntel.registration,
                excludingId = custodia.id,
            ),
        )
        assertNull(
            ChemicalStoreMatching.findByRegistrationIdentity(
                chemicals = listOf(custodia, forte),
                registration = null,
            ),
        )

        // Spray-line resolution: exact unique name only — no substring, no fuzz.
        val (byName, nameKind) = ChemicalSnapshotCapture.resolve(
            savedChemicalId = null,
            productName = "custodia",
            library = listOf(custodia, forte),
        )
        assertEquals(custodia.id, byName?.id)
        assertEquals(ChemicalSnapshotCapture.MatchKind.EXACT_NAME, nameKind)

        val (partial, partialKind) = ChemicalSnapshotCapture.resolve(
            savedChemicalId = null,
            productName = "Custodia 320",
            library = listOf(custodia, forte),
        )
        assertNull(partial)
        assertEquals(ChemicalSnapshotCapture.MatchKind.UNRESOLVED, partialKind)

        val (byKey, keyKind) = ChemicalSnapshotCapture.resolve(
            savedChemicalId = null,
            productName = null,
            registrationIdentityKey = "AU:apvma:91636",
            library = listOf(custodia, forte),
        )
        assertEquals(forte.id, byKey?.id)
        assertEquals(ChemicalSnapshotCapture.MatchKind.REGISTRATION_IDENTITY, keyKind)
    }

    // ---- Legacy splitter ----------------------------------------------------------

    @Test
    fun `the legacy splitter protects locant commas thousands separators and units`() {
        assertEquals(
            listOf("Azoxystrobin", "Tebuconazole"),
            ChemicalIntelligence.splitActiveNames("Azoxystrobin 120 g/L + Tebuconazole 200 g/L"),
        )
        assertEquals(listOf("2,4-D"), ChemicalIntelligence.splitActiveNames("2,4-D"))
        assertEquals(
            listOf("2,4-D", "Dicamba"),
            ChemicalIntelligence.splitActiveNames("2,4-D + Dicamba"),
        )
        assertEquals(
            listOf("Bacillus amyloliquefaciens"),
            ChemicalIntelligence.splitActiveNames("Bacillus amyloliquefaciens 1,000,000 CFU/g"),
        )
        assertEquals(
            listOf("Copper hydroxide", "Mancozeb"),
            ChemicalIntelligence.splitActiveNames("Copper hydroxide and Mancozeb"),
        )
        assertEquals(
            listOf("Azoxystrobin", "Tebuconazole"),
            ChemicalIntelligence.splitActiveNames("Azoxystrobin · Tebuconazole"),
        )
        assertEquals(
            listOf("Glyphosate", "Simazine"),
            ChemicalIntelligence.splitActiveNames("Glyphosate, Simazine"),
        )
        assertEquals(listOf("Sulfur"), ChemicalIntelligence.splitActiveNames("Sulfur 800 g/kg"))
    }

    companion object {
        /**
         * The shared `action=structured` edge-function response for "Custodia"
         * looked up in Australia. Identical string on iOS.
         */
        val CUSTODIA_FIXTURE_JSON: String = """
        {
          "product_name": "Custodia 320 SC",
          "product_category": "fungicide",
          "form_type": "liquid",
          "registration": {
            "country_code": "AU",
            "scheme": "apvma",
            "registration_number": "66541",
            "registrant": "Adama Australia Pty Ltd",
            "registered_product_name": "Custodia 320 SC"
          },
          "active_ingredients": [
            {
              "name": "Azoxystrobin",
              "concentration": 120,
              "concentration_unit": "g/L",
              "activity_group": { "scheme": "frac", "code": "11", "common_name": "QoI / Strobilurin" },
              "group_source": "authoritative_classification",
              "identity_source": "ai_interpretation"
            },
            {
              "name": "Tebuconazole",
              "concentration": 200,
              "concentration_unit": "g/L",
              "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI / Triazole" },
              "group_source": "authoritative_classification",
              "identity_source": "ai_interpretation"
            }
          ],
          "activity_groups": ["11", "3"],
          "activity_group_scheme": "frac",
          "registered_uses": [
            {
              "crop": "Grapevines",
              "target": "powdery_mildew",
              "target_raw": "Powdery mildew",
              "rates": [
                { "label": "Dilute spraying", "basis": "per_100_litres", "value": 65, "unit": "mL" },
                { "label": "Concentrate spraying", "basis": "per_hectare", "value": 1, "unit": "L" }
              ],
              "withholding_period_days": 28,
              "restrictions": "Protectant only. DO NOT apply more than 2 sprays per season. Export grapes: do not use later than 80% capfall. Do not re-enter treated areas until the spray has dried."
            },
            {
              "crop": "Wheat",
              "target_raw": "Stripe rust",
              "rates": [
                { "label": "Standard", "basis": "range_per_hectare", "min_value": 315, "max_value": 630, "unit": "mL" }
              ],
              "withholding_period_days": 42,
              "restrictions": "Harvest WHP 6 weeks. Grazing WHP 21 days."
            }
          ],
          "label_rate_bases": ["per_100_litres", "per_hectare", "range_per_hectare"],
          "verification": {
            "status": "partially_verified",
            "sources": [
              { "kind": "ai_interpretation", "name": "Model extraction (gpt-4o)", "retrieved_at": "2026-08-18T00:00:00Z" },
              { "kind": "authoritative_classification", "name": "VineTrack activity group reference v1 (FRAC/HRAC/IRAC)", "retrieved_at": "2026-08-18T00:00:00Z" }
            ],
            "conflicts": [],
            "unresolved_fields": ["label_reference", "label_version", "re_entry_period_hours"],
            "verified_at": null
          },
          "activity_group_table_version": 1,
          "schema_version": 1
        }
        """.trimIndent()
    }
}
