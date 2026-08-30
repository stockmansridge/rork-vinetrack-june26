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
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android parity tests for the Chemical Intelligence operator workflow.
 *
 * `ChemicalIntelligenceTest` covers the domain model itself. This suite covers the
 * decisions the Android UI layer makes on top of it — country resolution, the
 * duplicate-identity guard, the Needs Match upgrade, and the point where the real
 * Spray Calculator save path freezes chemistry onto a spray line.
 *
 * The bias throughout is that a grower's history must stay truthful: a product may
 * be re-classified, renamed or corrected at any time, and none of that is allowed
 * to reach backwards into sprays already recorded.
 */
class ChemicalIntelligenceParityTest {

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

    private fun registration(
        country: String = "AU",
        scheme: ChemicalRegistrationScheme? = ChemicalRegistrationScheme.APVMA,
        number: String? = "62764",
        productName: String = "Example Fungicide",
    ) = ChemicalRegistration.of(
        countryCode = country,
        scheme = scheme,
        registrationNumber = number,
        registrant = "Example Crop Science",
        registeredProductName = productName,
    )

    /** A verified Group 11 single-active product. */
    private fun group11Intel(country: String = "AU", number: String = "62764") = ChemicalIntelligence(
        activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
        registration = registration(country = country, number = number),
        verification = verifiedEvidence(),
        productCategory = "fungicide",
    )

    /** The worked mixture: FRAC 3 AND FRAC 11, independently. */
    private fun mixtureIntel() = ChemicalIntelligence(
        activeIngredients = listOf(
            active("Tebuconazole", 200.0, frac("3")),
            active("Azoxystrobin", 120.0, frac("11")),
        ),
        registration = registration(number = "70001"),
        verification = verifiedEvidence(),
        registeredUses = listOf(
            ChemicalRegisteredUse(
                crop = "Grapes (winegrapes)",
                targetRaw = "Powdery mildew",
                rates = listOf(
                    ChemicalLabelRate(
                        label = "Standard",
                        basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                        minValue = 1.0,
                        maxValue = 1.5,
                        unit = "L",
                    ),
                ),
                withholdingPeriodDays = 30,
                reEntryPeriodHours = 24,
            ),
            ChemicalRegisteredUse(
                crop = "Grapes (winegrapes)",
                targetRaw = "Downy mildew",
                rates = listOf(
                    ChemicalLabelRate(
                        label = "Dilute",
                        basis = ChemicalLabelRateBasis.PER_100_LITRES,
                        value = 100.0,
                        unit = "mL",
                    ),
                ),
                withholdingPeriodDays = 30,
            ),
        ),
        productCategory = "fungicide",
    )

