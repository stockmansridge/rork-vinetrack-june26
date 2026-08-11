package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CloneCatalogEntry
import com.rork.vinetrack.data.model.CloneRootstockOptions
import com.rork.vinetrack.data.model.RootstockCatalogEntry
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import kotlinx.serialization.builtins.ListSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Offline persistence/fallback contract for the shared clone + rootstock
 * catalogues (audit #10).
 *
 * The last successfully fetched built-in catalogues and per-vineyard custom
 * records are persisted so an offline cold restart hydrates the Block Setup
 * pickers instead of leaving them empty. Supabase stays the single source of
 * truth: a successful server read (even an empty one) always wins and
 * refreshes the cache; the cache is only ever a fallback.
 *
 * These tests exercise the exact production codec ([CatalogOfflineCache]
 * encode/decode — the same functions [DomainCacheStore] persists through)
 * and the resolution ladder used by AppViewModel's vineyard-data load.
 */
class CloneRootstockOfflineCacheTest {

    private val cloneSerializer = ListSerializer(CloneCatalogEntry.serializer())
    private val rootstockSerializer = ListSerializer(RootstockCatalogEntry.serializer())
    private val vineyardCloneSerializer = ListSerializer(VineyardCloneRow.serializer())
    private val vineyardRootstockSerializer = ListSerializer(VineyardRootstockRow.serializer())

    private val vineyardId = "11111111-1111-4111-8111-111111111111"
    private val otherVineyardId = "22222222-2222-4222-8222-222222222222"

    private val cloneCatalog = listOf(
        CloneCatalogEntry(
            key = "shiraz:pt23", varietyKey = "shiraz", displayName = "PT23",
            cloneCode = "PT23", selectionSystem = "Australian selection",
            sourceCountry = "Australia", aliases = listOf("PT 23"),
        ),
        CloneCatalogEntry(
            key = "pinot_noir:mv6", varietyKey = "pinot_noir", displayName = "MV6",
            cloneCode = "MV6", selectionSystem = "Australian selection", sourceCountry = "Australia",
        ),
    )

    private val rootstockCatalog = listOf(
        RootstockCatalogEntry(
            key = "1103_paulsen", canonicalName = "1103 Paulsen", displayName = "1103 Paulsen",
            aliases = listOf("1103P", "Paulsen"), parentage = "V. berlandieri × V. rupestris",
        ),
        RootstockCatalogEntry(
            key = "ramsey", canonicalName = "Ramsey", displayName = "Ramsey",
            aliases = listOf("Salt Creek"), parentage = "V. champinii",
        ),
    )

    private val customClones = listOf(
        VineyardCloneRow(
            id = "c1", vineyardId = vineyardId,
            cloneKey = "custom:$vineyardId:shiraz:old_block_selection",
            varietyKey = "shiraz", displayName = "Old Block Selection",
        ),
    )

    private val customRootstocks = listOf(
        VineyardRootstockRow(
            id = "r1", vineyardId = vineyardId,
            rootstockKey = "custom:$vineyardId:paulsen_hybrid",
            displayName = "Paulsen Hybrid",
        ),
    )

    // ---- Restart survival: encode → (process death) → decode -----------------

    @Test
    fun builtInCloneCatalogueSurvivesColdRestartRoundTrip() {
        val persisted = CatalogOfflineCache.encode(cloneSerializer, cloneCatalog)
        val restored = CatalogOfflineCache.decode(cloneSerializer, persisted)
        assertEquals(cloneCatalog, restored)
        // The restored snapshot drives a working picker, not an empty one.
        val shiraz = CloneRootstockOptions.systemClonesForVariety(restored, "shiraz")
        assertEquals(listOf("shiraz:pt23"), shiraz.map { it.key })
    }

    @Test
    fun builtInRootstockCatalogueSurvivesColdRestartRoundTrip() {
        val persisted = CatalogOfflineCache.encode(rootstockSerializer, rootstockCatalog)
        val restored = CatalogOfflineCache.decode(rootstockSerializer, persisted)
        assertEquals(rootstockCatalog, restored)
        val options = CloneRootstockOptions.systemRootstocks(restored)
        assertEquals(listOf("1103_paulsen", "ramsey"), options.map { it.key })
        // Alias search still works from the restored snapshot.
        val byAlias = CloneRootstockOptions.systemRootstocks(restored, "Salt Creek")
        assertEquals(listOf("ramsey"), byAlias.map { it.key })
    }

    @Test
    fun vineyardCustomRecordsSurviveRestartAndStayVineyardScoped() {
        val persistedClones = CatalogOfflineCache.encode(vineyardCloneSerializer, customClones)
        val persistedRootstocks = CatalogOfflineCache.encode(vineyardRootstockSerializer, customRootstocks)
        val restoredClones = CatalogOfflineCache.decode(vineyardCloneSerializer, persistedClones)
        val restoredRootstocks = CatalogOfflineCache.decode(vineyardRootstockSerializer, persistedRootstocks)
        assertEquals(customClones, restoredClones)
        assertEquals(customRootstocks, restoredRootstocks)
        // Variety scoping survives: the custom Shiraz clone never surfaces
        // under Pinot after hydration from the cache.
        assertTrue(CloneRootstockOptions.customClonesForVariety(restoredClones, "pinot_noir").isEmpty())
        assertEquals(
            listOf("c1"),
            CloneRootstockOptions.customClonesForVariety(restoredClones, "shiraz").map { it.id },
        )
        // The cache key is per vineyard; a row for another vineyard is a
        // different snapshot entirely (encode/decode never mixes them).
        assertTrue(restoredClones.all { it.vineyardId == vineyardId })
        assertFalse(restoredClones.any { it.vineyardId == otherVineyardId })
    }

    @Test
    fun corruptOrAbsentCachePayloadDecodesToEmptyNotCrash() {
        assertTrue(CatalogOfflineCache.decode(cloneSerializer, null).isEmpty())
        assertTrue(CatalogOfflineCache.decode(cloneSerializer, "{not json").isEmpty())
        assertTrue(CatalogOfflineCache.decode(rootstockSerializer, "[{\"broken\":").isEmpty())
    }

    // ---- Resolution ladder: server → in-memory → cache ------------------------

    @Test
    fun offlineColdRestartHydratesPickersFromTheCache() {
        // Cold restart offline: fetch failed (null), nothing in memory yet,
        // a cached snapshot exists → pickers use the last-known catalogue.
        val res = CatalogOfflineCache.resolve(
            server = null,
            inMemory = emptyList(),
            cached = cloneCatalog,
        )
        assertEquals(cloneCatalog, res.entries)
        assertFalse(res.fromServer)
        assertTrue(res.fromCache)
    }

    @Test
    fun offlineColdRestartWithNoCacheDegradesToEmptyWithoutCrashing() {
        val res = CatalogOfflineCache.resolve<CloneCatalogEntry>(
            server = null,
            inMemory = emptyList(),
            cached = null,
        )
        assertTrue(res.entries.isEmpty())
        assertFalse(res.fromServer)
        assertFalse(res.fromCache)
    }

    @Test
    fun midSessionOfflineDropKeepsTheInMemoryCatalogue() {
        // The app already holds a catalogue in memory; a failed refresh must
        // keep it (not swap to a possibly older cached snapshot).
        val newerInMemory = cloneCatalog + CloneCatalogEntry(
            key = "shiraz:bvrc12", varietyKey = "shiraz", displayName = "BVRC12", cloneCode = "BVRC12",
        )
        val res = CatalogOfflineCache.resolve(
            server = null,
            inMemory = newerInMemory,
            cached = cloneCatalog,
        )
        assertEquals(newerInMemory, res.entries)
        assertFalse(res.fromServer)
        assertFalse(res.fromCache)
    }

    @Test
    fun freshServerReadWinsAndTriggersCacheWriteThrough() {
        // Online refresh (#9 behaviour preserved): the server read replaces
        // both in-memory state and the cached snapshot. fromServer=true is
        // exactly the write-through gate AppViewModel uses.
        val serverNow = rootstockCatalog.drop(1) // remote archive removed 1103 Paulsen
        val res = CatalogOfflineCache.resolve(
            server = serverNow,
            inMemory = rootstockCatalog,
            cached = rootstockCatalog,
        )
        assertEquals(serverNow, res.entries)
        assertTrue(res.fromServer)
        assertFalse(res.fromCache)
    }

    @Test
    fun emptyServerReadIsAuthoritativeOverStaleCache() {
        // Supabase stays the source of truth: a genuinely empty server list
        // (e.g. every custom rootstock archived) must not be resurrected
        // from cache or memory.
        val res = CatalogOfflineCache.resolve(
            server = emptyList<VineyardRootstockRow>(),
            inMemory = customRootstocks,
            cached = customRootstocks,
        )
        assertTrue(res.entries.isEmpty())
        assertTrue(res.fromServer)
    }

    @Test
    fun refreshedSnapshotReplacesTheOldCachePayloadOnDisk() {
        // Simulate the full cycle: cache v1, remote adds a clone, refresh
        // fetches v2 → write-through persists v2 → next offline restart
        // hydrates v2 (the remote addition is present offline).
        val v1 = CatalogOfflineCache.encode(cloneSerializer, cloneCatalog)
        val remoteAddition = CloneCatalogEntry(
            key = "pinot_noir:d5v12", varietyKey = "pinot_noir", displayName = "D5V12", cloneCode = "D5V12",
        )
        val serverV2 = cloneCatalog + remoteAddition
        val res = CatalogOfflineCache.resolve(
            server = serverV2,
            inMemory = CatalogOfflineCache.decode(cloneSerializer, v1),
            cached = CatalogOfflineCache.decode(cloneSerializer, v1),
        )
        assertTrue(res.fromServer)
        val v2 = CatalogOfflineCache.encode(cloneSerializer, res.entries)
        val afterRestart = CatalogOfflineCache.decode(cloneSerializer, v2)
        assertEquals(serverV2, afterRestart)
        assertTrue(afterRestart.any { it.key == "pinot_noir:d5v12" })
    }
}
