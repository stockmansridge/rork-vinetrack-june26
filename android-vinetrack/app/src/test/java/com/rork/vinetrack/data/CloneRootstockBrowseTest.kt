package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CloneCatalogEntry
import com.rork.vinetrack.data.model.CloneRootstockBrowse
import com.rork.vinetrack.data.model.CloneRootstockSentinels
import com.rork.vinetrack.data.model.RootstockCatalogEntry
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the Grape Varieties settings catalogue browser
 * (Varieties | Clones | Rootstocks) — cross-variety browsing, search, and
 * block-allocation usage matching. Mirrors `CloneRootstockBrowseTests.swift`
 * on iOS so both platforms stay pinned to one contract.
 */
class CloneRootstockBrowseTest {

    private val vineyardId = "11111111-1111-4111-8111-111111111111"

    private val catalog = listOf(
        CloneCatalogEntry(key = "shiraz:pt23", varietyKey = "shiraz", displayName = "PT23", cloneCode = "PT23", selectionSystem = "Australian selection", sourceCountry = "Australia", aliases = listOf("PT 23")),
        CloneCatalogEntry(key = "shiraz:fps_07", varietyKey = "shiraz", displayName = "FPS 07", cloneCode = "FPS 07", selectionSystem = "FPS (UC Davis)", sourceCountry = "USA"),
        CloneCatalogEntry(key = "cabernet_sauvignon:fps_07", varietyKey = "cabernet_sauvignon", displayName = "FPS 07", cloneCode = "FPS 07", selectionSystem = "FPS (UC Davis)", sourceCountry = "USA"),
        CloneCatalogEntry(key = "pinot_noir:entav_115", varietyKey = "pinot_noir", displayName = "ENTAV-INRA 115", cloneCode = "115", selectionSystem = "ENTAV-INRA", sourceCountry = "France", aliases = listOf("Dijon 115")),
        CloneCatalogEntry(key = "pinot_noir:retired", varietyKey = "pinot_noir", displayName = "Retired", cloneCode = "Retired", isActive = false),
    )

    private val customClones = listOf(
        VineyardCloneRow(
            id = "c1", vineyardId = vineyardId,
            cloneKey = "custom:$vineyardId:shiraz:old_block_selection",
            varietyKey = "shiraz", displayName = "Old Block Selection",
        ),
        VineyardCloneRow(
            id = "c2", vineyardId = vineyardId,
            cloneKey = "custom:$vineyardId:pinot_noir:hillside",
            varietyKey = "pinot_noir", displayName = "Hillside",
        ),
        VineyardCloneRow(
            id = "c3", vineyardId = vineyardId,
            cloneKey = "custom:$vineyardId:shiraz:archived_pick",
            varietyKey = "shiraz", displayName = "Archived Pick", isActive = false,
        ),
    )

    private val rootstocks = listOf(
        RootstockCatalogEntry(key = "1103_paulsen", canonicalName = "1103 Paulsen", displayName = "1103 Paulsen", aliases = listOf("1103P", "Paulsen"), parentage = "V. berlandieri × V. rupestris"),
        RootstockCatalogEntry(key = "ramsey", canonicalName = "Ramsey", displayName = "Ramsey", aliases = listOf("Salt Creek"), parentage = "V. champinii"),
    )

    private val customRootstocks = listOf(
        VineyardRootstockRow(
            id = "r1", vineyardId = vineyardId,
            rootstockKey = "custom:$vineyardId:trial_stock_7", displayName = "Trial Stock 7",
        ),
    )

    // ---- Browsing across all varieties ------------------------------------

    @Test
    fun browseAllVarietiesReturnsEveryActiveClone() {
        val all = CloneRootstockBrowse.systemClones(catalog, varietyKey = null)
        assertEquals(4, all.size)
        assertFalse(all.any { it.key == "pinot_noir:retired" })

        val custom = CloneRootstockBrowse.customClones(customClones, varietyKey = null)
        assertEquals(listOf("c1", "c2"), custom.map { it.id })
    }

    @Test
    fun browseScopesToOneVariety() {
        val shiraz = CloneRootstockBrowse.systemClones(catalog, varietyKey = "shiraz")
        assertEquals(setOf("shiraz:pt23", "shiraz:fps_07"), shiraz.map { it.key }.toSet())

        val custom = CloneRootstockBrowse.customClones(customClones, varietyKey = "pinot_noir")
        assertEquals(listOf("c2"), custom.map { it.id })
    }