    private fun savedChemical(
        id: String = "chem-1",
        name: String = "Example Fungicide",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        productCategory: String = "fungicide",
        unit: String = "Litres",
        ratePerHa: Double = 0.0,
        packSize: Double? = null,
        pricePerPack: Double? = null,
        inventoryQuantity: Double? = null,
        notes: String = "",
        intelligence: ChemicalIntelligence? = null,
    ): SavedChemical = SavedChemical(
        id = id,
        vineyardId = "vineyard-1",
        name = name,
        chemicalGroup = chemicalGroup,
        manufacturer = "Example Crop Science",
        activeIngredient = activeIngredient,
        productCategory = productCategory,
        unit = unit,
        ratePerHa = ratePerHa,
        packSize = packSize,
        pricePerPack = pricePerPack,
        inventoryQuantity = inventoryQuantity,
        notes = notes,
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

    /**
     * Drive the REAL calculator save path: `buildTanks` is what
     * `SprayCalculatorScreen.buildInput()` calls to produce `spray_records.tanks`.
     */
    private fun buildTanksFor(
        chemicals: List<SavedChemical>,
        basis: SprayCalculator.RateBasis = SprayCalculator.RateBasis.PER_HECTARE,
    ): List<com.rork.vinetrack.data.model.SprayTank> {
        val results = chemicals.map { chem ->
            SprayCalculator.ChemicalResult(
                savedChemicalId = chem.id,
                name = chem.displayName,
                unit = chem.unit,
                basis = basis,
                rate = 1.5,
                totalAmount = 15.0,
                amountPerFullTank = 7.5,
                amountInLastTank = 7.5,
                costPerUnit = null,
            )
        }
        val result = SprayCalculator.Result(
            totalAreaHectares = 10.0,
            totalWaterLitres = 4000.0,
            tankCapacityLitres = 2000.0,
            fullTankCount = 1,
            lastTankLitres = 2000.0,
            concentrationFactor = 1.0,
            chemicalResults = results,
        )
        return SprayCalculator.buildTanks(
            result = result,
            chosenSprayRate = 400.0,
            snapshots = chemicals.mapNotNull { chem ->
                ChemicalLineSnapshot.capture(
                    intelligence = chem.resolvedIntelligence,
                    legacyChemicalGroup = chem.chemicalGroup,
                    savedChemicalId = chem.id,
                    productName = chem.name,
                    capturedAt = "2026-08-15T02:00:00Z",
                )?.let { chem.id to it }
            }.toMap(),
        )
    }

    // ---- Country ------------------------------------------------------------

    @Test
    fun `au vineyard resolves to the au register country`() {
        val resolved = ChemicalInfoService.resolveCountry("Australia")

        assertEquals("Australia", resolved)
        assertEquals("AU", ChemicalRegistration.normaliseCountry(resolved))
    }

    @Test
    fun `nz vineyard resolves to the nz register country`() {
        val resolved = ChemicalInfoService.resolveCountry("New Zealand")

        assertEquals("New Zealand", resolved)
        assertEquals("NZ", ChemicalRegistration.normaliseCountry(resolved))
    }

    @Test
    fun `an explicit vineyard country always beats the device region`() {
        // The grower's vineyard is the authority, not wherever the phone happens
        // to be. A consultant in France must still search the AU register.
        assertEquals("Australia", ChemicalInfoService.resolveCountry("Australia"))
        assertEquals("NZ", ChemicalInfoService.resolveCountry("NZ"))
    }

    @Test
    fun `same commercial name in two countries is never treated as one product`() {
        val au = savedChemical(id = "au-1", name = "Example Fungicide", intelligence = group11Intel("AU", "62764"))
        val nzIntel = group11Intel("NZ", "62764")

        // Identical brand name, identical number, different country: two products.
        val duplicate = ChemicalStoreMatching.findByRegistrationIdentity(
            chemicals = listOf(au),
            registration = nzIntel.registration,
        )

        assertNull(duplicate)
        assertNotEquals(
            au.resolvedIntelligence.registration?.identityKey,
            nzIntel.registration?.identityKey,
        )
        assertEquals("AU:apvma:62764", au.resolvedIntelligence.registration?.identityKey)
    }

    // ---- Duplicate identity protection --------------------------------------

    @Test
    fun `identical registration identity is detected as already in the store`() {
        val existing = savedChemical(id = "chem-au", intelligence = group11Intel())

        val duplicate = ChemicalStoreMatching.findByRegistrationIdentity(
            chemicals = listOf(existing),
            registration = group11Intel().registration,
        )

        assertNotNull(duplicate)
        assertEquals("chem-au", duplicate?.id)
    }

    @Test
    fun `a record being updated is never a duplicate of itself`() {
        val existing = savedChemical(id = "chem-au", intelligence = group11Intel())

        val duplicate = ChemicalStoreMatching.findByRegistrationIdentity(
            chemicals = listOf(existing),
            registration = group11Intel().registration,
            excludingId = "chem-au",
        )

        assertNull(duplicate)
    }

    @Test
    fun `duplicate detection ignores name similarity entirely`() {
        // Same marketing name, genuinely different registrations. Merging these
        // would merge two chemistries, so the store must keep them apart.
        val existing = savedChemical(
            id = "chem-a",
            name = "Example Fungicide",
            intelligence = group11Intel(number = "11111"),
        )

        val duplicate = ChemicalStoreMatching.findByRegistrationIdentity(
            chemicals = listOf(existing),
            registration = registration(number = "22222"),
        )

        assertNull(duplicate)
    }

    @Test
    fun `an unregistered candidate cannot be claimed as a duplicate`() {
        val existing = savedChemical(id = "chem-a", intelligence = group11Intel())

        // No registration number means no provable identity. The operator stays
        // in control rather than being blocked by a guess.
        val duplicate = ChemicalStoreMatching.findByRegistrationIdentity(
            chemicals = listOf(existing),
            registration = registration(number = null),
        )

        assertNull(duplicate)
    }

    // ---- Needs Match upgrade ------------------------------------------------

    @Test
    fun `matching a legacy chemical upgrades chemistry and keeps the same record`() {
        val legacy = savedChemical(
            id = "legacy-1",
            name = "Old Fungicide",
            activeIngredient = "azoxystrobin",
            chemicalGroup = "11",
            unit = "mL",
            ratePerHa = 750.0,
            packSize = 5.0,
            pricePerPack = 240.0,
            inventoryQuantity = 12.0,
            notes = "Shed B, top shelf",
        )
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, legacy.verificationStatus)

        val input = ChemicalStoreMatching.inputFor(legacy, "Example Fungicide", mixtureIntel())

        // Chemistry upgraded...
        assertEquals(listOf("3", "11"), input.intelligence?.activityGroupCodes)
        assertEquals("Example Fungicide", input.name)
        // ...and every unrelated field the grower maintains is carried through.
        // The display unit is NOT one of them: the label quotes its rates in
        // "L", so the unit follows the label's own liquid family (values are
        // stored in base units, so nothing is re-scaled). Mirrors the iOS
        // `ChemicalReviewDraft.productUnit` merge.
        assertEquals("Litres", input.unit)
        assertEquals(750.0, input.ratePerHa, 0.0001)
        assertEquals(5.0, input.packSize)
        assertEquals(240.0, input.pricePerPack)
        assertEquals(12.0, input.inventoryQuantity)
        assertEquals("Shed B, top shelf", input.notes)
    }

