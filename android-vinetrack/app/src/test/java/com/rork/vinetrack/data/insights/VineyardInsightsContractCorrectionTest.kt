package com.rork.vinetrack.data.insights

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import java.time.LocalDate

class VineyardInsightsContractCorrectionTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Test fun `growth stage upload uses applied database column`() {
        val payload = VineyardInsightsSyncApi.ObservationUpsert(
            id = "o", assessmentId = "a", vineyardId = "v", itemKind = "growth_stage",
            linkedPinId = "pin", linkedGrowthStageRecordId = "growth", clientUpdatedAt = "now",
        )
        val objectValue = json.parseToJsonElement(json.encodeToString(payload)).jsonObject
        assertEquals("growth", objectValue["linked_growth_record_id"]?.jsonPrimitive?.content)
        assertFalse("linked_growth_stage_record_id" in objectValue)
    }

    @Test fun `pulled observation restores pin and growth record identifiers`() {
        val row = json.decodeFromString<VineyardInsightsSyncApi.ObservationRow>(
            """{"id":"o","assessment_id":"a","vineyard_id":"v","item_kind":"growth_stage","linked_pin_id":"pin","linked_growth_record_id":"growth"}""",
        )
        assertEquals("pin", row.linkedPinId)
        assertEquals("growth", row.linkedGrowthStageRecordId)
    }

    @Test fun `custom note type has stable UUID and picker catalogue refreshes immediately`() {
        val raw = MemoryStore()
        val store = VineyardInsightsStore(raw)
        val controller = VineyardInsightsController(store)
        val type = assertNotNull(controller.addCustomNoteType("vineyard", "Wind damage"))
        assertTrue(runCatching { java.util.UUID.fromString(type.databaseId) }.isSuccess)
        assertEquals(type.databaseId, store.pendingNoteTypes("vineyard").single().databaseId)
        assertEquals(type.databaseId, controller.noteTypesByVineyard.value["vineyard"]?.single()?.databaseId)
    }

    @Test fun `bootstrap Frost selection creates saveable type only offline draft`() {
        val frost = VintageNoteCatalog.systemTypes.single { it.code == "frost" }
        val draft = VintageNoteDraft(
            date = LocalDate.of(2026, 9, 19),
            noteTypeId = frost.persistedIdentity,
            noteTypeLabel = frost.label,
        )
        assertEquals("frost", draft.noteTypeId)
        assertEquals("Frost", draft.noteTypeLabel)
        assertTrue(draft.canSave)
        val controller = VineyardInsightsController(VineyardInsightsStore(MemoryStore()))
        val saved = assertNotNull(controller.saveNote(draft, "vineyard", null, "Scout", 7, 1))
        assertEquals("frost", saved.noteTypeId)
        assertEquals("Frost", saved.noteTypeLabelSnapshot)
    }

    @Test fun `legacy frost code resolves to real UUID before pending note push`() {
        val store = VineyardInsightsStore(MemoryStore())
        val controller = VineyardInsightsController(store)
        val draft = VintageNoteDraft(
            date = LocalDate.of(2026, 9, 19),
            noteTypeId = "frost",
            noteTypeLabel = "Frost",
        )
        val note = assertNotNull(controller.saveNote(draft, "vineyard", null, "Scout", 7, 1))
        val frostId = "00000000-0000-0000-0000-000000000240"
        assertTrue(store.reconcileNoteTypes("vineyard", listOf(
            VintageNoteType(frostId, "frost", VintageNoteGroup.WEATHER, "Frost", 1, false, true, null, true),
        )))
        assertEquals(frostId, store.loadNotes().single { it.id == note.id }.noteTypeId)
        assertEquals("Frost", store.loadNotes().single { it.id == note.id }.noteTypeLabelSnapshot)
    }

    @Test fun `single flight collapses rapid requests and never overlaps processors`() = runTest {
        val coordinator = VineyardInsightsSingleFlightCoordinator()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var passes = 0
        var active = 0
        var maxActive = 0
        val first = launch {
            coordinator.request("vineyard") {
                passes += 1
                active += 1
                maxActive = maxOf(maxActive, active)
                if (passes == 1) {
                    started.complete(Unit)
                    release.await()
                }
                active -= 1
            }
        }
        started.await()
        (1..10).map { async { coordinator.request("vineyard") { error("active pass closure is reused") } } }.awaitAll()
        release.complete(Unit)
        first.join()
        assertEquals(2, passes)
        assertEquals(1, maxActive)
    }

    @Test fun `Android sign out removes local file cleanup journal`() {
        val raw = MemoryStore()
        val store = VineyardInsightsStore(raw)
        assertTrue(store.queueLocalFileCleanup("vineyard", listOf("v/o/p.jpg")))
        store.clearForSignOut()
        assertTrue(VineyardInsightsStore(raw).loadLocalFileCleanup().isEmpty())
    }

    @Test fun `pending debounce cannot start after sign out cancellation`() = runTest {
        var starts = 0
        val debouncer = VineyardInsightsDebouncer(this, delayMillis = 650) { starts += 1 }
        debouncer.schedule("vineyard")
        debouncer.cancelAll()
        advanceTimeBy(1_000)
        assertEquals(0, starts)
    }

    @Test fun `single flight invalidation discards retained follow up`() = runTest {
        val coordinator = VineyardInsightsSingleFlightCoordinator()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var passes = 0
        val first = launch {
            coordinator.request("vineyard") {
                passes += 1
                started.complete(Unit)
                release.await()
            }
        }
        started.await()
        coordinator.request("vineyard") { error("must remain coalesced") }
        coordinator.invalidateAll()
        release.complete(Unit)
        first.join()
        assertEquals(1, passes)
    }

    @Test fun `partial entity outbox failures repair after restart with stable ids`() {
        val raw = MemoryStore()
        val store = VineyardInsightsStore(raw)
        val visit = ScoutVisit(
            id = "visit-stable", vineyardId = "vineyard", vintageYear = 2027,
            scoutDateIso = "2026-09-20", scoutUserId = null, scoutNameSnapshot = "Scout",
            clientUpdatedAtIso = "2026-09-20T01:00:00Z",
        )
        assertTrue(store.saveVisit(visit))
        raw.failNext(VineyardInsightsStore.KEY_QUEUE)
        assertFalse(store.enqueue(
            visit.id, visit.vineyardId, VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT,
            VineyardInsightsStore.QueuedOperation.Operation.UPSERT, visit.clientUpdatedAtIso,
        ))
        val restarted = VineyardInsightsStore(raw)
        assertTrue(restarted.repairMissingObligations())
        assertEquals("visit-stable", restarted.loadQueue().single().recordId)
        assertEquals("visit-stable", restarted.loadVisits().single().id)
    }

    @Test fun `acknowledging exact revision controls synced state`() {
        val raw = MemoryStore()
        val store = VineyardInsightsStore(raw)
        val visit = ScoutVisit(
            id = "visit", vineyardId = "vineyard", vintageYear = 2027,
            scoutDateIso = "2026-09-20", status = ScoutStatus.COMPLETED,
            scoutUserId = null, scoutNameSnapshot = null,
            clientUpdatedAtIso = "2026-09-20T01:00:00Z", syncVersion = 3,
        )
        assertTrue(store.saveVisit(visit))
        assertTrue(store.enqueue(visit.id, visit.vineyardId,
            VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT,
            VineyardInsightsStore.QueuedOperation.Operation.UPSERT, visit.clientUpdatedAtIso,
            queueId = "queue"))
        assertTrue(store.isSyncOwedForVisit(visit.id))
        assertTrue(store.dequeue("queue"))
        assertFalse(store.isSyncOwedForVisit(visit.id))
    }

    @Test fun `older Scout weather retry never attaches current conditions`() = runTest {
        val store = VineyardInsightsStore(MemoryStore())
        var loads = 0
        val controller = VineyardInsightsController(
            store = store,
            weatherLoader = { _, capturedAt ->
                loads += 1
                ScoutWeatherSnapshot(
                    observedAtIso = capturedAt, capturedAtIso = capturedAt, source = "station",
                    temperatureCelsius = 22.0, humidityPercent = 50.0, windSpeedKph = 4.0,
                    windGustKph = null, recentRainfallMm = 0.0,
                )
            },
            clock = { java.time.Instant.parse("2026-09-20T12:00:00Z") },
        )
        val visit = controller.startVisit("vineyard", null, null, 7, 1, LocalDate.of(2026, 9, 19))
        controller.captureWeather(visit.id)
        assertEquals(0, loads)
        assertTrue(controller.visit(visit.id)?.weather?.isUnavailable == true)
        assertTrue(controller.visit(visit.id)?.weather?.source?.contains("older Scout") == true)
    }

    @Test fun `object cleanup and local file obligations survive store restart`() {
        val raw = MemoryStore()
        val first = VineyardInsightsStore(raw)
        assertTrue(first.queueObjectCleanup("vineyard", "vineyard/observation/photo.jpg"))
        assertTrue(first.queueLocalFileCleanup("vineyard", listOf("vineyard/observation/photo.jpg")))
        val restarted = VineyardInsightsStore(raw)
        assertEquals("vineyard/observation/photo.jpg", restarted.loadObjectCleanup().single().storagePath)
        assertEquals("vineyard/observation/photo.jpg", restarted.loadLocalFileCleanup().single().relativePath)
    }

    private class MemoryStore : InsightsKeyValueStore {
        private val values = mutableMapOf<String, String>()
        private var failingKey: String? = null
        fun failNext(key: String) { failingKey = key }
        override fun get(key: String): String? = values[key]
        override fun put(key: String, value: String): Boolean {
            if (failingKey == key) { failingKey = null; return false }
            values[key] = value
            return true
        }
        override fun remove(key: String): Boolean { values.remove(key); return true }
        override fun clear(): Boolean { values.clear(); return true }
    }
}
