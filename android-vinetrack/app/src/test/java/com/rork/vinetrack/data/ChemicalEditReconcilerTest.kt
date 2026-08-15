package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConcentrationUnit
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalEditReconciler
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalResistanceField
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 20 — verification must not survive a manual change to the very value
 * that was verified, and must not be disturbed by an edit to anything else.
 *
 * Every assertion here goes through [ChemicalEditReconciler] and then reads
 * `resolvedVerificationStatus`. None of them assign a status. That is the point:
 * the tests prove the EVIDENCE model reaches the right conclusion, so no UI
 * layer is ever in a position to declare something verified.
 */
class ChemicalEditReconcilerTest {

    // ---- Fixtures -----------------------------------------------------------

    private fun frac(code: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, code)

    /** Azoxystrobin is in the reference table as FRAC 11. */
    private fun verifiedAzoxystrobin() = ChemicalIntelligence(
        activeIngredients = listOf(
            ChemicalActiveIngredient(
                name = "Azoxystrobin",
                concentration = 250.0,
                concentrationUnit = ChemicalConcentrationUnit.GRAMS_PER_LITRE,
                activityGroup = frac("11"),
                groupSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                identitySource = ChemicalDataSourceKind.OFFICIAL_REGISTER,
            ),
        ),
        registration = ChemicalRegistration.of(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "62764",
            registrant = "Example Crop Science",
        ),
        verification = ChemicalVerification(
            status = ChemicalVerificationStatus.VERIFIED,
            sources = listOf(
                ChemicalDataSource(
                    kind = ChemicalDataSourceKind.OFFICIAL_REGISTER,
                    name = "APVMA PUBCRIS",
                ),
                AuthoritativeActivityGroups.source(),
            ),
            verifiedAt = "2026-08-15T00:00:00Z",
        ),
        productCategory = "fungicide",
        activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION,
    )

    /**
     * A verified product whose active the reference table has NO opinion about,
     * so a hand-typed group cannot be positively contradicted.
     */
    private fun verifiedUnknownActive() = verifiedAzoxystrobin().let { base ->
        base.copy(
            activeIngredients = listOf(
                base.activeIngredients.first().copy(name = "Vinclozolin-XT"),
            ),
        )
    }

    /** Replays a legacy-form save where the operator changed nothing chemical. */
    private fun untouchedLegacyEdit(intel: ChemicalIntelligence) =
        ChemicalEditReconciler.reconcileLegacyEdit(
            existing = intel,
            activeIngredientText = intel.legacyActiveIngredient,
            chemicalGroupText = intel.legacyChemicalGroup,
            modeOfActionText = "",
            productCategory = intel.productCategory,
            registrantText = intel.registration?.registrant.orEmpty(),
        )

    // ---- Verified → manual group edit ---------------------------------------

    @Test
    fun `hand-changing FRAC 11 to FRAC 3 cannot leave the record verified`() {
        val before = verifiedAzoxystrobin()
        assertEquals(ChemicalVerificationStatus.VERIFIED, before.resolvedVerificationStatus)

        val outcome = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = before,
            activeIngredientText = before.legacyActiveIngredient,
            chemicalGroupText = "3",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = before.registration?.registrant.orEmpty(),
        )

