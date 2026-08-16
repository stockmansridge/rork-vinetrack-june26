package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalManualActiveDraft
import com.rork.vinetrack.data.chemical.ChemicalManualDraft
import com.rork.vinetrack.data.chemical.ChemicalManualEntry
import com.rork.vinetrack.data.chemical.ChemicalManualRateDraft
import com.rork.vinetrack.data.chemical.ChemicalManualUseDraft
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.productLevelRates
import com.rork.vinetrack.data.chemical.statedUses
import com.rork.vinetrack.data.chemical.viticulturalTargets
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayProductRateBasis
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
 * The structured manual Chemical editor's actual behaviour.
 *
 * These drive [ChemicalManualEntry] — the same object both editor UIs drive —
 * rather than re-deriving the mapping, so a rule cannot pass here while the screen
 * does something else. The iOS suite `ChemicalManualEntryTests` asserts the same
 * fixtures and the same outcomes.
 *
 * Four properties are under protection:
 *
 *  1. A mixture is stored as N independent active→group relationships, never as
 *     one combined `"3 + 11"` string.
 *  2. Manual entry stays Unverified however completely it is filled in, and
 *     becomes Conflict only when the reference table positively disagrees.
 *  3. A draft read out of a record and written straight back is unchanged.
 *  4. Commercial and operational fields are untouched by chemistry edits.
 */
class ChemicalManualEntryTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val at = "2026-08-16T00:00:00.000Z"

    // ---- Fixtures ----

    private fun activeDraft(
        name: String,
        concentration: String = "",
        unit: ChemicalConcentrationUnit? = ChemicalConcentrationUnit.GRAMS_PER_LITRE,
        scheme: ChemicalActivityGroupScheme? = ChemicalActivityGroupScheme.FRAC,
        code: String = "",
    ) = ChemicalManualActiveDraft(
        name = name,
        concentrationText = concentration,
        concentrationUnit = unit,
        scheme = scheme,
        groupCode = code,
    )

    /** Tebuconazole FRAC 3 + Azoxystrobin FRAC 11 — the canonical mixture. */
    private fun mixtureDraft() = ChemicalManualDraft(
        productName = "Custom Mix 300",
        countryCode = "AU",
        productCategory = "fungicide",
        registrant = "Example Crop Science",
        actives = listOf(
            activeDraft("Tebuconazole", "200", code = "3"),
            activeDraft("Azoxystrobin", "120", code = "11"),
        ),
    )

    private fun savedFrom(
        intel: ChemicalIntelligence,
        name: String = "Custom Mix 300",
    ): SavedChemical {
        val reg = intel.registration
        return SavedChemical(
            id = "chem-1",
            vineyardId = "v1",
            name = name,
            manufacturer = reg?.registrant.orEmpty(),
            productCategory = intel.productCategory,
            unit = "Litres",
            // Commercial and operational data the grower maintains. Present in
            // every fixture so any test that loses it fails loudly.
            notes = "Shed B, top shelf",
            packSize = 10.0,
            pricePerPack = 425.0,
            inventoryQuantity = 3.0,
            applicationNotes = "Do not tank-mix with oil",
            activeIngredient = intel.legacyActiveIngredient,
            chemicalGroup = intel.legacyChemicalGroup,
            activeIngredients = intel.activeIngredients,
            activityGroups = intel.activityGroupCodes,
            registrationCountry = reg?.countryCode,
            registrationScheme = reg?.scheme?.raw,
            registrationNumber = reg?.registrationNumber,
            registrant = reg?.registrant,
            registeredProductName = reg?.registeredProductName,
            labelReference = reg?.labelReference,
            labelVersion = reg?.labelVersion,
            verificationStatusRaw = intel.resolvedVerificationStatus.raw,
            verificationSources = intel.verification.sources,
            verificationConflicts = intel.verification.conflicts,
            verificationUnresolvedFields = intel.verification.unresolvedFields,
            verifiedAt = intel.verification.verifiedAt,
            registeredUses = intel.registeredUses,
            labelRateBases = intel.labelRateBases.map { it.raw },
            activityGroupTableVersion = intel.activityGroupTableVersion,
            intelligenceSchemaVersion = intel.schemaVersion,
        )
    }

    // ---- Single active ----

    @Test
    fun `a manual single-active product is structured and unverified`() {
        val draft = ChemicalManualDraft(
            productName = "Knockdown 360",
            countryCode = "AU",
            productCategory = "herbicide",
            actives = listOf(
                activeDraft(
                    "Glyphosate",
                    "360",
                    scheme = ChemicalActivityGroupScheme.HRAC,
                    code = "G",
                ),
            ),
        )

        val outcome = ChemicalManualEntry.outcome(draft, existing = null, editedAt = at)
        val active = outcome.intelligence.activeIngredients.single()

        assertEquals("Glyphosate", active.name)
        assertEquals(360.0, active.concentration!!, 0.0001)
        assertEquals(ChemicalConcentrationUnit.GRAMS_PER_LITRE, active.concentrationUnit)
        assertEquals(ChemicalActivityGroupScheme.HRAC, active.activityGroup?.scheme)
        assertEquals("G", active.activityGroup?.code)
        // The single fact that keeps completeness from becoming trust.
        assertEquals(ChemicalDataSourceKind.MANUAL_ENTRY, active.groupSource)
        assertFalse(active.hasAuthoritativeGroup)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `a manual single active survives save and reload`() {
        val outcome = ChemicalManualEntry.outcome(
            ChemicalManualDraft(
                productName = "Knockdown 360",
                countryCode = "AU",
                actives = listOf(
                    activeDraft(
                        "Glyphosate",
                        "360",
                        scheme = ChemicalActivityGroupScheme.HRAC,
                        code = "G",
                    ),
                ),
            ),
            existing = null,
        )
        val reloaded = ChemicalManualEntry.draft(
            savedFrom(outcome.intelligence, name = "Knockdown 360"),
            fallbackCountry = "NZ",
        )

        val active = reloaded.actives.single()
        assertEquals("Glyphosate", active.name)
        assertEquals("360", active.concentrationText)
        assertEquals(ChemicalActivityGroupScheme.HRAC, active.scheme)
        assertEquals("G", active.groupCode)
        // The record's own country wins over the vineyard default on reload.
        assertEquals("AU", reloaded.countryCode)
    }

    @Test
    fun `a manual product appears in the spray picker with its groups and status`() {
        val outcome = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        val saved = savedFrom(outcome.intelligence)

        // What the picker row renders: name, actives, derived groups, trust.
        assertEquals("Custom Mix 300", saved.name)
        assertEquals("Tebuconazole 200 g/L + Azoxystrobin 120 g/L", saved.activeIngredient)
        assertEquals("3 + 11", saved.chemicalGroup)
        assertEquals(listOf("3", "11"), saved.resolvedIntelligence.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, saved.verificationStatus)
        // Unverified is not a reason to block use of a product the grower owns.
        assertFalse(saved.resolvedIntelligence.isResistanceDependable)
    }

    // ---- Mixture ----

    @Test
    fun `a manual mixture keeps two independent active to group relationships`() {
        val outcome = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        val actives = outcome.intelligence.activeIngredients

        assertEquals(2, actives.size)
        // Each relationship stands on its own. This is what `"3 + 11"` as a single
        // string could never express, and what resistance planning needs.
        assertEquals("Tebuconazole", actives[0].name)
        assertEquals("3", actives[0].activityGroup?.code)
        assertEquals("Azoxystrobin", actives[1].name)
        assertEquals("11", actives[1].activityGroup?.code)
        assertEquals(listOf("3", "11"), outcome.intelligence.activityGroupCodes)
    }

    @Test
    fun `the combined group string is derived for display only`() {
        assertEquals("FRAC 3 + 11", ChemicalManualEntry.groupSummary(mixtureDraft()))
        assertEquals(
            "Tebuconazole + Azoxystrobin",
            ChemicalManualEntry.activesSummary(mixtureDraft()),
        )
        // And the legacy column mirrors it without anything reading it back.
        val outcome = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        assertEquals("3 + 11", outcome.intelligence.legacyChemicalGroup)
    }

    @Test
    fun `mixed schemes stay qualified in the summary`() {
        val draft = ChemicalManualDraft(
            productName = "Odd Mix",
            actives = listOf(
                activeDraft("Tebuconazole", code = "3"),
                activeDraft("Bifenthrin", scheme = ChemicalActivityGroupScheme.IRAC, code = "3"),
            ),
        )
        // "3 + 3" would read as one chemistry used twice. FRAC 3 and IRAC 3 are
        // unrelated, so the summary must not collapse them.
        val summary = ChemicalManualEntry.groupSummary(draft)
        assertTrue(summary.contains("FRAC 3"))
        assertTrue(summary.contains("IRAC 3"))
    }

    @Test
    fun `a mixture survives save, reload and re-save unchanged`() {
        val first = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        val saved = savedFrom(first.intelligence)

        val reloaded = ChemicalManualEntry.draft(saved, fallbackCountry = "AU")
        assertEquals(2, reloaded.actives.size)
        assertEquals("Tebuconazole", reloaded.actives[0].name)
        assertEquals("3", reloaded.actives[0].groupCode)
        assertEquals("200", reloaded.actives[0].concentrationText)
        assertEquals("Azoxystrobin", reloaded.actives[1].name)
        assertEquals("11", reloaded.actives[1].groupCode)
        assertEquals("120", reloaded.actives[1].concentrationText)

        // Round-tripping the editor must not itself be an edit.
        val second = ChemicalManualEntry.outcome(reloaded, existing = first.intelligence)
        assertEquals(
            first.intelligence.activeIngredients,
            second.intelligence.activeIngredients,
        )
        assertFalse(second.hasResistanceCriticalChange)
    }

    @Test
    fun `adding a third active leaves the first two untouched`() {
        val first = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        val reloaded = ChemicalManualEntry.draft(savedFrom(first.intelligence), "AU")
        val grown = reloaded.copy(
            actives = reloaded.actives + activeDraft("Sulphur", "800", code = "M2"),
        )

        val outcome = ChemicalManualEntry.outcome(grown, existing = first.intelligence)
        assertEquals(3, outcome.intelligence.activeIngredients.size)
        assertEquals(listOf("3", "11", "M2"), outcome.intelligence.activityGroupCodes)
        assertEquals("3", outcome.intelligence.activeIngredients[0].activityGroup?.code)
        assertEquals("11", outcome.intelligence.activeIngredients[1].activityGroup?.code)
    }

    @Test
    fun `removing an active removes only its group`() {
        val first = ChemicalManualEntry.outcome(mixtureDraft(), existing = null)
        val reduced = mixtureDraft().copy(actives = listOf(activeDraft("Tebuconazole", "200", code = "3")))

        val outcome = ChemicalManualEntry.outcome(reduced, existing = first.intelligence)
        assertEquals(listOf("3"), outcome.intelligence.activityGroupCodes)
        assertEquals(1, outcome.intelligence.activeIngredients.size)
    }

    // ---- Schemes ----

    @Test
    fun `every scheme survives persistence and a JSON round trip`() {
        val cases = listOf(
            ChemicalActivityGroupScheme.FRAC to "11",
            ChemicalActivityGroupScheme.HRAC to "G",
            ChemicalActivityGroupScheme.IRAC to "4A",
        )
        for ((scheme, code) in cases) {
            val draft = ChemicalManualDraft(
                productName = "Scheme test",
                actives = listOf(activeDraft("Examplecide", scheme = scheme, code = code)),
            )
            val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence
            val decoded = json.decodeFromString(
                ChemicalIntelligence.serializer(),
                json.encodeToString(ChemicalIntelligence.serializer(), intel),
            )
            val group = decoded.activeIngredients.single().activityGroup
            assertEquals("$scheme round trip", scheme, group?.scheme)
            assertEquals("$scheme code round trip", code, group?.code)
        }
    }

    @Test
    fun `not applicable is recorded as an assertion, not as a missing group`() {
        val draft = ChemicalManualDraft(
            productName = "Wetting agent",
            productCategory = "adjuvant",
            actives = listOf(
                ChemicalManualActiveDraft(
                    name = "Non-ionic surfactant",
                    scheme = ChemicalActivityGroupScheme.NOT_APPLICABLE,
                ),
            ),
        )
        val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence
        val group = intel.activeIngredients.single().activityGroup

        assertNotNull(group)
        assertEquals(ChemicalActivityGroupScheme.NOT_APPLICABLE, group?.scheme)
        // "Has no resistance group" is a different claim from "group unknown", and
        // it must not contribute a code to the resistance columns.
        assertFalse(group!!.isResistanceRelevant)
        assertTrue(intel.activityGroupCodes.isEmpty())

        val decoded = json.decodeFromString(
            ChemicalIntelligence.serializer(),
            json.encodeToString(ChemicalIntelligence.serializer(), intel),
        )
        assertEquals(
            ChemicalActivityGroupScheme.NOT_APPLICABLE,
            decoded.activeIngredients.single().activityGroup?.scheme,
        )
    }

    @Test
    fun `a code without a scheme is refused rather than guessed`() {
        val draft = ChemicalManualDraft(
            productName = "Half entered",
            actives = listOf(activeDraft("Tebuconazole", scheme = null, code = "3")),
        )
        val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence

        // A bare "3" is ambiguous across schemes, so it is not stored as a group.
        assertNull(intel.activeIngredients.single().activityGroup)
        assertTrue(
            ChemicalManualEntry.problems(draft)
                .any { it.contains("which resistance group system") },
        )
    }

    // ---- Conflict ----

    @Test
    fun `a manually entered wrong group raises a conflict against the reference table`() {
        val draft = ChemicalManualDraft(
            productName = "Mislabelled",
            countryCode = "AU",
            productCategory = "fungicide",
            // The reference table knows Azoxystrobin is FRAC 11.
            actives = listOf(activeDraft("Azoxystrobin", "250", code = "3")),
        )
        val outcome = ChemicalManualEntry.outcome(draft, existing = null, editedAt = at)

        val conflict = outcome.intelligence.verification.conflicts.single()
        assertEquals("activity_group", conflict.field)
        assertEquals("Azoxystrobin", conflict.activeIngredientName)
        assertTrue(conflict.extractedValue.contains("3"))
        assertTrue(conflict.authoritativeValue.contains("11"))
        assertEquals(ChemicalVerificationStatus.CONFLICT, outcome.resolvedStatus)

        // The operator's own value is still what is stored — the table does not
        // silently overwrite them, it disagrees in the open.
        assertEquals("3", outcome.intelligence.activeIngredients.single().activityGroup?.code)
    }

    @Test
    fun `the reference table's authority is never attached to the typed group`() {
        val draft = ChemicalManualDraft(
            productName = "Mislabelled",
            actives = listOf(activeDraft("Azoxystrobin", "250", code = "3")),
        )
        val active = ChemicalManualEntry.outcome(draft, existing = null)
            .intelligence.activeIngredients.single()

        // The table's classification of Azoxystrobin-as-FRAC-11 must not read as
        // an endorsement of a hand-typed FRAC 3.
        assertEquals(ChemicalDataSourceKind.MANUAL_ENTRY, active.groupSource)
        assertFalse(active.hasAuthoritativeGroup)
    }

    @Test
    fun `correcting the group clears the stale conflict`() {
        val wrong = ChemicalManualEntry.outcome(
            ChemicalManualDraft(
                productName = "Mislabelled",
                productCategory = "fungicide",
                actives = listOf(activeDraft("Azoxystrobin", "250", code = "3")),
            ),
            existing = null,
        )
        assertEquals(ChemicalVerificationStatus.CONFLICT, wrong.resolvedStatus)

        val corrected = ChemicalManualEntry.outcome(
            ChemicalManualDraft(
                productName = "Mislabelled",
                productCategory = "fungicide",
                actives = listOf(activeDraft("Azoxystrobin", "250", code = "11")),
            ),
            existing = wrong.intelligence,
        )

        // Group conflicts are recomputed from scratch on every reconcile, so a
        // correction clears the conflict it caused instead of leaving it stuck.
        assertTrue(corrected.intelligence.verification.conflicts.isEmpty())
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, corrected.resolvedStatus)
    }

    @Test
    fun `an active the reference table does not know raises no conflict`() {
        val draft = ChemicalManualDraft(
            productName = "Novel product",
            productCategory = "fungicide",
            actives = listOf(activeDraft("Examplestrobin", "250", code = "11")),
        )
        val outcome = ChemicalManualEntry.outcome(draft, existing = null)

        assertFalse(AuthoritativeActivityGroups.knows("Examplestrobin"))
        assertTrue(outcome.intelligence.verification.conflicts.isEmpty())
        // No conflict is inventable, and no trust is granted either.
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, outcome.resolvedStatus)
    }

    // ---- Verification ----

    @Test
    fun `a fully completed manual product still resolves Unverified`() {
        val draft = ChemicalManualDraft(
            productName = "Completely Filled In",
            countryCode = "AU",
            productCategory = "fungicide",
            registrant = "Example Crop Science",
            // Exactly the shape an authoritative identity has.
            registrationScheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "12345",
            actives = listOf(
                activeDraft("Tebuconazole", "200", code = "3"),
                activeDraft("Azoxystrobin", "120", code = "11"),
            ),
            productRates = listOf(
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    valueText = "1.5",
                    unit = "L",
                ),
            ),
            uses = listOf(
                ChemicalManualUseDraft(
                    crop = "Grapes",
                    targetRaw = "Powdery Mildew",
                    withholdingPeriodDaysText = "14",
                ),
            ),
        )
        val outcome = ChemicalManualEntry.outcome(draft, existing = null, editedAt = at)

        // Every field the operator could fill is filled, the groups are the CORRECT
        // ones, and the answer is still Unverified — because the source is the
        // operator, and completeness is not evidence.
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, outcome.resolvedStatus)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
        assertNotEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `a hand-typed registration number is not an authoritative identity`() {
        val draft = ChemicalManualDraft(
            productName = "Typed Identity",
            countryCode = "AU",
            registrationScheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "12345",
            actives = listOf(activeDraft("Tebuconazole", "200", code = "3")),
        )
        val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence

        // The number is stored and usable as a lookup key...
        assertEquals("12345", intel.registration?.registrationNumber)
        assertEquals("AU:apvma:12345", intel.registration?.identityKey)
        // ...and it still is not proof of identity, because only the operator says so.
        assertTrue(intel.registration!!.isAuthoritativeIdentity)
        assertFalse(intel.hasEvidencedRegistration)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, intel.resolvedVerificationStatus)
    }

    @Test
    fun `manual verification cites the operator and holds no verified date`() {
        val intel = ChemicalManualEntry
            .outcome(mixtureDraft(), existing = null, editedAt = at).intelligence

        assertNull(intel.verification.verifiedAt)
        assertFalse(intel.verification.sources.any { it.kind.isAuthoritative })
        assertTrue(intel.verification.sources.all { it.kind.isSelfReported })
    }

    // ---- Rates ----

    @Test
    fun `every label rate shape survives save and reload`() {
        val draft = mixtureDraft().copy(
            productRates = listOf(
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    valueText = "1.5",
                    unit = "L",
                ),
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    minText = "1.0",
                    maxText = "1.5",
                    unit = "L",
                ),
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.PER_100_LITRES,
                    valueText = "100",
                    unit = "mL",
                ),
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                    minText = "80",
                    maxText = "100",
                    unit = "mL",
                ),
            ),
        )
        val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence
        val rates = intel.registeredUses.productLevelRates()

        assertEquals(4, rates.size)
        assertEquals("1.5 L/ha", rates[0].displayRate)
        assertEquals("1–1.5 L/ha", rates[1].displayRate)
        assertEquals("100 mL/100 L", rates[2].displayRate)
        assertEquals("80–100 mL/100 L", rates[3].displayRate)

        val reloaded = ChemicalManualEntry.draft(savedFrom(intel), "AU")
        assertEquals(4, reloaded.productRates.size)
        assertEquals("1.5", reloaded.productRates[0].valueText)
        assertEquals("1", reloaded.productRates[1].minText)
        assertEquals("1.5", reloaded.productRates[1].maxText)
        assertEquals(ChemicalLabelRateBasis.PER_100_LITRES, reloaded.productRates[2].basis)
        assertEquals("80", reloaded.productRates[3].minText)
    }

    @Test
    fun `a range typed back to front is stored low to high`() {
        val draft = mixtureDraft().copy(
            productRates = listOf(
                ChemicalManualRateDraft(
                    basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    minText = "2.0",
                    maxText = "1.0",
                    unit = "L",
                ),
            ),
        )
        val rate = ChemicalManualEntry.outcome(draft, existing = null)
            .intelligence.registeredUses.productLevelRates().single()

        assertEquals(1.0, rate.minValue!!, 0.0001)
        assertEquals(2.0, rate.maxValue!!, 0.0001)
        // A suggestion must never be handed the top of a band.
        assertEquals(1.0, rate.proposedValue!!, 0.0001)
        assertTrue(
            ChemicalManualEntry.problems(draft).any { it.contains("back to front") },
        )
    }

    @Test
    fun `the label rate basis drives the Guided Spray choices, not the carrier`() {
        val area = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                productRates = listOf(
                    ChemicalManualRateDraft(
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        valueText = "1.5",
                        unit = "L",
                    ),
                ),
            ),
            existing = null,
        ).intelligence

        // An area label leaves the whole-block vs treated-band decision to the job.
        assertEquals(listOf(ChemicalLabelRateBasis.PER_HECTARE), area.labelRateBases)
        assertEquals(
            listOf(SprayProductRateBasis.WHOLE_BLOCK_AREA, SprayProductRateBasis.TREATED_AREA),
            area.labelRateBases.single().compatibleProductRateBases,
        )

        val volume = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                productRates = listOf(
                    ChemicalManualRateDraft(
                        basis = ChemicalLabelRateBasis.PER_100_LITRES,
                        valueText = "100",
                        unit = "mL",
                    ),
                ),
            ),
            existing = null,
        ).intelligence

        // A per-100 L label stays carrier-based and offers exactly one option.
        assertEquals(
            listOf(SprayProductRateBasis.PER_100_LITRES),
            volume.labelRateBases.single().compatibleProductRateBases,
        )
    }

    @Test
    fun `an application decision is never stored inside the legal label rate`() {
        val intel = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                productRates = listOf(
                    ChemicalManualRateDraft(
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        valueText = "1.5",
                        unit = "L",
                    ),
                ),
            ),
            existing = null,
        ).intelligence
        val rate = intel.registeredUses.productLevelRates().single()

        // The label basis is the product's. Whole-block vs treated-area is the
        // spray job's decision and has no representation in here at all.
        assertEquals(ChemicalLabelRateBasis.PER_HECTARE, rate.basis)
        assertTrue(rate.basis.isAreaBased)
        assertFalse(rate.basis.isVolumeBased)
        assertNull(rate.rawText)
    }

    @Test
    fun `product-level rates do not claim a registered use`() {
        val intel = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                productRates = listOf(
                    ChemicalManualRateDraft(
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        valueText = "1.5",
                        unit = "L",
                    ),
                ),
            ),
            existing = null,
        ).intelligence

        // Knowing a rate is not knowing which crop and disease it was registered
        // for. The carrier contributes rate information and no use claim.
        assertEquals(1, intel.registeredUses.size)
        assertTrue(intel.registeredUses.statedUses().isEmpty())
        assertTrue(intel.registeredUses.viticulturalTargets().isEmpty())
        assertEquals(1, intel.labelRateBases.size)
    }

    // ---- Uses ----

    @Test
    fun `multiple structured uses survive save and reload`() {
        val draft = mixtureDraft().copy(
            uses = listOf(
                ChemicalManualUseDraft(
                    crop = "Grapes",
                    targetRaw = "Powdery Mildew",
                    rates = listOf(
                        ChemicalManualRateDraft(
                            basis = ChemicalLabelRateBasis.PER_100_LITRES,
                            valueText = "100",
                            unit = "mL",
                        ),
                    ),
                    withholdingPeriodDaysText = "14",
                    reEntryPeriodHoursText = "24",
                    restrictions = "Do not apply after bunch closure",
                ),
                ChemicalManualUseDraft(
                    crop = "Grapes",
                    targetRaw = "Botrytis",
                    rates = listOf(
                        ChemicalManualRateDraft(
                            basis = ChemicalLabelRateBasis.PER_HECTARE,
                            valueText = "2",
                            unit = "L",
                        ),
                    ),
                    withholdingPeriodDaysText = "30",
                ),
            ),
        )
        val intel = ChemicalManualEntry.outcome(draft, existing = null).intelligence
        val uses = intel.registeredUses.statedUses()

        assertEquals(2, uses.size)
        assertEquals("Grapes", uses[0].crop)
        assertEquals("Powdery Mildew", uses[0].targetRaw)
        assertEquals(SprayTarget.POWDERY_MILDEW, uses[0].resolvedTarget)
        assertEquals(14, uses[0].withholdingPeriodDays)
        assertEquals(24, uses[0].reEntryPeriodHours)
        assertEquals("Do not apply after bunch closure", uses[0].restrictions)
        assertEquals(SprayTarget.BOTRYTIS, uses[1].resolvedTarget)
        assertEquals(30, uses[1].withholdingPeriodDays)

        val reloaded = ChemicalManualEntry.draft(savedFrom(intel), "AU")
        assertEquals(2, reloaded.uses.size)
        assertEquals("Powdery Mildew", reloaded.uses[0].targetRaw)
        assertEquals("14", reloaded.uses[0].withholdingPeriodDaysText)
        assertEquals("24", reloaded.uses[0].reEntryPeriodHoursText)
        assertEquals("100", reloaded.uses[0].rates.single().valueText)
        assertEquals("30", reloaded.uses[1].withholdingPeriodDaysText)
    }

    @Test
    fun `a target VineTrack has no word for is recorded rather than force-fitted`() {
        val draft = mixtureDraft().copy(
            uses = listOf(ChemicalManualUseDraft(crop = "Grapes", targetRaw = "Phomopsis cane blight")),
        )
        val use = ChemicalManualEntry.outcome(draft, existing = null)
            .intelligence.registeredUses.statedUses().single()

        assertEquals("Phomopsis cane blight", use.targetRaw)
        // Guessing a typed target would tell the Resistance Engine the wrong
        // disease was being managed, so it stays unmapped and stays recorded.
        assertNull(use.resolvedTarget)
        assertTrue(use.isViticultural)
    }

    // ---- Critical vs non-critical editing ----

    @Test
    fun `a chemistry edit re-resolves trust on a verified record`() {
        // A genuinely verified record, as Match & Verify would have left it.
        val verified = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
            .let { manual ->
                manual.copy(
                    activeIngredients = manual.activeIngredients.map {
                        it.copy(
                            groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                            identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                        )
                    },
                    registration = com.rork.vinetrack.data.chemical.ChemicalRegistration.of(
                        countryCode = "AU",
                        scheme = ChemicalRegistrationScheme.APVMA,
                        registrationNumber = "62764",
                    ),
                    verification = com.rork.vinetrack.data.chemical.ChemicalVerification(
                        status = ChemicalVerificationStatus.VERIFIED,
                        sources = listOf(
                            com.rork.vinetrack.data.chemical.ChemicalDataSource(
                                kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                                name = "APVMA PUBCRIS",
                            ),
                            AuthoritativeActivityGroups.source(),
                        ),
                        verifiedAt = at,
                    ),
                )
            }
        assertEquals(ChemicalVerificationStatus.VERIFIED, verified.resolvedVerificationStatus)

        val edited = mixtureDraft().copy(
            actives = listOf(
                activeDraft("Tebuconazole", "200", code = "3"),
                // Hand-changed to a group nothing supports.
                activeDraft("Azoxystrobin", "120", code = "7"),
            ),
        )
        val outcome = ChemicalManualEntry.outcome(edited, existing = verified, editedAt = at)

        assertTrue(outcome.hasResistanceCriticalChange)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
        assertTrue(outcome.isDowngrade)
        assertNotNull(outcome.warning)
    }

    @Test
    fun `commercial and operational fields are untouched by the chemistry editor`() {
        val intel = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        val saved = savedFrom(intel)

        val reloaded = ChemicalManualEntry.draft(saved, "AU")
        val outcome = ChemicalManualEntry.outcome(
            reloaded.copy(actives = reloaded.actives + activeDraft("Sulphur", "800", code = "M2")),
            existing = intel,
        )

        // The chemistry editor's own output carries no commercial data at all,
        // which is structurally why price, pack, stock and notes cannot be lost.
        assertEquals(3, outcome.intelligence.activeIngredients.size)
        assertEquals(10.0, saved.packSize!!, 0.0001)
        assertEquals(425.0, saved.pricePerPack!!, 0.0001)
        assertEquals(3.0, saved.inventoryQuantity!!, 0.0001)
        assertEquals("Shed B, top shelf", saved.notes)
        assertEquals("Do not tank-mix with oil", saved.applicationNotes)
    }

    @Test
    fun `an untouched draft proposes no change at all`() {
        val intel = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        val saved = savedFrom(intel)
        val reloaded = ChemicalManualEntry.draft(saved, "AU")

        val outcome = ChemicalManualEntry.outcome(reloaded, existing = intel)

        // This is what lets a price-only or notes-only save leave verification
        // exactly where it was: nothing resistance-critical moved.
        assertFalse(outcome.hasResistanceCriticalChange)
        assertEquals(intel.resolvedVerificationStatus, outcome.resolvedStatus)
    }

    @Test
    fun `a legacy record's free-text seed is not treated as prior evidence`() {
        val legacy = SavedChemical(
            id = "legacy-1",
            vineyardId = "v1",
            name = "Old Fungicide",
            activeIngredient = "Azoxystrobin 250 g/L",
            chemicalGroup = "11",
            productCategory = "fungicide",
        )
        assertNull(legacy.storedIntelligence)
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, legacy.verificationStatus)

        // The editor opens on what the old columns implied...
        val draft = ChemicalManualEntry.draft(legacy, "AU")
        assertEquals("Azoxystrobin", draft.actives.single().name)

        // ...and saving it is the operator asserting those values themselves, so
        // the record becomes Unverified rather than inheriting the seed's status.
        val outcome = ChemicalManualEntry.outcome(draft, chemical = legacy, editedAt = at)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, outcome.resolvedStatus)
        assertEquals(
            ChemicalDataSourceKind.MANUAL_ENTRY,
            outcome.intelligence.activeIngredients.single().groupSource,
        )
    }

    // ---- Match & Verify / Re-verify compatibility ----

    @Test
    fun `a manual product with a typed registration is offered Re-verify`() {
        val intel = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                registrationScheme = ChemicalRegistrationScheme.APVMA,
                registrationNumber = "12345",
            ),
            existing = null,
        ).intelligence
        val saved = savedFrom(intel)

        assertTrue(ChemicalReverification.isOffered(saved, "AU"))
        val plan = ChemicalReverification.plan(saved, "AU")
        // The typed number is the strongest identity available, so the re-check
        // leads with it instead of restarting a brand-name search.
        assertEquals("12345", plan.registrationNumber)
        assertEquals(ChemicalRegistrationScheme.APVMA, plan.scheme)
    }

    @Test
    fun `a manual product with only a registrant and country is still re-verifiable`() {
        val intel = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        val saved = savedFrom(intel)

        // No registration number, but product name + registrant + country is a real
        // identity tier, so the domain can go and look. Manual entry does not have
        // to be complete to be re-checkable later.
        assertNull(intel.registration?.registrationNumber)
        assertTrue(ChemicalReverification.isOffered(saved, "AU"))
        assertEquals("Example Crop Science", ChemicalReverification.plan(saved, "AU").registrant)
    }

    @Test
    fun `a manual product with no country cannot be re-verified yet`() {
        val bare = ChemicalManualDraft(
            productName = "Shed Mix",
            actives = listOf(activeDraft("Tebuconazole", "200", code = "3")),
        )
        val saved = savedFrom(
            ChemicalManualEntry.outcome(bare, existing = null).intelligence,
            name = "Shed Mix",
        )

        // Without a country there is no register to check against, and the domain
        // says so rather than running a guess.
        assertFalse(ChemicalReverification.isOffered(saved, ""))
        assertNotNull(ChemicalReverification.unavailableReason(saved, ""))
    }

    @Test
    fun `matching a manual product later compares against what the operator recorded`() {
        val manual = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        // What a register would come back with six months later: the same two
        // actives, authoritatively classified, and one concentration corrected.
        val authoritative = manual.copy(
            activeIngredients = manual.activeIngredients.mapIndexed { index, active ->
                active.copy(
                    concentration = if (index == 1) 250.0 else active.concentration,
                    groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                    identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                )
            },
        )

        val diff = com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffer
            .diff(current = manual, candidate = authoritative)

        // The operator's record is the baseline the review screen diffs against, so
        // nothing they entered is discarded before they have seen the change.
        assertTrue(diff.hasMeaningfulChanges)
        val change = diff.changes.first { it.currentValue?.contains("120") == true }
        assertTrue(change.currentValue?.contains("120") == true)
        assertTrue(change.candidateValue?.contains("250") == true)
        // And a groupSource-only difference is NOT a chemistry change: the meaning
        // of the record is unmoved, only the evidence behind it.
        val evidenceOnly = com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffer.diff(
            current = manual,
            candidate = manual.copy(
                activeIngredients = manual.activeIngredients.map {
                    it.copy(groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION)
                },
            ),
        )
        assertFalse(evidenceOnly.hasResistanceCriticalChanges)
    }

    // ---- Snapshot and history ----

    @Test
    fun `selecting a manual product captures its complete structure`() {
        val intel = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        val saved = savedFrom(intel)

        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = saved.id,
            productName = saved.name,
            library = listOf(saved),
            capturedAt = at,
        )
        val snapshot = resolution.snapshot
        assertNotNull(snapshot)
        checkNotNull(snapshot)
        assertEquals(ChemicalSnapshotCapture.MatchKind.IDENTIFIER, resolution.match)

        assertEquals(2, snapshot.activeIngredients.size)
        assertEquals(listOf("3", "11"), snapshot.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, snapshot.verificationStatus)
        assertEquals("Custom Mix 300", snapshot.productName)
        assertEquals(saved.id, snapshot.savedChemicalId)
        assertEquals(at, snapshot.capturedAt)
        // Manual provenance travels with the frozen record.
        assertTrue(
            snapshot.activeIngredients.all {
                it.groupSource == ChemicalDataSourceKind.MANUAL_ENTRY
            },
        )
    }

    @Test
    fun `a completed spray keeps the chemistry it was recorded against`() {
        val manual = ChemicalManualEntry.outcome(mixtureDraft(), existing = null).intelligence
        val saved = savedFrom(manual)
        val frozen = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = saved.id,
            productName = saved.name,
            library = listOf(saved),
            capturedAt = at,
        ).snapshot
        checkNotNull(frozen)

        // The Saved Chemical is later matched and its chemistry moves on.
        val corrected = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                actives = listOf(activeDraft("Tebuconazole", "200", code = "3")),
            ),
            existing = manual,
        )
        assertEquals(listOf("3"), corrected.intelligence.activityGroupCodes)

        // The historical record does not move with it.
        assertEquals(listOf("3", "11"), frozen.activityGroupCodes)
        assertEquals(2, frozen.activeIngredients.size)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, frozen.verificationStatus)
        assertEquals(at, frozen.capturedAt)
    }

    // ---- Offline / JSON parity ----

    @Test
    fun `a structured mixture survives the offline JSON round trip intact`() {
        val intel = ChemicalManualEntry.outcome(
            mixtureDraft().copy(
                registrationScheme = ChemicalRegistrationScheme.APVMA,
                registrationNumber = "12345",
                productRates = listOf(
                    ChemicalManualRateDraft(
                        basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                        minText = "1.0",
                        maxText = "1.5",
                        unit = "L",
                    ),
                ),
                uses = listOf(
                    ChemicalManualUseDraft(
                        crop = "Grapes",
                        targetRaw = "Powdery Mildew",
                        withholdingPeriodDaysText = "14",
                        reEntryPeriodHoursText = "24",
                    ),
                ),
            ),
            existing = null,
        ).intelligence

        val encoded = json.encodeToString(ChemicalIntelligence.serializer(), intel)
        val decoded = json.decodeFromString(ChemicalIntelligence.serializer(), encoded)

        // The whole point: an offline create must not drop the structured arrays
        // on its way through the queue.
        assertEquals(intel, decoded)
        assertEquals(2, decoded.activeIngredients.size)
        assertEquals(listOf("3", "11"), decoded.activityGroupCodes)
        assertEquals("12345", decoded.registration?.registrationNumber)
        assertEquals(2, decoded.registeredUses.size)
        assertEquals(14, decoded.registeredUses.statedUses().single().withholdingPeriodDays)
        assertEquals(
            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            decoded.registeredUses.productLevelRates().single().basis,
        )
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, decoded.resolvedVerificationStatus)
    }

    @Test
    fun `an empty draft produces nothing rather than an empty shell`() {
        val empty = ChemicalManualDraft(actives = listOf(ChemicalManualActiveDraft()))
        val proposed = ChemicalManualEntry.proposedIntelligence(empty, existing = null)

        // A record whose chemistry was never entered must not be given a structured
        // payload just because the form was opened.
        assertTrue(proposed.isEmpty)
        assertTrue(proposed.activeIngredients.isEmpty())
        assertNull(proposed.registration)
    }

    @Test
    fun `a decimal comma is read rather than dropped`() {
        assertEquals(1.5, ChemicalManualEntry.parseDouble("1,5")!!, 0.0001)
        assertEquals(1.5, ChemicalManualEntry.parseDouble(" 1.5 ")!!, 0.0001)
        assertNull(ChemicalManualEntry.parseDouble(""))
        assertNull(ChemicalManualEntry.parseDouble("abc"))
        assertEquals(14, ChemicalManualEntry.parseInt("14"))
    }

    @Test
    fun `a duplicated active is reported`() {
        val draft = mixtureDraft().copy(
            actives = listOf(
                activeDraft("Tebuconazole", "200", code = "3"),
                activeDraft("tebuconazole", "200", code = "3"),
            ),
        )
        assertTrue(ChemicalManualEntry.problems(draft).any { it.contains("listed twice") })
    }

    @Test
    fun `a product name is required`() {
        val draft = mixtureDraft().copy(productName = "  ")
        assertTrue(ChemicalManualEntry.problems(draft).any { it.contains("Product name") })
        assertTrue(ChemicalManualEntry.problems(mixtureDraft()).isEmpty())
    }
}
