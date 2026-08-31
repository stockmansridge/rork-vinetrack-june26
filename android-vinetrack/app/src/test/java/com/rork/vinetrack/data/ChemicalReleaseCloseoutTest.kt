package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateDisplay
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateSelection
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalServerDefaultRateOption
import com.rork.vinetrack.data.chemical.ChemicalServerDefaultRateOptions
import com.rork.vinetrack.data.chemical.ChemicalSprayDefaultHandoff
import com.rork.vinetrack.data.chemical.ChemicalStoreMatching
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.chemical.clearedDefaultRates
import com.rork.vinetrack.data.chemical.staleBases
import com.rork.vinetrack.data.chemical.storedDefaultRates
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android chemical search/management release contract.
 *
 * Every rule here exists because breaking it puts a wrong number in a spray
 * tank or a wrong product in the Chemical Store. They are asserted against the
 * pure data layer rather than against Compose, so the contract is provable
 * rather than inferred from a screenshot.
 */
class ChemicalReleaseCloseoutTest {

    // ---- Fixtures ----------------------------------------------------------

    private fun exactRate(
        value: Double,
        unit: String = "L",
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.PER_HECTARE,
        rateId: String? = "rate_v1_a",
        label: String = "",
    ) = ChemicalLabelRate(
        label = label,
        basis = basis,
        value = value,
        unit = unit,
        rateId = rateId,
    )

    private fun bandRate(
        min: Double,
        max: Double,
        unit: String = "g",
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
        rateId: String? = "rate_v1_band",
    ) = ChemicalLabelRate(
        basis = basis,
        minValue = min,
        maxValue = max,
        unit = unit,
        rateId = rateId,
    )

    private fun grapeUse(vararg rates: ChemicalLabelRate) = ChemicalRegisteredUse(
        crop = "GRAPEVINES",
        targetRaw = "Powdery mildew",
        rates = rates.toList(),
    )

    private fun selectionFor(uses: List<ChemicalRegisteredUse>) =
        ChemicalDefaultRateSelection(plan = ChemicalDefaultRate.plan(uses))

    /**
     * A selection built from the SERVER's canonical options.
     *
     * Required by any test that PERSISTS: a default now carries the register's
     * own `option_key` and `rate_ids`, and an option the device assembled from
     * `registered_uses` is deliberately refused at the storage boundary.
     */
    private fun serverSelectionFor(
        options: ChemicalServerDefaultRateOptions,
    ) = ChemicalDefaultRateSelection(plan = ChemicalDefaultRate.plan(options))

    /** The CHATEAU band, 560–700 g/ha, as the server sends it. */
    private fun bandServerOptions(
        rateIds: List<String> = listOf("rate_v1_band"),
    ) = ChemicalServerDefaultRateOptions(
        perHectare = listOf(
            ChemicalServerDefaultRateOption(
                optionKey = "default_option_v1_band",
                rateIds = rateIds,
                basis = "per_hectare",
                unit = "g",
                minValue = 560.0,
                maxValue = 700.0,
            ),
        ),
    )

    private fun intelligenceFor(uses: List<ChemicalRegisteredUse>) = ChemicalIntelligence(
        registeredUses = uses,
        productCategory = "fungicide",
    )

    private fun chemical(
        id: String = "chem-1",
        name: String = "Example Fungicide",
        unit: String = "Litres",
        rates: List<ChemicalRate> = emptyList(),
        ratePerHa: Double = 0.0,
        defaultRates: StoredChemicalDefaultRates? = null,
        registeredUses: List<ChemicalRegisteredUse>? = null,
        purchase: ChemicalPurchase? = null,
    ) = SavedChemical(
        id = id,
        vineyardId = "vineyard-1",
        name = name,
        unit = unit,
        rates = rates,
        ratePerHa = ratePerHa,
        defaultRates = defaultRates,
        registeredUses = registeredUses,
        purchase = purchase,
    )

    private fun storedSlot(
        value: Double?,
        unit: String,
        basis: ChemicalDefaultRateBasis,
        rateIds: List<String> = listOf("rate_v1_a"),
        minValue: Double? = null,
        maxValue: Double? = null,
    ) = StoredChemicalDefaultRate(
        optionKey = "default_option_v1_test",
        rateIds = rateIds,
        basis = basis.raw,
        unit = unit,
        value = value,
        minValue = minValue,
        maxValue = maxValue,
    )

    // =========================================================================
    // 1-7  First-add confirmation
    // =========================================================================

