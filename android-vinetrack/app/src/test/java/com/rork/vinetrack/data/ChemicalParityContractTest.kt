package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.chemical.ChemicalVineyardScope
import com.rork.vinetrack.data.chemical.viticultural
import com.rork.vinetrack.data.model.SavedChemical
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The three Chemical Store parity contracts, tested as RULES rather than as
 * screens.
 *
 * Each one exists because the same customer workflow behaved differently on
 * iOS, Android and the Portal:
 *
 * ```text
 * item 2  vineyard-only operational uses   ChemicalVineyardScope
 * item 4  explicit default-rate choice     ChemicalDefaultRateSelection
 * item 5  duplicate decision BEFORE research ChemicalStoreMatching
 * ```
 *
 * They live in the data layer precisely so a test can prove them without
 * driving a bottom sheet — a rule that can only be checked by screenshot is a
 * rule that drifts.
 */
class ChemicalParityContractTest {

    // ---- Fixtures ----

    private fun rate(
        value: Double,
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.PER_100_LITRES,
        unit: String = "L",
        label: String = "",
    ) = ChemicalLabelRate(label = label, basis = basis, value = value, unit = unit)

    private fun use(
        crop: String,
        target: String = "Scale",
        rates: List<ChemicalLabelRate> = listOf(rate(2.0)),
    ) = ChemicalRegisteredUse(crop = crop, targetRaw = target, rates = rates)

    /** A use with no crop and no target: the product-level rate carrier. */
    private fun carrier(rates: List<ChemicalLabelRate> = listOf(rate(3.0))) =
        ChemicalRegisteredUse(crop = "", targetRaw = "", rates = rates)

    private fun intelligence(uses: List<ChemicalRegisteredUse>) = ChemicalIntelligence(
        activeIngredients = listOf(ChemicalActiveIngredient(name = "Paraffinic oil")),
        verification = ChemicalVerification(),
        registeredUses = uses,
        productCategory = "insecticide",
    )

    private fun stored(id: String, name: String) =
        SavedChemical(id = id, vineyardId = "vineyard-1", name = name)

    // =====================================================================
    // Item 2 — vineyard-only operational uses
    // =====================================================================

    @Test
    fun `a multi-crop label keeps only the grapevine directions`() {
        // The real shape of an APVMA label: one product, five crops.
        val label = listOf(
            use("GRAPEVINES", "Powdery mildew"),
            use("MACADAMIAS", "Husk spot"),
            use("CEREALS", "Rust"),
            use("CITRUS", "Scale"),
            use("PASTURE", "Weeds"),
        )
        val operational = ChemicalVineyardScope.operationalUses(label)
        assertEquals(1, operational.size)
        assertEquals("GRAPEVINES", operational.first().crop)
    }

    @Test
    fun `a product-level rate carrier is kept, because it is not another crop`() {
        // No crop and no target means the label quoted one rate for the drum.
        // Dropping it would discard a real registered rate.
        val label = listOf(carrier(), use("GRAPEVINES"), use("MACADAMIAS"))
        val operational = ChemicalVineyardScope.operationalUses(label)
        assertEquals(2, operational.size)
        assertTrue(operational.any { it.crop.isEmpty() })
        assertTrue(operational.any { it.crop == "GRAPEVINES" })
    }

    @Test
    fun `GRAPEFRUIT is a citrus and is never scoped in as a vine`() {
        // The whole-token predicate, checked at the scope boundary as well as
        // in ChemicalGrapevineCrop: a citrus rate on a vineyard record is a
        // wrong dose wearing a plausible name.
        val label = listOf(use("GRAPEFRUIT"), use("Grapevines"))
        val operational = ChemicalVineyardScope.operationalUses(label)
        assertEquals(1, operational.size)
        assertEquals("Grapevines", operational.first().crop)
    }

    @Test
    fun `scoping an intelligence payload narrows uses and touches nothing else`() {
        val whole = intelligence(listOf(use("Grapevines"), use("MACADAMIAS")))
        val scoped = ChemicalVineyardScope.scoped(whole)

        assertEquals(1, scoped.registeredUses.size)
        // Everything that is NOT a crop claim survives byte for byte.
        assertEquals(whole.activeIngredients, scoped.activeIngredients)
        assertEquals(whole.verification, scoped.verification)
        assertEquals(whole.productCategory, scoped.productCategory)
        assertEquals(whole.registration, scoped.registration)
        assertEquals(whole.fieldProvenance, scoped.fieldProvenance)
    }