    @Test
    fun `legacy scalars are rewritten as derived projections of the structured data`() {
        val legacy = savedChemical(id = "legacy-1", chemicalGroup = "11", activeIngredient = "azoxystrobin")

        val input = ChemicalStoreMatching.inputFor(legacy, "Example Fungicide", mixtureIntel())

        // The projection is an OUTPUT of the structured groups, never an input.
        assertEquals("3 + 11", input.chemicalGroup)
        assertTrue(input.activeIngredient?.contains("Tebuconazole") == true)
        assertTrue(input.activeIngredient?.contains("Azoxystrobin") == true)
    }

    @Test
    fun `a brand new confirmed product carries no inherited fields`() {
        val input = ChemicalStoreMatching.inputFor(null, "Example Fungicide", group11Intel())

        assertEquals("Example Fungicide", input.name)
        // A4 contract: nothing established a form or a rate unit — group11Intel
        // has no registered uses — so the unit stays UNSET for the operator.
        // An unknown product must never be defaulted to Litres/Liquid.
        assertEquals("", input.unit)
        assertEquals(0.0, input.ratePerHa, 0.0001)
        assertNull(input.packSize)
        assertEquals(listOf("11"), input.intelligence?.activityGroupCodes)
    }

    // ---- Registered uses ----------------------------------------------------

    @Test
    fun `multiple registered uses survive persistence on the saved chemical`() {
        val stored = savedChemical(intelligence = mixtureIntel())

        val reloaded: SavedChemical = json.decodeFromString(json.encodeToString(stored))
        val uses = reloaded.resolvedIntelligence.registeredUses

        assertEquals(2, uses.size)
        assertEquals(listOf("Powdery mildew", "Downy mildew"), uses.map { it.targetRaw })
        assertEquals(30, uses.first().withholdingPeriodDays)
        assertEquals(24, uses.first().reEntryPeriodHours)
    }

    @Test
    fun `both label rate bases of a product are preserved independently`() {
        val stored = savedChemical(intelligence = mixtureIntel())

        val bases = stored.resolvedIntelligence.labelRateBases

        assertTrue(bases.contains(ChemicalLabelRateBasis.RANGE_PER_HECTARE))
        assertTrue(bases.contains(ChemicalLabelRateBasis.PER_100_LITRES))
    }

    @Test
    fun `a per hectare label rate is not converted to the vineyards carrier basis`() {
        val use = mixtureIntel().registeredUses.first()
        val rate = use.rates.first()

        // The label says 1.0-1.5 L/ha. The vineyard spraying per 100 L does not
        // change what the label says, and the low end is what is proposed.
        assertEquals(ChemicalLabelRateBasis.RANGE_PER_HECTARE, rate.basis)
        assertEquals(1.0, rate.proposedValue)
        assertTrue(rate.basis.isAreaBased)
        assertFalse(rate.basis.isVolumeBased)
    }

    // ---- Real spray save path: snapshot -------------------------------------

    @Test
    fun `the real calculator save path freezes chemistry onto every tank line`() {
        val chem = savedChemical(intelligence = group11Intel())

        val tanks = buildTanksFor(listOf(chem))

        assertEquals(2, tanks.size)
        tanks.forEach { tank ->
            val line = tank.chemicals.single()
            assertTrue(line.hasResistanceSnapshot)
            assertEquals(listOf("11"), line.recordedActivityGroupCodes)
            assertEquals(
                ChemicalVerificationStatus.VERIFIED,
                line.chemicalSnapshot?.verificationStatus,
            )
            assertEquals("AU:apvma:62764", line.chemicalSnapshot?.registrationIdentityKey)
            assertEquals("AU", line.chemicalSnapshot?.countryCode)
            assertEquals("Azoxystrobin", line.chemicalSnapshot?.activeIngredients?.single()?.name)
            assertEquals(250.0, line.chemicalSnapshot?.activeIngredients?.single()?.concentration)
            // The snapshot names its own origin, so history is readable without
            // going back to the Chemical Store for context.
            assertEquals(chem.id, line.chemicalSnapshot?.savedChemicalId)
            assertEquals("Example Fungicide", line.chemicalSnapshot?.productName)
            assertEquals(1, line.chemicalSnapshot?.schemaVersion)
            // Copied verbatim from the record, never re-stamped with today's
            // table version — otherwise an old spray would claim it was
            // classified by a reference table that did not exist yet.
            assertEquals(
                chem.resolvedIntelligence?.activityGroupTableVersion,
                line.chemicalSnapshot?.activityGroupTableVersion,
            )
        }
    }

