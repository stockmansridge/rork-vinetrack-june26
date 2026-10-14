package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class ChemicalInventorySummaryTest {
    @Test fun archiveEvictsTotalsAndReloadNeverRequestsHistoricalRows() = runBlocking {
        val active = SavedChemical("active", "vineyard", name = "Active")
        val old = active.copy(id = "history", name = "Historical")
        val requests = mutableListOf<String>()
        val cache = ChemicalInventorySummaryState(this) { id ->
            requests.add(id)
            CatalogueRow(buildJsonObject { put("tracked", true); put("estimated_stock_value", 25) })
        }
        cache.update("account|vineyard|owner", listOf(active, old)); cache.waitForRefresh()
        assertEquals(50.0, cache.state.value.summaries.values.sumOf { it.number("estimated_stock_value") ?: 0.0 }, 0.0)
        val archived = old.copy(isActive = false)
        cache.update("account|vineyard|owner", listOf(active, archived)); cache.waitForRefresh()
        assertEquals(setOf(active.id), cache.state.value.summaries.keys)
        assertEquals(2, requests.size)
        assertEquals(25.0, cache.state.value.summaries.values.sumOf { it.number("estimated_stock_value") ?: 0.0 }, 0.0)
        val restored = SupabaseClient.json.decodeFromString<List<SavedChemical>>(SupabaseClient.json.encodeToString(listOf(active, archived)))
        val restarted = ChemicalInventorySummaryState(this) { id ->
            assertEquals(active.id, id); CatalogueRow(buildJsonObject { put("tracked", true) })
        }
        restarted.update("account|vineyard|owner", restored); restarted.waitForRefresh()
        assertEquals(setOf(active.id), restarted.state.value.summaries.keys)
        assertEquals("Historical", archived.name)
    }

    @Test fun onlyChangedSummaryReloadsAndMutationInvalidatesOne() = runBlocking {
        val one = SavedChemical("one", "vineyard", name = "One")
        val two = one.copy(id = "two", name = "Two")
        val requests = mutableListOf<String>()
        val cache = ChemicalInventorySummaryState(this) { id -> requests.add(id); CatalogueRow(buildJsonObject {}) }
        cache.update("A", listOf(one, two)); cache.waitForRefresh()
        cache.update("A", listOf(one, two)); cache.waitForRefresh()
        assertEquals(2, requests.size)
        val changed = one.copy(notes = "Edited")
        cache.update("A", listOf(changed, two)); cache.waitForRefresh()
        assertEquals(2, requests.count { it == one.id }); assertEquals(1, requests.count { it == two.id })
        cache.update("A", listOf(changed, two), setOf(two.id)); cache.waitForRefresh()
        assertEquals(4, requests.size)
    }

    @Test fun oldScopeAndMutationCannotPublishAndRequestsAreSerialized() = runBlocking {
        val chemical = SavedChemical("one", "vineyard", name = "One")
        lateinit var cache: ChemicalInventorySummaryState
        var requests = 0; var active = 0; var maximum = 0
        cache = ChemicalInventorySummaryState(this) {
            requests++; active++; maximum = maxOf(maximum, active)
            try {
                if (requests == 1) cache.update("B", listOf(chemical))
                if (requests == 2) cache.update("B", listOf(chemical), setOf(chemical.id))
                CatalogueRow(buildJsonObject { put("estimated_stock_value", requests) })
            } finally { active-- }
        }
        cache.update("A", listOf(chemical)); cache.waitForRefresh()
        assertEquals(3, requests); assertEquals(1, maximum)
        assertEquals("B", cache.state.value.scope)
        assertEquals(3.0, cache.state.value.summaries[chemical.id]?.number("estimated_stock_value") ?: -1.0, 0.0)
        cache.update(null, emptyList()); assertTrue(cache.state.value.summaries.isEmpty())
    }

    @Test fun offlineRetainsUnchangedRowsAndPermissionChangeClearsCache() = runBlocking {
        val chemical = SavedChemical("one", "vineyard", name = "One")
        var fail = false
        val cache = ChemicalInventorySummaryState(this) {
            if (fail) throw IOException("Offline synthetic transport")
            CatalogueRow(buildJsonObject { put("tracked", true) })
        }
        cache.update("owner", listOf(chemical)); cache.waitForRefresh()
        fail = true; cache.update("owner", listOf(chemical)); cache.waitForRefresh()
        assertEquals(1, cache.state.value.summaries.size)
        cache.update("operator", listOf(chemical)); assertTrue(cache.state.value.summaries.isEmpty())
        cache.waitForRefresh(); assertNotNull(cache.state.value.error)
        fail = false; cache.retry(); cache.waitForRefresh()
        assertEquals(1, cache.state.value.summaries.size); assertNull(cache.state.value.error)
    }
}
