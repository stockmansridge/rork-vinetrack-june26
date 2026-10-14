package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** Isolated real preferences/store recreation, not OS-process restart or live-server acceptance. */
@RunWith(AndroidJUnit4::class)
class InventoryUpcomingPersistenceAndroidTest {
    private class Installation(base: Context) : ContextWrapper(base) {
        private val prefix = "inventory_upcoming_${UUID.randomUUID()}_"
        private val names = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name)
            return baseContext.getSharedPreferences(prefix + name, mode)
        }
        fun dispose() { names.forEach { baseContext.deleteSharedPreferences(prefix + it) } }
    }

    @Test fun archivedInventoryStaysHiddenAfterRealStoreRecreationAndScopeSwitch() = runBlocking {
        withTimeout(10_000) {
            val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
            val owner = "22222222-2222-4222-8222-222222222222"
            try {
                SessionStore(context).save("synthetic-access", "synthetic-refresh", owner, null)
                val active = SavedChemical("active", "vineyard", name = "Active")
                val history = active.copy(id = "history", name = "Historical", isActive = false, inventoryQuantity = 75.0)
                assertTrue(SavedChemicalLocalStore(context).save(owner, "vineyard", listOf(active, history)))
                val restored = SavedChemicalLocalStore(context).load(owner, "vineyard")
                assertEquals(listOf(active), ChemicalStorePresentation.active(restored))
                assertEquals(history, restored.single { it.id == history.id })
                assertTrue(SavedChemicalLocalStore(context).load("other-account", "vineyard").isEmpty())
                assertTrue(SavedChemicalLocalStore(context).load(owner, "other-vineyard").isEmpty())
                val requested = mutableListOf<String>()
                val state = ChemicalInventorySummaryState(this) { id ->
                    requested.add(id); CatalogueRow(buildJsonObject { put("tracked", true); put("estimated_stock_value", 25) })
                }
                state.update("$owner|vineyard|owner", restored); state.waitForRefresh()
                assertEquals(listOf(active.id), requested)
                assertEquals(25.0, state.state.value.summaries.values.sumOf { it.number("estimated_stock_value") ?: 0.0 }, 0.0)
                state.update("$owner|other-vineyard|owner", emptyList())
                assertTrue(state.state.value.summaries.isEmpty())
                state.update("other-account|vineyard|operator", emptyList())
                assertTrue(state.state.value.summaries.isEmpty())
            } finally { context.dispose() }
        }
    }

    @Test fun cachedUpcomingRolloverCompleteReopenAndVineyardAccountIsolation() {
        val context = Installation(InstrumentationRegistry.getInstrumentation().targetContext)
        val owner = "22222222-2222-4222-8222-222222222222"
        try {
            SessionStore(context).save("synthetic-access", "synthetic-refresh", owner, null)
            val task = WorkTask("task", "vineyard", date = "2026-10-14T00:00:00Z")
            val stage = task.copy(id = "stage", scheduleBasis = "el_stage", targetELStage = 35)
            val cache = DomainCacheRepository(context)
            cache.saveWorkTasks(owner, "vineyard", listOf(task, stage))
            val restored = DomainCacheRepository(context).loadWorkTasks(owner, "vineyard").orEmpty()
            val zone = ZoneId.of("Australia/Sydney")
            val before = Instant.parse("2026-10-14T12:59:59Z")
            assertEquals(listOf(stage, task), WorkTaskPlanning.upcoming(restored, before, zone))
            assertEquals(listOf(stage), WorkTaskPlanning.upcoming(restored, before.plusSeconds(1), zone))
            val completed = WorkTaskCompletion.complete(task, LocalDate.parse("2026-10-14"), zone, before, owner)
            cache.saveWorkTasks(owner, "vineyard", listOf(completed, stage))
            assertEquals(listOf(stage), WorkTaskPlanning.upcoming(DomainCacheRepository(context).loadWorkTasks(owner, "vineyard").orEmpty(), before, zone))
            cache.saveWorkTasks(owner, "vineyard", listOf(WorkTaskCompletion.reopen(completed), stage))
            assertEquals(listOf(stage, task), WorkTaskPlanning.upcoming(DomainCacheRepository(context).loadWorkTasks(owner, "vineyard").orEmpty(), before, zone))
            assertNull(DomainCacheRepository(context).loadWorkTasks("other-account", "vineyard"))
            assertNull(DomainCacheRepository(context).loadWorkTasks(owner, "other-vineyard"))
        } finally { context.dispose() }
    }
}