    @Test
    fun `scoping is idempotent, so a re-save can never compound the filter`() {
        val once = ChemicalVineyardScope.scoped(
            intelligence(listOf(use("Grapevines"), use("CEREALS"))),
        )
        val twice = ChemicalVineyardScope.scoped(once)
        assertEquals(once.registeredUses, twice.registeredUses)
        // A payload that needs no narrowing is returned unchanged.
        assertEquals(once, twice)
    }

    @Test
    fun `an unrelated crop can never become a selectable default rate`() {
        // The operational consequence: item 2's "do not allow unrelated crops
        // to become selectable default rates".
        val scoped = ChemicalVineyardScope.scoped(
            intelligence(
                listOf(
                    use("MACADAMIAS", rates = listOf(rate(9.0))),
                    use("Grapevines", rates = listOf(rate(2.0))),
                ),
            ),
        )
        val plan = ChemicalDefaultRate.plan(scoped.registeredUses.viticultural())
        val values = plan.per100Litres.options.mapNotNull { it.rate.value }
        assertEquals(listOf(2.0), values)
        assertFalse(values.contains(9.0))
    }

    @Test
    fun `the exclusion notice names the crops that were left out`() {
        val notice = ChemicalVineyardScope.exclusionNotice(
            listOf(use("Grapevines"), use("MACADAMIAS"), use("CITRUS")),
        )
        assertNotNull(notice)
        assertTrue(notice!!.contains("MACADAMIAS"))
        assertTrue(notice.contains("CITRUS"))
        // A grapevine-only label produces no notice at all — an empty warning
        // is noise.
        assertNull(ChemicalVineyardScope.exclusionNotice(listOf(use("Grapevines"))))
    }

    // =====================================================================
    // Item 5 — duplicate decision BEFORE research
    // =====================================================================

    @Test
    fun `the same product typed three ways is one product`() {
        assertTrue(
            ChemicalStoreMatching.namesMatch("Kocide Blue Xtra", "KOCIDE BLUE XTRA"),
        )
        assertTrue(
            ChemicalStoreMatching.namesMatch("Kocide-Blue  Xtra", "Kocide Blue Xtra"),
        )
    }

    @Test
    fun `a prefix is NOT a match, because it is a different registration`() {
        // "Kocide Blue" and "Kocide Blue Xtra" are two products with two labels.
        // Offering the stored one would invite the operator to skip the register
        // check for a product they do not own.
        assertFalse(ChemicalStoreMatching.namesMatch("Kocide Blue", "Kocide Blue Xtra"))
    }

    @Test
    fun `a single token is too weak to claim a match`() {
        // "Blue" must not adopt "Blue Shield": this decision only ever offers a
        // choice, and a false positive pushes an operator at the wrong record.
        assertFalse(ChemicalStoreMatching.namesMatch("Blue", "Blue Shield"))
    }

    @Test
    fun `pack sizes are not stripped, because they can be different registrations`() {
        assertFalse(ChemicalStoreMatching.namesMatch("Product 5 L", "Product 20 L"))
    }

    @Test
    fun `an archived chemical is never offered as a duplicate`() {
        // Archiving is a deliberate retirement. Resurrecting the row as a
        // duplicate candidate would undo that decision without asking.
        val chemicals = listOf(stored("1", "Kocide Blue Xtra").copy(isActive = false))
        assertTrue(
            ChemicalStoreMatching.findByProductName(chemicals, "Kocide Blue Xtra").isEmpty(),
        )
    }

    @Test
    fun `only the exactly-named record is offered, not its longer sibling`() {
        val chemicals = listOf(
            stored("1", "Kocide Blue Xtra"),
            stored("2", "Kocide Blue"),
        )
        val found = ChemicalStoreMatching.findByProductName(chemicals, "Kocide Blue")
        assertEquals(1, found.size)
        assertEquals("Kocide Blue", found.first().displayName)
    }