    @Test
    fun `1 - a single exact registered rate saves without an operator tap`() {
        val uses = listOf(grapeUse(exactRate(2.0)))
        val selection = selectionFor(uses)

        // Nothing confirmed, and nothing needs to be: the label prints the
        // rate, and that is what the Chemical Store is recording.
        assertFalse(selection.hasConfirmedDefault)
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(uses),
            defaults = selection,
        )
        assertTrue(
            "a registered rate is enough to save",
            ChemicalSaveContract.blockingViolations(evaluation, emptySet()).isEmpty(),
        )
        // And an unconfirmed recommendation is still never persisted as one.
        assertNull(selection.storedDefaultRates(uses))
    }

    @Test
    fun `2 - multiple rates require a selection`() {
        val uses = listOf(
            grapeUse(
                exactRate(2.0, rateId = "rate_v1_a"),
                exactRate(3.0, rateId = "rate_v1_b"),
            ),
        )
        val selection = selectionFor(uses)
        assertEquals(2, selection.plan.perHectare.options.size)
        assertFalse(selection.hasConfirmedDefault)
        // No recommendation is adopted on the operator's behalf.
        assertNull(selection.confirmedOption(ChemicalDefaultRateBasis.PER_HECTARE))
    }

    @Test
    fun `3 - a registered range saves as a range, and no dose is invented`() {
        val uses = listOf(grapeUse(bandRate(560.0, 700.0)))
        val selection = selectionFor(uses)

        // 560-700 g/ha is a complete record of the registration. The exact
        // applied dose is a spray decision, so nothing is demanded here.
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(uses),
            defaults = selection,
        )
        assertTrue(
            "a registered range is enough to save",
            ChemicalSaveContract.blockingViolations(evaluation, emptySet()).isEmpty(),
        )

        // Choosing the band alone still names no dose and stores none.
        val chosen = selection.selecting(
            selection.plan.perHectare.options.first(),
            ChemicalDefaultRateBasis.PER_HECTARE,
        )
        assertNull(chosen.confirmedDose(ChemicalDefaultRateBasis.PER_HECTARE))
        assertNull(chosen.storedDefaultRates(uses))

        // The authorisation rule is untouched: a dose outside the band is
        // refused outright, and an in-range one completes an OPTIONAL default.
        assertNull(chosen.settingValue(900.0, ChemicalDefaultRateBasis.PER_HECTARE))
        val dosed = chosen.settingValue(600.0, ChemicalDefaultRateBasis.PER_HECTARE)
        assertNotNull(dosed)
        assertEquals(600.0, dosed!!.confirmedDose(ChemicalDefaultRateBasis.PER_HECTARE))
        assertTrue(dosed.isConfirmed)

        // And the registered band itself is never narrowed by any of it.
        val band = uses.flatMap { it.rates }.first()
        assertEquals(560.0, band.minValue)
        assertEquals(700.0, band.maxValue)
    }

    @Test
    fun `4 - a blank range never falls back to its minimum`() {
        // There is no minimum, maximum or midpoint fallback anywhere.
        val uses = listOf(grapeUse(bandRate(560.0, 700.0)))
        val chosen = selectionFor(uses).let {
            it.selecting(it.plan.perHectare.options.first(), ChemicalDefaultRateBasis.PER_HECTARE)
        }
        assertNull(chosen.confirmedDose(ChemicalDefaultRateBasis.PER_HECTARE))
        assertNull(chosen.storedDefaultRates(uses))

        // Clearing a typed dose returns to unfinished, not to 560.
        val dosed = chosen.settingValue(600.0, ChemicalDefaultRateBasis.PER_HECTARE)!!
        val cleared = dosed.clearingValue(ChemicalDefaultRateBasis.PER_HECTARE)
        assertNull(cleared.confirmedDose(ChemicalDefaultRateBasis.PER_HECTARE))
    }

    @Test
    fun `5 - a confirmed range persists as a scalar with both bounds null`() {
        // Shared shape D3: a persisted amount is a scalar OR a range, never
        // both. Storing 600 alongside 560-700 reads as an amount that is
        // simultaneously "exactly 600" and "anywhere in 560-700".
        val uses = listOf(grapeUse(bandRate(560.0, 700.0)))
        val dosed = serverSelectionFor(bandServerOptions()).let {
            it.selecting(it.plan.perHectare.options.first(), ChemicalDefaultRateBasis.PER_HECTARE)
        }.settingValue(600.0, ChemicalDefaultRateBasis.PER_HECTARE)!!

        val stored = dosed.storedDefaultRates(uses)
        assertNotNull(stored)
        val slot = stored!!.slot(ChemicalDefaultRateBasis.PER_HECTARE)
        assertNotNull(slot)
        assertEquals(600.0, slot!!.value)
        assertNull(slot.minValue)
        assertNull(slot.maxValue)
        // The label's own unit, and the supporting server-minted identity.
        assertEquals("g", slot.unit)
        assertEquals(listOf("rate_v1_band"), slot.rateIds)
        assertEquals(StoredChemicalDefaultRate.SOURCE_OPERATOR, slot.source)
    }

    @Test
    fun `6 - an unconfirmed recommendation produces no stored default`() {
        val uses = listOf(grapeUse(exactRate(2.0)))
        val selection = selectionFor(uses)
        // The recommendation is visible...
        assertNotNull(selection.resolvedOption(ChemicalDefaultRateBasis.PER_HECTARE))
        // ...and is still not a decision, so nothing is persisted.
        assertNull(selection.storedDefaultRates(uses))
    }

    @Test
    fun `7 - a new lookup without a confirmed default can save`() {
        val uses = listOf(grapeUse(exactRate(2.0)))
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(uses),
            defaults = selectionFor(uses),
        )
        // A brand-new chemical has an EMPTY baseline, so nothing is excused
        // here — this is the real gate, and a registered rate opens it.
        val blocking = ChemicalSaveContract.blockingViolations(evaluation, emptySet())
        assertTrue(blocking.isEmpty())
    }

    @Test
    fun `7c - a grapevine label with no usable rate still cannot save`() {
        // The fail-closed path this change must leave exactly as it was.
        val uses = listOf(ChemicalRegisteredUse(crop = "Grapevines", targetRaw = "Downy mildew"))
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(uses),
            defaults = selectionFor(uses),
        )
        val blocking = ChemicalSaveContract.blockingViolations(evaluation, emptySet())
        assertTrue(
            blocking.any { it.code == ChemicalSaveViolationCode.USABLE_RATE_MISSING },
        )
    }

    @Test
    fun `7b - only one basis is required, never both`() {
        // Plenty of vineyards dose per hectare and never per 100 L.
        val uses = listOf(
            grapeUse(
                exactRate(2.0, basis = ChemicalLabelRateBasis.PER_HECTARE, rateId = "rate_v1_ha"),
                exactRate(
                    150.0,
                    unit = "g",
                    basis = ChemicalLabelRateBasis.PER_100_LITRES,
                    rateId = "rate_v1_100l",
                ),
            ),
        )
        val confirmed = selectionFor(uses).let {
            it.selecting(it.plan.perHectare.options.first(), ChemicalDefaultRateBasis.PER_HECTARE)
        }
        assertTrue(confirmed.isConfirmed)
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(uses),
            defaults = confirmed,
        )
        assertFalse(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_REQUIRED
            },
        )
    }

    // =========================================================================
    // 8-9  Duplicate decision
    // =========================================================================

    @Test
    fun `8 - declining a duplicate performs zero research and zero writes`() {
        val decision = ChemicalStoreMatching.Decision.KeepAsIs
        assertFalse(ChemicalStoreMatching.permitsResearch(decision))
        assertFalse(ChemicalStoreMatching.permitsWrite(decision))
    }

    @Test
    fun `9 - accepting a duplicate re-verifies the stored id and never inserts`() {
        val stored = chemical(id = "stored-1", name = "Kocide Blue Xtra")
        val decision = ChemicalStoreMatching.Decision.CheckForUpdates(stored)
        // Carries the STORED record, so the re-check is keyed on the identity
        // the operator already owns rather than on a fresh brand-name search.
        assertEquals("stored-1", decision.chemical.id)
        assertFalse(ChemicalStoreMatching.permitsWrite(decision))
        assertFalse(ChemicalStoreMatching.permitsResearch(decision))
    }

    @Test
    fun `9b - an archived same-name product is never offered as a duplicate`() {
        val archived = chemical(id = "old", name = "Kocide Blue Xtra").copy(isActive = false)
        val found = ChemicalStoreMatching.findByProductName(listOf(archived), "Kocide Blue Xtra")
        assertTrue(found.isEmpty())
    }

    // =========================================================================
    // 14-15  Stale default identities
    // =========================================================================

    @Test
    fun `14 - a vanished rate id makes the default stale`() {
        val defaults = StoredChemicalDefaultRates(
            perHectare = storedSlot(
                value = 2.0,
                unit = "L",
                basis = ChemicalDefaultRateBasis.PER_HECTARE,
                rateIds = listOf("rate_v1_gone"),
            ),
        )
        // The refreshed label carries a DIFFERENT registered identity.
        val refreshed = listOf(grapeUse(exactRate(2.0, rateId = "rate_v1_new")))
        assertEquals(
            listOf(ChemicalDefaultRateBasis.PER_HECTARE),
            defaults.staleBases(refreshed),
        )

        // And the contract refuses the save until it is resolved.
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example",
            productCategory = "fungicide",
            intelligence = intelligenceFor(refreshed),
            staleDefaultBases = defaults.staleBases(refreshed),
        )
        assertTrue(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_STALE
            },
        )
        assertTrue(
            evaluation.violations.any { it.message.contains("Confirm a rate again") },
        )
    }

    @Test
    fun `15 - a stale default is never silently repointed`() {
        // The new label prints the SAME number under a NEW identity. Matching
        // by value or by array position would silently adopt it, moving a
        // compliance fact without telling anybody.
        val defaults = StoredChemicalDefaultRates(
            perHectare = storedSlot(
                value = 2.0,
                unit = "L",
                basis = ChemicalDefaultRateBasis.PER_HECTARE,
                rateIds = listOf("rate_v1_old"),
            ),
        )
        val refreshed = listOf(grapeUse(exactRate(2.0, rateId = "rate_v1_replacement")))
        assertTrue(defaults.staleBases(refreshed).isNotEmpty())
        // The slot is untouched: nothing rewrote it to the replacement id.
        assertEquals(
            listOf("rate_v1_old"),
            defaults.slot(ChemicalDefaultRateBasis.PER_HECTARE)?.rateIds,
        )
    }

    @Test
    fun `15b - a default whose every cited identity survives is not stale`() {
        val defaults = StoredChemicalDefaultRates(
            perHectare = storedSlot(
                value = 2.0,
                unit = "L",
                basis = ChemicalDefaultRateBasis.PER_HECTARE,
                rateIds = listOf("rate_v1_a"),
            ),
        )
        assertTrue(defaults.staleBases(listOf(grapeUse(exactRate(2.0)))).isEmpty())
    }

    @Test
    fun `15c - clearing writes an explicit empty v1 contract, not an omitted null`() {
        // A JSON null would be dropped by `explicitNulls = false`, so the old
        // default would survive the very act of clearing it.
        val cleared = clearedDefaultRates()
        assertTrue(cleared.isEmpty)
        val encoded = Json { explicitNulls = false }
            .encodeToString(StoredChemicalDefaultRates.serializer(), cleared)
        assertTrue(encoded.contains("\"version\":1"))
    }

    // =========================================================================
    // 16  Chemical Store display
    // =========================================================================

    @Test
    fun `16 - the store list reads default_rates, not the legacy rate fields`() {
        val confirmed = chemical(
            unit = "Kg",
            // Legacy columns deliberately disagree with the confirmed default.
            ratePerHa = 999.0,
            rates = listOf(ChemicalRate(id = "r1", label = "Per Ha", value = 999.0, basis = "per_hectare")),
            registeredUses = listOf(grapeUse(exactRate(560.0, unit = "g"))),
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(560.0, "g", ChemicalDefaultRateBasis.PER_HECTARE),
            ),
        )
        // The confirmed default wins, in the slot's OWN unit.
        assertEquals("560 g/ha", ChemicalDefaultRateDisplay.line(confirmed))
        assertFalse(ChemicalDefaultRateDisplay.needsConfirmation(confirmed))
    }

    @Test
    fun `16b - no confirmed default falls back to the registered label rate`() {
        val unconfirmed = chemical(
            ratePerHa = 2.0,
            rates = listOf(ChemicalRate(id = "r1", label = "Per Ha", value = 2000.0, basis = "per_hectare")),
            registeredUses = listOf(grapeUse(exactRate(2.0))),
        )
        // A usable registered grapevine rate is a complete record of what the
        // label permits — the same rule that admitted the save — so the card
        // states the LABEL's figure, clearly named as such, instead of
        // demanding a confirmation for a record with nothing wrong with it.
        // Still never the legacy `rates` row or `rate_per_ha` (which here
        // disagree, at 2000 and 2), and nothing is written to default_rates.
        assertEquals(
            "Registered label rate: 2 L/ha",
            ChemicalDefaultRateDisplay.line(unconfirmed),
        )
        assertFalse(ChemicalDefaultRateDisplay.needsConfirmation(unconfirmed))
    }

    @Test
    fun `16b2 - structured with NO usable registered rate still says so`() {
        // The genuinely unfinished case keeps its prompt: registered uses
        // exist but none carries a rate a calculation could use.
        val unconfirmed = chemical(registeredUses = listOf(grapeUse()))
        assertEquals(
            ChemicalDefaultRateDisplay.CONFIRMATION_REQUIRED,
            ChemicalDefaultRateDisplay.line(unconfirmed),
        )
        assertTrue(ChemicalDefaultRateDisplay.needsConfirmation(unconfirmed))
    }

    @Test
    fun `16c - both confirmed bases render together`() {
        val both = chemical(
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(2.0, "L", ChemicalDefaultRateBasis.PER_HECTARE),
                per100Litres = storedSlot(150.0, "g", ChemicalDefaultRateBasis.PER_100_LITRES),
            ),
        )
        assertEquals("2 L/ha · 150 g/100 L", ChemicalDefaultRateDisplay.line(both))
    }

    @Test
    fun `16d - a legacy manual chemical keeps its own line`() {
        val legacy = chemical(ratePerHa = 2.0)
        // Null means "the caller keeps the legacy line" — never the
        // confirmation prompt, because nothing about an old record is
        // unfinished; it simply predates the structured contract.
        assertNull(ChemicalDefaultRateDisplay.line(legacy))
        assertFalse(ChemicalDefaultRateDisplay.isStructured(legacy))
    }

    // =========================================================================
    // 17-24  Spray handoff
    // =========================================================================

    @Test
    fun `17 - a confirmed 2 L per ha default prefills 2 L per ha`() {
        val chem = chemical(
            unit = "Litres",
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(2.0, "L", ChemicalDefaultRateBasis.PER_HECTARE),
            ),
        )
        val prefill = ChemicalSprayDefaultHandoff.prefillFor(chem)
        assertNotNull(prefill)
        assertEquals(2.0, prefill!!.rate, 0.0001)
        assertEquals("L", prefill.unit)
        assertEquals(SprayCalculator.RateBasis.PER_HECTARE, prefill.basis)
    }

    @Test
    fun `18 - a confirmed 560 g per ha default on a Kg product prefills 560 g per ha`() {
        // The exact bug this contract exists to prevent: reading the INVENTORY
        // unit beside the rate printed "560 Kg/ha" — a thousandfold error.
        val chem = chemical(
            unit = "Kg",
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(560.0, "g", ChemicalDefaultRateBasis.PER_HECTARE),
            ),
        )
        val prefill = ChemicalSprayDefaultHandoff.prefillFor(chem)
        assertNotNull(prefill)
        assertEquals(560.0, prefill!!.rate, 0.0001)
        assertEquals("g", prefill.unit)
        // The amount is NEVER converted into the inventory unit.
        assertEquals(SprayCalculator.RateBasis.PER_HECTARE, prefill.basis)
    }

    @Test
    fun `19 - a stored range with no scalar dose produces no prefill`() {
        val chem = chemical(
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(
                    value = null,
                    unit = "g",
                    basis = ChemicalDefaultRateBasis.PER_HECTARE,
                    minValue = 560.0,
                    maxValue = 700.0,
                ),
            ),
        )
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(chem))
    }

    @Test
    fun `20 - two confirmed bases produce no automatic prefill`() {
        // Which basis to dose by is an operating decision, not a default.
        val chem = chemical(
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(2.0, "L", ChemicalDefaultRateBasis.PER_HECTARE),
                per100Litres = storedSlot(150.0, "g", ChemicalDefaultRateBasis.PER_100_LITRES),
            ),
        )
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(chem))
    }

    @Test
    fun `20b - a missing or malformed contract produces no prefill`() {
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(chemical()))
        // Unsupported unit: nothing can safely cost or display it.
        val odd = chemical(
            defaultRates = StoredChemicalDefaultRates(
                perHectare = storedSlot(2.0, "sachets", ChemicalDefaultRateBasis.PER_HECTARE),
            ),
        )
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(odd))
    }

    @Test
    fun `20c - unit spelling is normalised but never converted`() {
        assertEquals("L", ChemicalSprayDefaultHandoff.canonicalUnit("Litres"))
        assertEquals("mL", ChemicalSprayDefaultHandoff.canonicalUnit("ML"))
        assertEquals("kg", ChemicalSprayDefaultHandoff.canonicalUnit("Kg"))
        assertEquals("g", ChemicalSprayDefaultHandoff.canonicalUnit(" grams "))
        assertNull(ChemicalSprayDefaultHandoff.canonicalUnit("sachets"))
    }

    @Test
    fun `22 and 23 - a structured chemical never falls back to legacy rate fields`() {
        // `rates.first()` is an ordering accident and `rate_per_ha` has no link
        // back to a registered direction. Neither may reach a spray line.
        val structured = chemical(
            unit = "Kg",
            ratePerHa = 999.0,
            rates = listOf(
                ChemicalRate(id = "r1", label = "Per Ha", value = 999.0, basis = "per_hectare"),
            ),
            registeredUses = listOf(grapeUse(exactRate(560.0, unit = "g"))),
        )
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(structured))
        assertFalse(ChemicalSprayDefaultHandoff.isLegacyRateRecord(structured))
    }

    @Test
    fun `23b - a structured product is not legacy merely because its default is empty`() {
        val structuredNoDefault = chemical(
            registeredUses = listOf(grapeUse(exactRate(2.0))),
        )
        assertFalse(ChemicalSprayDefaultHandoff.isLegacyRateRecord(structuredNoDefault))
    }

    @Test
    fun `24 - a legacy manual chemical remains usable`() {
        val legacy = chemical(
            unit = "Litres",
            ratePerHa = 2.0,
            rates = listOf(
                ChemicalRate(id = "r1", label = "Per Ha", value = 2000.0, basis = "per_hectare"),
            ),
        )
        assertTrue(ChemicalSprayDefaultHandoff.isLegacyRateRecord(legacy))
    }

    // ---- Cost conversion ----------------------------------------------------

    @Test
    fun `cost converts exactly between units of one family`() {
        // $20/kg is $0.02/g. Multiplying a gram amount by a per-kilogram price
        // would overstate the job cost a thousandfold.
        val chem = chemical(
            unit = "Kg",
            purchase = ChemicalPurchase(costDollars = 20.0, containerSizeML = 1.0, containerUnit = "Kg"),
        )
        assertEquals(20.0, chem.costPerUnit!!, 0.0001)
        assertEquals(0.02, ChemicalSprayDefaultHandoff.costPerRateUnit(chem, "g")!!, 0.000001)
        assertEquals(20.0, ChemicalSprayDefaultHandoff.costPerRateUnit(chem, "Kg")!!, 0.0001)
    }

    @Test
    fun `cost is null rather than invented across incompatible units`() {
        val chem = chemical(
            unit = "Kg",
            purchase = ChemicalPurchase(costDollars = 20.0, containerSizeML = 1.0, containerUnit = "Kg"),
        )
        // Solid priced product, liquid rate unit: no defensible conversion.
        assertNull(ChemicalSprayDefaultHandoff.costPerRateUnit(chem, "L"))
        assertNull(ChemicalSprayDefaultHandoff.costPerRateUnit(chem, "sachets"))
    }

    // =========================================================================
    // 28  Database write contract
    // =========================================================================

    @Test
    fun `28 - sql-215 fields are absent from the saved-chemical write DTO`() {
        // sql/215 is NOT applied. Naming those columns in a database DTO makes
        // PostgREST reject the WHOLE write, and it did so precisely when the
        // resolver had found a manufacturer document - the good-data case.
        //
        // Asserted against the serial descriptor rather than an encoded sample:
        // a field whose value happens to equal its default is omitted from the
        // output anyway, so encoding would pass this test even if the column
        // were re-added.
        val descriptor = SavedChemical.serializer().descriptor
        val names = (0 until descriptor.elementsCount).map { descriptor.getElementName(it) }

        assertFalse(names.contains("manufacturer_label_url"))
        assertFalse(names.contains("manufacturer_product_url"))
        assertFalse(names.contains("regulator_label_url"))

        // The surviving canonical link fields carry all three concepts:
        // regulator label, manufacturer page, and (via verification_sources)
        // the manufacturer's own label document.
        assertTrue(names.contains("label_reference"))
        assertTrue(names.contains("product_url"))
        assertTrue(names.contains("verification_sources"))
        assertTrue(names.contains("default_rates"))
    }
}
