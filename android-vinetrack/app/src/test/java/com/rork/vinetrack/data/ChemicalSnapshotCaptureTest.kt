package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the ONE canonical Chemical Intelligence capture path.
 *
 * The iOS suite `ChemicalSnapshotCaptureTests` asserts the same fixtures and the
 * same outcomes, so a spray created on either platform freezes an identical
 * shape into the shared `tanks` JSONB.
 *
 * Everything here protects four rules:
 *
 *  1. A NEW application freezes the chemistry that exists NOW.
 *  2. A template is configuration, so instantiating it re-reads the store.
 *  3. An unresolvable product stays honestly unresolved — never invented.
 *  4. A completed application never changes because the store changed.
 */
class ChemicalSnapshotCaptureTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    // ---- Fixtures -----------------------------------------------------------

    private fun frac(code: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, code)

    private fun active(name: String, concentration: Double?, group: ChemicalActivityGroup?) =
        ChemicalActiveIngredient(
            name = name,
            concentration = concentration,
            concentrationUnit = concentration?.let { ChemicalConcentrationUnit.GRAMS_PER_LITRE },
            activityGroup = group,
            groupSource = group?.let { ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION },
            identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
        )

    private fun verifiedEvidence(conflicts: List<ChemicalVerificationConflict> = emptyList()) =
        ChemicalVerification(
            status = ChemicalVerificationStatus.VERIFIED,
            sources = listOf(
                ChemicalDataSource(
                    kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                    name = "APVMA PUBCRIS",
                ),
                AuthoritativeActivityGroups.source(),
            ),
            verifiedAt = "2026-08-15T00:00:00Z",
            conflicts = conflicts,
        )

    /** Azoxystrobin, FRAC 11, verified — the reference product for this stage. */
    private fun group11Intel(
        number: String = "62764",
        conflicts: List<ChemicalVerificationConflict> = emptyList(),
    ) = ChemicalIntelligence(
        activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
        registration = ChemicalRegistration.of(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = number,
            registrant = "Example Crop Science",
            registeredProductName = "Example Fungicide",
        ),
        verification = verifiedEvidence(conflicts),
        productCategory = "fungicide",
    )

    /** The SAME product legitimately re-verified as FRAC 3. */
    private fun group3Intel() = ChemicalIntelligence(
        activeIngredients = listOf(active("Tebuconazole", 200.0, frac("3"))),
        registration = ChemicalRegistration.of(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "62764",
            registrant = "Example Crop Science",
            registeredProductName = "Example Fungicide",
        ),
        verification = verifiedEvidence(),
        productCategory = "fungicide",
    )

    private fun savedChemical(
        id: String = "chem-1",
        name: String = "Example Fungicide",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        modeOfAction: String = "",
        intelligence: ChemicalIntelligence? = null,
    ): SavedChemical = SavedChemical(
        id = id,
        vineyardId = "vineyard-1",
        name = name,
        chemicalGroup = chemicalGroup,
        manufacturer = "Example Crop Science",
        activeIngredient = activeIngredient,
        modeOfAction = modeOfAction,
        productCategory = "fungicide",
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

    private val at = "2026-08-15T02:00:00Z"

    // ---- Phase 15: the normal Spray Calculator path -------------------------

    @Test
    fun `new application freezes id name identity active group and resolved status`() {
        val chem = savedChemical(intelligence = group11Intel())

        val snapshot = ChemicalSnapshotCapture
            .captureForNewApplication(
                savedChemicalId = chem.id,
                productName = chem.name,
                library = listOf(chem),
                capturedAt = at,
            )
            .snapshot

        assertNotNull(snapshot)
        assertEquals("chem-1", snapshot!!.savedChemicalId)
        assertEquals("Example Fungicide", snapshot.productName)
        assertEquals("AU:apvma:62764", snapshot.registrationIdentityKey)
        assertEquals("AU", snapshot.countryCode)
        assertEquals(listOf("Azoxystrobin"), snapshot.activeIngredients.map { it.name })
        assertEquals(listOf("11"), snapshot.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, snapshot.verificationStatus)
        assertEquals(at, snapshot.capturedAt)
        assertTrue(snapshot.hasResistanceData)
    }

    @Test
    fun `reclassifying the product later never restates a recorded application`() {
        val september = savedChemical(intelligence = group11Intel())
        val historical = ChemicalSnapshotCapture
            .captureForNewApplication(
                savedChemicalId = september.id,
                productName = september.name,
                library = listOf(september),
                capturedAt = at,
            )
            .snapshot!!

        // The Chemical Store is corrected months later.
        val november = savedChemical(intelligence = group3Intel())
        val fresh = ChemicalSnapshotCapture
            .captureForNewApplication(
                savedChemicalId = november.id,
                productName = november.name,
                library = listOf(november),
                capturedAt = "2026-11-01T02:00:00Z",
            )
            .snapshot!!

        assertEquals(listOf("11"), historical.activityGroupCodes)
        assertEquals(listOf("3"), fresh.activityGroupCodes)
    }

    @Test
    fun `resolution reports how the product was matched`() {
        val chem = savedChemical(intelligence = group11Intel())

        assertEquals(
            ChemicalSnapshotCapture.MatchKind.IDENTIFIER,
            ChemicalSnapshotCapture.resolve("chem-1", null, library = listOf(chem)).second,
        )
        assertEquals(
            ChemicalSnapshotCapture.MatchKind.EXACT_NAME,
            ChemicalSnapshotCapture.resolve(null, "example fungicide", library = listOf(chem)).second,
        )
        assertEquals(
            ChemicalSnapshotCapture.MatchKind.REGISTRATION_IDENTITY,
            ChemicalSnapshotCapture
                .resolve(null, null, registrationIdentityKey = "AU:apvma:62764", library = listOf(chem))
                .second,
        )
    }

    // ---- Phase 16: template instantiation -----------------------------------

    @Test
    fun `instantiating a template snapshots the products current chemistry`() {
        // A template recorded in September, when the product was FRAC 11.
        val septemberLine = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            ratePerHa = 1500.0,
            savedChemicalId = "chem-1",
            chemicalSnapshot = ChemicalSnapshotCapture.capture(
                savedChemical(intelligence = group11Intel()),
                capturedAt = "2026-09-01T02:00:00Z",
            ),
        )
        // By November the product has legitimately been re-verified as FRAC 3.
        val november = listOf(savedChemical(intelligence = group3Intel()))

        val instantiated = ChemicalSnapshotCapture
            .captureForNewApplication(
                savedChemicalId = septemberLine.savedChemicalId,
                productName = septemberLine.name,
                library = november,
                capturedAt = "2026-11-01T02:00:00Z",
            )
            .snapshot!!

        // The template's configuration was reusable; its chemistry was not.
        assertEquals(listOf("3"), instantiated.activityGroupCodes)
        assertEquals("2026-11-01T02:00:00Z", instantiated.capturedAt)
        // And the completed September application is untouched.
        assertEquals(listOf("11"), septemberLine.chemicalSnapshot!!.activityGroupCodes)
    }

    @Test
    fun `template carries product identity forward not its frozen chemistry`() {
        val templateSnapshot = ChemicalSnapshotCapture.capture(
            savedChemical(intelligence = group11Intel()),
            capturedAt = "2026-09-01T02:00:00Z",
        )!!
        val november = listOf(savedChemical(intelligence = group3Intel()))

        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = templateSnapshot.savedChemicalId,
            productName = templateSnapshot.productName,
            registrationIdentityKey = templateSnapshot.registrationIdentityKey,
            library = november,
            capturedAt = "2026-11-01T02:00:00Z",
        )

        assertTrue(resolution.isResolved)
        assertEquals("chem-1", resolution.savedChemicalId)
        assertEquals(listOf("3"), resolution.snapshot!!.activityGroupCodes)
    }

    // ---- Phase 17: template pointing at a missing chemical ------------------

    @Test
    fun `template referencing a deleted chemical invents no verified chemistry`() {
        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = "deleted-chem",
            productName = "Vanished Fungicide",
            library = emptyList(),
            capturedAt = at,
        )

        assertFalse(resolution.isResolved)
        assertEquals(ChemicalSnapshotCapture.MatchKind.UNRESOLVED, resolution.match)
        assertNull(resolution.savedChemicalId)
        // No legacy text either, so there is genuinely nothing to record.
        assertNull(resolution.snapshot)
    }

    @Test
    fun `unresolved product with legacy group text keeps it as legacy evidence only`() {
        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = null,
            productName = "Unknown Mixture",
            legacyChemicalGroup = "Group 3 + 11",
            library = emptyList(),
            capturedAt = at,
        )

        val snapshot = resolution.snapshot
        assertNotNull(snapshot)
        assertEquals("Group 3 + 11", snapshot!!.legacyChemicalGroup)
        // Preserved for faithful display — never promoted to structured groups.
        assertTrue(snapshot.activityGroupCodes.isEmpty())
        assertTrue(snapshot.activeIngredients.isEmpty())
        assertEquals(ChemicalVerificationStatus.UNVERIFIED, snapshot.verificationStatus)
        assertEquals(0, snapshot.schemaVersion)
        assertEquals(0, snapshot.activityGroupTableVersion)
        assertFalse(snapshot.hasResistanceData)
        assertNull(snapshot.savedChemicalId)
    }

    // ---- Phase 18: CSV import with a reliable match -------------------------

    @Test
    fun `imported line with a reliable match is equivalent to a calculator spray`() {
        val chem = savedChemical(intelligence = group11Intel())

        val calculator = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", "Example Fungicide", library = listOf(chem), capturedAt = at)
            .snapshot
        // The importer links names that match exactly and uniquely.
        val imported = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", "Example Fungicide", library = listOf(chem), capturedAt = at)
            .snapshot

        assertEquals(calculator, imported)
    }

    @Test
    fun `imported snapshot survives persist and reload unchanged`() {
        val chem = savedChemical(intelligence = group11Intel())
        val line = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            ratePerHa = 1500.0,
            savedChemicalId = "chem-1",
            chemicalSnapshot = ChemicalSnapshotCapture
                .captureForNewApplication("chem-1", "Example Fungicide", library = listOf(chem), capturedAt = at)
                .snapshot,
        )

        val reloaded: SprayChemical = json.decodeFromString(json.encodeToString(line))

        assertEquals(line.chemicalSnapshot, reloaded.chemicalSnapshot)
        assertEquals(listOf("11"), reloaded.chemicalSnapshot!!.activityGroupCodes)
        assertEquals(1500.0, reloaded.ratePerHa, 0.0001)
    }

    // ---- Phase 19: CSV import without a reliable match ----------------------

    @Test
    fun `an ambiguous name is left unresolved rather than guessed`() {
        // Two library entries share the name — picking either would attach one
        // product's chemistry to another product's spray.
        val library = listOf(
            savedChemical(id = "chem-1", intelligence = group11Intel()),
            savedChemical(id = "chem-2", intelligence = group3Intel()),
        )

        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = null,
            productName = "Example Fungicide",
            library = library,
            capturedAt = at,
        )

        assertFalse(resolution.isResolved)
        assertNull(resolution.snapshot)
    }

    @Test
    fun `a partial name never attaches authoritative chemistry`() {
        val library = listOf(savedChemical(intelligence = group11Intel()))

        // "Example" is a prefix of "Example Fungicide" — deliberately not a match.
        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = null,
            productName = "Example",
            library = library,
            capturedAt = at,
        )

        assertFalse(resolution.isResolved)
        assertNull(resolution.snapshot)
    }

    @Test
    fun `unresolved import preserves the line and its rate`() {
        val resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId = null,
            productName = "Mystery Product",
            legacyChemicalGroup = "Group 3 + 11",
            library = emptyList(),
            capturedAt = at,
        )
        val line = SprayChemical(
            id = "line-1",
            name = "Mystery Product",
            ratePerHa = 2000.0,
            unit = "Litres",
            savedChemicalId = resolution.savedChemicalId,
            chemicalSnapshot = resolution.snapshot,
        )

        // The application is never lost just because its chemistry is unknown.
        assertEquals("Mystery Product", line.name)
        assertEquals(2000.0, line.ratePerHa, 0.0001)
        assertNull(line.savedChemicalId)
        assertEquals("Group 3 + 11", line.chemicalSnapshot!!.legacyChemicalGroup)
        assertTrue(line.chemicalSnapshot!!.activeIngredients.isEmpty())
        assertEquals(
            ChemicalVerificationStatus.UNVERIFIED,
            line.chemicalSnapshot!!.verificationStatus,
        )
    }

    // ---- Phase 20: offline creation -----------------------------------------

    @Test
    fun `an offline spray keeps the chemistry captured at application time`() {
        // Offline: the device knows the product as FRAC 11.
        val cached = savedChemical(intelligence = group11Intel())
        val offlineLine = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            ratePerHa = 1500.0,
            savedChemicalId = "chem-1",
            chemicalSnapshot = ChemicalSnapshotCapture
                .captureForNewApplication("chem-1", "Example Fungicide", library = listOf(cached), capturedAt = at)
                .snapshot,
        )

        // The queued payload is serialised, the store changes elsewhere, then the
        // device replays tomorrow. Replay carries the payload verbatim.
        val queued = json.encodeToString(offlineLine)
        val replayed: SprayChemical = json.decodeFromString(queued)

        assertEquals(listOf("11"), replayed.chemicalSnapshot!!.activityGroupCodes)
        assertEquals(at, replayed.chemicalSnapshot!!.capturedAt)
        assertEquals(offlineLine.chemicalSnapshot, replayed.chemicalSnapshot)
    }

    // ---- Phase 12: historical records ---------------------------------------

    @Test
    fun `a historical line without chemistry keeps the absence`() {
        val legacyLine = SprayChemical(id = "line-1", name = "Old product", ratePerHa = 2000.0)

        val reloaded: SprayChemical = json.decodeFromString(json.encodeToString(legacyLine))

        // Never back-filled from today's store: the Resistance Engine must be
        // able to say "intelligence unavailable" rather than fabricate certainty.
        assertNull(reloaded.chemicalSnapshot)
        assertEquals("Old product", reloaded.name)
    }

    // ---- Phase 13: resolved verification at capture time --------------------

    @Test
    fun `capture records the resolved status not the stored claim`() {
        // The stored row says VERIFIED, but the evidence now carries a conflict.
        val conflicted = group11Intel(
            conflicts = listOf(
                ChemicalVerificationConflict(
                    field = "activity_group",
                    activeIngredientName = "Azoxystrobin",
                    extractedValue = "3",
                    authoritativeValue = "11",
                ),
            ),
        )
        val chem = savedChemical(intelligence = conflicted)
        assertEquals(ChemicalVerificationStatus.VERIFIED, chem.storedIntelligence!!.verification.status)

        val snapshot = ChemicalSnapshotCapture.capture(chem, capturedAt = at)!!

        assertEquals(ChemicalVerificationStatus.CONFLICT, snapshot.verificationStatus)
    }

    @Test
    fun `a legacy only product freezes an honest needs-match reading`() {
        val legacy = savedChemical(
            activeIngredient = "Azoxystrobin",
            chemicalGroup = "Group 11",
            modeOfAction = "11 (QoI)",
            intelligence = null,
        )

        val snapshot = ChemicalSnapshotCapture.capture(legacy, capturedAt = at)!!

        // Legacy text seeds the audit, but it is structurally incapable of
        // passing as verified.
        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, snapshot.verificationStatus)
        assertEquals("Group 11", snapshot.legacyChemicalGroup)
        assertEquals(listOf("Azoxystrobin"), snapshot.activeIngredients.map { it.name })
        assertTrue(
            snapshot.activeIngredients.none { it.hasAuthoritativeGroup },
        )
    }

    // ---- Phase 21: every new-application constructor ------------------------

    @Test
    fun `every resolvable new application line carries a canonical snapshot`() {
        val chem = savedChemical(intelligence = group11Intel())
        val library = listOf(chem)
        val canonical = ChemicalSnapshotCapture.capture(chem, capturedAt = at)

        // The four shapes a new application line arrives in: an explicit id
        // (calculator, manual sheet), a template's id, an importer's linked id,
        // and a name-only import row.
        val byCalculatorId = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", "Example Fungicide", library = library, capturedAt = at)
        val byTemplateId = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", null, library = library, capturedAt = at)
        val byImporterId = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", "example fungicide", library = library, capturedAt = at)
        val byName = ChemicalSnapshotCapture
            .captureForNewApplication(null, "Example Fungicide", library = library, capturedAt = at)

        for (resolution in listOf(byCalculatorId, byTemplateId, byImporterId, byName)) {
            assertTrue(resolution.isResolved)
            assertNotNull(resolution.snapshot)
            // One capture path means one shape — no per-screen drift.
            assertEquals(canonical, resolution.snapshot)
        }
    }

    @Test
    fun `an archived product still resolves by id because the spray happened`() {
        val archived = savedChemical(intelligence = group11Intel()).copy(isActive = false)

        val resolution = ChemicalSnapshotCapture
            .captureForNewApplication("chem-1", "Example Fungicide", library = listOf(archived), capturedAt = at)

        assertTrue(resolution.isResolved)
        assertEquals(listOf("11"), resolution.snapshot!!.activityGroupCodes)
    }

    // ---- Phase 14: cross-platform JSON --------------------------------------

    @Test
    fun `snapshot serialises the shared snake_case shape`() {
        val chem = savedChemical(intelligence = group11Intel())
        val snapshot = ChemicalSnapshotCapture.capture(chem, capturedAt = at)!!

        val encoded = json.encodeToString(snapshot)

        for (key in listOf(
            "\"saved_chemical_id\"",
            "\"product_name\"",
            "\"active_ingredients\"",
            "\"activity_groups\"",
            "\"verification_status\"",
            "\"registration_identity_key\"",
            "\"country_code\"",
            "\"schema_version\"",
            "\"activity_group_table_version\"",
            "\"captured_at\"",
        )) {
            assertTrue("missing $key in $encoded", encoded.contains(key))
        }
        // Status travels as its raw string, and captured_at as an ISO-8601
        // string — the same two shapes iOS writes into the same column.
        assertTrue(encoded.contains("\"verified\""))
        assertTrue(encoded.contains("\"$at\""))

        val reloaded: ChemicalLineSnapshot = json.decodeFromString(encoded)
        assertEquals(snapshot, reloaded)
    }
}
