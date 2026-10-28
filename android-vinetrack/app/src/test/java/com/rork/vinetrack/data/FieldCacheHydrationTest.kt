package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class FieldCacheHydrationTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private fun source() = mutableMapOf<String, Any?>("cache_owner_user_id" to "user",
        "pins_A" to json.encodeToString(ListSerializer(Pin.serializer()), listOf(Pin("pin", "A"))), "pins_at_A" to 1L)

    @Test fun exactBytesTimestampOwnerAndVineyardMustMatch() {
        val source = source()
        val snapshot = requireNotNull(FieldCacheHydration.prepare("user", "A", source))
        assertTrue(snapshot.matches("user", "A", source))
        assertFalse(snapshot.matches("other", "A", source))
        assertFalse(snapshot.matches("user", "B", source))
        for (key in listOf("pins_A", "pins_at_A", "cache_owner_user_id")) {
            val changed = source.toMutableMap()
            changed[key] = if (key == "pins_at_A") 2L else "changed"
            assertFalse(snapshot.matches("user", "A", changed))
        }
        assertEquals("pin", snapshot.pins!!.single().id)
    }

    @Test fun corruptMissingOrForeignCacheDoesNotBecomeAnEmptyAuthoritativeCollection() {
        assertNull(FieldCacheHydration.prepare("other", "A", source()))
        assertNull(FieldCacheHydration.prepare("", "A", source()))
        val broken = source().apply { this["pins_A"] = "bad json" }
        assertNull(FieldCacheHydration.prepare("user", "A", broken)!!.pins)
        val missing = source().apply { remove("pins_at_A") }
        assertNull(FieldCacheHydration.prepare("user", "A", missing)!!.pins)
        val empty = source().apply { this["pins_A"] = "[]" }
        assertEquals(emptyList<Pin>(), FieldCacheHydration.prepare("user", "A", empty)!!.pins)
    }

    @Test fun snapshotsDoNotRetainMutablePreferenceMapsAndTopLevelRowsAreReadOnly() {
        val source = source()
        val snapshot = requireNotNull(FieldCacheHydration.prepare("user", "A", source))
        source["pins_A"] = "[]"
        assertFalse(snapshot.matches("user", "A", source))
        assertEquals(1, snapshot.pins!!.size)
        try { (snapshot.pins as MutableList<Pin>).clear(); fail("Prepared rows must not be mutable") }
        catch (_: UnsupportedOperationException) { }
    }

    @Test fun cancellationBeforeWorkerCompletionPreventsPublication() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val release = java.util.concurrent.CountDownLatch(1)
        var published = false
        val read = launch {
            LocalCacheReadWorker.read {
                started.complete(Unit)
                check(release.await(3, java.util.concurrent.TimeUnit.SECONDS))
                FieldCacheHydration.prepare("user", "A", source())
            }
            published = true
        }
        started.await()
        read.cancel()
        release.countDown()
        read.join()
        assertFalse(published)
    }

    @Test fun suspendedPreparationReconcilesOnlyFreshPendingIntentAfterSourceVerification() = runBlocking {
        val source = source()
        val completed = CompletableDeferred<FieldCacheHydration>()
        val pending = mutableListOf<PendingWrite>()
        val publish = async(start = CoroutineStart.UNDISPATCHED) {
            val prepared = completed.await()
            check(prepared.matches("user", "A", source))
            PendingPinReadOverlay.reconcile(prepared.pins.orEmpty(), emptyList(), pending.toList(), "A")
        }
        pending += PendingWrite("delete", PendingEntityType.PIN, PendingOpType.DELETE,
            "{\"pinId\":\"pin\"}", "pin", 1, 1)
        completed.complete(LocalCacheReadWorker.read { requireNotNull(FieldCacheHydration.prepare("user", "A", source)) })
        assertTrue(publish.await().rows.isEmpty())
        assertEquals(1, pending.size)
    }

    @Test fun setupReferencesRemainOwnerVineyardAndExactSourceScoped() {
        val preferences = source().apply {
            this["machines_A"] = json.encodeToString(ListSerializer(VineyardMachine.serializer()), listOf(
                VineyardMachine("tractor-A", "A"), VineyardMachine("foreign", "B")))
            this["machines_at_A"] = 2L
            this["spray_equipment_A"] = json.encodeToString(ListSerializer(SprayEquipment.serializer()), listOf(
                SprayEquipment("rig-A", "A"), SprayEquipment("foreign", "B")))
            this["spray_equipment_at_A"] = 3L
        }
        val snapshot = requireNotNull(FieldCacheHydration.prepare("user", "A", preferences))
        assertEquals(listOf("tractor-A"), snapshot.machines!!.map { it.id })
        assertEquals(listOf("rig-A"), snapshot.sprayEquipment!!.map { it.id })
        assertEquals(2L, snapshot.syncedAt("machines"))
        assertEquals(3L, snapshot.syncedAt("spray_equipment"))
        assertNull(FieldCacheHydration.prepare("other", "A", preferences))
        assertNull(FieldCacheHydration.prepare("user", "B", preferences)!!.machines)
        for (key in listOf("machines_A", "machines_at_A", "spray_equipment_A", "spray_equipment_at_A")) {
            assertFalse(snapshot.matches("user", "A", preferences.toMutableMap().apply { this[key] = "changed" }))
        }
    }

    @Test fun failedSetupCacheIsUnknownWhileExplicitEmptyIsRetainedAsCachedOnly() {
        val preferences = source().apply {
            this["machines_A"] = "[]"; this["machines_at_A"] = 1L
            this["spray_equipment_A"] = "broken"; this["spray_equipment_at_A"] = 1L
        }
        val snapshot = requireNotNull(FieldCacheHydration.prepare("user", "A", preferences))
        assertEquals(emptyList<VineyardMachine>(), snapshot.machines)
        assertNull(snapshot.sprayEquipment)
        assertFalse(HomeReadKnowledge.Unknown.isKnown)
        assertTrue(HomeReadKnowledge.Cached.isKnown)
        assertNotEquals(HomeReadKnowledge.Fresh, HomeReadKnowledge.Cached)
        assertNull(FieldCacheHydration.prepare("user", "A", preferences.apply { remove("machines_at_A") })!!.machines)
    }

    @Test fun pairedSmallMediumAndLargeDecodeAndPublicationSizing() = runBlocking {
        for (scale in listOf(1, 10, 100)) {
            val source = mutableMapOf<String, Any?>("cache_owner_user_id" to "user")
            val pins = (0 until 50 * scale).map { Pin("pin-$it", "A", notes = "x".repeat(512)) }
            val route = (0 until 2000).map { CoordinatePoint(-34.0 + it * 0.000001, 138.0) }
            val trips = (0 until 2 * scale).map { Trip("trip-$it", "A", pathPoints = route, isActive = false) }
            val spray = (0 until 10 * scale).map { SprayRecord("spray-$it", "A", notes = "x".repeat(512)) }
            val tasks = (0 until 20 * scale).map { WorkTask("task-$it", "A", notes = "x".repeat(512)) }
            val growth = (0 until 50 * scale).map { GrowthStageRecord("growth-$it", "A", notes = "x".repeat(512)) }
            source["pins_A"] = json.encodeToString(ListSerializer(Pin.serializer()), pins)
            source["trips_A"] = json.encodeToString(ListSerializer(Trip.serializer()), trips)
            source["spray_A"] = json.encodeToString(ListSerializer(SprayRecord.serializer()), spray)
            source["worktask_A"] = json.encodeToString(ListSerializer(WorkTask.serializer()), tasks)
            source["growth_A"] = json.encodeToString(ListSerializer(GrowthStageRecord.serializer()), growth)
            listOf("pins", "trips", "spray", "worktask", "growth").forEach { source["${it}_at_A"] = 1L }
            fun publication(prepared: FieldCacheHydration): Int {
                check(prepared.matches("user", "A", source))
                val overlaidPins = PendingPinReadOverlay.reconcile(prepared.pins.orEmpty(), emptyList(), emptyList(), "A").rows
                val overlaidSpray = PendingWriteOverlay.overlaySpray(prepared.spray.orEmpty(), emptyList(), "A")
                val overlaidTasks = PendingWriteOverlay.overlayWorkTaskHeaders(prepared.tasks.orEmpty(), emptyList(), "A")
                val overlaidGrowth = PendingWriteOverlay.overlayGrowth(prepared.growth.orEmpty(), emptyList(), "A")
                return overlaidPins.size + prepared.trips.orEmpty().filter { !it.isActive }.size +
                    overlaidSpray.size + overlaidTasks.size + overlaidGrowth.size
            }
            repeat(3) { run ->
                val beforeStart = System.nanoTime()
                assertEquals(132 * scale, publication(requireNotNull(FieldCacheHydration.prepare("user", "A", source))))
                val before = (System.nanoTime() - beforeStart) / 1_000_000.0
                val caller = Thread.currentThread().id
                var workerThread = caller
                val elapsedStart = System.nanoTime()
                val prepared = LocalCacheReadWorker.read {
                    workerThread = Thread.currentThread().id
                    requireNotNull(FieldCacheHydration.prepare("user", "A", source))
                }
                val afterStart = System.nanoTime()
                assertEquals(132 * scale, publication(prepared))
                val after = (System.nanoTime() - afterStart) / 1_000_000.0
                assertNotEquals(caller, workerThread)
                val elapsed = (System.nanoTime() - elapsedStart) / 1_000_000.0
                val bytes = source.values.filterIsInstance<String>().filter { it.startsWith("[") }.sumOf { it.toByteArray().size }
                println("PAIRED_HOST_HYDRATION records=${132 * scale} routePoints=${4000 * scale} bytes=$bytes run=$run callerBeforeMs=$before callerAfterMs=$after awaitedElapsedMs=$elapsed AndroidMainLooperNotMeasured=true diskExcluded=true")
            }
        }
    }
}
