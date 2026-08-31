package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalDefaultRate
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateOption
import com.rork.vinetrack.data.chemical.ChemicalServerDefaultRateOption
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
    fun `no main source can mint a canonical identity`() {
        // The strongest form of this guarantee is that the code to do it no
        // longer exists. The minting helpers were deleted outright rather than
        // left unused, because an available minting function is one call site
        // away from being used again.
        val root = listOf(
            File("src/main/java"),
            File("app/src/main/java"),
            File("android-vinetrack/app/src/main/java"),
        ).first { it.isDirectory }
        val offenders = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                val code = file.readText()
                    .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
                    .lines()
                    .filterNot { it.trimStart().startsWith("//") }
                    .joinToString("\n")
                code.contains("mintOptionKey")
            }
            .map { it.name }
            .toList()
        assertEquals(
            "Android must never mint a canonical option key: $offenders",
            emptyList<String>(),
            offenders,
        )
    }

    @Test
    fun `the server option key reaches storage byte for byte`() {
        val stored = requireNotNull(
            confirmedDefaultRate(
                option = chateauOption(),
                basis = ChemicalDefaultRateBasis.PER_HECTARE,
                grapevineUses = listOf(chateauUse()),
                confirmedValue = 620.0,
            ),
        )
        assertEquals(goldenBandKey, stored.optionKey)
    }

    @Test
    fun `the server rate ids reach storage in the server's own order`() {
        // Deliberately NOT re-sorted or de-duplicated on the way through: the
        // server minted `option_key` over these exact bytes, so tidying them
        // here would break the pairing the key exists to prove.
        val serverOrder = listOf("rate_v1_bbb", "rate_v1_aaa")
        val stored = requireNotNull(
            confirmedDefaultRate(
                option = ChemicalServerDefaultRateOption(
                    optionKey = goldenSingleValueKey,
                    rateIds = serverOrder,
                    basis = "per_100_litres",
                    unit = "L",
                    value = 3.0,
                ).toDomainOption(),
                basis = ChemicalDefaultRateBasis.PER_100_LITRES,
                grapevineUses = listOf(chateauUse()),
            ),
        )
        assertEquals(serverOrder, stored.rateIds)
        assertEquals(goldenSingleValueKey, stored.optionKey)
    }

    @Test
    fun `an option with no server twin can never be persisted`() {
        // An option the device assembled from `registered_uses` for display
        // carries no identity the register issued, so it stops at the
        // persistence boundary rather than being written with an invented one.
        val uses = listOf(chateauUse())
        val displayOnly = requireNotNull(
            ChemicalDefaultRate.options(ChemicalDefaultRateBasis.PER_HECTARE, uses).firstOrNull(),
        )
        assertNull(displayOnly.server)
        assertNull(
            confirmedDefaultRate(
                displayOnly, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 620.0,
            ),
        )
    }

    @Test
    fun `a malformed server option is rejected rather than repaired`() {
        val uses = listOf(chateauUse())
        fun refuses(label: String, option: ChemicalServerDefaultRateOption) {
            assertFalse("$label must not validate", option.isValid)
            assertNull(
                "$label must not persist",
                confirmedDefaultRate(
                    option.toDomainOption(),
                    ChemicalDefaultRateBasis.PER_HECTARE,
                    uses,
                    confirmedValue = 620.0,
                ),
            )
        }
        val good = chateauServerOption()
        refuses("an empty citation list", good.copy(rateIds = emptyList()))
        refuses("a UUID citation", good.copy(rateIds = listOf("8f14e45f-ceea-467a")))
        refuses("an unminted option key", good.copy(optionKey = "option-42"))
        refuses("a bare prefix key", good.copy(optionKey = "default_option_v1_"))
        refuses("a blank unit", good.copy(unit = " "))
        refuses("an unknown basis", good.copy(basis = "per_vine"))
        refuses("an inverted band", good.copy(minValue = 700.0, maxValue = 560.0))
        refuses("a lone bound", good.copy(maxValue = null))
        refuses(
            "a scalar carrying bounds",
            good.copy(value = 620.0, minValue = 560.0, maxValue = 700.0),
        )
    }

    @Test
    fun `a server option filed under the wrong basis is refused`() {
        // A per-100 L option sitting in the per-hectare slot would be applied
        // per hectare.
        val misfiled = chateauServerOption().copy(basis = "per_100_litres")
        assertTrue(misfiled.isValid)
        assertNull(
            confirmedDefaultRate(
                misfiled.toDomainOption(),
                ChemicalDefaultRateBasis.PER_HECTARE,
                listOf(chateauUse()),
                confirmedValue = 620.0,
            ),
        )
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

    /** The CHATEAU option exactly as the server sends it. */
    private fun chateauServerOption(
        optionKey: String = goldenBandKey,
        rateIds: List<String> = listOf("rate_v1_chateau"),
    ) = ChemicalServerDefaultRateOption(
        optionKey = optionKey,
        rateIds = rateIds,
        basis = "per_hectare",
        unit = "g",
        minValue = 560.0,
        maxValue = 700.0,
        directionIds = listOf("dir_v1_chateau"),
        targets = listOf("Annual broadleaf weeds"),
        conditions = listOf("All states"),
        crops = listOf("Grapevines"),
    )

    /** The domain option the picker renders, carrying the server's identity. */
    private fun chateauOption(): ChemicalDefaultRateOption =
        chateauServerOption().toDomainOption()

    /**
     * The option under test.
     *
     * Now built from the SERVER's block rather than re-grouped from
     * [ChemicalRegisteredUse]s: the register issues the identity, so a test
     * that assembled one locally would be exercising a path the app no longer
     * has.
     */
    private fun option(
        @Suppress("UNUSED_PARAMETER") basis: ChemicalDefaultRateBasis,
        @Suppress("UNUSED_PARAMETER") uses: List<ChemicalRegisteredUse>,
    ): ChemicalDefaultRateOption? = chateauOption()

    // ---------------------------------------------------------------------
    // Building a confirmed default
    // ---------------------------------------------------------------------

    @Test
    fun `an unnarrowed band records no default at all`() {
        // A band nobody narrowed is a decision that was never finished.
        //
        // This REVERSES the earlier shape, which stored the band's own bounds
        // as though choosing the row were the whole answer. `560-700 g/ha`
        // states what the label PERMITS; it says nothing about what this
        // vineyard pours, and there is no minimum, maximum or midpoint
        // fallback anywhere in this contract.
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        assertNull(confirmedDefaultRate(option, ChemicalDefaultRateBasis.PER_HECTARE, uses))
    }

    @Test
    fun `an exact dose inside the band is stored as a scalar with both bounds null`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        val stored = requireNotNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 620.0,
            ),
        )

        // Shared shape D3: an amount is a scalar OR a range, never both.
        // Storing 620 alongside 560-700 reads back as an amount that is
        // simultaneously "exactly 620" and "anywhere in 560-700", and a
        // consumer has no principled way to choose between them.
        assertEquals(620.0, stored.value!!, 1e-9)
        assertNull(stored.minValue)
        assertNull(stored.maxValue)

        // The printed band is NOT lost: `registered_uses` still carries it
        // verbatim and stays the sole authority on what the label permits.
        assertEquals(560.0, uses.first().rates.first().minValue!!, 1e-9)
        assertEquals(700.0, uses.first().rates.first().maxValue!!, 1e-9)

        // IDENTITY is still minted from the LABEL's own amounts, so two
        // vineyards dosing 620 and 650 inside one printed band are recognised
        // as having chosen the same registered option.
        assertEquals(goldenBandKey, stored.optionKey)
        assertEquals(listOf("rate_v1_chateau"), stored.rateIds)
        assertEquals("per_hectare", stored.basis)
        assertEquals("g", stored.unit)
        assertEquals("operator", stored.source)
    }

    @Test
    fun `a dose outside the registered band is refused`() {
        val uses = listOf(chateauUse())
        val option = requireNotNull(option(ChemicalDefaultRateBasis.PER_HECTARE, uses))
        // 900 g/ha is not registered, so nothing is recorded at all - the
        // unauthorised figure is never written, and the band is not silently
        // stored in its place either.
        assertNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 900.0,
            ),
        )
    }

    /**
     * An untraceable default is exactly the invented provenance this contract
     * exists to prevent: a number that looks chosen, attributed to a direction
     * nobody can point at.
     */
    @Test
    fun `a rate with no server-minted id cannot become a default`() {
        val uses = listOf(chateauUse(rateId = null))
        val option = chateauServerOption(rateIds = emptyList()).toDomainOption()
        assertNull(
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 620.0,
            ),
        )
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
        // The SERVER builds its options from the grapevine partition, so an
        // apple direction never appears among the citations that reach
        // storage. The device no longer re-derives this set at all — which is
        // what makes the partition impossible to get wrong here.
        val uses = listOf(grapevine)
        val stored = requireNotNull(
            confirmedDefaultRate(
                chateauOption(),
                ChemicalDefaultRateBasis.PER_HECTARE,
                uses,
                confirmedValue = 620.0,
            ),
        )
        val ids = stored.rateIds
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
        // The confirmed scalar, and NO bounds: `explicitNulls = false` omits
        // them entirely, which is exactly the scalar shape the server reads.
        assertEquals(620.0, slotJson["value"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertNull(slotJson["min_value"])
        assertNull(slotJson["max_value"])
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
            confirmedDefaultRate(
                option, ChemicalDefaultRateBasis.PER_HECTARE, uses, confirmedValue = 620.0,
            ),
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
        // The operator's exact dose is what survives the round trip.
        assertEquals(620.0, reloaded.defaultRates?.perHectare?.value!!, 1e-9)
        assertNull(reloaded.defaultRates?.perHectare?.minValue)
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
