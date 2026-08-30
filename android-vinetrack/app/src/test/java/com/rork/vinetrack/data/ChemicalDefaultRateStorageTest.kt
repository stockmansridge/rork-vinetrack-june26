package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateIdentity
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateOption
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.chemical.confirmedDefaultRate
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The persistence contract for a CONFIRMED operational rate (sql/214).
 *
 * The customer outcome this protects: an operator searches a product, reads its
 * grapevine label, confirms the amount they actually pour, saves — and that
 * exact amount is waiting for them in the next spray, on every device.
 *
 * Before this existed, `default_rates` round-tripped nowhere on Android or iOS:
 * the confirmation was recorded in the UI, projected into the legacy `rates`
 * array, and the authoritative choice itself was dropped. Every client then
 * re-derived it by matching a bare number back to a label direction, which is
 * inference, not a decision.
 *
 * The golden option keys are minted by the DENO implementation
 * (`mintDefaultOptionKey` in `default_rates.ts`) and hard-coded on purpose. A
 * key is only useful if the server, iOS and Android independently arrive at the
 * same string for the same choice; asserting against a value this file computed
 * itself would prove nothing.
 */
class ChemicalDefaultRateStorageTest {

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** `3 L/100 L` supported by two printed directions. */
    private val goldenSingleValueKey = "default_option_v1_7de7c29980f279f49fac2e717ed4968d"

    /** `560–700 g/ha` — the CHATEAU (APVMA 80647) grapevine band. */
    private val goldenBandKey = "default_option_v1_dd81178fa70649ce9a097ad840805834"

    // ---------------------------------------------------------------------
    // Identity parity with the server
    // ---------------------------------------------------------------------

    @Test
    fun `option key matches the server for a single-value rate`() {
        val key = ChemicalDefaultRateIdentity.mintOptionKey(
            basis = "per_100_litres",
            unit = "L",
            value = 3.0,
            minValue = null,
            maxValue = null,
            rateIds = listOf("rate_v1_aaa", "rate_v1_bbb"),
        )
        assertEquals(goldenSingleValueKey, key)
    }

    @Test
    fun `option key matches the server for a true label band`() {
        val key = ChemicalDefaultRateIdentity.mintOptionKey(
            basis = "per_hectare",
            unit = "g",
            value = null,
            minValue = 560.0,
            maxValue = 700.0,
            rateIds = listOf("rate_v1_chateau"),
        )
        assertEquals(goldenBandKey, key)
    }

    /**
     * A client listing Grapevine Scale first must reach the same option as one
     * listing European Red Mites first: they made the same choice.
     */
    @Test
    fun `option key is independent of rate id order`() {
        val forward = ChemicalDefaultRateIdentity.mintOptionKey(
            "per_100_litres", "L", 3.0, null, null, listOf("rate_v1_aaa", "rate_v1_bbb"),
        )
        val reversed = ChemicalDefaultRateIdentity.mintOptionKey(
            "per_100_litres", "L", 3.0, null, null, listOf("rate_v1_bbb", "rate_v1_aaa"),
        )
        assertEquals(forward, reversed)
        assertEquals(goldenSingleValueKey, forward)
    }

    /** "No upper bound" and "an upper bound of zero" must never hash alike. */
    @Test
    fun `absent and zero amounts are distinct identities`() {
        assertEquals("-", ChemicalDefaultRateIdentity.normaliseNumber(null))
        assertEquals("0", ChemicalDefaultRateIdentity.normaliseNumber(0.0))
        assertEquals("3", ChemicalDefaultRateIdentity.normaliseNumber(3.0))
        // `3`, `3.0` and `3.000` are one number.
        assertEquals("3", ChemicalDefaultRateIdentity.normaliseNumber(3.000))
    }

    /**
     * Provenance must never move the identity, or a reissued label restating the
     * same direction would silently orphan the operator's default.
     */
    @Test
    fun `label version and timestamp are not part of identity`() {
        val input = ChemicalDefaultRateIdentity.canonicalInput(
            "per_hectare", "g", null, 560.0, 700.0, listOf("rate_v1_chateau"),
        )
        assertFalse(input.contains("2026"))
        assertFalse(input.lowercase().contains("operator"))
        assertFalse(input.lowercase().contains("label_version"))
    }

    // ---------------------------------------------------------------------
    // Fixtures
    // ---------------------------------------------------------------------

