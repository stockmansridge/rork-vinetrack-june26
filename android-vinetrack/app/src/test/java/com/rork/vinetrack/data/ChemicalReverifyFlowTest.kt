package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceChangeKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffField
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffSection
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalReverifyFlow
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
 * The Re-verify Chemical screen's actual behaviour.
 *
 * These drive [ChemicalReverifyFlow] — the same object the Compose sheet drives —
 * rather than re-deriving the sequence, so a rule cannot pass here while the screen
 * does something else. The iOS suite `ChemicalReverifyFlowTests` asserts the same
 * fixtures and the same outcomes.
 *
 * Four properties are under protection:
 *
 *  1. Cancel is writing nothing, by construction.
 *  2. Accept writes the outcome that was PREVIEWED, through the reconciler.
 *  3. A failed or empty lookup never downgrades a record.
 *  4. A completed spray's frozen snapshot survives any accepted update.
 */
class ChemicalReverifyFlowTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val at = "2026-08-16T00:00:00.000Z"

    /**
     * Deliberately not a real active — see the note in `ChemicalReverificationTest`.
     * A fixture that legitimately moves FRAC 11 → 3 cannot use a real active,
     * because the reference table knows the real classification and would correctly
     * raise a conflict (asserted separately in `a conflicted candidate...`).
     */
    private val referenceActive = "Examplestrobin"

    // MARK: Fixtures

    private fun frac(code: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, code)

    private fun active(
        name: String,
        concentration: Double? = null,
        group: ChemicalActivityGroup? = null,
        authoritative: Boolean = true,
    ) = ChemicalActiveIngredient(
        name = name,
        concentration = concentration,
        concentrationUnit = concentration?.let { ChemicalConcentrationUnit.GRAMS_PER_LITRE },
        activityGroup = group,
        groupSource = group?.let {
            if (authoritative) ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION
            else ChemicalDataSourceKind.MANUAL_ENTRY
        },
        identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
    )

    private fun registration(
        number: String? = "62764",
        name: String? = "Example Fungicide",
        registrant: String? = "Example Crop Science",
        labelVersion: String? = null,
    ) = ChemicalRegistration.of(
        countryCode = "AU",
        scheme = ChemicalRegistrationScheme.APVMA,
        registrationNumber = number,
        registrant = registrant,
        registeredProductName = name,
        labelVersion = labelVersion,
    )

    private fun verifiedEvidence(
        conflicts: List<ChemicalVerificationConflict> = emptyList(),
        extraSource: ChemicalDataSource? = null,
    ) = ChemicalVerification(
        status = ChemicalVerificationStatus.VERIFIED,
        sources = listOfNotNull(
            ChemicalDataSource(
                kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                name = "APVMA PUBCRIS",
            ),
            AuthoritativeActivityGroups.source(),
            extraSource,
        ),
        verifiedAt = at,
        conflicts = conflicts,
    )

    private fun group11(
        labelVersion: String? = null,
        uses: List<ChemicalRegisteredUse> = emptyList(),
        verification: ChemicalVerification = verifiedEvidence(),
    ) = ChemicalIntelligence(
        activeIngredients = listOf(active(referenceActive, 250.0, frac("11"))),
        registration = registration(labelVersion = labelVersion),
        verification = verification,
        registeredUses = uses,
        productCategory = "fungicide",
        activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION,
        schemaVersion = ChemicalIntelligence.CURRENT_SCHEMA_VERSION,
    )

    private fun group3() = group11().copy(
        activeIngredients = listOf(active(referenceActive, 250.0, frac("3"))),
    )

    private fun use(
        crop: String = "Grapes",
        target: String = "Powdery mildew",
        rates: List<ChemicalLabelRate> = emptyList(),
        whp: Int? = null,
        reEntry: Int? = null,
    ) = ChemicalRegisteredUse(
        crop = crop,
        targetRaw = target,
        rates = rates,
        withholdingPeriodDays = whp,
        reEntryPeriodHours = reEntry,
    )

    private fun rate(
        basis: ChemicalLabelRateBasis,
        value: Double? = null,
        min: Double? = null,
        max: Double? = null,
        unit: String = "mL",
    ) = ChemicalLabelRate(
        label = "",
        basis = basis,
        value = value,
        minValue = min,
        maxValue = max,
        unit = unit,
    )

    /**
     * A store record carrying real operational data the grower maintains.
     *
     * The pack size, price, stock and notes are here on purpose: accepting a
     * re-verification must upgrade the chemistry without discarding years of
     * inventory and costing, and that is an integration property of the write
     * payload rather than of the diff.
     */
    private fun savedChemical(
        name: String = "Example Fungicide",
        intelligence: ChemicalIntelligence? = group11(),
        activeIngredient: String = "",
        chemicalGroup: String = "",
    ): SavedChemical {
        val base = SavedChemical(
            id = "chem-1",
            vineyardId = "v1",
            name = name,
            manufacturer = "Example Crop Science",
            activeIngredient = activeIngredient,
            chemicalGroup = chemicalGroup,
            productCategory = "fungicide",
            unit = "Litres",
            notes = "Shed B, top shelf",
            packSize = 10.0,
            pricePerPack = 425.0,
            inventoryQuantity = 3.0,
            applicationNotes = "Do not tank-mix with oil",
        )
        val intel = intelligence ?: return base
        val reg = intel.registration
        return base.copy(
            activeIngredients = intel.activeIngredients,
            activityGroups = intel.activityGroupCodes,
            registrationCountry = reg?.countryCode,
            registrationScheme = reg?.scheme?.raw,
            registrationNumber = reg?.registrationNumber,
            registrant = reg?.registrant,
            registeredProductName = reg?.registeredProductName,
            labelVersion = reg?.labelVersion,
            verificationStatusRaw = intel.verification.status.raw,
            verificationSources = intel.verification.sources,
            verificationConflicts = intel.verification.conflicts,
            verifiedAt = intel.verification.verifiedAt,
            registeredUses = intel.registeredUses,
            activityGroupTableVersion = intel.activityGroupTableVersion,
            intelligenceSchemaVersion = intel.schemaVersion,
        )
    }

    private fun changes(
        stored: SavedChemical,
        candidate: ChemicalIntelligence,
    ): ChemicalReverifyFlow.Result.Changes {
        val result = ChemicalReverifyFlow.resolve(stored, candidate, at)
        assertTrue(
            "expected Changes, got ${result::class.simpleName}",
            result is ChemicalReverifyFlow.Result.Changes,
        )
        return result as ChemicalReverifyFlow.Result.Changes
    }

    private fun current(
        stored: SavedChemical,
        candidate: ChemicalIntelligence,
    ): ChemicalReverifyFlow.Result.Current {
        val result = ChemicalReverifyFlow.resolve(stored, candidate, at)
        assertTrue(
            "expected Current, got ${result::class.simpleName}",
            result is ChemicalReverifyFlow.Result.Current,
        )
        return result as ChemicalReverifyFlow.Result.Current
    }

    // MARK: No change

    @Test
    fun `an unchanged product resolves to the current result`() {
        val result = current(savedChemical(), group11())

        assertTrue(ChemicalReverifyFlow.currentIntelligence(savedChemical()) != null)
        assertNotNull(result.refreshed)
        // Chemistry untouched on a no-change confirmation.
        assertEquals(listOf("11"), result.refreshed!!.activityGroupCodes)
    }

    @Test
    fun `a no-change result on a legacy-only record refreshes nothing`() {
        // A record with no structured intelligence has only a legacy SEED. A
        // "nothing changed" answer must not become that record's first structured
        // write, or re-verification would quietly materialise a guess as data.
        val legacy = savedChemical(
            intelligence = null,
            activeIngredient = "$referenceActive 250 g/L",
            chemicalGroup = "11",
        )
        val candidate = ChemicalReverifyFlow.currentIntelligence(legacy)!!

        val result = current(legacy, candidate)

        assertNull(result.refreshed)
    }

    // MARK: Group change

    @Test
    fun `a group change reaches the review screen as a resistance-critical change`() {
        val result = changes(savedChemical(), group3())

        val change = result.diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE
        }
        assertEquals("FRAC 11", change.currentValue)
        assertEquals("FRAC 3", change.candidateValue)
        assertTrue(change.isResistanceCritical)
        assertTrue(result.diff.hasResistanceCriticalChanges)
        // Chemistry leads the screen.
        assertEquals(
            ChemicalIntelligenceDiffSection.ACTIVITY_GROUPS,
            result.diff.populatedSections.first(),
        )
    }

    // MARK: Actives added / removed / concentration

    @Test
    fun `an active added and removed both reach the review screen`() {
        val candidate = group11().copy(
            activeIngredients = listOf(active("Tebuconazole", 200.0, frac("3"))),
        )

        val result = changes(savedChemical(), candidate)

        val actives = result.diff.changes.filter {
            it.field == ChemicalIntelligenceDiffField.ACTIVE_INGREDIENT
        }
        assertEquals(2, actives.size)
        assertTrue(actives.any { it.kind == ChemicalIntelligenceChangeKind.ADDED })
        assertTrue(actives.any { it.kind == ChemicalIntelligenceChangeKind.REMOVED })
    }

    @Test
    fun `a concentration change reaches the review screen`() {
        val candidate = group11().copy(
            activeIngredients = listOf(active(referenceActive, 200.0, frac("11"))),
        )

        val result = changes(savedChemical(), candidate)

        val change = result.diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVE_CONCENTRATION
        }
        assertEquals("250 g/L", change.currentValue)
        assertEquals("200 g/L", change.candidateValue)
    }

    // MARK: Label rates

    @Test
    fun `a rate value change reaches the review screen as one change`() {
        val stored = savedChemical(
            intelligence = group11(
                uses = listOf(
                    use(rates = listOf(rate(ChemicalLabelRateBasis.PER_100_LITRES, value = 100.0))),
                ),
            ),
        )
        val candidate = group11(
            uses = listOf(
                use(
                    rates = listOf(
                        rate(ChemicalLabelRateBasis.PER_100_LITRES, min = 80.0, max = 100.0),
                    ),
                ),
            ),
        )

        val result = changes(stored, candidate)

        val change = result.diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.LABEL_RATE
        }
        assertEquals(ChemicalIntelligenceChangeKind.CHANGED, change.kind)
        assertEquals("100 mL/100 L", change.currentValue)
        assertEquals("80–100 mL/100 L", change.candidateValue)
    }

    @Test
    fun `a rate basis change reaches the review screen as a removal and an addition`() {
        val stored = savedChemical(
            intelligence = group11(
                uses = listOf(
                    use(rates = listOf(rate(ChemicalLabelRateBasis.PER_100_LITRES, value = 100.0))),
                ),
            ),
        )
        val candidate = group11(
            uses = listOf(
                use(
                    rates = listOf(
                        rate(ChemicalLabelRateBasis.PER_HECTARE, value = 1.5, unit = "L"),
                    ),
                ),
            ),
        )

        val result = changes(stored, candidate)

        val rateChanges = result.diff.changes.filter {
            it.field == ChemicalIntelligenceDiffField.LABEL_RATE
        }
        assertEquals(2, rateChanges.size)
        assertTrue(rateChanges.any { it.kind == ChemicalIntelligenceChangeKind.ADDED })
        assertTrue(rateChanges.any { it.kind == ChemicalIntelligenceChangeKind.REMOVED })
    }

    // MARK: Registered uses, WHP, re-entry

    @Test
    fun `a registered use change reaches the review screen`() {
        val stored = savedChemical(
            intelligence = group11(uses = listOf(use(target = "Powdery mildew"))),
        )
        val candidate = group11(
            uses = listOf(use(target = "Powdery mildew"), use(target = "Downy mildew")),
        )

        val result = changes(stored, candidate)

        val change = result.diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.REGISTERED_USE
        }
        assertEquals(ChemicalIntelligenceChangeKind.ADDED, change.kind)
        assertEquals("Grapes — Downy mildew", change.candidateValue)
        // Administrative, so it must not be dressed up as resistance news.
        assertFalse(change.isResistanceCritical)
    }

    @Test
    fun `a withholding and re-entry change reaches the review screen`() {
        val stored = savedChemical(
            intelligence = group11(uses = listOf(use(whp = 14, reEntry = 24))),
        )
        val candidate = group11(uses = listOf(use(whp = 21, reEntry = 48)))

        val result = changes(stored, candidate)

        assertEquals(
            "21 days",
            result.diff.changes
                .single { it.field == ChemicalIntelligenceDiffField.WITHHOLDING_PERIOD }
                .candidateValue,
        )
        assertEquals(
            "48 hours",
            result.diff.changes
                .single { it.field == ChemicalIntelligenceDiffField.RE_ENTRY_PERIOD }
                .candidateValue,
        )
    }

    // MARK: Source and version changes

    @Test
    fun `a source and label version change is a current result not an update`() {
        // Evidence-only movement is "current, freshly confirmed". Presenting a new
        // retrieval date as a product update is how operators learn to click
        // through review screens without reading them.
        val stored = savedChemical(intelligence = group11(labelVersion = "2024-06"))
        val candidate = group11(
            labelVersion = "2026-02",
            verification = verifiedEvidence(
                extraSource = ChemicalDataSource(
                    kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                    name = "APVMA label PDF",
                ),
            ),
        )

        val result = current(stored, candidate)

        val refreshed = result.refreshed!!
        // Chemistry untouched, provenance refreshed.
        assertEquals(listOf("11"), refreshed.activityGroupCodes)
        assertEquals("2026-02", refreshed.registration?.labelVersion)
        assertTrue(refreshed.verification.sources.any { it.name == "APVMA label PDF" })
    }

    // MARK: Conflict

    @Test
    fun `a conflicted candidate reaches review without a verified result`() {
        val conflicted = group3().copy(
            verification = verifiedEvidence(
                conflicts = listOf(
                    ChemicalVerificationConflict(
                        field = "concentration",
                        activeIngredientName = referenceActive,
                        extractedValue = "250 g/L",
                        authoritativeValue = "200 g/L",
                    ),
                ),
            ),
        )

        val result = changes(savedChemical(), conflicted)

        // The screen renders the outcome's conflicts, so they must survive here.
        assertTrue(result.outcome.intelligence.verification.conflicts.isNotEmpty())
        assertEquals(ChemicalVerificationStatus.CONFLICT, result.outcome.resolvedStatus)
        assertFalse(result.outcome.resolvedStatus.isResistanceDependable)
    }

    @Test
    fun `a contradicting group on a known active reaches review as a conflict`() {
        // Azoxystrobin is authoritatively FRAC 11. A lookup claiming FRAC 3 is a
        // disagreement, not an update, and the review screen must say so.
        val stored = savedChemical(
            intelligence = group11().copy(
                activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
            ),
        )
        val contradicting = group11().copy(
            activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("3"))),
        )

        val result = changes(stored, contradicting)

        assertEquals(ChemicalVerificationStatus.CONFLICT, result.outcome.resolvedStatus)
        assertTrue(result.outcome.intelligence.verification.conflicts.isNotEmpty())
    }

    // MARK: Lookup failure

    @Test
    fun `an empty lookup result is unusable and changes nothing`() {
        val stored = savedChemical()
        val before = json.encodeToString(SavedChemical.serializer(), stored)

        val result = ChemicalReverifyFlow.resolve(stored, ChemicalIntelligence(), at)

        assertTrue(result is ChemicalReverifyFlow.Result.Unusable)
        // A failed check is not evidence about the product, so nothing moves and
        // the record keeps the verification it already earned.
        assertEquals(before, json.encodeToString(SavedChemical.serializer(), stored))
        assertEquals(ChemicalVerificationStatus.VERIFIED, stored.verificationStatus)
        assertEquals(listOf("11"), stored.activityGroupCodes)
    }

    // MARK: Cancel

    @Test
    fun `cancelling a reviewed change leaves the record untouched`() {
        val stored = savedChemical()
        val before = json.encodeToString(SavedChemical.serializer(), stored)

        // Reviewing is the whole of a cancelled re-verification: resolve, show,
        // drop. Cancel is safe because no flow function mutates anything.
        val result = changes(stored, group3())
        assertTrue(result.diff.hasMeaningfulChanges)

        assertEquals(before, json.encodeToString(SavedChemical.serializer(), stored))
        assertEquals(listOf("11"), stored.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, stored.verificationStatus)
    }

    // MARK: Accept

    @Test
    fun `accepting writes the previewed outcome to the current record`() {
        val stored = savedChemical()
        val result = changes(stored, group3())

        val updated = ChemicalReverifyFlow.acceptedChemical(stored, result.outcome)

        assertEquals(listOf("3"), updated.activityGroupCodes)
        // Compatibility scalars stay derived from the structured truth.
        assertEquals("3", updated.chemicalGroup)
        assertTrue(updated.activeIngredient.contains(referenceActive))
        // The Chemical Store row reads the resolved status, so it updates at once.
        assertEquals(ChemicalVerificationStatus.VERIFIED, updated.verificationStatus)
    }

    @Test
    fun `the accepted write payload carries the structured intelligence`() {
        val stored = savedChemical()
        val result = changes(stored, group3())

        val input = ChemicalReverifyFlow.acceptedInput(stored, result.outcome)

        // Exactly the reconciled outcome — never a UI-assembled copy.
        assertEquals(result.outcome.intelligence, input.intelligence)
        assertEquals("3", input.chemicalGroup)
    }

    @Test
    fun `accepting an update keeps the operational data the grower maintains`() {
        val stored = savedChemical()
        val result = changes(stored, group3())

        val input = ChemicalReverifyFlow.acceptedInput(stored, result.outcome)

        // Upgrading chemistry must not cost the grower their inventory and costing.
        assertEquals(10.0, input.packSize)
        assertEquals(425.0, input.pricePerPack)
        assertEquals(3.0, input.inventoryQuantity)
        assertEquals("Shed B, top shelf", input.notes)
        assertEquals("Do not tank-mix with oil", input.applicationNotes)
        assertEquals("Litres", input.unit)
    }

    @Test
    fun `accepting cannot force verified from an AI-only reading`() {
        val stored = savedChemical()
        val aiCandidate = group3().copy(
            activeIngredients = listOf(
                active(referenceActive, 250.0, frac("3"), authoritative = false),
            ),
            verification = ChemicalVerification(
                status = ChemicalVerificationStatus.VERIFIED,
                sources = listOf(
                    ChemicalDataSource(
                        kind = ChemicalDataSourceKind.AI_INTERPRETATION,
                        name = "Search summary",
                    ),
                ),
            ),
        )

        val result = changes(stored, aiCandidate)

        // Completeness is not evidence. There is no path here that sets VERIFIED.
        assertFalse(result.outcome.resolvedStatus.isResistanceDependable)
        assertTrue(result.outcome.isDowngrade)
    }

    // MARK: Current status refresh

    @Test
    fun `confirming a current result writes evidence only`() {
        val stored = savedChemical(intelligence = group11(labelVersion = "2024-06"))
        val result = current(stored, group11(labelVersion = "2026-02"))

        val input = ChemicalReverifyFlow.confirmedInput(stored, result.refreshed!!)

        // Same chemistry, fresher provenance.
        assertEquals(listOf("11"), input.intelligence?.activityGroupCodes)
        assertEquals("2026-02", input.intelligence?.registration?.labelVersion)
        assertEquals(at, input.intelligence?.verification?.verifiedAt)
        // And no meaningless product change was invented.
        assertEquals("11", input.chemicalGroup)
    }

    // MARK: Historical immutability

    @Test
    fun `accepting an update never touches a completed spray snapshot`() {
        val stored = savedChemical()
        // A spray completed while the product was FRAC 11.
        val line = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            ratePerHa = 1500.0,
            savedChemicalId = stored.id,
            chemicalSnapshot = ChemicalSnapshotCapture.capture(stored, at),
        )
        val frozen = line.chemicalSnapshot
        assertNotNull(frozen)
        checkNotNull(frozen)

        // The operator re-verifies onto FRAC 3 and accepts, through the real path.
        val result = changes(stored, group3())
        val updated = ChemicalReverifyFlow.acceptedChemical(stored, result.outcome)

        // Current record moved.
        assertEquals(listOf("3"), updated.activityGroupCodes)
        // Completed application did not, in any frozen dimension.
        assertEquals(listOf("11"), line.chemicalSnapshot?.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, frozen.verificationStatus)
        assertEquals(AuthoritativeActivityGroups.TABLE_VERSION, frozen.activityGroupTableVersion)
        assertEquals(at, frozen.capturedAt)
        assertEquals("AU:apvma:62764", frozen.registrationIdentityKey)

        // Still true through a persist/reload cycle.
        val reloaded = json.decodeFromString(
            SprayChemical.serializer(),
            json.encodeToString(SprayChemical.serializer(), line),
        )
        assertEquals(listOf("11"), reloaded.chemicalSnapshot?.activityGroupCodes)
        assertEquals(at, reloaded.chemicalSnapshot?.capturedAt)
    }

    @Test
    fun `confirming a current result never touches a completed spray snapshot`() {
        val stored = savedChemical(intelligence = group11(labelVersion = "2024-06"))
        val line = SprayChemical(
            id = "line-1",
            name = "Example Fungicide",
            ratePerHa = 1500.0,
            savedChemicalId = stored.id,
            chemicalSnapshot = ChemicalSnapshotCapture.capture(stored, at),
        )
        val frozen = line.chemicalSnapshot
        assertNotNull(frozen)
        checkNotNull(frozen)

        val result = current(stored, group11(labelVersion = "2026-02"))
        ChemicalReverifyFlow.confirmedInput(stored, result.refreshed!!)

        // A freshly confirmed check must not restamp a completed application.
        // `capturedAt` is the one that matters most here: if refreshing evidence
        // could move it, the audit trail would claim the spray was recorded
        // against information that did not exist on the day it was applied.
        assertEquals(at, frozen.capturedAt)
        assertEquals(listOf("11"), frozen.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, frozen.verificationStatus)
        assertEquals(frozen, line.chemicalSnapshot)
    }

    // MARK: Entry-point eligibility comes from the domain

    @Test
    fun `the entry point is offered exactly where the domain says it is`() {
        // Verified, partially verified, unverified and conflicted records all hold
        // an identity worth re-checking.
        for (status in listOf(
            ChemicalVerificationStatus.VERIFIED,
            ChemicalVerificationStatus.PARTIALLY_VERIFIED,
            ChemicalVerificationStatus.UNVERIFIED,
            ChemicalVerificationStatus.CONFLICT,
        )) {
            val intel = group11(verification = verifiedEvidence().copy(status = status))
            assertTrue(
                "expected Re-verify offered for $status",
                ChemicalReverification.isOffered(savedChemical(intelligence = intel), "AU"),
            )
        }

        // A legacy record with nothing but a typed name goes to Match & Verify.
        val legacy = savedChemical(
            intelligence = null,
            activeIngredient = "Azoxystrobin",
            chemicalGroup = "11",
        )
        assertFalse(ChemicalReverification.isOffered(legacy, "AU"))
        assertNotNull(ChemicalReverification.unavailableReason(legacy, "AU"))
    }

    @Test
    fun `the lookup leads with the held registration rather than the brand name`() {
        val plan = ChemicalReverification.plan(savedChemical(), "AU")

        assertEquals(
            ChemicalReverification.IdentityStrength.REGISTRATION_IDENTITY,
            plan.strength,
        )
        // Re-verification must not restart as a broad product-name search.
        assertTrue(plan.lookupQuery.contains("62764"))
        assertTrue(plan.lookupQuery.contains("APVMA"))
    }
}
