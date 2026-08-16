package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceAvailability
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceChangeKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffField
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffSection
import com.rork.vinetrack.data.chemical.ChemicalIntelligenceDiffer
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalReverification
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import com.rork.vinetrack.data.chemical.resistanceAvailability
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
 * Re-verification, the old → new diff, and the chemical-intelligence
 * availability contract.
 *
 * The iOS suite `ChemicalReverificationTests` asserts the same fixtures and the
 * same outcomes. Four rules are under protection here:
 *
 *  1. A diff compares MEANING, so reordering is never reported as a change.
 *  2. Cancel writes nothing; Accept changes only the current record.
 *  3. A completed spray's frozen snapshot survives any re-verification.
 *  4. An absent snapshot is "cannot assess", never "no concern".
 */
class ChemicalReverificationTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val at = "2026-08-15T00:00:00.000Z"

    /**
     * The reference product's active, deliberately NOT a real one.
     *
     * A fixture that legitimately moves from FRAC 11 to FRAC 3 cannot use a real
     * active, because `AuthoritativeActivityGroups` knows the real classification
     * and would correctly raise a conflict — see
     * `re-verifying a known active onto a contradicting group conflicts`, which
     * asserts exactly that. Using an unknown active isolates the diff/accept
     * behaviour from the reference-table cross-check.
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
    ) = ChemicalVerification(
        status = ChemicalVerificationStatus.VERIFIED,
        sources = listOf(
            ChemicalDataSource(
                kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                name = "APVMA PUBCRIS",
            ),
            AuthoritativeActivityGroups.source(),
        ),
        verifiedAt = at,
        conflicts = conflicts,
    )

    /** Azoxystrobin, FRAC 11, verified — the reference product. */
    private fun group11(
        labelVersion: String? = null,
        uses: List<ChemicalRegisteredUse> = emptyList(),
    ) = ChemicalIntelligence(
        activeIngredients = listOf(active(referenceActive, 250.0, frac("11"))),
        registration = registration(labelVersion = labelVersion),
        verification = verifiedEvidence(),
        registeredUses = uses,
        productCategory = "fungicide",
        activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION,
        schemaVersion = ChemicalIntelligence.CURRENT_SCHEMA_VERSION,
    )

    /** The same product legitimately re-verified onto FRAC 3. */
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
        label: String = "",
    ) = ChemicalLabelRate(
        label = label,
        basis = basis,
        value = value,
        minValue = min,
        maxValue = max,
        unit = unit,
    )

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

    // MARK: Phase 25 — no change

    @Test
    fun `identical current and candidate produce an empty diff`() {
        val diff = ChemicalIntelligenceDiffer.diff(group11(), group11())

        assertTrue(diff.isEmpty)
        assertFalse(diff.hasMeaningfulChanges)
        assertTrue(ChemicalReverification.isNoChangeResult(diff))
    }

    @Test
    fun `reordering actives sources and uses is not a change`() {
        val a = active("Tebuconazole", 200.0, frac("3"))
        val b = active(referenceActive, 120.0, frac("11"))
        val useA = use(target = "Powdery mildew")
        val useB = use(target = "Downy mildew")
        val sources = verifiedEvidence().sources

        val current = group11().copy(
            activeIngredients = listOf(a, b),
            registeredUses = listOf(useA, useB),
            verification = verifiedEvidence().copy(sources = sources),
        )
        // Same facts, every unordered collection reversed.
        val candidate = current.copy(
            activeIngredients = listOf(b, a),
            registeredUses = listOf(useB, useA),
            verification = current.verification.copy(sources = sources.reversed()),
        )

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        assertTrue(
            "ordering alone must not diff, got ${diff.changes.map { it.id }}",
            diff.isEmpty,
        )
    }

    // MARK: Phase 25 — group change

    @Test
    fun `group change 11 to 3 is reported against the active`() {
        val diff = ChemicalIntelligenceDiffer.diff(group11(), group3())

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE
        }
        assertEquals(ChemicalIntelligenceChangeKind.CHANGED, change.kind)
        assertEquals(referenceActive, change.subject)
        assertEquals("FRAC 11", change.currentValue)
        assertEquals("FRAC 3", change.candidateValue)
        assertTrue(diff.hasResistanceCriticalChanges)
        assertFalse(ChemicalReverification.isNoChangeResult(diff))
        // Reported once, not also as a product-level add/remove pair.
        assertEquals(
            1,
            diff.changes.count { it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE },
        )
    }

    @Test
    fun `activity group scheme change is reported`() {
        val candidate = group11().copy(
            activeIngredients = listOf(
                active(
                    referenceActive, 250.0,
                    ChemicalActivityGroup.of(ChemicalActivityGroupScheme.HRAC, "11"),
                ),
            ),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_SCHEME
        }
        assertEquals("FRAC", change.currentValue)
        assertEquals("HRAC", change.candidateValue)
    }

    // MARK: Phase 25 — actives added/removed, concentration

    @Test
    fun `active added and removed are both reported`() {
        val candidate = group11().copy(
            activeIngredients = listOf(active("Tebuconazole", 200.0, frac("3"))),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val added = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVE_INGREDIENT &&
                it.kind == ChemicalIntelligenceChangeKind.ADDED
        }
        val removed = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVE_INGREDIENT &&
                it.kind == ChemicalIntelligenceChangeKind.REMOVED
        }
        assertEquals("Tebuconazole", added.subject)
        assertEquals(referenceActive, removed.subject)
        // The product's group set moved too, and that is separately visible.
        assertTrue(
            diff.changes.any {
                it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE
            },
        )
    }

    @Test
    fun `concentration change is reported with both values`() {
        val candidate = group11().copy(
            activeIngredients = listOf(active(referenceActive, 200.0, frac("11"))),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.ACTIVE_CONCENTRATION
        }
        assertEquals("250 g/L", change.currentValue)
        assertEquals("200 g/L", change.candidateValue)
        assertTrue(change.isResistanceCritical)
    }

    @Test
    fun `concentration unit change is reported`() {
        val candidate = group11().copy(
            activeIngredients = listOf(
                active(referenceActive, 250.0, frac("11")).copy(
                    concentrationUnit = ChemicalConcentrationUnit.GRAMS_PER_KILOGRAM,
                ),
            ),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.CONCENTRATION_UNIT
        }
        assertEquals("g/L", change.currentValue)
        assertEquals("g/kg", change.candidateValue)
    }

    // MARK: Phase 25 — registration identity

    @Test
    fun `registration identity change is reported and is resistance critical`() {
        val candidate = group11().copy(registration = registration(number = "70001"))

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.REGISTRATION_IDENTIFIER
        }
        assertEquals("62764", change.currentValue)
        assertEquals("70001", change.candidateValue)
        assertTrue(change.isResistanceCritical)
        assertEquals(ChemicalIntelligenceDiffSection.IDENTITY, change.section)
    }

    @Test
    fun `a lookup that omits a field does not report it as removed`() {
        // Silence is not evidence of absence: an incomplete lookup response must
        // not read as the regulator having withdrawn the registration number.
        val candidate = group11().copy(
            registration = ChemicalRegistration.of(countryCode = "AU"),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        assertFalse(
            diff.changes.any {
                it.field == ChemicalIntelligenceDiffField.REGISTRATION_IDENTIFIER
            },
        )
    }

    // MARK: Phase 25 — label rates

    @Test
    fun `label rate value change is one change not an add plus remove`() {
        val current = group11(
            uses = listOf(
                use(rates = listOf(rate(ChemicalLabelRateBasis.PER_100_LITRES, value = 100.0))),
            ),
        )
        val candidate = group11(
            uses = listOf(
                use(
                    rates = listOf(
                        rate(
                            ChemicalLabelRateBasis.PER_100_LITRES,
                            min = 80.0, max = 100.0,
                        ),
                    ),
                ),
            ),
        )

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.LABEL_RATE
        }
        assertEquals(ChemicalIntelligenceChangeKind.CHANGED, change.kind)
        assertEquals("100 mL/100 L", change.currentValue)
        assertEquals("80–100 mL/100 L", change.candidateValue)
    }

    @Test
    fun `label rate basis change reports a removal and an addition`() {
        val current = group11(
            uses = listOf(
                use(rates = listOf(rate(ChemicalLabelRateBasis.PER_100_LITRES, value = 100.0))),
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

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        val rateChanges = diff.changes.filter {
            it.field == ChemicalIntelligenceDiffField.LABEL_RATE
        }
        assertEquals(2, rateChanges.size)
        assertTrue(rateChanges.any { it.kind == ChemicalIntelligenceChangeKind.ADDED })
        assertTrue(rateChanges.any { it.kind == ChemicalIntelligenceChangeKind.REMOVED })
    }

    // MARK: Phase 25 — registered uses, WHP, re-entry

    @Test
    fun `registered use added is reported with its crop and target`() {
        val current = group11(uses = listOf(use(target = "Powdery mildew")))
        val candidate = group11(
            uses = listOf(use(target = "Powdery mildew"), use(target = "Downy mildew")),
        )

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.REGISTERED_USE
        }
        assertEquals(ChemicalIntelligenceChangeKind.ADDED, change.kind)
        assertEquals("Grapes — Downy mildew", change.candidateValue)
    }

    @Test
    fun `registered use removed is reported`() {
        val current = group11(
            uses = listOf(use(target = "Powdery mildew"), use(target = "Downy mildew")),
        )
        val candidate = group11(uses = listOf(use(target = "Powdery mildew")))

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.REGISTERED_USE
        }
        assertEquals(ChemicalIntelligenceChangeKind.REMOVED, change.kind)
        assertEquals("Grapes — Downy mildew", change.currentValue)
    }

    @Test
    fun `withholding and re-entry changes are reported`() {
        val current = group11(uses = listOf(use(whp = 14, reEntry = 24)))
        val candidate = group11(uses = listOf(use(whp = 21, reEntry = 48)))

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        val whp = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.WITHHOLDING_PERIOD
        }
        val reEntry = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.RE_ENTRY_PERIOD
        }
        assertEquals("14 days", whp.currentValue)
        assertEquals("21 days", whp.candidateValue)
        assertEquals("24 hours", reEntry.currentValue)
        assertEquals("48 hours", reEntry.candidateValue)
    }

    // MARK: Phase 25 — evidence and version changes

    @Test
    fun `label and table version changes are evidence only`() {
        val current = group11(labelVersion = "2024-06")
        val candidate = group11(labelVersion = "2026-02")
            .copy(activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION + 1)

        val diff = ChemicalIntelligenceDiffer.diff(current, candidate)

        assertTrue(diff.hasMeaningfulChanges)
        assertTrue(diff.isEvidenceOnly)
        assertFalse(diff.hasResistanceCriticalChanges)
        // Evidence-only movement is "current, freshly confirmed", not "updated".
        assertTrue(ChemicalReverification.isNoChangeResult(diff))
        assertEquals(
            listOf(ChemicalIntelligenceDiffSection.EVIDENCE),
            diff.populatedSections,
        )
    }

    @Test
    fun `a newly cited source is reported as evidence`() {
        val candidate = group11().copy(
            verification = verifiedEvidence().copy(
                sources = verifiedEvidence().sources + ChemicalDataSource(
                    kind = ChemicalDataSourceKind.MANUFACTURER_LABEL,
                    name = "Example label 2026",
                ),
            ),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(), candidate)

        val change = diff.changes.single {
            it.field == ChemicalIntelligenceDiffField.SOURCE
        }
        assertEquals(ChemicalIntelligenceChangeKind.ADDED, change.kind)
        assertEquals("Example label 2026", change.candidateValue)
        assertTrue(diff.isEvidenceOnly)
    }

    @Test
    fun `sections are ordered chemistry first`() {
        val candidate = group3().copy(
            registration = registration(number = "70001", labelVersion = "2026-02"),
            registeredUses = listOf(use()),
        )

        val diff = ChemicalIntelligenceDiffer.diff(group11(uses = emptyList()), candidate)

        // Whatever else moved, the operator reads the group change first.
        assertEquals(ChemicalIntelligenceDiffSection.ACTIVITY_GROUPS, diff.populatedSections.first())
    }

    // MARK: Phase 25 — cancel and accept

    @Test
    fun `cancel leaves the stored chemical untouched`() {
        val stored = savedChemical()
        val before = json.encodeToString(SavedChemical.serializer(), stored)

        // Diffing is the whole of a cancelled re-verification: read, show, drop.
        val diff = ChemicalIntelligenceDiffer.diff(stored.resolvedIntelligence, group3())
        assertTrue(diff.hasMeaningfulChanges)

        assertEquals(before, json.encodeToString(SavedChemical.serializer(), stored))
        assertEquals(listOf("11"), stored.activityGroupCodes)
    }

    @Test
    fun `accept updates the saved chemical to the new chemistry`() {
        val stored = savedChemical()

        val outcome = ChemicalReverification.apply(
            candidate = group3(),
            current = stored.resolvedIntelligence,
            at = at,
        )
        val updated = ChemicalReverification.updated(stored, outcome)

        assertEquals(listOf("3"), updated.activityGroupCodes)
        // Legacy scalar mirrors follow the structured truth.
        assertEquals("3", updated.chemicalGroup)
        assertTrue(updated.activeIngredient.contains(referenceActive))
        // The stored CLAIM is persisted; the displayed status is re-derived.
        assertEquals(
            ChemicalVerificationStatus.VERIFIED,
            ChemicalVerificationStatus.from(updated.verificationStatusRaw),
        )
        assertEquals(ChemicalVerificationStatus.VERIFIED, updated.verificationStatus)
    }

    @Test
    fun `accept never forces verified when the lookup is only an AI reading`() {
        val stored = savedChemical()
        // A complete-looking candidate whose only citation is an AI reading.
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

        val outcome = ChemicalReverification.apply(
            candidate = aiCandidate,
            current = stored.resolvedIntelligence,
            at = at,
        )

        // Completeness is not evidence. Trust may not rise on an AI answer.
        assertFalse(outcome.resolvedStatus.isResistanceDependable)
        assertTrue(outcome.isDowngrade)
    }

    @Test
    fun `re-verifying a known active onto a contradicting group conflicts`() {
        // Azoxystrobin is authoritatively FRAC 11. A lookup claiming FRAC 3 for it
        // is not an update, it is a disagreement — and the reference-table
        // cross-check must catch it during re-verification exactly as it does
        // during a manual edit, or a bad lookup could launder itself into a
        // Verified record.
        val stored = savedChemical(
            intelligence = group11().copy(
                activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("11"))),
            ),
        )
        val contradicting = group11().copy(
            activeIngredients = listOf(active("Azoxystrobin", 250.0, frac("3"))),
        )

        val outcome = ChemicalReverification.apply(
            candidate = contradicting,
            current = stored.resolvedIntelligence,
            at = at,
        )

        assertEquals(ChemicalVerificationStatus.CONFLICT, outcome.resolvedStatus)
        // The operator's/lookup's value is still stored — VineTrack does not pick
        // a winner, it surfaces the disagreement.
        assertEquals(
            "3",
            outcome.intelligence.activeIngredients.single().activityGroup?.code,
        )
        assertTrue(outcome.intelligence.verification.conflicts.isNotEmpty())
    }

    @Test
    fun `a candidate carrying an unresolved conflict cannot become verified`() {
        val stored = savedChemical()
        // A non-group conflict on purpose. Activity-group conflicts are
        // deliberately RECOMPUTED from the reference table on every reconcile, so
        // that correcting a bad group clears the conflict it caused; injecting one
        // here would test the wrong thing. A concentration disagreement is
        // carried through untouched, which is what proves an unresolved conflict
        // from the lookup survives into the accepted record.
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

        val outcome = ChemicalReverification.apply(
            candidate = conflicted,
            current = stored.resolvedIntelligence,
            at = at,
        )

        assertEquals(ChemicalVerificationStatus.CONFLICT, outcome.resolvedStatus)
        val updated = ChemicalReverification.updated(stored, outcome)
        assertEquals(ChemicalVerificationStatus.CONFLICT, updated.verificationStatus)
    }

    @Test
    fun `a no-change result refreshes evidence without rewriting chemistry`() {
        val current = group11()
        val candidate = group11(labelVersion = "2026-02")

        val confirmed = ChemicalReverification.confirmingCurrent(current, candidate, at)

        // Values untouched.
        assertEquals(current.activeIngredients, confirmed.activeIngredients)
        assertEquals(listOf("11"), confirmed.activityGroupCodes)
        // Evidence refreshed.
        assertEquals(at, confirmed.verification.verifiedAt)
        assertEquals("2026-02", confirmed.registration?.labelVersion)
        // And the freshly confirmed record still diffs clean against itself.
        assertTrue(ChemicalIntelligenceDiffer.diff(confirmed, confirmed).isEmpty)
    }

    // MARK: Phase 2 — strongest identity first

    @Test
    fun `re-verification keys on the held registration number not the brand name`() {
        val plan = ChemicalReverification.plan(savedChemical())

        assertEquals(ChemicalReverification.IdentityStrength.REGISTRATION_IDENTITY, plan.strength)
        assertEquals("AU:apvma:62764", plan.identityKey)
        // The exact registration leads the query; the name only disambiguates.
        assertTrue(plan.lookupQuery.contains("62764"))
        assertTrue(plan.lookupQuery.contains("APVMA"))
    }

    @Test
    fun `identity strength falls back through registrant to name only`() {
        val noNumber = group11().copy(registration = registration(number = null))
        assertEquals(
            ChemicalReverification.IdentityStrength.PRODUCT_REGISTRANT_COUNTRY,
            ChemicalReverification.plan(savedChemical(intelligence = noNumber)).strength,
        )

        val bare = group11().copy(
            registration = ChemicalRegistration.of(countryCode = "AU", registrant = null),
        )
        assertEquals(
            ChemicalReverification.IdentityStrength.PRODUCT_NAME_ONLY,
            ChemicalReverification.plan(
                savedChemical(intelligence = bare).copy(manufacturer = ""),
            ).strength,
        )
    }

    @Test
    fun `re-verify is offered for every structured status`() {
        for (status in listOf(
            ChemicalVerificationStatus.VERIFIED,
            ChemicalVerificationStatus.PARTIALLY_VERIFIED,
            ChemicalVerificationStatus.UNVERIFIED,
            ChemicalVerificationStatus.CONFLICT,
        )) {
            val intel = group11().copy(
                verification = verifiedEvidence().copy(status = status),
            )
            assertTrue(
                "expected re-verify offered for $status",
                ChemicalReverification.isOffered(savedChemical(intelligence = intel)),
            )
        }
    }

    @Test
    fun `a legacy needs-match product with no registration is sent to match and verify`() {
        // Nothing but a typed name: there is no identity to re-check, so
        // re-verification would silently become a fresh brand-name search.
        val legacy = savedChemical(
            intelligence = null,
            activeIngredient = "Azoxystrobin",
            chemicalGroup = "11",
        )

        assertEquals(ChemicalVerificationStatus.NEEDS_MATCH, legacy.verificationStatus)
        assertFalse(ChemicalReverification.isOffered(legacy, fallbackCountry = "AU"))
        assertNotNull(ChemicalReverification.unavailableReason(legacy, fallbackCountry = "AU"))
    }

    @Test
    fun `a needs-match product that does hold a registration can be re-verified`() {
        val intel = group11().copy(
            verification = ChemicalVerification.legacy(),
        )

        assertTrue(ChemicalReverification.isOffered(savedChemical(intelligence = intel)))
    }

    @Test
    fun `re-verify is refused when no country is known`() {
        val noCountry = group11().copy(
            registration = ChemicalRegistration.of(countryCode = "", registrationNumber = "62764"),
        )

        val chemical = savedChemical(intelligence = noCountry)
        assertFalse(ChemicalReverification.isOffered(chemical))
        assertTrue(
            ChemicalReverification.unavailableReason(chemical).orEmpty().contains("country"),
        )
    }

    // MARK: Phase 8 — historical immutability

    @Test
    fun `re-verifying a chemical never changes a completed spray snapshot`() {
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

        // The store is re-verified onto FRAC 3 and accepted.
        val outcome = ChemicalReverification.apply(group3(), stored.resolvedIntelligence, at)
        val updated = ChemicalReverification.updated(stored, outcome)
        assertEquals(listOf("3"), updated.activityGroupCodes)

        // The completed application is untouched, in every frozen dimension.
        assertEquals(listOf("11"), line.chemicalSnapshot?.activityGroupCodes)
        assertEquals(ChemicalVerificationStatus.VERIFIED, frozen.verificationStatus)
        assertEquals(
            AuthoritativeActivityGroups.TABLE_VERSION,
            frozen.activityGroupTableVersion,
        )
        assertEquals(at, frozen.capturedAt)
        assertEquals("AU:apvma:62764", frozen.registrationIdentityKey)

        // Still true after a persist/reload cycle.
        val reloaded = json.decodeFromString(
            SprayChemical.serializer(),
            json.encodeToString(SprayChemical.serializer(), line),
        )
        assertEquals(frozen, reloaded.chemicalSnapshot)
    }

    // MARK: Phase 28 — availability

    @Test
    fun `availability reflects each frozen verification status`() {
        val cases = mapOf(
            ChemicalVerificationStatus.VERIFIED to
                ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED,
            ChemicalVerificationStatus.PARTIALLY_VERIFIED to
                ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED,
            ChemicalVerificationStatus.UNVERIFIED to
                ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
            ChemicalVerificationStatus.NEEDS_MATCH to
                ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
            ChemicalVerificationStatus.CONFLICT to
                ChemicalIntelligenceAvailability.CONFLICT,
        )
        for ((status, expected) in cases) {
            val snapshot = ChemicalLineSnapshot(
                activityGroupCodes = listOf("11"),
                activeIngredients = listOf(active(referenceActive, 250.0, frac("11"))),
                verificationStatus = status,
            )
            assertEquals(expected, ChemicalIntelligenceAvailability.resolve(snapshot))
        }
    }

    @Test
    fun `an absent snapshot is unavailable and never a clean result`() {
        val availability = ChemicalIntelligenceAvailability.resolve(null)

        assertEquals(ChemicalIntelligenceAvailability.UNAVAILABLE, availability)
        // The single most important assertion in this file: silence is not safety.
        assertFalse(availability.canAssess)
        assertFalse(availability.permitsCleanResult)
        assertFalse(availability.isDependable)
        assertTrue(availability.requiresQualification)
        assertNotNull(availability.assessmentCaveat)
    }

    @Test
    fun `a legacy-only snapshot carries no assessable chemistry`() {
        // Preserved display text, no structured group: honestly unassessable.
        val legacyOnly = ChemicalLineSnapshot(
            productName = "Mystery Product",
            legacyChemicalGroup = "Group 3 + 11",
            verificationStatus = ChemicalVerificationStatus.UNVERIFIED,
        )

        assertFalse(legacyOnly.hasResistanceData)
        assertEquals(
            ChemicalIntelligenceAvailability.UNAVAILABLE,
            ChemicalIntelligenceAvailability.resolve(legacyOnly),
        )
    }

    @Test
    fun `a historical line with no snapshot reports unavailable`() {
        val legacyLine = SprayChemical(id = "c1", name = "Old product", ratePerHa = 2000.0)

        assertNull(legacyLine.chemicalSnapshot)
        assertEquals(
            ChemicalIntelligenceAvailability.UNAVAILABLE,
            legacyLine.resistanceAvailability,
        )
    }

    @Test
    fun `only verified chemistry is dependable`() {
        assertTrue(ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED.isDependable)
        for (other in listOf(
            ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED,
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED,
            ChemicalIntelligenceAvailability.CONFLICT,
            ChemicalIntelligenceAvailability.UNAVAILABLE,
        )) {
            assertFalse("$other must not be dependable", other.isDependable)
            assertTrue(other.requiresQualification)
            assertNotNull(other.assessmentCaveat)
        }
    }

    @Test
    fun `a mixed tank is governed by its weakest line`() {
        val verified = ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED
        val unknown = ChemicalIntelligenceAvailability.UNAVAILABLE

        // One unknown product in the tank could be the very group that breaks
        // the rotation, so the whole application stops being assessable.
        assertEquals(
            unknown,
            ChemicalIntelligenceAvailability.combined(listOf(verified, unknown)),
        )
        assertEquals(
            ChemicalIntelligenceAvailability.CONFLICT,
            ChemicalIntelligenceAvailability.combined(
                listOf(verified, ChemicalIntelligenceAvailability.CONFLICT),
            ),
        )
        // An application with no lines at all is not vacuously fine.
        assertEquals(unknown, ChemicalIntelligenceAvailability.combined(emptyList()))
    }

    @Test
    fun `availability serialises to the shared raw values`() {
        assertEquals("available_verified", ChemicalIntelligenceAvailability.AVAILABLE_VERIFIED.raw)
        assertEquals(
            "available_partially_verified",
            ChemicalIntelligenceAvailability.AVAILABLE_PARTIALLY_VERIFIED.raw,
        )
        assertEquals(
            "available_unverified",
            ChemicalIntelligenceAvailability.AVAILABLE_UNVERIFIED.raw,
        )
        assertEquals("conflict", ChemicalIntelligenceAvailability.CONFLICT.raw)
        assertEquals("unavailable", ChemicalIntelligenceAvailability.UNAVAILABLE.raw)
    }

    // MARK: Phase 29 — diff field parity

    @Test
    fun `diff field and section raw values are stable across platforms`() {
        assertEquals("activity_group_code", ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE.raw)
        assertEquals("active_concentration", ChemicalIntelligenceDiffField.ACTIVE_CONCENTRATION.raw)
        assertEquals(
            "registration_identifier",
            ChemicalIntelligenceDiffField.REGISTRATION_IDENTIFIER.raw,
        )
        assertEquals("label_rate", ChemicalIntelligenceDiffField.LABEL_RATE.raw)
        assertEquals("registered_use", ChemicalIntelligenceDiffField.REGISTERED_USE.raw)
        assertEquals("activity_groups", ChemicalIntelligenceDiffSection.ACTIVITY_GROUPS.raw)
        assertEquals("evidence", ChemicalIntelligenceDiffSection.EVIDENCE.raw)
    }
}
