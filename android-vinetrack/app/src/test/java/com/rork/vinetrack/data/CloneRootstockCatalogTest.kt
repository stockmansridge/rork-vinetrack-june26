package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CloneCatalogEntry
import com.rork.vinetrack.data.model.CloneRootstockOptions
import com.rork.vinetrack.data.model.CloneRootstockSentinels
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.RootstockCatalogEntry
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the shared Clone + Rootstock catalogues (sql/182).
 * Mirrors `CloneRootstockCatalogTests.swift` on iOS so both platforms stay
 * pinned to one contract.
 */
class CloneRootstockCatalogTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val catalog = listOf(
        CloneCatalogEntry(key = "shiraz:pt23", varietyKey = "shiraz", displayName = "PT23", cloneCode = "PT23", selectionSystem = "Australian selection", sourceCountry = "Australia", aliases = listOf("PT 23")),
        CloneCatalogEntry(key = "shiraz:fps_07", varietyKey = "shiraz", displayName = "FPS 07", cloneCode = "FPS 07", selectionSystem = "FPS (UC Davis)", sourceCountry = "USA"),
        CloneCatalogEntry(key = "cabernet_sauvignon:fps_07", varietyKey = "cabernet_sauvignon", displayName = "FPS 07", cloneCode = "FPS 07", selectionSystem = "FPS (UC Davis)", sourceCountry = "USA"),
        CloneCatalogEntry(key = "pinot_noir:entav_115", varietyKey = "pinot_noir", displayName = "ENTAV-INRA 115", cloneCode = "115", selectionSystem = "ENTAV-INRA", sourceCountry = "France", aliases = listOf("Dijon 115")),
        CloneCatalogEntry(key = "pinot_noir:mv6", varietyKey = "pinot_noir", displayName = "MV6", cloneCode = "MV6", selectionSystem = "Australian selection", sourceCountry = "Australia"),
    )

    private val vineyardId = "11111111-1111-4111-8111-111111111111"

    private val customClones = listOf(
        VineyardCloneRow(
            id = "c1", vineyardId = vineyardId,
            cloneKey = "custom:$vineyardId:shiraz:old_block_selection",
            varietyKey = "shiraz", displayName = "Old Block Selection",
        ),
    )

    private val rootstocks = listOf(
        RootstockCatalogEntry(key = "1103_paulsen", canonicalName = "1103 Paulsen", displayName = "1103 Paulsen", aliases = listOf("1103P", "Paulsen"), parentage = "V. berlandieri × V. rupestris"),
        RootstockCatalogEntry(key = "ramsey", canonicalName = "Ramsey", displayName = "Ramsey", aliases = listOf("Salt Creek"), parentage = "V. champinii"),
        RootstockCatalogEntry(key = "101_14", canonicalName = "101-14 Mgt", displayName = "101-14 Mgt", aliases = listOf("101-14")),
    )

    // ---- Clone lookup scoped by variety --------------------------------------

    @Test
    fun cloneLookupIsScopedToVariety() {
        val shiraz = CloneRootstockOptions.systemClonesForVariety(catalog, "shiraz")
        assertEquals(listOf("shiraz:pt23", "shiraz:fps_07"), shiraz.map { it.key })

        // A Shiraz custom clone never surfaces under Chardonnay/Pinot.
        assertTrue(CloneRootstockOptions.customClonesForVariety(customClones, "pinot_noir").isEmpty())
        assertEquals(1, CloneRootstockOptions.customClonesForVariety(customClones, "shiraz").size)

        // No variety selected → no clone options at all.
        assertTrue(CloneRootstockOptions.systemClonesForVariety(catalog, null).isEmpty())
    }

    @Test
    fun cloneFilteringWhenVarietyChanges() {
        // The same query under two varieties yields DIFFERENT records —
        // FPS 07 (Shiraz) and FPS 07 (Cabernet) are distinct selections.
        val shiraz = CloneRootstockOptions.systemClonesForVariety(catalog, "shiraz", "FPS 07")
        val cab = CloneRootstockOptions.systemClonesForVariety(catalog, "cabernet_sauvignon", "FPS 07")
        assertEquals("shiraz:fps_07", shiraz.single().key)
        assertEquals("cabernet_sauvignon:fps_07", cab.single().key)
    }

    @Test
    fun cloneSearchMatchesAliases() {
        val byAlias = CloneRootstockOptions.systemClonesForVariety(catalog, "pinot_noir", "Dijon 115")
        assertEquals("pinot_noir:entav_115", byAlias.single().key)
    }

    @Test
    fun customCloneAddOnlyOfferedForGenuinelyNewNames() {
        assertTrue(CloneRootstockOptions.canOfferCustomClone(catalog, customClones, "shiraz", "Estate Selection"))
        // Exact system/custom matches suppress the add action.
        assertFalse(CloneRootstockOptions.canOfferCustomClone(catalog, customClones, "shiraz", "pt23"))
        assertFalse(CloneRootstockOptions.canOfferCustomClone(catalog, customClones, "shiraz", "old block selection"))
        // No variety → never offered (a clone requires its parent variety).
        assertFalse(CloneRootstockOptions.canOfferCustomClone(catalog, customClones, null, "Something"))
    }

    // ---- Rootstock catalogue: independent + searchable ------------------------

    @Test
    fun rootstockSearchMatchesNameAliasAndParentage() {
        assertEquals("ramsey", CloneRootstockOptions.systemRootstocks(rootstocks, "salt creek").single().key)
        assertEquals("1103_paulsen", CloneRootstockOptions.systemRootstocks(rootstocks, "1103P").single().key)
        assertEquals("ramsey", CloneRootstockOptions.systemRootstocks(rootstocks, "champinii").single().key)
        assertEquals(3, CloneRootstockOptions.systemRootstocks(rootstocks, "").size)
    }

    @Test
    fun customRootstockAddSuppressedForBuiltinNames() {
        val custom = listOf(
            VineyardRootstockRow(
                id = "r1", vineyardId = vineyardId,
                rootstockKey = "custom:$vineyardId:trial_stock_7", displayName = "Trial Stock 7",
            ),
        )
        assertTrue(CloneRootstockOptions.canOfferCustomRootstock(rootstocks, custom, "New Stock"))
        assertFalse(CloneRootstockOptions.canOfferCustomRootstock(rootstocks, custom, "Ramsey"))
        assertFalse(CloneRootstockOptions.canOfferCustomRootstock(rootstocks, custom, "salt creek"))
        assertFalse(CloneRootstockOptions.canOfferCustomRootstock(rootstocks, custom, "trial stock 7"))
    }

    // ---- Sentinels are conventions, not records --------------------------------

    @Test
    fun sentinelsAreNotCatalogueRecords() {
        assertEquals("mass_selection", CloneRootstockSentinels.MASS_SELECTION)
        assertEquals("own_roots", CloneRootstockSentinels.OWN_ROOTS)
        assertFalse(catalog.any { it.key == CloneRootstockSentinels.MASS_SELECTION })
        assertFalse(rootstocks.any { it.key == CloneRootstockSentinels.OWN_ROOTS })
    }

    // ---- Allocation round-trip (matches the iOS wire format) -------------------

    @Test
    fun allocationSerialisesCloneAndRootstockKeys() {
        val alloc = PaddockVarietyAllocation(
            varietyKey = "shiraz", name = "Shiraz / Syrah", percent = 50.0,
            clone = "PT23", rootstock = "1103 Paulsen",
            cloneKey = "shiraz:pt23", rootstockKey = "1103_paulsen",
        )
        val encoded = json.encodeToString(PaddockVarietyAllocation.serializer(), alloc)
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertEquals("shiraz:pt23", obj["cloneKey"]?.jsonPrimitive?.content)
        assertEquals("1103_paulsen", obj["rootstockKey"]?.jsonPrimitive?.content)

        val decoded = json.decodeFromString(PaddockVarietyAllocation.serializer(), encoded)
        assertEquals(alloc.cloneKey, decoded.cloneKey)
        assertEquals(alloc.rootstockKey, decoded.rootstockKey)
    }

    @Test
    fun legacyFreeTextAllocationIsPreserved() {
        val legacyJson = """
            {"varietyKey":"shiraz","name":"Shiraz","percent":70.0,
             "clone":"old vine selection","rootstock":"unknown mix"}
        """.trimIndent()
        val decoded = json.decodeFromString(PaddockVarietyAllocation.serializer(), legacyJson)
        assertEquals("old vine selection", decoded.clone)
        assertEquals("unknown mix", decoded.rootstock)
        assertNull(decoded.cloneKey)
        assertNull(decoded.rootstockKey)
    }

    @Test
    fun sameVarietyTwiceWithDifferentCloneAndRootstockNeverMerges() {
        val a = PaddockVarietyAllocation(
            varietyKey = "shiraz", name = "Shiraz", percent = 50.0,
            clone = "PT23", cloneKey = "shiraz:pt23",
            rootstock = "1103 Paulsen", rootstockKey = "1103_paulsen",
        )
        val b = PaddockVarietyAllocation(
            varietyKey = "shiraz", name = "Shiraz", percent = 50.0,
            clone = "BVRC12", cloneKey = "shiraz:bvrc12",
            rootstock = "Ramsey", rootstockKey = "ramsey",
        )
        val encoded = json.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(PaddockVarietyAllocation.serializer()),
            listOf(a, b),
        )
        val array = json.parseToJsonElement(encoded).jsonArray
        assertEquals(2, array.size)
        val decoded = json.decodeFromString(
            kotlinx.serialization.builtins.ListSerializer(PaddockVarietyAllocation.serializer()),
            encoded,
        )
        assertEquals("shiraz", decoded[0].varietyKey)
        assertEquals(decoded[0].varietyKey, decoded[1].varietyKey)
        assertFalse(decoded[0].cloneKey == decoded[1].cloneKey)
        assertFalse(decoded[0].rootstockKey == decoded[1].rootstockKey)
    }

    @Test
    fun ownRootsAndMassSelectionRoundTrip() {
        val alloc = PaddockVarietyAllocation(
            varietyKey = "pinot_noir", name = "Pinot Noir", percent = 100.0,
            clone = CloneRootstockSentinels.MASS_SELECTION_DISPLAY,
            cloneKey = CloneRootstockSentinels.MASS_SELECTION,
            rootstock = CloneRootstockSentinels.OWN_ROOTS_DISPLAY,
            rootstockKey = CloneRootstockSentinels.OWN_ROOTS,
        )
        val decoded = json.decodeFromString(
            PaddockVarietyAllocation.serializer(),
            json.encodeToString(PaddockVarietyAllocation.serializer(), alloc),
        )
        assertEquals(CloneRootstockSentinels.MASS_SELECTION, decoded.cloneKey)
        assertEquals(CloneRootstockSentinels.OWN_ROOTS, decoded.rootstockKey)
    }
}