    @Test
    fun browseSearchMatchesCodeAndAliasCaseInsensitive() {
        // Alias "PT 23" (with space).
        assertEquals(
            listOf("shiraz:pt23"),
            CloneRootstockBrowse.systemClones(catalog, null, "pt 23").map { it.key },
        )
        // Code match across two varieties — identity is never collapsed.
        assertEquals(
            2,
            CloneRootstockBrowse.systemClones(catalog, null, "fps").size,
        )
        // Alias "Dijon 115".
        assertEquals(
            listOf("pinot_noir:entav_115"),
            CloneRootstockBrowse.systemClones(catalog, null, "dijon").map { it.key },
        )
        // Custom by name.
        assertEquals(
            listOf("c1"),
            CloneRootstockBrowse.customClones(customClones, null, "old block").map { it.id },
        )
    }

    @Test
    fun rootstockBrowseMatchesAliasAndParentage() {
        assertEquals(
            listOf("ramsey"),
            CloneRootstockBrowse.systemRootstocks(rootstocks, "salt creek").map { it.key },
        )
        assertEquals(
            listOf("ramsey"),
            CloneRootstockBrowse.systemRootstocks(rootstocks, "champinii").map { it.key },
        )
        assertEquals(
            listOf("r1"),
            CloneRootstockBrowse.customRootstocks(customRootstocks, "trial").map { it.id },
        )
    }

    // ---- Allocation usage matching -----------------------------------------

    @Test
    fun usageMatchesByStableKey() {
        val pt23 = catalog.first { it.key == "shiraz:pt23" }
        val names = CloneRootstockBrowse.cloneMatchNames(pt23)
        assertTrue(CloneRootstockBrowse.allocationUsesClone("shiraz:pt23", "PT23", "shiraz:pt23", names))
        // Different key never matches — even with colliding display text.
        assertFalse(CloneRootstockBrowse.allocationUsesClone("shiraz:fps_07", "PT23", "shiraz:pt23", names))
    }

    @Test
    fun legacyTextMatchesOnlyWhenKeyAbsent() {
        val pt23 = catalog.first { it.key == "shiraz:pt23" }
        val names = CloneRootstockBrowse.cloneMatchNames(pt23)
        // Free-text legacy row (no key) matches canonically via the alias.
        assertTrue(CloneRootstockBrowse.allocationUsesClone(null, "pt 23", "shiraz:pt23", names))
        assertTrue(CloneRootstockBrowse.allocationUsesClone(null, "PT23", "shiraz:pt23", names))
        // Unrelated text does not.
        assertFalse(CloneRootstockBrowse.allocationUsesClone(null, "BVRC12", "shiraz:pt23", names))
        // Blank text does not.
        assertFalse(CloneRootstockBrowse.allocationUsesClone(null, "  ", "shiraz:pt23", names))
        assertFalse(CloneRootstockBrowse.allocationUsesClone(null, null, "shiraz:pt23", names))
    }

    @Test
    fun sentinelsNeverMatchCatalogueRecords() {
        val pt23 = catalog.first { it.key == "shiraz:pt23" }
        val names = CloneRootstockBrowse.cloneMatchNames(pt23)
        assertFalse(
            CloneRootstockBrowse.allocationUsesClone(
                CloneRootstockSentinels.MASS_SELECTION,
                CloneRootstockSentinels.MASS_SELECTION_DISPLAY,
                "shiraz:pt23",
                names,
            ),
        )

        val ramsey = rootstocks.first { it.key == "ramsey" }
        val rootstockNames = CloneRootstockBrowse.rootstockMatchNames(ramsey)
        assertFalse(
            CloneRootstockBrowse.allocationUsesRootstock(
                CloneRootstockSentinels.OWN_ROOTS,
                CloneRootstockSentinels.OWN_ROOTS_DISPLAY,
                "ramsey",
                rootstockNames,
            ),
        )
    }

    @Test
    fun rootstockUsageMatchesKeyAndLegacyText() {
        val ramsey = rootstocks.first { it.key == "ramsey" }
        val names = CloneRootstockBrowse.rootstockMatchNames(ramsey)
        assertTrue(CloneRootstockBrowse.allocationUsesRootstock("ramsey", null, "ramsey", names))
        // Legacy alias text.
        assertTrue(CloneRootstockBrowse.allocationUsesRootstock(null, "Salt Creek", "ramsey", names))
        // Different key with colliding text never matches.
        assertFalse(CloneRootstockBrowse.allocationUsesRootstock("1103_paulsen", "Ramsey", "ramsey", names))
    }

    @Test
    fun customRecordUsageMatchesItsVineyardKey() {
        val row = customClones.first()
        assertTrue(
            CloneRootstockBrowse.allocationUsesClone(row.cloneKey, row.displayName, row.cloneKey, listOf(row.displayName)),
        )
        // Legacy text naming the custom clone (no key) also counts.
        assertTrue(
            CloneRootstockBrowse.allocationUsesClone(null, "old block selection", row.cloneKey, listOf(row.displayName)),
        )
    }
}
