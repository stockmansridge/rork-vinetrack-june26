package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Exercises production coordinators and durable repository compare-and-mutations across suspended requests. */
class ReplayVersionIntegrityTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val before = Trip("trip", "A", isActive = true, trackingPattern = "sequential", rowSequence = listOf(1.5, 2.5))
    private val target = before.copy(rowSequence = listOf(2.5, 1.5))
    private val newest = before.copy(rowSequence = listOf(3.5, 4.5))

    private class DiskStore(private val file: File) : PendingWriteStoring {
        private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
        private val serializer = ListSerializer(PendingWrite.serializer())
        override fun load(): List<PendingWrite> = if (file.exists()) json.decodeFromString(serializer, file.readText()) else emptyList()
        override fun save(writes: List<PendingWrite>): Boolean { file.writeText(json.encodeToString(serializer, writes)); return true }
        override fun clear(): Boolean = !file.exists() || file.delete()
    }

    @Test(timeout = 10000) fun routeReplacementSurvivesSuccessfulOlderResponseAndDiskRestart() = runBlocking {
        val directory = Files.createTempDirectory("route-version").toFile()
        try {
            val file = File(directory, "outbox.json")
            val queue = PendingWriteRepository(DiskStore(file))
            val started = CompletableDeferred<Unit>()
            val response = CompletableDeferred<Trip>()
            var publications = 0
            val sync = TripRowPlanSync(queue, { before }) { _, _ -> started.complete(Unit); response.await() }
            sync.enqueue(before, target)
            val original = queue.list().single()
            val replay = async { sync.replayAll { publications++ } }
            started.await()
            sync.enqueue(target, newest)
            val replacement = queue.list().single()
            assertEquals(original.id, replacement.id)
            response.complete(target)
            replay.await()
            assertEquals(0, publications)
            assertEquals(listOf(replacement), queue.list())
            assertEquals(listOf(replacement), PendingWriteRepository(DiskStore(file)).list())
            assertEquals(TripRowPlanSync.Plan.from(newest), json.decodeFromString(TripRowPlanSync.Payload.serializer(), replacement.payloadJson).target)
        } finally { directory.deleteRecursively() }
    }

    @Test(timeout = 10000) fun replacementAfterFetchPreventsOldPatch() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val started = CompletableDeferred<Unit>()
        val fetch = CompletableDeferred<Trip>()
        var patches = 0
        val sync = TripRowPlanSync(queue, { started.complete(Unit); fetch.await() }) { _, _ -> patches++; target }
        sync.enqueue(before, target)
        val replay = async { sync.replayAll { fail("Obsolete route was published") } }
        started.await()
        sync.enqueue(target, newest)
        val replacement = queue.list().single()
        fetch.complete(before)
        replay.await()
        assertEquals(0, patches)
        assertEquals(listOf(replacement), queue.list())
    }

    @Test(timeout = 10000) fun olderNetworkFailureCannotIncrementOrFailReplacementAcrossRestart() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Trip>()
        val sync = TripRowPlanSync(queue, { before }) { _, _ -> started.complete(Unit); response.await() }
        sync.enqueue(before, target)
        val replay = async { sync.replayAll { fail("Failed request published") } }
        started.await()
        sync.enqueue(target, newest)
        val replacement = queue.list().single()
        response.completeExceptionally(java.io.IOException("offline"))
        replay.await()
        assertEquals(listOf(replacement), PendingWriteRepository(store).list())
        assertEquals(0, replacement.attemptCount)
        assertEquals(PendingWriteStatus.PENDING, replacement.status)
    }

    @Test(timeout = 10000) fun olderPermanentFailureCannotBlockReplacement() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Trip>()
        val sync = TripRowPlanSync(queue, { before }) { _, _ -> started.complete(Unit); response.await() }
        sync.enqueue(before, target)
        val replay = async { sync.replayAll { } }
        started.await()
        sync.enqueue(target, newest)
        val replacement = queue.list().single()
        response.completeExceptionally(BackendError.Server(403, "forbidden"))
        replay.await()
        assertEquals(listOf(replacement), queue.list())
    }

    @Test(timeout = 10000) fun cancellationRetainsExactPayloadWithoutConsumingAttempt() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val started = CompletableDeferred<Unit>()
        val sync = TripRowPlanSync(queue, { before }) { _, _ -> started.complete(Unit); awaitCancellation() }
        sync.enqueue(before, target)
        val original = queue.list().single()
        val replay = launch { sync.replayAll { fail("Cancelled request published") } }
        started.await()
        replay.cancelAndJoin()
        val recovered = PendingWriteRepository(store).list().single()
        assertEquals(original.payloadJson, recovered.payloadJson)
        assertEquals(original.id, recovered.id)
        assertEquals(original.createdAt, recovered.createdAt)
        assertEquals(0, recovered.attemptCount)
        assertEquals(PendingWriteStatus.FAILED, recovered.status)
    }

    @Test(timeout = 10000) fun cancellationCannotChangeReplacementStatus() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val started = CompletableDeferred<Unit>()
        val sync = TripRowPlanSync(queue, { before }) { _, _ -> started.complete(Unit); awaitCancellation() }
        sync.enqueue(before, target)
        val replay = launch { sync.replayAll { } }
        started.await()
        sync.enqueue(target, newest)
        val replacement = queue.list().single()
        replay.cancelAndJoin()
        assertEquals(listOf(replacement), queue.list())
    }

    @Test(timeout = 10000) fun completionCoalescingDuringRequestSuppressesOldDisplayAndRetainsNewId() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Pin>()
        var publications = 0
        val sync = PinCompletionSync(queue) { _, _ -> started.complete(Unit); response.await() }
        val original = sync.enqueue("pin", true)
        val replay = async { sync.replayAll { publications++ } }
        started.await()
        val replacement = sync.enqueue("pin", false)
        assertNotEquals(original.id, replacement.id)
        response.complete(Pin("pin", "A", isCompleted = true))
        replay.await()
        assertEquals(0, publications)
        assertEquals(listOf(replacement), PendingWriteRepository(store).list())
    }

    @Test(timeout = 10000) fun frozenPermitRejectsSameIdPayloadFromDifferentVineyardBeforeSend() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        var requests = 0
        val sync = PinCreateSync(queue) { input -> requests++; Pin(requireNotNull(input.id), input.vineyardId) }
        val frozen = sync.enqueue(PinRepository.PinInput("pin", "A"))
        val replacement = queue.upsertCoalesced(PendingEntityType.PIN, "pin",
            json.encodeToString(PinRepository.PinInput.serializer(), PinRepository.PinInput("pin", "B")), PendingOpType.CREATE)
        sync.replayAll(setOf(frozen.id), mapOf(frozen.id to frozen)) { fail("Unpreserved write published") }
        assertEquals(0, requests)
        assertEquals(listOf(replacement), queue.list())
    }

    @Test(timeout = 10000) fun olderCreateAcknowledgementCannotRemoveSameIdReplacement() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Pin>()
        val sync = PinCreateSync(queue) { started.complete(Unit); response.await() }
        val original = sync.enqueue(PinRepository.PinInput("pin", "A", notes = "original"))
        val replay = async { sync.replayAll(setOf(original.id), mapOf(original.id to original)) { fail("Old result published") } }
        started.await()
        val replacement = queue.upsertCoalesced(PendingEntityType.PIN, "pin",
            json.encodeToString(PinRepository.PinInput.serializer(), PinRepository.PinInput("pin", "A", notes = "new")), PendingOpType.CREATE)
        response.complete(Pin("pin", "A"))
        replay.await()
        assertEquals(listOf(replacement), PendingWriteRepository(store).list())
    }

    @Test(timeout = 10000) fun duplicateAcknowledgementAndStaleStatusAreNoOps() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val original = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "{}", "pin")
        val claim = requireNotNull(queue.claimReplay(original))
        assertNull(queue.claimReplay(original))
        assertTrue(queue.removeIfCurrent(claim))
        assertFalse(queue.removeIfCurrent(claim))
        assertFalse(queue.updateStatusIfCurrent(claim, PendingWriteStatus.BLOCKED, "old"))
        assertTrue(queue.list().isEmpty())
    }

    @Test(timeout = 10000) fun retryCapIsAtomicAndReplacementAttemptsAreNotConsumed() {
        val original = PendingWrite("op", PendingEntityType.TRIP_ROW_PLAN, PendingOpType.UPDATE, "{}", "trip", createdAt = 1, updatedAt = 1, attemptCount = 7)
        val store = InMemoryPendingWriteStore(listOf(original))
        val queue = PendingWriteRepository(store)
        val claim = requireNotNull(queue.claimReplay(original))
        assertTrue(queue.retryIfCurrent(claim, "offline"))
        val blocked = PendingWriteRepository(store).list().single()
        assertEquals(8, blocked.attemptCount)
        assertEquals(PendingWriteStatus.BLOCKED, blocked.status)
        assertFalse(queue.retryIfCurrent(claim, "duplicate"))
        assertEquals(blocked, queue.list().single())
    }

    @Test(timeout = 10000) fun tripReplayPublicationKeepsUnrelatedNewerLocalFieldsAndOwnership() {
        val local = before.copy(tripTitle = "new title", completedPaths = listOf(1.5),
            totalDistance = 123.0, activeTankNumber = 3, isFillingTank = true,
            manualCorrectionEvents = listOf("local evidence"))
        val server = before.copy(tripTitle = "confirmed", completedPaths = listOf(2.5), totalDistance = 10.0)
        assertEquals(local.completedPaths, TripReplayPublication.metadata(server, local).completedPaths)
        assertEquals(local.activeTankNumber, TripReplayPublication.metadata(server, local).activeTankNumber)
        assertEquals(local.totalDistance, TripReplayPublication.metadata(server, local).totalDistance)
        assertEquals(local.tripTitle, TripReplayPublication.seeding(server, local).tripTitle)
        assertEquals(local.tripTitle, TripReplayPublication.gps(server, local).tripTitle)
        assertEquals(local.activeTankNumber, TripReplayPublication.rows(server, local).activeTankNumber)
        assertEquals(local.totalDistance, TripReplayPublication.rows(server, local).totalDistance)
        assertEquals(local.manualCorrectionEvents, TripReplayPublication.rows(server, local).manualCorrectionEvents)
        assertEquals(local, TripReplayPublication.tanks(server, local))
        assertEquals(local, TripReplayPublication.metadata(server.copy(vineyardId = "B"), local))
    }

    @Test(timeout = 10000) fun tankMarkerReplacementWhileRequestSuspendsSurvivesRestartWithoutOldCallback() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        queue.configureReplayScope { PendingWriteRepository.ReplayScope("user", 1) }
        val snapshotStorage = object : ActiveTripSnapshotStorage {
            var bytes: String? = null
            override fun read() = bytes
            override fun write(value: String) { bytes = value }
            override fun remove() { bytes = null }
        }
        val active = ActiveTripStore(snapshotStorage)
        val tank = TankSession(id = "tank", tankNumber = 1, startTime = "2026-10-10T00:00:00Z")
        val local = before.copy(tankSessions = listOf(tank), activeTankNumber = 1)
        assertTrue(active.claimIfAvailable("user", "A", local))
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Trip>()
        val sync = TripTankSync(null, queue, active, { before }, { _, _, _, _, _ -> started.complete(Unit); response.await() })
        val original = sync.enqueue(local)
        val replay = async { sync.replayAll { fail("Superseded tank state published") } }
        started.await()
        val ended = local.copy(tankSessions = listOf(tank.copy(endTime = "2026-10-10T00:10:00Z")), activeTankNumber = null)
        active.save("user", "A", ended)
        val replacement = sync.enqueue(ended)
        assertNotEquals(original.id, replacement.id)
        response.complete(local)
        replay.await()
        assertEquals(listOf(replacement), PendingWriteRepository(store).list())
        assertEquals(ended, ActiveTripStore(snapshotStorage).load()?.trip)
    }

    @Test(timeout = 10000) fun accountEpochChangeRejectsOlderAcknowledgementAndStatus() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        var scope = PendingWriteRepository.ReplayScope("account-A", 1)
        queue.configureReplayScope { scope }
        val original = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "{}", "pin")
        val claim = requireNotNull(queue.claimReplay(original))
        scope = PendingWriteRepository.ReplayScope("account-B", 2)
        assertFalse(queue.removeIfCurrent(claim))
        assertFalse(queue.retryIfCurrent(claim, "old account response"))
        assertEquals(listOf(claim), queue.list())
        scope = PendingWriteRepository.ReplayScope("account-A", 3)
        assertFalse(queue.removeIfCurrent(claim))
    }

    @Test(timeout = 10000) fun lateOnlineToggleFallbackCannotCoalesceAwayNewerOfflineIntent() {
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val clock = PinCompletionActionClock()
        val olderOnlineAction = clock.begin("pin")
        val newerOfflineAction = clock.begin("pin")
        val sync = PinCompletionSync(queue) { id, value -> Pin(id, "A", isCompleted = value) }
        val newest = sync.enqueue("pin", false)
        if (clock.isCurrent("pin", olderOnlineAction)) sync.enqueue("pin", true)
        assertFalse(clock.isCurrent("pin", olderOnlineAction))
        assertTrue(clock.isCurrent("pin", newerOfflineAction))
        assertEquals(listOf(newest), PendingWriteRepository(store).list())
        val repeatedBooleanAction = clock.begin("pin")
        assertTrue(clock.isCurrent("pin", repeatedBooleanAction))
        assertFalse(clock.isCurrent("pin", olderOnlineAction))
    }

    @Test(timeout = 10000) fun newerTankActualSurvivesOlderUploadAcknowledgementAndDiskRestart() = runBlocking {
        val directory = Files.createTempDirectory("actual-version").toFile()
        try {
            val file = File(directory, "actuals.json")
            fun store() = SprayTankActualStore(
                { if (file.exists()) file.readText() else null },
                { bytes -> file.writeText(bytes); true },
            )
            val actuals = store()
            val original = SprayTankActual("actual", "A", "spray", "trip", "session", 1,
                waterVolumeL = 100.0, chemicals = emptyList(), confirmedAt = "2026-10-10T00:00:00Z", confirmedBy = "user")
            assertTrue(actuals.save(original))
            val started = CompletableDeferred<Unit>()
            val response = CompletableDeferred<Unit>()
            val replay = async { started.complete(Unit); response.await(); actuals.markSyncedIfCurrent(original) }
            started.await()
            val replacement = original.copy(waterVolumeL = 200.0, clientUpdatedAt = "2026-10-10T00:01:00Z")
            assertTrue(actuals.save(replacement))
            response.complete(Unit)
            assertFalse(replay.await())
            assertEquals(listOf(replacement), store().pending())
            assertTrue(actuals.markSyncedIfCurrent(replacement))
            assertFalse(actuals.markSyncedIfCurrent(replacement))
            assertTrue(store().pending().isEmpty())
            assertEquals(listOf(replacement), store().load())
        } finally { directory.deleteRecursively() }
    }

    @Test(timeout = 10000) fun interruptedTankActualUploadLeavesPendingBytesIntact() = runBlocking {
        var bytes: String? = null
        val actuals = SprayTankActualStore({ bytes }, { bytes = it; true })
        val original = SprayTankActual("actual", "A", "spray", "trip", "session", 1,
            chemicals = emptyList(), confirmedAt = "2026-10-10T00:00:00Z", confirmedBy = "user")
        assertTrue(actuals.save(original))
        val started = CompletableDeferred<Unit>()
        val replay = launch { started.complete(Unit); awaitCancellation(); actuals.markSyncedIfCurrent(original) }
        started.await()
        replay.cancelAndJoin()
        assertEquals(listOf(original), SprayTankActualStore({ bytes }, { bytes = it; true }).pending())
    }

    @Test(timeout = 10000) fun frozenPreservationCannotBeClaimedAfterAccountChangeBeforeLaunch() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        var scope = PendingWriteRepository.ReplayScope("A", 1)
        queue.configureReplayScope { scope }
        val original = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "{}", "pin")
        val versions = queue.freezeReplayVersions(listOf(original))
        scope = PendingWriteRepository.ReplayScope("B", 2)
        assertNull(queue.claimReplay(original, versions))
        assertEquals(listOf(original), queue.list())
    }

    @Test(timeout = 10000) fun failedDurableMutationDoesNotPublishRemoval() {
        val original = PendingWrite("op", PendingEntityType.PIN, PendingOpType.CREATE, "{}", "pin", createdAt = 1, updatedAt = 1)
        val store = object : PendingWriteStoring {
            override fun load() = listOf(original)
            override fun save(writes: List<PendingWrite>) = false
            override fun clear() = false
        }
        val queue = PendingWriteRepository(store)
        assertNull(queue.claimReplay(original))
        assertFalse(queue.removeIfCurrent(original))
        assertEquals(listOf(original), queue.list())
    }
}