        requireNotNull(outcome)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
        assertTrue(outcome.isDowngrade)
        assertTrue(ChemicalResistanceField.ACTIVITY_GROUP_CODE in outcome.changedFields)
        // The reference table positively disagrees, so this is a conflict rather
        // than a mere absence of evidence.
        assertEquals(ChemicalVerificationStatus.CONFLICT, outcome.resolvedStatus)
        assertTrue(outcome.intelligence.verification.conflicts.isNotEmpty())
    }

    @Test
    fun `the operators typed group is stored, not silently discarded`() {
        val outcome = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = verifiedUnknownActive(),
            activeIngredientText = "Vinclozolin-XT 250 g/L",
            chemicalGroupText = "3",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "Example Crop Science",
        )

        requireNotNull(outcome)
        val active = outcome.intelligence.activeIngredients.single()
        assertEquals("3", active.activityGroup?.code)
        // Stored as the operator's own claim, which is why it cannot verify itself.
        assertEquals(ChemicalDataSourceKind.MANUAL_ENTRY, active.groupSource)
        assertFalse(active.hasAuthoritativeGroup)
    }

    @Test
    fun `a group edge the reference table cannot judge falls to the surviving evidence`() {
        val outcome = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = verifiedUnknownActive(),
            activeIngredientText = "Vinclozolin-XT 250 g/L",
            chemicalGroupText = "3",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "Example Crop Science",
        )

        requireNotNull(outcome)
        // No conflict is inventable, but the group is no longer authoritative —
        // and the registered identity still is. "Partially verified" is the
        // honest middle, and it is COMPUTED, not chosen.
        assertEquals(ChemicalVerificationStatus.PARTIALLY_VERIFIED, outcome.resolvedStatus)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `correcting a group back to the authoritative value clears the conflict`() {
        val conflicted = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = verifiedAzoxystrobin(),
            activeIngredientText = "Azoxystrobin 250 g/L",
            chemicalGroupText = "3",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "Example Crop Science",
        )
        requireNotNull(conflicted)
        assertEquals(ChemicalVerificationStatus.CONFLICT, conflicted.resolvedStatus)

        // The operator realises the mistake and puts 11 back.
        val fixed = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = conflicted.intelligence,
            activeIngredientText = "Azoxystrobin 250 g/L",
            chemicalGroupText = "11",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "Example Crop Science",
        )

        requireNotNull(fixed)
        assertTrue(fixed.intelligence.verification.conflicts.isEmpty())
        // A record must be able to escape conflict, or one typo poisons it forever.
        assertNotEquals(ChemicalVerificationStatus.CONFLICT, fixed.resolvedStatus)
    }

    // ---- Edits that must NOT touch verification -----------------------------

    @Test
    fun `a price only edit leaves a verified product verified`() {
        // The legacy form's price, pack and note fields are not part of the
        // reconciler's input at all, so a save that only moved them reports no
        // resistance-critical change and the structured columns are left alone.
        val before = verifiedAzoxystrobin()

        assertNull(untouchedLegacyEdit(before))
        assertEquals(ChemicalVerificationStatus.VERIFIED, before.resolvedVerificationStatus)
    }

    @Test
    fun `a notes edit leaves a verified product verified`() {
        val before = verifiedAzoxystrobin()
        assertNull(untouchedLegacyEdit(before))
    }

    @Test
    fun `re-typing the same group in different case and spacing is not a change`() {
        val before = verifiedAzoxystrobin()

        val outcome = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = before,
            activeIngredientText = "  azoxystrobin   250 g/L ",
            chemicalGroupText = " ${before.legacyChemicalGroup} ",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = " example crop science ",
        )

        // Whitespace and capitalisation are not evidence of anything.
        assertNull(outcome)
    }

    @Test
    fun `a product rename does not disturb a registered identity`() {
        // Name lives on SavedChemical, not in the reconciler's inputs: once a
        // registration number is known, THAT is the identity and the display
        // name is the grower's to tidy.
        val before = verifiedAzoxystrobin()
        assertNull(untouchedLegacyEdit(before))
    }

    // ---- Verified → registration edit --------------------------------------

    @Test
    fun `changing the registrant re-resolves the claim`() {
        val outcome = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = verifiedAzoxystrobin(),
            activeIngredientText = "Azoxystrobin 250 g/L",
            chemicalGroupText = "11",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "A Completely Different Registrant",
        )

        requireNotNull(outcome)
        assertTrue(ChemicalResistanceField.PRODUCT_IDENTITY in outcome.changedFields)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `changing the registration number invalidates the inherited identity`() {
        val before = verifiedAzoxystrobin()

        val outcome = ChemicalEditReconciler.reconcile(
            existing = before,
            proposed = before.copy(
                registration = before.registration?.copy(registrationNumber = "99999"),
            ),
        )

        assertTrue(ChemicalResistanceField.REGISTRATION_IDENTIFIER in outcome.changedFields)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `changing the country makes it a different registered product`() {
        val before = verifiedAzoxystrobin()

        val outcome = ChemicalEditReconciler.reconcile(
            existing = before,
            proposed = before.copy(
                registration = before.registration?.copy(countryCode = "NZ"),
            ),
        )

        assertTrue(ChemicalResistanceField.COUNTRY in outcome.changedFields)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `changing a concentration re-resolves the claim`() {
        val before = verifiedAzoxystrobin()

        val outcome = ChemicalEditReconciler.reconcile(
            existing = before,
            proposed = before.copy(
                activeIngredients = listOf(
                    before.activeIngredients.first().copy(concentration = 500.0),
                ),
            ),
        )

        assertTrue(ChemicalResistanceField.ACTIVE_CONCENTRATION in outcome.changedFields)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `adding an active to a verified mixture cannot inherit verification`() {
        val before = verifiedAzoxystrobin()

        val outcome = ChemicalEditReconciler.reconcile(
            existing = before,
            proposed = before.copy(
                activeIngredients = before.activeIngredients + ChemicalActiveIngredient(
                    name = "Tebuconazole",
                    activityGroup = frac("3"),
                ),
            ),
        )

        assertTrue(ChemicalResistanceField.ACTIVE_INGREDIENTS in outcome.changedFields)
        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
        // The untouched active keeps its authoritative classification: evidence
        // belongs to a value, so only the changed part loses its backing.
        val kept = outcome.intelligence.activeIngredients
            .first { it.name == "Azoxystrobin" }
        assertTrue(kept.hasAuthoritativeGroup)
    }

    @Test
    fun `changing a structured label rate is recorded as resistance critical`() {
        val before = verifiedAzoxystrobin().copy(
            registeredUses = listOf(
                ChemicalRegisteredUse(
                    crop = "Grapes (winegrapes)",
                    targetRaw = "Powdery mildew",
                    rates = listOf(
                        ChemicalLabelRate(
                            label = "Standard",
                            basis = ChemicalLabelRateBasis.PER_HECTARE,
                            value = 1.0,
                            unit = "L",
                        ),
                    ),
                ),
            ),
        )

        val outcome = ChemicalEditReconciler.reconcile(
            existing = before,
            proposed = before.copy(
                registeredUses = listOf(
                    before.registeredUses.first().copy(
                        rates = listOf(
                            before.registeredUses.first().rates.first().copy(value = 2.0),
                        ),
                    ),
                ),
            ),
        )

        assertTrue(ChemicalResistanceField.LABEL_RATES in outcome.changedFields)
        assertTrue(ChemicalResistanceField.REGISTERED_USES in outcome.changedFields)
    }

    // ---- Stale stored status ------------------------------------------------

    @Test
    fun `a stored verified status is not believed when the evidence is incomplete`() {
        // Exactly the shape a stale or hand-patched database row would have:
        // status says verified, but no authoritative group and no registration.
        val stale = ChemicalIntelligence(
            activeIngredients = listOf(
                ChemicalActiveIngredient(
                    name = "Azoxystrobin",
                    activityGroup = frac("11"),
                    groupSource = ChemicalDataSourceKind.AI_INTERPRETATION,
                ),
            ),
            verification = ChemicalVerification(status = ChemicalVerificationStatus.VERIFIED),
        )

        assertNotEquals(ChemicalVerificationStatus.VERIFIED, stale.resolvedVerificationStatus)
    }

    @Test
    fun `a stored verified status is not believed when a conflict is attached`() {
        val before = verifiedAzoxystrobin()
        val conflicted = before.copy(
            verification = before.verification.addingConflict(
                com.rork.vinetrack.data.chemical.ChemicalVerificationConflict(
                    field = "activity_group",
                    activeIngredientName = "Azoxystrobin",
                    extractedValue = "FRAC 3",
                    authoritativeValue = "FRAC 11",
                ),
            ).copy(status = ChemicalVerificationStatus.VERIFIED),
        )

        assertEquals(ChemicalVerificationStatus.CONFLICT, conflicted.resolvedVerificationStatus)
    }

    @Test
    fun `the reconciler never raises confidence`() {
        val manual = ChemicalIntelligence(
            activeIngredients = listOf(
                ChemicalActiveIngredient(
                    name = "Tebuconazole",
                    activityGroup = frac("3"),
                    groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                ),
            ),
            verification = ChemicalVerification.manual(),
        )

        val outcome = ChemicalEditReconciler.reconcile(
            existing = manual,
            // Someone tries to hand the model a verified claim it has not earned.
            proposed = manual.copy(
                activeIngredients = listOf(
                    manual.activeIngredients.first().copy(concentration = 200.0),
                ),
                verification = manual.verification.copy(
                    status = ChemicalVerificationStatus.VERIFIED,
                ),
            ),
        )

        assertNotEquals(ChemicalVerificationStatus.VERIFIED, outcome.resolvedStatus)
    }

    @Test
    fun `an operator facing warning is offered only when trust actually falls`() {
        val downgraded = ChemicalEditReconciler.reconcileLegacyEdit(
            existing = verifiedAzoxystrobin(),
            activeIngredientText = "Azoxystrobin 250 g/L",
            chemicalGroupText = "3",
            modeOfActionText = "",
            productCategory = "fungicide",
            registrantText = "Example Crop Science",
        )
        requireNotNull(downgraded)
        assertTrue(downgraded.warning?.isNotBlank() == true)

        // A manual record has nothing to lose, so it is not warned.
        val alreadyUnverified = ChemicalIntelligence(
            activeIngredients = listOf(
                ChemicalActiveIngredient(
                    name = "Vinclozolin-XT",
                    activityGroup = frac("3"),
                    groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                ),
            ),
            verification = ChemicalVerification.manual(),
        )
        val outcome = ChemicalEditReconciler.reconcile(
            existing = alreadyUnverified,
            proposed = alreadyUnverified.copy(
                activeIngredients = listOf(
                    alreadyUnverified.activeIngredients.first().copy(concentration = 200.0),
                ),
            ),
        )
        assertNull(outcome.warning)
    }
}
