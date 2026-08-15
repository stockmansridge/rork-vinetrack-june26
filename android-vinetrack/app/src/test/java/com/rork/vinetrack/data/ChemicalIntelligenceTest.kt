package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.rateBases
import com.rork.vinetrack.data.chemical.viticultural
import com.rork.vinetrack.data.chemical.viticulturalTargets
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
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
 * Contract tests for the Chemical Intelligence foundation.
 *
 * The iOS suite `ChemicalIntelligenceTests` asserts the same fixtures and the
 * same outcomes, so both platforms classify a product identically.
 *
 * Everything here protects one rule: resistance decisions are made from
 * structured, source-attributed data, never from parsing a free-text
 * `chemical_group` string — and a product is only ever as trusted as the weakest
 * evidence behind it.
 */
class ChemicalIntelligenceTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    // ---- Fixtures -----------------------------------------------------------

    private fun frac(code: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, code)

    private fun active(
        name: String,
        concentration: Double? = null,
        group: ChemicalActivityGroup? = null,
        groupSource: ChemicalDataSourceKind? = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
    ) = ChemicalActiveIngredient(
        name = name,
        concentration = concentration,
        concentrationUnit = concentration?.let { ChemicalConcentrationUnit.GRAMS_PER_LITRE },
        activityGroup = group,
        groupSource = group?.let { groupSource },
        identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
    )

    private fun registration(
        country: String = "AU",
        scheme: ChemicalRegistrationScheme? = ChemicalRegistrationScheme.APVMA,
        number: String? = "62764",
    ) = ChemicalRegistration.of(
        countryCode = country,
        scheme = scheme,
        registrationNumber = number,
        registrant = "Example Crop Science",
        registeredProductName = "Example Fungicide",
    )

    private fun verifiedEvidence() = ChemicalVerification(
        status = ChemicalVerificationStatus.VERIFIED,
        sources = listOf(
            ChemicalDataSource(
                kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                name = "APVMA PUBCRIS",
            ),
            AuthoritativeActivityGroups.source(),
        ),
        verifiedAt = "2026-08-15T00:00:00Z",
    )

    /**
     * THE worked example from the specification: a two-active mixture that must
     * count as Group 3 AND Group 11.
     */
    private fun combinationProduct() = ChemicalIntelligence(
        activeIngredients = listOf(
            active("Tebuconazole", 200.0, frac("3")),
            active("Azoxystrobin", 120.0, frac("11")),
        ),
        registration = registration(),
        verification = verifiedEvidence(),
        registeredUses = listOf(
            ChemicalRegisteredUse(
                crop = "Grapes (winegrapes)",
                targetRaw = "Powdery mildew",
                rates = listOf(
                    ChemicalLabelRate(
                        label = "Standard",
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        value = 1.5,
                        unit = "L",
                    ),
                ),
                withholdingPeriodDays = 30,
            ),
        ),
        productCategory = "fungicide",
    )

    private fun singleActiveProduct() = ChemicalIntelligence(
        activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
        registration = registration(number = "50123"),
        verification = verifiedEvidence(),
        productCategory = "fungicide",
    )

    private fun savedChemical(
        name: String = "Example Fungicide",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        modeOfAction: String = "",
        productCategory: String = "fungicide",
        intelligence: ChemicalIntelligence? = null,
    ): SavedChemical = SavedChemical(
        id = "chem-1",
        vineyardId = "vineyard-1",
        name = name,
        chemicalGroup = chemicalGroup,
        manufacturer = "Example Crop Science",
        activeIngredient = activeIngredient,
        modeOfAction = modeOfAction,
        productCategory = productCategory,
        activeIngredients = intelligence?.activeIngredients,
        activityGroups = intelligence?.activityGroupCodes,
        registrationCountry = intelligence?.registration?.countryCode,
        registrationScheme = intelligence?.registration?.scheme?.raw,
        registrationNumber = intelligence?.registration?.registrationNumber,
        registrant = intelligence?.registration?.registrant,
        registeredProductName = intelligence?.registration?.registeredProductName,
        verificationStatusRaw = intelligence?.verification?.status?.raw,
        verificationSources = intelligence?.verification?.sources,
        verificationConflicts = intelligence?.verification?.conflicts,
        verificationUnresolvedFields = intelligence?.verification?.unresolvedFields,
        verifiedAt = intelligence?.verification?.verifiedAt,
        registeredUses = intelligence?.registeredUses,
        labelRateBases = intelligence?.labelRateBases?.map { it.raw },
        activityGroupTableVersion = intelligence?.activityGroupTableVersion,
        intelligenceSchemaVersion = intelligence?.schemaVersion,
    )

    private inline fun <reified T> roundTrip(value: T): T =
        json.decodeFromString(json.encodeToString(value))

    // ---- Single active ------------------------------------------------------

    @Test
    fun `single active product exposes exactly one group`() {
        val intel = singleActiveProduct()

        assertEquals(1, intel.activeIngredients.size)
        assertEquals(listOf("11"), intel.activityGroupCodes)
        assertEquals(ChemicalActivityGroupScheme.FRAC, intel.activityGroups.first().scheme)
        assertEquals(ChemicalVerificationStatus.VERIFIED, intel.resolvedVerificationStatus)
        assertEquals(listOf("11"), roundTrip(intel).activityGroupCodes)
    }

    // ---- Combination product ------------------------------------------------

    @Test
    fun `two active mixture counts as both groups never as one fused string`() {
        val intel = combinationProduct()

        // The headline requirement of the whole stage.
        assertEquals(listOf("3", "11"), intel.activityGroupCodes)
        assertNotEquals(listOf("3 + 11"), intel.activityGroupCodes)
        assertEquals(2, intel.activityGroups.size)

        // Each group belongs to its OWN active — the relationship the future
        // engine needs in order to reason about a mixture at all.
        assertEquals("3", intel.activeIngredients[0].activityGroup?.code)
        assertEquals("11", intel.activeIngredients[1].activityGroup?.code)
    }

    @Test
    fun `group order is stable regardless of entry order`() {
        val forward = combinationProduct()
        val reversed = forward.copy(activeIngredients = forward.activeIngredients.reversed())

        // Two identical products must never persist as two different-looking
        // histories, or the future rotation analysis sees phantom variety.
        assertEquals(forward.activityGroupCodes, reversed.activityGroupCodes)
        assertEquals(listOf("3", "11"), reversed.activityGroupCodes)
    }

    @Test
    fun `all groups of a mixture survive persistence and reload`() {
        val reloaded = roundTrip(combinationProduct())

        assertEquals(listOf("3", "11"), reloaded.activityGroupCodes)
        assertEquals(2, reloaded.activeIngredients.size)
        assertEquals("Tebuconazole", reloaded.activeIngredients[0].name)
        assertEquals(200.0, reloaded.activeIngredients[0].concentration!!, 0.0001)
        assertEquals(
            ChemicalConcentrationUnit.GRAMS_PER_LITRE,
            reloaded.activeIngredients[0].concentrationUnit,
        )
        assertEquals("11", reloaded.activeIngredients[1].activityGroup?.code)
        assertEquals(ChemicalVerificationStatus.VERIFIED, reloaded.resolvedVerificationStatus)
    }

    @Test
    fun `legacy group string is derived from the groups not the reverse`() {
        val intel = combinationProduct()

        assertEquals("3 + 11", intel.legacyChemicalGroup)
        assertEquals(
            "Tebuconazole 200 g/L + Azoxystrobin 120 g/L",
            intel.legacyActiveIngredient,
        )

        // The direction of authority is what matters: dropping an active changes
        // the projection, because the projection is an output.
        val single = intel.copy(activeIngredients = intel.activeIngredients.dropLast(1))
        assertEquals("3", single.legacyChemicalGroup)
    }

    // ---- Legacy chemicals ---------------------------------------------------

    @Test
    fun `pre chemical intelligence chemical still loads and keeps display fields`() {
        val legacy = savedChemical(
            activeIngredient = "Tebuconazole 200 g/L + Azoxystrobin 120 g/L",
            chemicalGroup = "3 + 11",
            modeOfAction = "3 (DMI) + 11 (QoI / Strobilurin)",
        )

        // Untouched scalars: the Chemical Store renders exactly as it did.
        assertEquals("3 + 11", legacy.chemicalGroup)
        assertEquals("Tebuconazole 200 g/L + Azoxystrobin 120 g/L", legacy.activeIngredient)
        assertNull(legacy.storedIntelligence)

        // The candidate reading identifies both actives for the audit...
        val seeded = legacy.resolvedIntelligence
        assertEquals(listOf("Tebuconazole", "Azoxystrobin"), seeded.activeIngredients.map { it.name })
        // ...but is explicitly UNMATCHED, never verified.
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, seeded.resolvedVerificationStatus)
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, legacy.verificationStatus)
    }

    @Test
    fun `groups parsed from legacy text can never satisfy a verified claim`() {
        val seeded = savedChemical(
            activeIngredient = "Tebuconazole + Azoxystrobin",
            chemicalGroup = "3 + 11",
        ).resolvedIntelligence

        assertEquals(listOf("3", "11"), seeded.activityGroupCodes)
        // Every one is tagged as coming from an old record, which makes
        // hasAuthoritativeGroup false and Verified structurally unreachable.
        assertTrue(
            seeded.activeIngredients.all { it.groupSource == ChemicalDataSourceKind.LEGACY_RECORD },
        )
        assertTrue(seeded.activeIngredients.none { it.hasAuthoritativeGroup })
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, seeded.resolvedVerificationStatus)
    }

    @Test
    fun `legacy group is never attached to the wrong active in a mixture`() {
        // Two actives but only one parsable group: which active owns it is
        // unknowable, so attaching it anywhere would be a fabrication.
        val seeded = savedChemical(
            activeIngredient = "Tebuconazole + Azoxystrobin",
            chemicalGroup = "11",
        ).resolvedIntelligence

        assertEquals(2, seeded.activeIngredients.size)
        assertTrue(seeded.activeIngredients.all { it.activityGroup == null })
        assertTrue(seeded.activityGroupCodes.isEmpty())
    }

    @Test
    fun `chemistry name in the legacy group field yields no false codes`() {
        val legacy = savedChemical(
            activeIngredient = "Seaweed extract",
            chemicalGroup = "Biostimulant - Amino Acid",
            productCategory = "biostimulant",
        )

        assertTrue(legacy.resolvedIntelligence.activityGroupCodes.isEmpty())
        assertFalse(ChemicalActivityGroup.isPlausibleCode("STROBILURIN"))
        assertTrue(ChemicalActivityGroup.isPlausibleCode("M5"))
        assertTrue(ChemicalActivityGroup.isPlausibleCode("G"))
        assertTrue(ChemicalActivityGroup.isPlausibleCode("4A"))
    }

    @Test
    fun `saving a legacy chemical never rewrites its own display fields`() {
        val (activeText, groupText) = savedChemical(
            activeIngredient = "Tebuconazole 200 g/L",
            chemicalGroup = "Triazole",
        ).legacyProjection

        // No structured intelligence means no derived projection: the operator's
        // own words survive the round trip untouched.
        assertEquals("Triazole", groupText)
        assertEquals("Tebuconazole 200 g/L", activeText)
    }

    @Test
    fun `structured chemical writes derived legacy scalars for old clients`() {
        val (activeText, groupText) = savedChemical(
            activeIngredient = "old text",
            chemicalGroup = "old group",
            intelligence = combinationProduct(),
        ).legacyProjection

        assertEquals("3 + 11", groupText)
        assertEquals("Tebuconazole 200 g/L + Azoxystrobin 120 g/L", activeText)
    }

    // ---- Verification states ------------------------------------------------

    @Test
    fun `verification states round trip`() {
        for (status in ChemicalVerificationStatus.entries) {
            val verification = ChemicalVerification(status = status)
            assertEquals(status, roundTrip(verification).status)
        }
    }

    @Test
    fun `product with an unconfirmed group cannot claim verified`() {
        val intel = combinationProduct().let {
            it.copy(
                activeIngredients = listOf(
                    it.activeIngredients[0],
                    it.activeIngredients[1].copy(
                        groupSource = ChemicalDataSourceKind.AI_INTERPRETATION,
                    ),
                ),
            )
        }

        assertEquals(ChemicalVerificationStatus.VERIFIED, intel.verification.status)
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.resolvedVerificationStatus)
        assertFalse(intel.isResistanceDependable)
    }

    @Test
    fun `product with no registration cannot claim verified`() {
        val intel = combinationProduct().copy(registration = null)
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.resolvedVerificationStatus)
    }

    @Test
    fun `an ai hit alone is never verified`() {
        val intel = ChemicalIntelligence(
            activeIngredients = listOf(
                active("Azoxystrobin", 250.0, frac("11"), ChemicalDataSourceKind.AI_INTERPRETATION),
            ),
            registration = registration(),
            verification = ChemicalVerification(
                status = ChemicalVerificationStatus.VERIFIED,
                sources = listOf(
                    ChemicalDataSource(
                        kind = ChemicalDataSourceKind.AI_INTERPRETATION,
                        name = "Model extraction",
                    ),
                ),
            ),
        )

        // The lookup found something real, and it is still not a verification.
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.resolvedVerificationStatus)
        assertFalse(ChemicalDataSourceKind.AI_INTERPRETATION.isAuthoritative)
    }

    @Test
    fun `an unresolved field keeps a product below verified`() {
        val intel = combinationProduct().let {
            it.copy(verification = it.verification.copy(unresolvedFields = listOf("registered_uses")))
        }
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, intel.resolvedVerificationStatus)
    }

    @Test
    fun `manually entered chemical defaults to unverified`() {
        val manual = ChemicalIntelligence(
            activeIngredients = listOf(
                ChemicalActiveIngredient(
                    name = "Tebuconazole",
                    concentration = 430.0,
                    concentrationUnit = ChemicalConcentrationUnit.GRAMS_PER_LITRE,
                    activityGroup = frac("3"),
                    groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                    identitySource = ChemicalDataSourceKind.MANUAL_ENTRY,
                ),
            ),
            verification = ChemicalVerification.manual(),
            productCategory = "fungicide",
        )

        // Structured entry is still supported — the operator gets the full model,
        // not a free-text box — but typing is not evidence.
        assertEquals(1, manual.activeIngredients.size)
        assertEquals(listOf("3"), manual.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, manual.resolvedVerificationStatus)
        assertFalse(manual.isResistanceDependable)
    }

    // ---- Source conflict ----------------------------------------------------

    @Test
    fun `disagreement between extraction and classification becomes a conflict`() {
        // The specification's example: extraction says Group 11, the
        // authoritative classification says Group 3.
        val outcome = AuthoritativeActivityGroups.reconcile(
            activeName = "Tebuconazole",
            extracted = frac("11"),
            extractedSource = ChemicalDataSourceKind.AI_INTERPRETATION,
        )

        val conflict = outcome.conflict
        assertNotNull(conflict)
        assertEquals("activity_group", conflict!!.field)
        assertEquals("Tebuconazole", conflict.activeIngredientName)
        assertTrue(conflict.extractedValue.contains("11"))
        assertTrue(conflict.authoritativeValue.contains("3"))

        // The authoritative answer is what survives — the extracted value is
        // never silently kept.
        assertEquals("3", outcome.group?.code)
        assertEquals(ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION, outcome.source)
    }

    @Test
    fun `conflicted product can never be verified whatever status is stored`() {
        var intel = combinationProduct()
        intel = intel.copy(
            verification = intel.verification.addingConflict(
                ChemicalVerificationConflict(
                    field = "activity_group",
                    activeIngredientName = "Tebuconazole",
                    extractedValue = "FRAC 11",
                    authoritativeValue = "FRAC 3",
                ),
            ),
        )

        assertEquals(ChemicalVerificationStatus.CONFLICT, intel.verification.status)
        assertEquals(ChemicalVerificationStatus.CONFLICT, intel.resolvedVerificationStatus)
        assertFalse(intel.isResistanceDependable)

        // Even forcing the stored status back to verified cannot promote it: the
        // resolved status is computed from evidence, not from the claim.
        val forced = intel.copy(
            verification = intel.verification.copy(status = ChemicalVerificationStatus.VERIFIED),
        )
        assertEquals(ChemicalVerificationStatus.CONFLICT, forced.resolvedVerificationStatus)
        assertEquals(
            ChemicalVerificationStatus.CONFLICT,
            roundTrip(forced).resolvedVerificationStatus,
        )
    }

    @Test
    fun `agreement between sources upgrades the attribution not the value`() {
        val outcome = AuthoritativeActivityGroups.reconcile(
            activeName = "Azoxystrobin",
            extracted = frac("11"),
            extractedSource = ChemicalDataSourceKind.AI_INTERPRETATION,
        )

        assertNull(outcome.conflict)
        assertEquals("11", outcome.group?.code)
        assertEquals(ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION, outcome.source)
    }

    @Test
    fun `active the table does not know keeps its weaker attribution`() {
        val outcome = AuthoritativeActivityGroups.reconcile(
            activeName = "Novelmoleculeium",
            extracted = frac("11"),
            extractedSource = ChemicalDataSourceKind.AI_INTERPRETATION,
        )

        // No opinion is not agreement. The group survives so the operator can see
        // it, but it stays attributed to the AI and cannot reach Verified.
        assertNull(outcome.conflict)
        assertEquals("11", outcome.group?.code)
        assertEquals(ChemicalDataSourceKind.AI_INTERPRETATION, outcome.source)
        assertFalse(AuthoritativeActivityGroups.knows("Novelmoleculeium"))
    }

    // ---- Country separation -------------------------------------------------

    @Test
    fun `identically named au and nz products are different identities`() {
        val au = ChemicalRegistration.of(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "62764",
            registeredProductName = "Example Fungicide",
        )
        val nz = ChemicalRegistration.of(
            countryCode = "NZ",
            scheme = ChemicalRegistrationScheme.ACVM,
            registrationNumber = "P7391",
            registeredProductName = "Example Fungicide",
        )

        assertEquals("AU:apvma:62764", au.identityKey)
        assertEquals("NZ:acvm:P7391", nz.identityKey)
        assertNotEquals(au.identityKey, nz.identityKey)
    }

    @Test
    fun `same registration number in two countries is still two products`() {
        val au = ChemicalRegistration.of(
            "AU", ChemicalRegistrationScheme.APVMA, registrationNumber = "1234",
        )
        val nz = ChemicalRegistration.of(
            "NZ", ChemicalRegistrationScheme.ACVM, registrationNumber = "1234",
        )

        // Country is part of the key precisely so NZ rates can never be read off
        // an AU label.
        assertNotEquals(au.identityKey, nz.identityKey)
    }

    @Test
    fun `each country resolves to its own registers and others stay empty`() {
        assertEquals(
            listOf(ChemicalRegistrationScheme.APVMA),
            ChemicalRegistrationScheme.schemesForCountry("AU"),
        )
        assertEquals(
            listOf(ChemicalRegistrationScheme.ACVM, ChemicalRegistrationScheme.NZ_EPA),
            ChemicalRegistrationScheme.schemesForCountry("NZ"),
        )
        // Extensible without pretending coverage exists.
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("US").isEmpty())
    }

    @Test
    fun `country names and codes normalise to the same stored value`() {
        assertEquals("AU", ChemicalRegistration.of("Australia").countryCode)
        assertEquals("NZ", ChemicalRegistration.of("New Zealand").countryCode)
        assertEquals("NZ", ChemicalRegistration.of("nz").countryCode)
    }

    @Test
    fun `registration without a scheme cannot underwrite verified`() {
        val vague = ChemicalRegistration.of(
            "AU", ChemicalRegistrationScheme.OTHER, registrationNumber = "?",
        )
        assertFalse(vague.isAuthoritativeIdentity)
        assertTrue(registration().isAuthoritativeIdentity)
    }

    // ---- Label rate basis ---------------------------------------------------

    @Test
    fun `label rate basis is independent of the spray carrier basis`() {
        val perHectare = ChemicalLabelRate(
            label = "Standard",
            basis = ChemicalLabelRateBasis.PER_HECTARE,
            value = 1.5,
            unit = "L",
        )
        val per100L = ChemicalLabelRate(
            label = "Standard",
            basis = ChemicalLabelRateBasis.PER_100_LITRES,
            value = 100.0,
            unit = "mL",
        )

        assertEquals("1.5 L/ha", perHectare.displayRate)
        assertEquals("100 mL/100 L", per100L.displayRate)
        assertTrue(perHectare.basis.isAreaBased)
        assertTrue(per100L.basis.isVolumeBased)

        // An NZ vineyard measuring carrier in L/100 m still applies a 1.5 L/ha
        // product: the label basis is never rewritten to match the carrier.
        assertNotEquals(perHectare.basis, per100L.basis)
    }

    @Test
    fun `per 100 L label offers exactly one spray basis so no picker is shown`() {
        assertEquals(
            listOf(SprayProductRateBasis.PER_100_LITRES),
            ChemicalLabelRateBasis.PER_100_LITRES.compatibleProductRateBases,
        )
        assertEquals(
            listOf(SprayProductRateBasis.PER_100_LITRES),
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES.compatibleProductRateBases,
        )
    }

    @Test
    fun `area label offers whole block and treated area the banded ambiguity`() {
        assertEquals(
            listOf(SprayProductRateBasis.WHOLE_BLOCK_AREA, SprayProductRateBasis.TREATED_AREA),
            ChemicalLabelRateBasis.PER_HECTARE.compatibleProductRateBases,
        )
        assertEquals(
            listOf(SprayProductRateBasis.WHOLE_BLOCK_AREA, SprayProductRateBasis.TREATED_AREA),
            ChemicalLabelRateBasis.RANGE_PER_HECTARE.compatibleProductRateBases,
        )
    }

    @Test
    fun `rate range proposes its low end never its high end`() {
        val range = ChemicalLabelRate(
            label = "Disease pressure",
            basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            minValue = 1.0,
            maxValue = 2.0,
            unit = "L",
        )

        assertEquals("1–2 L/ha", range.displayRate)
        // An automatic suggestion must never inflate a dose on the operator's behalf.
        assertEquals(1.0, range.proposedValue!!, 0.0001)
    }

    @Test
    fun `unusual label basis is preserved verbatim rather than force fitted`() {
        val odd = ChemicalLabelRate(
            label = "Per vine",
            basis = ChemicalLabelRateBasis.OTHER,
            unit = "mL",
            rawText = "5 mL per vine",
        )

        assertEquals("5 mL per vine", odd.displayRate)
        assertTrue(odd.basis.compatibleProductRateBases.isEmpty())
    }

    @Test
    fun `distinct label rate bases are collected across registered uses`() {
        val uses = listOf(
            ChemicalRegisteredUse(
                crop = "Grapes",
                targetRaw = "Powdery mildew",
                rates = listOf(
                    ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "L"),
                ),
            ),
            ChemicalRegisteredUse(
                crop = "Grapes",
                targetRaw = "Botrytis",
                rates = listOf(
                    ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, value = 100.0, unit = "mL"),
                ),
            ),
        )

        val bases = uses.rateBases()
        assertEquals(2, bases.size)
        assertTrue(bases.contains(ChemicalLabelRateBasis.PER_HECTARE))
        assertTrue(bases.contains(ChemicalLabelRateBasis.PER_100_LITRES))
    }

    // ---- Registered uses / targets ------------------------------------------

    @Test
    fun `registered uses map onto typed targets only when the label is unambiguous`() {
        assertEquals(SprayTarget.POWDERY_MILDEW, ChemicalRegisteredUse.mapTarget("Powdery mildew"))
        assertEquals(
            SprayTarget.DOWNY_MILDEW,
            ChemicalRegisteredUse.mapTarget("Downy mildew (Plasmopara viticola)"),
        )
        assertEquals(SprayTarget.BOTRYTIS, ChemicalRegisteredUse.mapTarget("Botrytis bunch rot"))
        // Never guessed: a wrong target would tell the future engine the wrong
        // disease was being managed.
        assertNull(ChemicalRegisteredUse.mapTarget("Light brown apple moth"))
        assertNull(ChemicalRegisteredUse.mapTarget(""))
    }

    @Test
    fun `target is never inferred from the chemistry`() {
        // A Group 11 product with no registered uses recorded. It is emphatically
        // NOT assumed to control powdery mildew just because of its chemistry.
        val intel = ChemicalIntelligence(
            activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
            registration = registration(),
            verification = verifiedEvidence(),
        )

        assertEquals(listOf("11"), intel.activityGroupCodes)
        assertTrue(intel.registeredUses.isEmpty())
        assertTrue(intel.registeredUses.viticulturalTargets().isEmpty())
    }

    @Test
    fun `only viticultural uses are surfaced as vine targets`() {
        val uses = listOf(
            ChemicalRegisteredUse(crop = "Grapes (winegrapes)", targetRaw = "Powdery mildew"),
            ChemicalRegisteredUse(crop = "Wheat", targetRaw = "Rust"),
        )

        assertEquals(1, uses.viticultural().size)
        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), uses.viticulturalTargets())
    }

    // ---- Resistance profile contract ----------------------------------------

    @Test
    fun `resistance profile hands over codes never a fused string`() {
        val profile = savedChemical(intelligence = combinationProduct()).resistanceProfile()

        assertEquals(listOf("3", "11"), profile.activityGroupCodes)
        assertEquals(2, profile.activeIngredients.size)
        assertEquals(ChemicalVerificationStatus.VERIFIED, profile.verificationStatus)
        assertTrue(profile.isDependable)
        assertEquals("AU", profile.countryCode)
        assertEquals("AU:apvma:62764", profile.registrationIdentityKey)
        assertEquals(listOf(ChemicalLabelRateBasis.PER_HECTARE), profile.labelRateBases)
        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), profile.viticulturalTargets)
    }

    @Test
    fun `unmatched legacy chemical still yields a profile marked undependable`() {
        val profile = savedChemical(
            activeIngredient = "Sulphur 800 g/kg",
            chemicalGroup = "M2",
        ).resistanceProfile()

        assertFalse(profile.isDependable)
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, profile.verificationStatus)
    }

    // ---- Spray line snapshot ------------------------------------------------

    @Test
    fun `spray line freezes the classification that was current when applied`() {
        val snapshot = ChemicalLineSnapshot.capture(combinationProduct(), "3 + 11")
        assertNotNull(snapshot)
        val line = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            volumePerTank = 1_500.0,
            ratePerHa = 1_500.0,
            unit = "Litres",
            rateBasis = SprayProductRateBasis.WHOLE_BLOCK_AREA.raw,
            chemicalSnapshot = snapshot,
        )

        assertEquals(listOf("3", "11"), line.recordedActivityGroupCodes)
        assertTrue(line.hasResistanceSnapshot)
        assertEquals(ChemicalVerificationStatus.VERIFIED, line.chemicalSnapshot?.verificationStatus)
        assertEquals("AU:apvma:62764", line.chemicalSnapshot?.registrationIdentityKey)
        assertEquals(listOf("3", "11"), roundTrip(line).recordedActivityGroupCodes)
    }

    @Test
    fun `correcting the chemical store later does not restate a historical spray`() {
        // The spray as it was recorded, against a product classified 3 + 11.
        val line = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            chemicalSnapshot = ChemicalLineSnapshot.capture(combinationProduct(), "3 + 11"),
        )

        // Three years later the Chemical Store record is corrected: one active
        // was wrong, and the whole product is reclassified.
        val corrected = combinationProduct().copy(
            activeIngredients = listOf(active("Fluopyram", 400.0, frac("7"))),
        )
        assertEquals(listOf("7"), savedChemical(intelligence = corrected).activityGroupCodes)

        // The historical spray is untouched. It still reports what VineTrack
        // actually used when the application happened.
        assertEquals(listOf("3", "11"), line.recordedActivityGroupCodes)
        assertEquals(listOf("3", "11"), roundTrip(line).recordedActivityGroupCodes)
    }

    @Test
    fun `line whose product has nothing structured stays honestly empty`() {
        assertNull(ChemicalLineSnapshot.capture(null, ""))

        // A legacy display string alone is preserved for faithful reproduction,
        // but carries no machine-readable groups — "we did not know" is the honest
        // answer, not an invitation to go and read today's record.
        val legacyOnly = ChemicalLineSnapshot.capture(null, "3 + 11")
        assertEquals("3 + 11", legacyOnly?.legacyChemicalGroup)
        assertTrue(legacyOnly!!.activityGroupCodes.isEmpty())
        assertFalse(legacyOnly.hasResistanceData)
    }

    @Test
    fun `legacy spray line without a snapshot decodes cleanly`() {
        // Exactly the shape a pre-Chemical-Intelligence tank JSONB holds.
        val payload = """
            {"id":"line-1","name":"Sulphur","volumePerTank":2000.0,
             "ratePerHa":2000.0,"ratePer100L":0.0,"costPerUnit":0.0,"unit":"Kg"}
        """.trimIndent()
        val line = json.decodeFromString<SprayChemical>(payload)

        assertEquals("Sulphur", line.name)
        assertNull(line.chemicalSnapshot)
        assertTrue(line.recordedActivityGroupCodes.isEmpty())
        assertFalse(line.hasResistanceSnapshot)
    }

    @Test
    fun `snapshot records the resolved status not an optimistic claim`() {
        var intel = combinationProduct()
        intel = intel.copy(
            verification = intel.verification
                .addingConflict(
                    ChemicalVerificationConflict(
                        field = "activity_group",
                        extractedValue = "FRAC 11",
                        authoritativeValue = "FRAC 3",
                    ),
                )
                .copy(status = ChemicalVerificationStatus.VERIFIED),
        )

        val snapshot = ChemicalLineSnapshot.capture(intel, "")
        // A spray must never claim its product was verified when the evidence at
        // the time said otherwise.
        assertEquals(ChemicalVerificationStatus.CONFLICT, snapshot?.verificationStatus)
    }

    // ---- Tolerant decoding --------------------------------------------------

    @Test
    fun `unknown source kind is read as the weakest never the strongest`() {
        // Erring downward is the only safe direction for a trust claim.
        assertEquals(
            ChemicalDataSourceKind.AI_INTERPRETATION,
            ChemicalDataSourceKind.from("future_source"),
        )
        assertFalse(ChemicalDataSourceKind.from("future_source")!!.isAuthoritative)
        assertEquals(
            ChemicalVerificationStatus.UNVERIFIED,
            ChemicalVerificationStatus.from("future_status"),
        )
    }

    @Test
    fun `group codes normalise so the same group never stores two ways`() {
        assertEquals("3", ChemicalActivityGroup.normaliseCode("Group 3"))
        assertEquals("11", ChemicalActivityGroup.normaliseCode(" 11 (QoI / Strobilurin)"))
        assertEquals("7", ChemicalActivityGroup.normaliseCode("frac 7"))
        assertEquals("M5", ChemicalActivityGroup.normaliseCode("m5"))
    }
}