    /** The CHATEAU grapevine direction: one printed band, one server rate id. */
    private fun chateauUse(rateId: String? = "rate_v1_chateau") = ChemicalRegisteredUse(
        crop = "Grapevines",
        targetRaw = "Annual broadleaf weeds",
        rates = listOf(
            ChemicalLabelRate(
                label = "All states",
                basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                minValue = 560.0,
                maxValue = 700.0,
                unit = "g",
                rawText = "560 - 700 g/ha",
                rateId = rateId,
            ),
        ),
        directionId = "dir_v1_chateau",
    )

    private fun option(
        basis: ChemicalDefaultRateBasis,
        uses: List<ChemicalRegisteredUse>,
    ): ChemicalDefaultRateOption? = ChemicalDefaultRate.options(basis, uses).firstOrNull()

    // ---------------------------------------------------------------------
    // Building a confirmed default
    // ---------------------------------------------------------------------

    @Test
    fun `a confirmed band records both bounds and cites its direction`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val stored = requireNotNull(
            confirmedDefaultRate(option, ChemicalDefaultRateBasis.PER_HECTARE, uses),
        )

        assertEquals(goldenBandKey, stored.optionKey)
        assertEquals(listOf("rate_v1_chateau"), stored.rateIds)
        assertEquals("per_hectare", stored.basis)
        assertEquals("g", stored.unit)
        // A true label range keeps BOTH bounds. Splitting it into two defaults,
        // or collapsing it to one number, would misreport the registration.
        assertEquals(560.0, stored.minValue!!, 1e-9)
        assertEquals(700.0, stored.maxValue!!, 1e-9)
        // Confirmed by a human, so the provenance says so.
        assertEquals("operator", stored.source)
    }

    @Test
    fun `an exact dose inside the band is accepted and stored alongside it`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val stored = requireNotNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 620.0,
            ),
        )
        assertEquals(620.0, stored.value!!, 1e-9)
        // The registered band is NOT rewritten to the operator's figure.
        assertEquals(560.0, stored.minValue!!, 1e-9)
        assertEquals(700.0, stored.maxValue!!, 1e-9)
    }

    @Test
    fun `a dose outside the registered band is refused`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val stored = requireNotNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 900.0,
            ),
        )
        // 900 g/ha is not registered, so it is not recorded. The band stands.
        assertNull(stored.value)
        assertEquals(560.0, stored.minValue!!, 1e-9)
        assertEquals(700.0, stored.maxValue!!, 1e-9)
    }

    /**
     * An untraceable default is exactly the invented provenance this contract
     * exists to prevent: a number that looks chosen, attributed to a direction
     * nobody can point at.
     */
    @Test
    fun `a rate with no server-minted id cannot become a default`() {
        val uses = listOf(chateauUse(rateId = null))
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        assertNull(confirmedDefaultRate(option, ChemicalDefaultRateBasis.PER_HECTARE, uses))
    }

    /**
     * Other crops are retained on the record and are never candidates for a
     * vineyard's default.
     */
    @Test
    fun `an other-crop direction never supplies a vineyard rate id`() {
        val grapevine = chateauUse()
        val apples = ChemicalRegisteredUse(
            crop = "Apples",
            targetRaw = "Black spot",
            rates = listOf(
                ChemicalLabelRate(
                    label = "All states",
                    basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    minValue = 560.0,
                    maxValue = 700.0,
                    unit = "g",
                    rateId = "rate_v1_apples",
                ),
            ),
        )
        // The plan is built from the GRAPEVINE partition only.
        val uses = listOf(grapevine)
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val ids = ChemicalDefaultRateIdentity.rateIdsFor(option, uses)
        assertEquals(listOf("rate_v1_chateau"), ids)
        assertFalse(ids.contains("rate_v1_apples"))
        // Sanity: the apple direction really does state an identical amount, so
        // this proves the partition, not an accidental mismatch.
        assertEquals(560.0, apples.rates.first().minValue!!, 1e-9)
    }

    // ---------------------------------------------------------------------
    // Round trip
    // ---------------------------------------------------------------------

    @Test
    fun `the stored shape survives encode and decode with server key names`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val slot = requireNotNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses,
                confirmedValue = 620.0, labelVersion = "2024-07",
            ),
        )
        val value = StoredChemicalDefaultRates()
            .withSlot(ChemicalDefaultRateBasis.PER_HECTARE, slot)

        val encoded = json.encodeToString(StoredChemicalDefaultRates.serializer(), value)
        val obj = json.parseToJsonElement(encoded).jsonObject
        // Exact server key names — a client spelling is a guaranteed drift.
        assertEquals(1, obj["version"]!!.jsonPrimitive.content.toInt())
        val slotJson = requireNotNull(obj["per_hectare"]).jsonObject
        assertEquals(goldenBandKey, slotJson["option_key"]!!.jsonPrimitive.content)
        assertEquals(
            listOf("rate_v1_chateau"),
            slotJson["rate_ids"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(560.0, slotJson["min_value"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals(700.0, slotJson["max_value"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals("2024-07", slotJson["label_version"]!!.jsonPrimitive.content)

        val decoded = json.decodeFromString(StoredChemicalDefaultRates.serializer(), encoded)
        assertEquals(value, decoded)
        // The other basis stays independent: a per-ha default never manufactures
        // a per-100 L one, which would need a water volume the label never gave.
        assertNull(decoded.per100Litres)
    }

    @Test
    fun `a saved chemical carries its confirmed default through save and reload`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val slot = requireNotNull(
            confirmedDefaultRate(option, ChemicalDefaultRateBasis.PER_HECTARE, uses),
        )
        val chemical = SavedChemical(
            id = "c1",
            vineyardId = "v1",
            name = "CHATEAU",
            defaultRates = StoredChemicalDefaultRates()
                .withSlot(ChemicalDefaultRateBasis.PER_HECTARE, slot),
        )

        val encoded = json.encodeToString(SavedChemical.serializer(), chemical)
        val reloaded = json.decodeFromString(SavedChemical.serializer(), encoded)
        assertEquals(goldenBandKey, reloaded.defaultRates?.perHectare?.optionKey)
        assertEquals(listOf("rate_v1_chateau"), reloaded.defaultRates?.perHectare?.rateIds)
    }

    /**
     * A chemical saved before sql/214 has no default. That is a real answer and
     * must never be read as "this label has no rates".
     */
    @Test
    fun `a chemical saved before the column existed still loads`() {
        val decoded = json.decodeFromString(
            SavedChemical.serializer(),
            """{"id":"c1","vineyard_id":"v1","name":"Legacy"}""",
        )
        assertNull(decoded.defaultRates)
        assertEquals("Legacy", decoded.name)
    }

    // ---------------------------------------------------------------------
    // The database write shape
    // ---------------------------------------------------------------------

    /**
     * sql/215 is NOT applied. PostgREST rejects an entire write that names an
     * unknown column, so shipping these keys broke saving precisely when the
     * resolver HAD found a manufacturer document — the good-data case.
     *
     * The insert/patch DTOs are private, so this asserts on the repository
     * source: the rule is about what those bodies may name, and the source is
     * where that is decided.
     */
    @Test
    fun `the write DTOs name no unapplied sql215 column`() {
        val source = File(
            "src/main/java/com/rork/vinetrack/data/SavedChemicalRepository.kt",
        )
        assertTrue(
            "SavedChemicalRepository.kt not found at ${source.absolutePath}",
            source.exists(),
        )
        val text = source.readText()
        val writeShapes = text.substringAfter("private data class ChemicalInsert")
        assertFalse(
            "ChemicalInsert/ChemicalPatch must not name manufacturer_label_url (sql/215 unapplied)",
            writeShapes.contains("manufacturer_label_url"),
        )
        assertFalse(
            "ChemicalInsert/ChemicalPatch must not name manufacturer_product_url (sql/215 unapplied)",
            writeShapes.contains("manufacturer_product_url"),
        )
        // The confirmed default DOES belong in both write shapes.
        assertEquals(
            2,
            Regex("""@SerialName\("default_rates"\)""").findAll(writeShapes).count(),
        )
    }

    /**
     * Omitted, not blanked: an edit that carries no rate decision must never
     * erase a confirmation made earlier or on another device.
     */
    @Test
    fun `a null default is omitted from the write body rather than blanking it`() {
        val chemical = SavedChemical(id = "c1", vineyardId = "v1", name = "CHATEAU")
        val encoded = json.encodeToString(SavedChemical.serializer(), chemical)
        assertFalse(encoded.contains("default_rates"))
    }

    @Test
    fun `an empty selection records nothing rather than an empty object`() {
        val empty = StoredChemicalDefaultRates()
        assertTrue(empty.isEmpty)
        assertNotNull(StoredChemicalDefaultRates.DEFAULT_RATES_VERSION)
        assertEquals(1, StoredChemicalDefaultRates.DEFAULT_RATES_VERSION)
    }
}
