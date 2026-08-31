package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalConflictReconciliation
import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRateGate
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.chemical.ChemicalVerificationStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The screenshot addendum: the rate gate must not be a dead end, and the
 * customer copy must describe what VineTrack did rather than what it stores.
 *
 * The defect these pin down is specific. The review screen refused to save
 * ("Rate not found — enter the rate from the label before saving"), offered no
 * rate control, and disabled Add to Chemical Store — an instruction naming an
 * action the screen did not provide, with no way forward.
 */
class ChemicalRateGateAddendumTest {

    // ---- Fixtures ----------------------------------------------------------

    private fun bandRate(
        min: Double,
        max: Double,
        unit: String = "g",
        rateId: String = "rate_v1_chateau",
    ) = ChemicalLabelRate(
        basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
        minValue = min,
        maxValue = max,
        unit = unit,
        rateId = rateId,
    )

    private fun grapeUse(vararg rates: ChemicalLabelRate) = ChemicalRegisteredUse(
        crop = "GRAPEVINES",
        targetRaw = "Annual weeds",
        rates = rates.toList(),
    )

    /** A use with no rate at all — the CHATEAU-before-deployment situation. */
    private fun ratelessGrapeUse() = ChemicalRegisteredUse(
        crop = "GRAPEVINES",
        targetRaw = "Annual weeds",
        rates = emptyList(),
    )

    private fun selectionFor(uses: List<ChemicalRegisteredUse>) =
        ChemicalDefaultRateSelection(plan = ChemicalDefaultRate.plan(uses))