    @Test
    fun `the record being re-matched is never a duplicate of itself`() {
        val chemicals = listOf(stored("1", "Kocide Blue Xtra"))
        val found = ChemicalStoreMatching.findByProductName(
            chemicals,
            "Kocide Blue Xtra",
            excludingId = "1",
        )
        assertTrue(found.isEmpty())
    }

    @Test
    fun `declining the duplicate decision performs no research and no write`() {
        // Required test 8. "No, keep it as it is" must cost exactly nothing:
        // no search, no structured lookup, no insert, no update.
        val keep = ChemicalStoreMatching.Decision.KeepAsIs
        assertFalse(ChemicalStoreMatching.permitsResearch(keep))
        assertFalse(ChemicalStoreMatching.permitsWrite(keep))
    }

    @Test
    fun `accepting the duplicate decision re-verifies and never inserts`() {
        // Required test 9. "Yes, check for updates" carries the STORED record,
        // so re-verification is keyed on the identity the operator already
        // owns rather than on a fresh brand-name search. This add flow issues
        // no lookup of its own and writes nothing at all.
        val existing = stored("1", "Kocide")
        val check = ChemicalStoreMatching.Decision.CheckForUpdates(existing)
        assertEquals(existing.id, check.chemical.id)
        assertFalse(ChemicalStoreMatching.permitsResearch(check))
        assertFalse(ChemicalStoreMatching.permitsWrite(check))
    }

    @Test
    fun `only a deliberate proceed reaches the network`() {
        // There is deliberately no "this is a different product" decision any
        // more: it let a second copy of one chemical be created in a single
        // tap, and a duplicated chemical is a duplicated chemistry.
        assertTrue(ChemicalStoreMatching.permitsResearch(ChemicalStoreMatching.Decision.Proceed))
        assertTrue(ChemicalStoreMatching.permitsWrite(ChemicalStoreMatching.Decision.Proceed))
    }

    @Test
    fun `the duplicate prompt asks about updating, naming the stored product`() {
        val question = ChemicalStoreMatching.sameNameQuestion("Kocide Blue Xtra")
        assertEquals(
            "“Kocide Blue Xtra” is already in your Chemical Store. " +
                "Check whether its information is up to date?",
            question,
        )
        assertEquals("No, keep it as it is", ChemicalStoreMatching.KEEP_AS_IS_ACTION)
        assertEquals("Yes, check for updates", ChemicalStoreMatching.CHECK_FOR_UPDATES_ACTION)
    }

    @Test
    fun `an empty query matches nothing, so a blank box never offers a decision`() {
        val chemicals = listOf(stored("1", "Kocide Blue"))
        assertTrue(ChemicalStoreMatching.findByProductName(chemicals, "   ").isEmpty())
    }

    // =====================================================================
    // Item 4 — explicit grapevine default-rate confirmation
    // =====================================================================

    private fun selectionFor(rates: List<ChemicalLabelRate>): ChemicalDefaultRateSelection =
        ChemicalDefaultRateSelection(
            plan = ChemicalDefaultRate.plan(listOf(use("Grapevines", rates = rates))),
        )