    @Test
    fun `the frozen line carries its own rate basis and calculated quantity`() {
        val chem = savedChemical(intelligence = group11Intel())

        val line = buildTanksFor(listOf(chem)).first().chemicals.single()

        // Rate, basis and computed quantity are frozen on the LINE beside the
        // snapshot rather than duplicated inside it, so a single number can
        // never disagree with itself in one record.
        assertEquals(1.5, line.ratePerHa, 0.0001)
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA.raw, line.rateBasis)
        assertEquals(7.5, line.volumePerTank, 0.0001)
        assertEquals(chem.id, line.savedChemicalId)
    }

    @Test
    fun `renaming a product later does not rewrite the name on a recorded spray`() {
        val before = savedChemical(name = "Amistar 250", intelligence = group11Intel())
        val historical = json.encodeToString(buildTanksFor(listOf(before)))

        // The grower renames the store record next season.
        savedChemical(name = "Amistar 250 SC (old stock)", intelligence = group11Intel())

        val reloaded = json
            .decodeFromString<List<com.rork.vinetrack.data.model.SprayTank>>(historical)
            .first().chemicals.single()

        assertEquals("Amistar 250", reloaded.chemicalSnapshot?.productName)
    }

    @Test
    fun `a mixture freezes both groups onto the spray line`() {
        val chem = savedChemical(intelligence = mixtureIntel())

        val line = buildTanksFor(listOf(chem)).first().chemicals.single()

        assertEquals(listOf("3", "11"), line.recordedActivityGroupCodes)
        assertNotEquals(listOf("3 + 11"), line.recordedActivityGroupCodes)
    }

    @Test
    fun `re-classifying a product does not restate a spray already recorded`() {
        // Group 11 today...
        val before = savedChemical(intelligence = group11Intel())
        val tanks = buildTanksFor(listOf(before))
        val historical = json.encodeToString(tanks)

        // ...corrected to Group 3 in the Chemical Store later.
        val corrected = savedChemical(
            intelligence = ChemicalIntelligence(
                activeIngredients = listOf(active("Difenoconazole", 250.0, frac("3"))),
                registration = registration(),
                verification = verifiedEvidence(),
                productCategory = "fungicide",
            ),
        )
        assertEquals(listOf("3"), corrected.activityGroupCodes)

        // Reloading the historical spray must still say Group 11.
        val reloaded: List<com.rork.vinetrack.data.model.SprayTank> =
            json.decodeFromString(historical)
        reloaded.forEach { tank ->
            assertEquals(listOf("11"), tank.chemicals.single().recordedActivityGroupCodes)
        }
    }

    @Test
    fun `an unverified product is still sprayable and still snapshots honestly`() {
        // Nothing here blocks the spray: refusing to record a real application
        // would push the operator to keep it somewhere VineTrack cannot see.
        val manual = savedChemical(
            intelligence = ChemicalIntelligence(
                activeIngredients = listOf(
                    active(
                        "Sulfur",
                        800.0,
                        frac("M2"),
                        groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                    ),
                ),
                verification = ChemicalVerification(
                    status = ChemicalVerificationStatus.VERIFIED,
                    sources = listOf(
                        ChemicalDataSource(kind = ChemicalDataSourceKind.MANUAL_ENTRY, name = "Operator"),
                    ),
                ),
                productCategory = "fungicide",
            ),
        )

        val line = buildTanksFor(listOf(manual)).first().chemicals.single()

        assertNotNull(line.chemicalSnapshot)
        // Manual evidence can never resolve to Verified, and the frozen line
        // records the resolved truth rather than the optimistic stored claim.
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, line.chemicalSnapshot?.verificationStatus)
        assertEquals(manual.verificationStatus, line.chemicalSnapshot?.verificationStatus)
    }

    @Test
    fun `a product with nothing structured carries no resistance data`() {
        val legacy = savedChemical(id = "legacy-1", chemicalGroup = "", activeIngredient = "")

        val line = buildTanksFor(listOf(legacy)).first().chemicals.single()

        // A legacy chemical still produces a snapshot, because "VineTrack knew
        // nothing dependable about this chemistry when it was applied" is itself a
        // fact worth freezing. What it must never do is resemble usable data.
        assertEquals(emptyList<String>(), line.recordedActivityGroupCodes)
        assertFalse(line.hasResistanceSnapshot)
        assertEquals(
            ChemicalVerificationStatus.NEEDS_MATCH,
            line.chemicalSnapshot?.verificationStatus,
        )
        assertTrue(line.chemicalSnapshot?.activeIngredients?.isEmpty() == true)
    }

    @Test
    fun `a legacy chemical with only group text keeps that text for reproduction`() {
        val legacy = savedChemical(id = "legacy-1", chemicalGroup = "11", activeIngredient = "azoxystrobin")

        val line = buildTanksFor(listOf(legacy)).first().chemicals.single()

        // Legacy text is preserved so the old record still reproduces, but it
        // must never present itself as dependable resistance data.
        assertEquals("11", line.chemicalSnapshot?.legacyChemicalGroup)
        assertEquals(
            ChemicalVerificationStatus.NEEDS_MATCH,
            line.chemicalSnapshot?.verificationStatus,
        )
        assertFalse(line.chemicalSnapshot?.verificationStatus?.isResistanceDependable == true)
    }

    @Test
    fun `the per 100 L carrier basis does not alter the frozen chemistry`() {
        val chem = savedChemical(intelligence = mixtureIntel())

        val perHa = buildTanksFor(listOf(chem), SprayCalculator.RateBasis.PER_HECTARE)
            .first().chemicals.single()
        val per100 = buildTanksFor(listOf(chem), SprayCalculator.RateBasis.PER_100L)
            .first().chemicals.single()

        // Carrier basis changes the quantity maths, never the chemistry.
        assertEquals(perHa.recordedActivityGroupCodes, per100.recordedActivityGroupCodes)
        assertEquals(SprayProductRateBasis.PER_100_LITRES.raw, per100.rateBasis)
        assertEquals(SprayProductRateBasis.WHOLE_BLOCK_AREA.raw, perHa.rateBasis)
    }

    @Test
    fun `each line in a tank mix freezes its own chemistry`() {
        val a = savedChemical(id = "chem-a", name = "Single", intelligence = group11Intel())
        val b = savedChemical(id = "chem-b", name = "Mixture", intelligence = mixtureIntel())

        val lines = buildTanksFor(listOf(a, b)).first().chemicals

        assertEquals(2, lines.size)
        assertEquals(listOf("11"), lines.first { it.savedChemicalId == "chem-a" }.recordedActivityGroupCodes)
        assertEquals(listOf("3", "11"), lines.first { it.savedChemicalId == "chem-b" }.recordedActivityGroupCodes)
    }

    // ---- Offline ------------------------------------------------------------

    @Test
    fun `a cached structured chemical stays fully usable with no network`() {
        // Simulates the offline cache: the chemical arrives as stored JSON and
        // nothing in this path touches Supabase or the lookup edge function.
        val cached = json.encodeToString(savedChemical(intelligence = mixtureIntel()))

        val offline: SavedChemical = json.decodeFromString(cached)

        assertEquals(listOf("3", "11"), offline.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, offline.verificationStatus)
        assertEquals(2, offline.resolvedIntelligence.activeIngredients.size)

        // ...and it can still be selected and snapshotted into a spray offline.
        val line = buildTanksFor(listOf(offline)).first().chemicals.single()
        assertEquals(listOf("3", "11"), line.recordedActivityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, line.chemicalSnapshot?.verificationStatus)
    }

    @Test
    fun `an offline captured snapshot survives the round trip to the server`() {
        val chem = savedChemical(intelligence = mixtureIntel())
        val tanks = buildTanksFor(listOf(chem))

        // Queued offline, then synced: the structured intelligence must not be
        // dropped in transit, or the spray loses its resistance history.
        val synced: List<com.rork.vinetrack.data.model.SprayTank> =
            json.decodeFromString(json.encodeToString(tanks))

        val line = synced.first().chemicals.single()
        assertEquals(listOf("3", "11"), line.recordedActivityGroupCodes)
        assertEquals("AU:apvma:70001", line.chemicalSnapshot?.registrationIdentityKey)
        assertEquals(
            ChemicalIntelligence.CURRENT_SCHEMA_VERSION,
            line.chemicalSnapshot?.schemaVersion,
        )
    }
}