    private fun source(relative: String): String {
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android-vinetrack/app/$relative"),
        )
        val found = candidates.firstOrNull { it.exists() }
            ?: error("source not found for $relative (cwd=${File(".").absolutePath})")
        return found.readText()
    }

    private fun codeOnly(text: String): String = text
        .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
        .lines()
        .filterNot { it.trimStart().startsWith("//") }
        .joinToString("\n")

    private val matchFlow = "src/main/java/com/rork/vinetrack/ui/screens/ChemicalMatchFlowSheet.kt"
    private val storeScreen = "src/main/java/com/rork/vinetrack/ui/screens/ChemicalsScreen.kt"

    // =========================================================================
    // 1-2  The dead end
    // =========================================================================

    @Test
    fun `1 - missing canonical options offer four corrective actions`() {
        val uses = listOf(rerated())
        val decision = ChemicalRateGate.decide(selectionFor(uses), uses)

        assertEquals(ChemicalRateGate.Decision.NoCanonicalRate, decision)
        assertEquals(
            listOf(
                "Retry label details",
                "Open official label",
                "Enter manually",
                "Change product",
            ),
            ChemicalRateGate.correctiveActions,
        )

        // And the screen genuinely renders that panel on this branch.
        val screen = codeOnly(source(matchFlow))
        assertTrue(screen.contains("NoCanonicalRatePanel("))
        ChemicalRateGate.correctiveActions.forEach { action ->
            assertTrue(
                "the panel must offer $action",
                source(matchFlow).contains(action),
            )
        }
    }

    private fun rerated() = ratelessGrapeUse()

    @Test
    fun `2 - the warning never instructs rate entry without a control`() {
        val uses = listOf(rerated())
        val decision = ChemicalRateGate.decide(selectionFor(uses), uses)

        assertFalse(
            "no rate control exists on this branch, so no instruction to enter one",
            ChemicalRateGate.mayInstructRateEntry(decision),
        )

        // The contract's own message must not name an action the screen lacks.
        val gate = ChemicalSaveContract.evaluate(
            productName = "CHATEAU Herbicide",
            productCategory = "herbicide",
            intelligence = ChemicalIntelligence(
                registeredUses = uses,
                productCategory = "herbicide",
            ),
        )
        val rateViolation = gate.violations.firstOrNull {
            it.code == ChemicalSaveViolationCode.USABLE_RATE_MISSING
        }
        assertNotNull("a rateless label must still block the save", rateViolation)
        assertEquals(ChemicalRateGate.NO_CANONICAL_RATE_MESSAGE, rateViolation!!.message)
        assertFalse(
            "must not tell the operator to enter a rate",
            rateViolation.message.contains("enter the rate", ignoreCase = true),
        )

        // The old dead-end string must be gone from the whole app.
        assertFalse(
            source(matchFlow).contains("Rate not found"),
        )
    }

    @Test
    fun `2b - a registered band is stated read-only and saves`() {
        // The gate must not be vacuously fail-closed: a real label reaches the
        // stated branch, and that branch permits the save.
        val uses = listOf(grapeUse(bandRate(560.0, 700.0)))
        val decision = ChemicalRateGate.decide(selectionFor(uses), uses)
        assertEquals(ChemicalRateGate.Decision.RegisteredRateStated, decision)
        assertTrue(ChemicalRateGate.permitsSave(decision))
        // And it asks for no dose, so it may not instruct one either.
        assertFalse(ChemicalRateGate.mayInstructRateEntry(decision))

        // The screen states the band and says where the dose is chosen.
        val screen = source(matchFlow)
        assertTrue(screen.contains("Registered label range: "))
        assertTrue(
            screen.contains(
                "The registered label rate is saved with this chemical. Choose the exact ",
            ),
        )
        // The old setup-time dose question is gone.
        assertFalse(screen.contains("Your vineyard rate"))
    }

    @Test
    fun `2c - a rateless grapevine label is still refused`() {
        val uses = listOf(ratelessGrapeUse())
        val decision = ChemicalRateGate.decide(selectionFor(uses), uses)
        assertEquals(ChemicalRateGate.Decision.NoCanonicalRate, decision)
        assertFalse(ChemicalRateGate.permitsSave(decision))
    }

    // =========================================================================
    // 3-4  Retry and label actions write nothing and start no search
    // =========================================================================

    @Test
    fun `3 and 4 - retry re-runs enrichment only, and opening the label writes nothing`() {
        val screen = codeOnly(source(matchFlow))

        // Retry re-runs structured enrichment for the ALREADY-SELECTED
        // registration. It must not call runSearch(), which would throw the
        // operator back to a product list they had already worked past.
        assertTrue(
            "retry must re-run enrichment for the selected registration",
            screen.contains("onRetry = { selected?.let { loadStructured(it) } }"),
        )
        val retryBlock = screen.substringAfter("onRetry = {").substringBefore("}")
        assertFalse("retry must not restart the product search", retryBlock.contains("runSearch"))

        // Opening the label is a read: it hands a URL to the system browser.
        assertTrue(
            screen.contains("onOpenLabel = { url -> uriHandler.openUri(url) }"),
        )
        val panel = screen.substringAfter("private fun NoCanonicalRatePanel(")
            .substringBefore("private fun SaveBlockedNotice")
        listOf("createSavedChemical", "updateSavedChemical", "vm.").forEach { write ->
            assertFalse(
                "the corrective panel must perform no write ($write)",
                panel.contains(write),
            )
        }
    }

    // =========================================================================
    // 5-6  Android never mints canonical identities
    // =========================================================================

    @Test
    fun `5 - the manual fallback mints no canonical identity`() {
        // The prefixes only a server may issue.
        assertTrue(ChemicalRateGate.isServerOnlyIdentity("default_option_v1_abc"))
        assertTrue(ChemicalRateGate.isServerOnlyIdentity("rate_v1_abc"))
        assertTrue(ChemicalRateGate.isServerOnlyIdentity("direction_v1_abc"))
        assertFalse(ChemicalRateGate.isServerOnlyIdentity("manual-entry"))
        assertFalse(ChemicalRateGate.isServerOnlyIdentity(null))

        // Android must never CONSTRUCT a rate or direction identity. (The
        // option-key mint is a separate, still-open item — see the report.)
        val mainRoot = listOf(
            File("src/main/java"),
            File("app/src/main/java"),
            File("android-vinetrack/app/src/main/java"),
        ).first { it.isDirectory }
        val minted = mainRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                val text = codeOnly(file.readText())
                text.contains("\"rate_v1_\" +") || text.contains("\"direction_v1_\" +") ||
                    text.contains("\"rate_v1_\$") || text.contains("\"direction_v1_\$")
            }
            .map { it.name }
            .toList()
        assertEquals(
            "Android must not construct rate or direction identities: $minted",
            emptyList<String>(),
            minted,
        )
    }

    @Test
    fun `6 - a rateless label keeps the structured save blocked`() {
        val uses = listOf(rerated())
        val gate = ChemicalSaveContract.evaluate(
            productName = "CHATEAU Herbicide",
            productCategory = "herbicide",
            intelligence = ChemicalIntelligence(
                registeredUses = uses,
                productCategory = "herbicide",
            ),
            defaults = selectionFor(uses),
        )
        assertTrue(
            "no canonical option means no label-checked save",
            gate.violations.any { it.code == ChemicalSaveViolationCode.USABLE_RATE_MISSING },
        )
    }

    // =========================================================================
    // 7-8  CHATEAU's 560-700 band
    // =========================================================================

    @Test
    fun `7 and 8 - a CHATEAU dose is valid inside 560-700 and invalid outside`() {
        val uses = listOf(grapeUse(bandRate(560.0, 700.0)))
        val basis = ChemicalDefaultRateBasis.PER_HECTARE
        val option = selectionFor(uses).plan.group(basis).options.first()
        val chosen = selectionFor(uses).selecting(option, basis)

        // Inside the band, inclusive at both ends.
        listOf(560.0, 600.0, 650.0, 700.0).forEach { dose ->
            assertNotNull("$dose g/ha is registered", chosen.settingValue(dose, basis))
        }
        // Outside it, in either direction.
        listOf(559.9, 400.0, 700.1, 900.0).forEach { dose ->
            assertNull("$dose g/ha is not registered", chosen.settingValue(dose, basis))
        }

        // A confirmed in-band dose satisfies the contract.
        val confirmed = chosen.settingValue(620.0, basis)!!
        assertTrue(confirmed.hasConfirmedDefault)
        assertTrue(confirmed.basesAwaitingExactDose.isEmpty())
    }

    // =========================================================================
    // 9-11  Customer copy
    // =========================================================================

    @Test
    fun `9 - technical compatibility copy is absent from the customer screen`() {
        val screen = codeOnly(source(matchFlow))
        listOf(
            "The structured record is saved in full",
            "kept in step with it for",
        ).forEach { phrase ->
            assertFalse(
                "implementation detail must not be customer copy: $phrase",
                screen.contains(phrase),
            )
        }
    }

    @Test
    fun `10 and 11 - store filters and banner use the operator's language`() {
        val ui = source("src/main/java/com/rork/vinetrack/ui/components/ChemicalIntelligenceUi.kt")
        listOf(
            "\"Label checked\"",
            "\"Details unavailable\"",
            "\"Not checked\"",
            "\"Review required\"",
        ).forEach { assertTrue("filter wording missing: $it", ui.contains(it)) }
        assertFalse(
            "\"Partially verified\" must not reach a customer filter",
            codeOnly(ui).contains("Partially verified"),
        )

        val store = codeOnly(source(storeScreen))
        assertTrue(store.contains("chemicals need attention"))
        assertTrue(store.contains("1 chemical needs attention"))
        assertFalse(store.contains("chemicals need verification"))

        // Status wording itself, at the source of truth.
        assertEquals("Official label checked", ChemicalVerificationStatus.VERIFIED.label)
        assertEquals(
            "Label checked — details unavailable",
            ChemicalVerificationStatus.PARTIALLY_VERIFIED.label,
        )
        assertEquals("Not checked", ChemicalVerificationStatus.UNVERIFIED.label)
        assertEquals("Not checked", ChemicalVerificationStatus.NEEDS_MATCH.label)
        assertEquals("Review required", ChemicalVerificationStatus.CONFLICT.label)
        assertEquals(
            "VineTrack checked official product information, but some label details " +
                "were unavailable.",
            ChemicalVerificationStatus.PARTIALLY_VERIFIED.detail,
        )
    }

    // =========================================================================
    // 12  The false HRAC conflict
    // =========================================================================

    private fun groupConflict(extracted: String, authoritative: String) =
        ChemicalVerificationConflict(
            field = "activity_group",
            activeIngredientName = "Flumioxazin",
            extractedValue = extracted,
            authoritativeValue = authoritative,
        )

    @Test
    fun `12 - flumioxazin 14 against legacy E is not a conflict`() {
        // The exact pairing from the screenshot.
        assertTrue(ChemicalConflictReconciliation.isSpurious(groupConflict("HRAC 14", "HRAC E")))
        // The Australian legacy letter too, and in the other order.
        assertTrue(ChemicalConflictReconciliation.isSpurious(groupConflict("HRAC 14", "HRAC G")))
        assertTrue(ChemicalConflictReconciliation.isSpurious(groupConflict("HRAC E", "HRAC 14")))
        // Identical codes are trivially not a disagreement.
        assertTrue(ChemicalConflictReconciliation.isSpurious(groupConflict("HRAC 14", "HRAC 14")))

        // A GENUINE disagreement survives, which is what the check is for.
        assertFalse(ChemicalConflictReconciliation.isSpurious(groupConflict("HRAC 2", "HRAC 14")))
        // A conflict naming no active can never be shown to be spurious.
        assertFalse(
            ChemicalConflictReconciliation.isSpurious(
                ChemicalVerificationConflict(
                    field = "activity_group",
                    extractedValue = "HRAC 14",
                    authoritativeValue = "HRAC E",
                ),
            ),
        )
        // A different field is out of scope entirely.
        assertFalse(
            ChemicalConflictReconciliation.isSpurious(
                ChemicalVerificationConflict(
                    field = "concentration",
                    activeIngredientName = "Flumioxazin",
                    extractedValue = "500",
                    authoritativeValue = "480",
                ),
            ),
        )
    }

    @Test
    fun `12b - a record whose only conflict is legacy wording is not Review required`() {
        val actives = listOf(
            ChemicalActiveIngredient(
                name = "Flumioxazin",
                activityGroup = ChemicalActivityGroup.of(ChemicalActivityGroupScheme.HRAC, "14"),
            ),
        )
        val spurious = ChemicalVerification(
            status = ChemicalVerificationStatus.VERIFIED,
            conflicts = listOf(groupConflict("HRAC 14", "HRAC E")),
        )
        assertTrue(ChemicalConflictReconciliation.allSpurious(spurious.conflicts))
        assertTrue(ChemicalConflictReconciliation.customerVisible(spurious.conflicts).isEmpty())
        assertFalse(
            "a legacy-code artefact must not force Review required",
            spurious.resolvedStatus(actives, hasRegistration = true) ==
                ChemicalVerificationStatus.CONFLICT,
        )

        // A real disagreement still resolves to conflict.
        val genuine = ChemicalVerification(
            status = ChemicalVerificationStatus.VERIFIED,
            conflicts = listOf(groupConflict("HRAC 2", "HRAC 14")),
        )
        assertEquals(
            ChemicalVerificationStatus.CONFLICT,
            genuine.resolvedStatus(actives, hasRegistration = true),
        )
    }
}
