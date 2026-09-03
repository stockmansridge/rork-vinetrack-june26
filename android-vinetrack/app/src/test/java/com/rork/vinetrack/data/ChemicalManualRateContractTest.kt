package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalApplicationRateOutcome
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateValidity
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.chemical.ChemicalSprayDefaultHandoff
import com.rork.vinetrack.data.chemical.ChemicalSprayRateResolution
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The user-confirmed manual rate contract.
 *
 * A rate the operator typed because the label reader could not extract one is
 * real VineTrack data once they confirm it. It must be usable in Spray Program
 * WITHOUT acquiring a fabricated official identity, and must stay permanently
 * distinguishable from a registered label direction.
 *
 * The mirror of iOS `ChemicalManualRateContractTests`.
 */
class ChemicalManualRateContractTest {

    /** The SHARED client's configuration, mirrored exactly. */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }

    // ---- Fixtures ----------------------------------------------------------

    private fun canonicalSlot(
        value: Double? = null,
        minValue: Double? = null,
        maxValue: Double? = null,
        unit: String = "L",
        basis: ChemicalDefaultRateBasis = ChemicalDefaultRateBasis.PER_HECTARE,
    ) = StoredChemicalDefaultRate(
        optionKey = "default_option_v1_abc",
        rateIds = listOf("rate_v1_a"),
        basis = basis.raw,
        unit = unit,
        value = value,
        minValue = minValue,
        maxValue = maxValue,
        source = StoredChemicalDefaultRate.SOURCE_OPERATOR,
    )

    private fun defaults(
        perHectare: StoredChemicalDefaultRate? = null,
        per100Litres: StoredChemicalDefaultRate? = null,
    ) = StoredChemicalDefaultRates(
        version = StoredChemicalDefaultRates.DEFAULT_RATES_VERSION,
        perHectare = perHectare,
        per100Litres = per100Litres,
    )

    private fun chemical(defaults: StoredChemicalDefaultRates?) = SavedChemical(
        id = "chem-1",
        vineyardId = "vy-1",
        name = "Stifle",
        unit = "Litres",
        defaultRates = defaults,
    )

    /** The SACOA/Stifle case: 2-3 L/100 L, typed and confirmed by the operator. */
    private fun manualRange() = StoredChemicalDefaultRate.manual(
        basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        unit = "L",
        minValue = 2.0,
        maxValue = 3.0,
    )

    private fun manualScalar() = StoredChemicalDefaultRate.manual(
        basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        unit = "L",
        value = 2.0,
    )

    // ---- No fabricated official identity -----------------------------------

    @Test
    fun `a manual rate carries no official identity at all`() {
        val slot = manualRange()
        assertEquals("", slot.optionKey)
        assertTrue(slot.rateIds.isEmpty())
        assertTrue(slot.isManualEntry)
        assertTrue(slot.isConfirmedByOperator)

        // And none of the tempting fabrications appear anywhere in the payload.
        val encoded = json.encodeToString(StoredChemicalDefaultRate.serializer(), slot)
        for (fake in listOf("default_option_v1_", "rate_v1_", "manual_rate", "user_rate", "custom")) {
            assertFalse("must not mint $fake: $encoded", encoded.contains(fake))
        }
    }

    @Test
    fun `a manual rate validates despite having no option key or rate ids`() {
        val valid = ChemicalDefaultRateValidity.validSlot(
            defaults(per100Litres = manualRange()),
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        assertNotNull("a user-confirmed rate must be believable", valid)
        assertTrue(valid!!.isManualEntry)
        assertTrue(valid.isConfirmedByOperator)
    }

    /**
     * A row claiming to be manual while carrying a citation contradicts itself.
     * Believing either half would lend label authority to something typed.
     */
    @Test
    fun `a manual row carrying an official citation is rejected`() {
        val contradictory = manualRange().copy(
            optionKey = "default_option_v1_abc",
            rateIds = listOf("rate_v1_a"),
        )
        assertNull(
            ChemicalDefaultRateValidity.validSlot(
                defaults(per100Litres = contradictory),
                ChemicalDefaultRateBasis.PER_100_LITRES,
            ),
        )
    }

    // ---- Scalar: saves, reloads, prefills -----------------------------------

    @Test
    fun `a user-confirmed scalar saves, reloads and prefills spray program`() {
        val stored = defaults(per100Litres = manualScalar())

        val reloaded = json.decodeFromString(
            StoredChemicalDefaultRates.serializer(),
            json.encodeToString(StoredChemicalDefaultRates.serializer(), stored),
        )

        val resolution = ChemicalSprayDefaultHandoff.resolutionFor(reloaded)
        assertTrue(resolution is ChemicalSprayRateResolution.Prefilled)
        val prefill = (resolution as ChemicalSprayRateResolution.Prefilled).prefill
        assertEquals(2.0, prefill.rate, 1e-9)
        assertEquals("L", prefill.unit)
        assertEquals(SprayCalculator.RateBasis.PER_100L, prefill.basis)
        assertTrue("provenance must survive the round trip", prefill.isUserEntered)
        assertTrue(ChemicalSprayDefaultHandoff.isSprayReady(reloaded))
    }

    // ---- Range: spray-ready, but requires an in-range choice ----------------

    @Test
    fun `a user-confirmed range is spray-ready but requires a chosen dose`() {
        val stored = defaults(per100Litres = manualRange())

        assertTrue(
            "a confirmed band must no longer read as 'confirmation required'",
            ChemicalSprayDefaultHandoff.isSprayReady(stored),
        )

        val resolution = ChemicalSprayDefaultHandoff.resolutionFor(stored)
        assertTrue(resolution is ChemicalSprayRateResolution.RequiresSelection)
        val selection = (resolution as ChemicalSprayRateResolution.RequiresSelection).selection
        assertEquals(2.0, selection.min, 1e-9)
        assertEquals(3.0, selection.max, 1e-9)
        assertEquals("L", selection.unit)
        assertEquals(SprayCalculator.RateBasis.PER_100L, selection.basis)
        assertTrue(selection.isUserEntered)

        // Nothing is prefilled: choosing 2, 3 or 2.5 would be deciding the dose
        // on the operator's behalf.
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(stored, ChemicalDefaultRateBasis.PER_100_LITRES))
        assertNull(resolution.prefillOrNull)
    }

    @Test
    fun `a chosen dose is validated against the confirmed band`() {
        val selection = (
            ChemicalSprayDefaultHandoff.resolutionFor(defaults(per100Litres = manualRange()))
                as ChemicalSprayRateResolution.RequiresSelection
            ).selection

        assertEquals(
            2.5,
            ChemicalSprayDefaultHandoff.validateApplicationRate(2.5, selection).acceptedValue!!,
            1e-9,
        )
        // Both bounds are legal doses of the direction.
        assertTrue(ChemicalSprayDefaultHandoff.validateApplicationRate(2.0, selection).isAccepted)
        assertTrue(ChemicalSprayDefaultHandoff.validateApplicationRate(3.0, selection).isAccepted)

        assertTrue(
            ChemicalSprayDefaultHandoff.validateApplicationRate(1.9, selection)
                is ChemicalApplicationRateOutcome.BelowMinimum,
        )
        assertTrue(
            ChemicalSprayDefaultHandoff.validateApplicationRate(3.1, selection)
                is ChemicalApplicationRateOutcome.AboveMaximum,
        )
        assertTrue(
            ChemicalSprayDefaultHandoff.validateApplicationRate(null, selection)
                is ChemicalApplicationRateOutcome.NotANumber,
        )
        assertTrue(
            ChemicalSprayDefaultHandoff.validateApplicationRate(0.0, selection)
                is ChemicalApplicationRateOutcome.NotANumber,
        )
    }

    // ---- The range never collapses ------------------------------------------

    @Test
    fun `a 2-3 L per 100L band never collapses to min, max or midpoint`() {
        val stored = defaults(per100Litres = manualRange())
        val reloaded = json.decodeFromString(
            StoredChemicalDefaultRates.serializer(),
            json.encodeToString(StoredChemicalDefaultRates.serializer(), stored),
        )
        val slot = reloaded.per100Litres!!
        assertEquals(2.0, slot.minValue!!, 1e-9)
        assertEquals(3.0, slot.maxValue!!, 1e-9)
        assertNull("no scalar may appear", slot.value)

        // And no per-hectare projection is invented from it.
        assertNull(chemical(reloaded).legacyRatePerHaProjection)
        for (invented in listOf(0.0, 2.0, 2.5, 3.0)) {
            assertFalse(chemical(reloaded).legacyRatePerHaProjection == invented)
        }
    }

    @Test
    fun `a per-100L manual rate never migrates onto the per-hectare basis`() {
        val stored = defaults(per100Litres = manualRange())
        assertNull(
            ChemicalDefaultRateValidity.validSlot(stored, ChemicalDefaultRateBasis.PER_HECTARE),
        )
        val resolutions = ChemicalSprayDefaultHandoff.resolutions(stored)
        assertEquals(1, resolutions.size)
        assertEquals(SprayCalculator.RateBasis.PER_100L, resolutions.single().basis)
    }

    // ---- Existing canonical behaviour is unchanged ---------------------------

    @Test
    fun `a canonical scalar still prefills and is not marked user-entered`() {
        val stored = defaults(perHectare = canonicalSlot(value = 2.0))
        val prefill = ChemicalSprayDefaultHandoff
            .prefillFor(stored, ChemicalDefaultRateBasis.PER_HECTARE)!!
        assertEquals(2.0, prefill.rate, 1e-9)
        assertFalse("a label rate is not user-entered", prefill.isUserEntered)
        assertEquals(2.0, chemical(stored).legacyRatePerHaProjection!!, 1e-9)
    }

    @Test
    fun `a canonical row missing its identity is still rejected`() {
        val noKey = canonicalSlot(value = 2.0).copy(optionKey = "")
        assertNull(
            "only a manual row may omit the official identity",
            ChemicalDefaultRateValidity.validSlot(
                defaults(perHectare = noKey),
                ChemicalDefaultRateBasis.PER_HECTARE,
            ),
        )

        val fakeKey = canonicalSlot(value = 2.0).copy(optionKey = "manual_rate", rateIds = listOf("user_rate_1"))
        assertNull(
            ChemicalDefaultRateValidity.validSlot(
                defaults(perHectare = fakeKey),
                ChemicalDefaultRateBasis.PER_HECTARE,
            ),
        )
    }

    /** A row written before `entry_method` existed is canonical by construction. */
    @Test
    fun `a legacy row with no entry method decodes as canonical`() {
        val legacy = """
            {"version":1,"per_hectare":{"option_key":"default_option_v1_abc",
            "rate_ids":["rate_v1_a"],"basis":"per_hectare","unit":"L","value":2,
            "source":"operator"}}
        """.trimIndent()
        val decoded = json.decodeFromString(StoredChemicalDefaultRates.serializer(), legacy)
        val slot = decoded.perHectare!!
        assertEquals(StoredChemicalDefaultRate.ENTRY_CANONICAL, slot.entryMethod)
        assertFalse(slot.isManualEntry)
        assertNotNull(
            ChemicalDefaultRateValidity.validSlot(decoded, ChemicalDefaultRateBasis.PER_HECTARE),
        )
    }

    // ---- Offline round trip --------------------------------------------------

    @Test
    fun `an offline manual chemical round-trips with its contract intact`() {
        val offline = chemical(defaults(per100Litres = manualRange()))
        val reloaded = json.decodeFromString(
            SavedChemical.serializer(),
            json.encodeToString(SavedChemical.serializer(), offline),
        )

        assertNull("no manufactured legacy scalar", reloaded.ratePerHa)
        val slot = reloaded.defaultRates!!.per100Litres!!
        assertEquals(2.0, slot.minValue!!, 1e-9)
        assertEquals(3.0, slot.maxValue!!, 1e-9)
        assertTrue(slot.isManualEntry)
        assertEquals("", slot.optionKey)
        assertTrue(slot.rateIds.isEmpty())
        assertTrue(ChemicalSprayDefaultHandoff.isSprayReady(reloaded.defaultRates))
    }

    // ---- Spray record provenance ---------------------------------------------

    @Test
    fun `the spray record snapshots the applied dose and its provenance`() {
        val stored = defaults(per100Litres = manualRange())
        val selection = (
            ChemicalSprayDefaultHandoff.resolutionFor(stored)
                as ChemicalSprayRateResolution.RequiresSelection
            ).selection
        val chosen = ChemicalSprayDefaultHandoff.validateApplicationRate(2.5, selection)
            .acceptedValue!!

        val snapshot = ChemicalLineSnapshot(
            savedChemicalId = "chem-1",
            productName = "Stifle",
        ).recordingApplied(
            rate = chosen,
            unit = selection.unit,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
            entryMethod = StoredChemicalDefaultRate.ENTRY_MANUAL,
            confirmedRange = ChemicalDefaultRateValidity.Amount.Range(2.0, 3.0),
        )

        assertEquals(2.5, snapshot.appliedRate!!, 1e-9)
        assertEquals("L", snapshot.appliedRateUnit)
        assertEquals("per_100_litres", snapshot.appliedRateBasis)
        assertEquals("chem-1", snapshot.savedChemicalId)
        assertEquals("Stifle", snapshot.productName)
        assertTrue("history must remember this was user-confirmed", snapshot.isUserEnteredRate)
        assertEquals(2.0, snapshot.rateRangeMin!!, 1e-9)
        assertEquals(3.0, snapshot.rateRangeMax!!, 1e-9)

        // The saved chemical is untouched: the 2.5 belonged to one tank.
        val slot = stored.per100Litres!!
        assertEquals(2.0, slot.minValue!!, 1e-9)
        assertEquals(3.0, slot.maxValue!!, 1e-9)
        assertNull(slot.value)
    }

    @Test
    fun `a canonical spray line records canonical provenance`() {
        val snapshot = ChemicalLineSnapshot(savedChemicalId = "chem-2")
            .recordingApplied(
                rate = 2.0,
                unit = "L",
                basis = ChemicalDefaultRateBasis.PER_HECTARE,
                entryMethod = StoredChemicalDefaultRate.ENTRY_CANONICAL,
            )
        assertFalse(snapshot.isUserEnteredRate)
        assertEquals("per_hectare", snapshot.appliedRateBasis)
        assertNull(snapshot.rateRangeMin)
    }

    @Test
    fun `the applied-rate snapshot survives a json round trip`() {
        val snapshot = ChemicalLineSnapshot(savedChemicalId = "chem-1").recordingApplied(
            rate = 2.5,
            unit = "L",
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
            entryMethod = StoredChemicalDefaultRate.ENTRY_MANUAL,
            confirmedRange = ChemicalDefaultRateValidity.Amount.Range(2.0, 3.0),
        )
        val reloaded = json.decodeFromString(
            ChemicalLineSnapshot.serializer(),
            json.encodeToString(ChemicalLineSnapshot.serializer(), snapshot),
        )
        assertEquals(2.5, reloaded.appliedRate!!, 1e-9)
        assertEquals("per_100_litres", reloaded.appliedRateBasis)
        assertTrue(reloaded.isUserEnteredRate)
    }
}
