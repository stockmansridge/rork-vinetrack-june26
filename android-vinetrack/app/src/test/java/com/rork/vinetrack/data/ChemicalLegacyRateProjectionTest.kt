package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateValidity
import com.rork.vinetrack.data.chemical.ChemicalSprayDefaultHandoff
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The legacy `rate_per_ha` projection contract (sql/222).
 *
 * A chemical must never acquire a fabricated rate merely because an old column
 * requires one. Before sql/222 the column was `NOT NULL DEFAULT 0`, so a writer
 * that honestly omitted it got a manufactured `0` — indistinguishable, on read,
 * from a real operator decision.
 *
 * Every case below is one way a number could be invented: a range minimum, a
 * maximum, a midpoint, a per-100 L conversion, or a zero. The regression cases
 * are lettered to match the agreed contract correction.
 */
class ChemicalLegacyRateProjectionTest {

    /**
     * The SHARED client's configuration, mirrored exactly.
     *
     * `explicitNulls = false` is the whole reason the PATCH carries a
     * [JsonElement]: under it a Kotlin null is dropped from the request, so
     * "clear the stale legacy value" sent as null would arrive as "change
     * nothing". Asserting with any other configuration would test a request
     * this app never sends.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }

    // ---- Fixtures ----------------------------------------------------------

    private fun slot(
        value: Double? = null,
        minValue: Double? = null,
        maxValue: Double? = null,
        unit: String = "L",
        basis: ChemicalDefaultRateBasis = ChemicalDefaultRateBasis.PER_HECTARE,
        source: String = StoredChemicalDefaultRate.SOURCE_OPERATOR,
    ) = StoredChemicalDefaultRate(
        optionKey = "default_option_v1_abc",
        rateIds = listOf("rate_v1_a"),
        basis = basis.raw,
        unit = unit,
        value = value,
        minValue = minValue,
        maxValue = maxValue,
        source = source,
    )

    private fun defaults(
        perHectare: StoredChemicalDefaultRate? = null,
        per100Litres: StoredChemicalDefaultRate? = null,
    ) = StoredChemicalDefaultRates(
        version = StoredChemicalDefaultRates.DEFAULT_RATES_VERSION,
        perHectare = perHectare,
        per100Litres = per100Litres,
    )

    private fun chemical(
        ratePerHa: Double? = null,
        defaults: StoredChemicalDefaultRates? = null,
    ) = SavedChemical(
        id = "chem-1",
        vineyardId = "vy-1",
        name = "Stifle",
        ratePerHa = ratePerHa,
        unit = "Litres",
        defaultRates = defaults,
    )

    // ---- A: single per-hectare --------------------------------------------

    @Test
    fun `A a confirmed single per-hectare rate projects that exact scalar`() {
        val c = chemical(defaults = defaults(perHectare = slot(value = 2.0)))
        assertEquals(2.0, c.legacyRatePerHaProjection!!, 1e-9)
    }

    // ---- B: per-hectare range ---------------------------------------------

    @Test
    fun `B a per-hectare RANGE projects null, never a bound or a midpoint`() {
        val c = chemical(defaults = defaults(perHectare = slot(minValue = 2.0, maxValue = 3.0)))
        val projected = c.legacyRatePerHaProjection
        assertNull("a range has no single per-hectare scalar", projected)
        // Stated explicitly: none of the tempting fabrications appear.
        for (invented in listOf(0.0, 2.0, 2.5, 3.0)) {
            assertFalse("must not invent $invented", projected == invented)
        }
    }

    // ---- C: single per-100 L ----------------------------------------------

    @Test
    fun `C a single per-100L rate projects null and is never converted`() {
        val c = chemical(defaults = defaults(per100Litres = slot(
            value = 2.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        )))
        assertNull(
            "converting per-100L to per-hectare needs a job water volume",
            c.legacyRatePerHaProjection,
        )
    }

    // ---- D: the SACOA/Stifle case -----------------------------------------

    /**
     * The case that motivated the whole correction. `2–3 L/100 L` is a genuine
     * registered rate with no truthful per-hectare scalar whatsoever.
     */
    @Test
    fun `D a 2-3 L per 100L range never becomes 0, 2, 3 or 2 point 5 per hectare`() {
        val stored = defaults(per100Litres = slot(
            minValue = 2.0,
            maxValue = 3.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        ))
        val c = chemical(defaults = stored)
        val projected = c.legacyRatePerHaProjection

        assertNull("2-3 L/100 L has no per-hectare scalar at all", projected)
        for (invented in listOf(0.0, 2.0, 2.5, 3.0)) {
            assertFalse("must not invent $invented L/ha", projected == invented)
        }

        // The structured rate itself survives untouched: still a range, still
        // per-100 L, still 2 and 3 — not narrowed, not converted.
        val slot = ChemicalDefaultRateValidity.validSlot(
            stored,
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        assertNotNull(slot)
        val range = slot!!.amount as? ChemicalDefaultRateValidity.Amount.Range
        assertNotNull("must remain a range", range)
        assertEquals(2.0, range!!.min, 1e-9)
        assertEquals(3.0, range.max, 1e-9)
        assertEquals("L", slot.unit)
        assertEquals(ChemicalDefaultRateBasis.PER_100_LITRES, slot.basis)
        assertNull("a range is not a confirmed dose", slot.scalar)
    }

    /** A range survives a JSON round-trip without collapsing to a scalar. */
    @Test
    fun `D the 2-3 L per 100L range survives a reload unchanged`() {
        val stored = defaults(per100Litres = slot(
            minValue = 2.0,
            maxValue = 3.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        ))
        val reloaded = json.decodeFromString(
            StoredChemicalDefaultRates.serializer(),
            json.encodeToString(StoredChemicalDefaultRates.serializer(), stored),
        )
        val slot = reloaded.per100Litres!!
        assertEquals(2.0, slot.minValue!!, 1e-9)
        assertEquals(3.0, slot.maxValue!!, 1e-9)
        assertNull("no midpoint may appear on reload", slot.value)
        assertNull(chemical(defaults = reloaded).legacyRatePerHaProjection)
    }

    // ---- F: unconfirmed rates are not spray-ready --------------------------

    @Test
    fun `F an unnarrowed range never prefills a spray line`() {
        val stored = defaults(per100Litres = slot(
            minValue = 2.0,
            maxValue = 3.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        ))
        assertNull(
            "the operator must choose a dose inside the registered band",
            ChemicalSprayDefaultHandoff.prefillFor(
                stored,
                ChemicalDefaultRateBasis.PER_100_LITRES,
            ),
        )
    }

    /** A confirmed single per-100 L rate DOES prefill — on its own basis. */
    @Test
    fun `C a confirmed single per-100L rate prefills as per-100L, not per-hectare`() {
        val stored = defaults(per100Litres = slot(
            value = 2.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        ))
        val prefill = ChemicalSprayDefaultHandoff.prefillFor(
            stored,
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )
        assertNotNull(prefill)
        assertEquals(2.0, prefill!!.rate, 1e-9)
        assertEquals("L", prefill.unit)
        assertEquals(SprayCalculator.RateBasis.PER_100L, prefill.basis)
    }

    // ---- G: stale legacy value must be CLEARED on update -------------------

    /**
     * The stale-value case, stated as the sequence that produces it.
     *
     * A chemical saved as `2 L/ha` carries `rate_per_ha = 2`. The operator then
     * changes its authoritative rate to `2–3 L/100 L`. If the writer merely
     * omitted the column, PostgreSQL would leave the old `2` in place forever.
     */
    @Test
    fun `G changing 2 L per ha to a 2-3 L per 100L rate clears the legacy scalar`() {
        val before = chemical(
            ratePerHa = 2.0,
            defaults = defaults(perHectare = slot(value = 2.0)),
        )
        assertEquals("precondition: the legacy value is live", 2.0, before.legacyRatePerHaProjection!!, 1e-9)

        // The authoritative edit: per-hectare slot gone, per-100 L range in.
        val after = before.copy(
            defaultRates = defaults(per100Litres = slot(
                minValue = 2.0,
                maxValue = 3.0,
                basis = ChemicalDefaultRateBasis.PER_100_LITRES,
            )),
        )
        assertNull(
            "the stale 2 must not survive an authoritative rate change",
            after.legacyRatePerHaProjection,
        )
    }

    @Test
    fun `G changing 2 L per ha to a 2-3 L per ha range also clears the scalar`() {
        val after = chemical(
            ratePerHa = 2.0,
            defaults = defaults(perHectare = slot(minValue = 2.0, maxValue = 3.0)),
        )
        assertNull(after.legacyRatePerHaProjection)
    }

    @Test
    fun `G changing 2 L per ha to 2 point 5 L per ha projects the new scalar`() {
        val after = chemical(
            ratePerHa = 2.0,
            defaults = defaults(perHectare = slot(value = 2.5)),
        )
        assertEquals(2.5, after.legacyRatePerHaProjection!!, 1e-9)
    }

    /**
     * A cleared projection has to reach the wire as a literal `null`.
     *
     * This is the assertion that would have caught the bug: under
     * `explicitNulls = false` a Kotlin null is OMITTED, and an omitted key on a
     * PATCH means "leave it alone".
     */
    @Test
    fun `G a cleared projection serialises as an explicit JSON null`() {
        @Serializable
        data class PatchShape(@SerialName("rate_per_ha") val ratePerHa: JsonElement)

        val cleared = json.encodeToString(PatchShape.serializer(), PatchShape(JsonNull))
        assertTrue(
            "an omitted key would leave the stale value in place: $cleared",
            cleared.contains("\"rate_per_ha\":null"),
        )

        val kept = json.encodeToString(PatchShape.serializer(), PatchShape(JsonPrimitive(2.0)))
        assertTrue(kept.contains("\"rate_per_ha\":2"))
    }

    /** Proof the naive shape really does drop the key — why the above matters. */
    @Test
    fun `G a nullable Double would be omitted, which is the bug`() {
        @Serializable
        data class NaivePatch(@SerialName("rate_per_ha") val ratePerHa: Double? = null)

        val encoded = json.encodeToString(NaivePatch.serializer(), NaivePatch(null))
        assertFalse(
            "explicitNulls=false drops the key, so the stale value would survive",
            encoded.contains("rate_per_ha"),
        )
    }

    // ---- H: an unrelated edit must not disturb the projection --------------

    @Test
    fun `H editing notes only leaves a valid per-hectare projection intact`() {
        val before = chemical(
            ratePerHa = 2.0,
            defaults = defaults(perHectare = slot(value = 2.0)),
        )
        val after = before.copy(notes = "Store in the shed")
        assertEquals(2.0, after.legacyRatePerHaProjection!!, 1e-9)
    }

    /**
     * An edit that carries NO rate decision leaves the stored default alone.
     *
     * `defaultRates == null` means "leave the confirmation untouched", so the
     * caller's existing legacy value passes straight through rather than being
     * cleared by an edit that never mentioned rates.
     */
    @Test
    fun `H an edit carrying no rate decision passes the legacy value through`() {
        val c = chemical(ratePerHa = 2.0, defaults = null)
        assertEquals(2.0, c.legacyRatePerHaProjection!!, 1e-9)
    }

    // ---- I: offline / decode -----------------------------------------------

    /**
     * A null column must decode as absent, not as zero. Coercing here would
     * recreate on the client exactly the fabrication sql/222 removed from the
     * database — and an offline row would then sync a manufactured 0 back up.
     */
    @Test
    fun `I a null rate_per_ha decodes as absent rather than zero`() {
        val row = """{"id":"c1","vineyard_id":"v1","name":"Stifle","rate_per_ha":null}"""
        val decoded = json.decodeFromString(SavedChemical.serializer(), row)
        assertNull(decoded.ratePerHa)
        assertFalse("null must not become 0.0", decoded.ratePerHa == 0.0)
    }

    @Test
    fun `I a missing rate_per_ha decodes as absent rather than zero`() {
        val row = """{"id":"c1","vineyard_id":"v1","name":"Stifle"}"""
        val decoded = json.decodeFromString(SavedChemical.serializer(), row)
        assertNull(decoded.ratePerHa)
    }

    @Test
    fun `I an offline per-100L chemical round-trips with the legacy field null`() {
        val offline = chemical(defaults = defaults(per100Litres = slot(
            minValue = 2.0,
            maxValue = 3.0,
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        )))
        val reloaded = json.decodeFromString(
            SavedChemical.serializer(),
            json.encodeToString(SavedChemical.serializer(), offline),
        )
        assertNull("the cached row must not manufacture a zero", reloaded.ratePerHa)
        assertNull(reloaded.legacyRatePerHaProjection)
        // And the structured rate is still the same range after the round-trip.
        val slot = reloaded.defaultRates!!.per100Litres!!
        assertEquals(2.0, slot.minValue!!, 1e-9)
        assertEquals(3.0, slot.maxValue!!, 1e-9)
    }

    // ---- J: historical legacy-only rows ------------------------------------

    @Test
    fun `J a historical row with only a legacy scalar keeps working`() {
        val legacy = chemical(ratePerHa = 2.0, defaults = null)
        assertEquals(2.0, legacy.legacyRatePerHaProjection!!, 1e-9)
        assertEquals(2.0, legacy.ratePerHaDisplay!!, 1e-9)
    }

    /**
     * Precedence runs authoritative-first. A structured confirmation outranks
     * the legacy column, never the reverse.
     */
    @Test
    fun `J a structured confirmation outranks a stale legacy scalar`() {
        val c = chemical(
            ratePerHa = 99.0,
            defaults = defaults(perHectare = slot(value = 2.0)),
        )
        assertEquals(
            "the confirmed structured rate wins, not the legacy 99",
            2.0,
            c.legacyRatePerHaProjection!!,
            1e-9,
        )
    }

    @Test
    fun `J a legacy scalar never resurrects a chemical whose rate is per-100L`() {
        val c = chemical(
            ratePerHa = 99.0,
            defaults = defaults(per100Litres = slot(
                value = 2.0,
                basis = ChemicalDefaultRateBasis.PER_100_LITRES,
            )),
        )
        assertNull(
            "a per-100L confirmation means there is no per-hectare scalar",
            c.legacyRatePerHaProjection,
        )
    }

    // ---- Basis and unit are never converted --------------------------------

    @Test
    fun `basis and unit survive the handoff exactly as stored`() {
        val stored = defaults(per100Litres = slot(
            value = 250.0,
            unit = "mL",
            basis = ChemicalDefaultRateBasis.PER_100_LITRES,
        ))
        val prefill = ChemicalSprayDefaultHandoff.prefillFor(
            stored,
            ChemicalDefaultRateBasis.PER_100_LITRES,
        )!!
        assertEquals(250.0, prefill.rate, 1e-9)
        assertEquals("mL", prefill.unit)
        assertEquals(SprayCalculator.RateBasis.PER_100L, prefill.basis)
        assertNull("250 mL/100 L has no per-hectare projection", chemical(defaults = stored).legacyRatePerHaProjection)
    }
}