    @Test
    fun `a single exact rate still requires one deliberate tap`() {
        // Required test 1. This REVERSES the previous rule.
        //
        // A lone registered rate used to be adopted automatically on the
        // reasoning that there was nothing to choose between. That is true
        // about the label and false about the vineyard: showing "2 L/ha" and
        // treating the display as consent means the first spray doses off a
        // number nobody read.
        val selection = selectionFor(listOf(rate(2.0)))
        assertTrue(selection.requiresExplicitConfirmation(ChemicalDefaultRateBasis.PER_100_LITRES))
        assertFalse(selection.isConfirmed)
        assertFalse(selection.hasConfirmedDefault)
        // The recommendation is still SHOWN — it simply is not an answer.
        assertNotNull(selection.resolvedOption(ChemicalDefaultRateBasis.PER_100_LITRES))
        assertNull(selection.confirmedOption(ChemicalDefaultRateBasis.PER_100_LITRES))

        // One tap completes it.
        val confirmed = selection.selecting(
            selection.plan.per100Litres.options.first(),
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        assertTrue(confirmed.isConfirmed)
        assertEquals(2.0, confirmed.confirmedDose(ChemicalDefaultRateBasis.PER_100_LITRES))
    }

    @Test
    fun `several registered rates demand a deliberate choice`() {
        val selection = selectionFor(listOf(rate(2.0), rate(3.0)))
        assertTrue(selection.requiresExplicitConfirmation(ChemicalDefaultRateBasis.PER_100_LITRES))
        assertFalse(selection.isConfirmed)
        assertEquals(
            listOf(ChemicalDefaultRateBasis.PER_100_LITRES),
            selection.basesAwaitingConfirmation,
        )
    }

    @Test
    fun `choosing one of several rates satisfies the confirmation`() {
        val selection = selectionFor(listOf(rate(2.0), rate(3.0)))
        val option = selection.plan.per100Litres.options.first()
        val chosen = selection.selecting(option, ChemicalDefaultRateBasis.PER_100_LITRES)
        assertTrue(chosen.isConfirmed)
        assertTrue(chosen.isExplicitlyConfirmed(ChemicalDefaultRateBasis.PER_100_LITRES))
    }

    @Test
    fun `a basis the label states nothing on is never awaiting a choice`() {
        // Demanding a choice between no options would be unanswerable, and the
        // contract forbids manufacturing a rate that does not exist.
        val selection = selectionFor(listOf(rate(2.0)))
        assertTrue(selection.plan.perHectare.isEmpty)
        assertFalse(selection.requiresExplicitConfirmation(ChemicalDefaultRateBasis.PER_HECTARE))

        // Confirming the ONE basis the label does state is enough. A product is
        // never required to hold both a per-hectare and a per-100 L default.
        val confirmed = selection.selecting(
            selection.plan.per100Litres.options.first(),
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        assertTrue(confirmed.isConfirmed)
    }

    @Test
    fun `a product the label registers no grapevine rate on demands no default`() {
        // Nothing to choose from, so there is nothing to confirm — the record
        // is incomplete for reasons the contract already states elsewhere.
        val selection = ChemicalDefaultRateSelection(
            plan = ChemicalDefaultRate.plan(emptyList()),
        )
        assertFalse(selection.offersAnyChoice)
        assertTrue(selection.isConfirmed)
    }

    @Test
    fun `the save contract blocks an unconfirmed multi-rate product`() {
        val selection = selectionFor(listOf(rate(2.0), rate(3.0)))
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "HORTITROL WINTER OIL",
            productCategory = "insecticide",
            intelligence = intelligence(
                listOf(use("Grapevines", rates = listOf(rate(2.0), rate(3.0)))),
            ),
            defaults = selection,
        )
        assertTrue(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_REQUIRED
            },
        )
        assertEquals(
            listOf(ChemicalDefaultRateBasis.PER_100_LITRES),
            evaluation.basesAwaitingConfirmation,
        )
    }

    @Test
    fun `the save contract passes once the operator has chosen`() {
        val rates = listOf(rate(2.0), rate(3.0))
        val selection = selectionFor(rates)
        val chosen = selection.selecting(
            selection.plan.per100Litres.options.first(),
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "HORTITROL WINTER OIL",
            productCategory = "insecticide",
            intelligence = intelligence(listOf(use("Grapevines", rates = rates))),
            defaults = chosen,
        )
        assertFalse(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_REQUIRED
            },
        )
    }

    @Test
    fun `the plain edit path never demands a default-rate choice it did not offer`() {
        // `defaults = null` is the editor, which takes no default-rate
        // decision. It must not start refusing saves for one.
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "HORTITROL WINTER OIL",
            productCategory = "insecticide",
            intelligence = intelligence(
                listOf(use("Grapevines", rates = listOf(rate(2.0), rate(3.0)))),
            ),
        )
        assertFalse(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_REQUIRED
            },
        )
        assertTrue(evaluation.basesAwaitingConfirmation.isEmpty())
    }

    @Test
    fun `a label band still authorises only doses inside its own bounds`() {
        // The confirmation work must not have loosened the authorisation rule.
        val band = ChemicalLabelRate(
            label = "",
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 100.0,
            maxValue = 200.0,
            unit = "mL",
        )
        val selection = selectionFor(listOf(band))
        assertNotNull(selection.settingValue(150.0, ChemicalDefaultRateBasis.PER_100_LITRES))
        assertNull(selection.settingValue(250.0, ChemicalDefaultRateBasis.PER_100_LITRES))
    }
}
