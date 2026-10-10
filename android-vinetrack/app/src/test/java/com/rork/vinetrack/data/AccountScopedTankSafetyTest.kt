package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import com.rork.vinetrack.data.model.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** Focused persisted source-owner and delayed production coordinator callback acceptance. */
class AccountScopedTankSafetyTest {
    private val server = Trip("trip", "vineyard-A", isActive = true)
    private val local = server.copy(tankSessions = listOf(TankSession("tank", 1,
        startTime = "2026-10-10T00:00:00Z")), activeTankNumber = 1)
    private val actual = SprayTankActual("actual", "vineyard-A", "spray", "trip", "tank", 1,
        waterVolumeL = 123.45, chemicals = emptyList(), confirmedAt = "2026-10-10T00:00:00Z", confirmedBy = "A")

    @Test fun actualNoticeExplainsPendingDependencyAndAcknowledgementWithoutWriting() {
        var raw: String? = null
        val store = SprayTankActualStore({ raw }, { raw = it; true })
        val access = requireNotNull(AuthRetentionGuard({ false }, { true }).captureAccount("A"))
        assertTrue(store.save(actual))
        val before = raw
        assertTrue(requireNotNull(store.syncNotice(access, "vineyard-A") { false }).contains("not yet acknowledged"))
        assertTrue(requireNotNull(store.syncNotice(access, "vineyard-A") { true }).contains("earlier Trip"))
        assertEquals(before, raw)
        val revision = store.syncEvidenceChanges.value
        assertTrue(store.markSyncedIfCurrent(actual))
        assertTrue(store.syncEvidenceChanges.value > revision)
        assertNull(store.syncNotice(access, "vineyard-A") { false })
    }

    @Test fun unknownForeignOrCorrectedActualNoticeNeverDisclosesContent() {
        val access = requireNotNull(AuthRetentionGuard({ false }, { true }).captureAccount("B"))
        for (row in listOf(actual, actual.copy(confirmedBy = ""), actual.copy(correctionVersion = 1))) {
            var raw: String? = null
            val store = SprayTankActualStore({ raw }, { raw = it; true })
            store.save(row)
            val before = raw
            val notice = requireNotNull(store.syncNotice(access, "vineyard-A") { fail("Foreign dependency inspected"); false })
            assertTrue(notice.contains("review"))
            assertFalse(notice.contains("123.45")); assertFalse(notice.contains("vineyard-A")); assertFalse(notice.contains("confirmed_by"))
            assertEquals(before, raw)
        }
    }

    @Test fun corruptActualNoticeIsNotAnEmptySuccessAndLeavesRawBytesUnchanged() {
        val raw = "{broken"
        val store = SprayTankActualStore({ raw }, { fail("Unexpected write"); false })
        val access = requireNotNull(AuthRetentionGuard({ false }, { true }).captureAccount("A"))
        assertTrue(requireNotNull(store.syncNotice(access, "vineyard-A") { false }).contains("couldn't be read"))
        assertFalse(store.hasReadableSyncEvidence())
    }

    @Test(timeout = 10000) fun foreignSnapshotRefusedBeforeClaimProbeOrSendAcrossRestart() = runBlocking {
        val root = Files.createTempDirectory("tank-owner").toFile()
        try {
            val file = File(root, "snapshot")
            fun snapshots() = ActiveTripStore(object : ActiveTripSnapshotStorage {
                override fun read() = if (file.exists()) file.readText() else null
                override fun write(value: String) = commitReviewBytes(file, value.toByteArray())
                override fun remove() { file.delete() }
            })
            snapshots().save("A", "vineyard-A", local)
            val queueFile = File(root, "queue")
            TripTankSync(null, PendingWriteRepository(ReviewWriteDisk(queueFile)), snapshots()).enqueue(local)
            val before = queueFile.readBytes()
            val snapshotBefore = file.readBytes()
            for (owner in listOf("B", "")) {
                val queue = PendingWriteRepository(ReviewWriteDisk(queueFile))
                queue.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 2) }
                var probes = 0
                var sends = 0
                TripTankSync(null, queue, snapshots(), { probes++; server }, { _, _, _, _, _ -> sends++; local })
                    .replayAll(queue.freezeReplayVersions(queue.list())) { fail("Foreign publication") }
                assertEquals(0, probes); assertEquals(0, sends)
                assertArrayEquals(before, queueFile.readBytes())
                assertArrayEquals(snapshotBefore, file.readBytes())
            }
            val returning = PendingWriteRepository(ReviewWriteDisk(queueFile))
            returning.configureReplayScope { PendingWriteRepository.ReplayScope("A", 3) }
            var published = 0
            TripTankSync(null, returning, snapshots(), { server }, { _, _, _, _, _ -> local })
                .replayAll { published++ }
            assertEquals(1, published)
            assertTrue(returning.list().isEmpty())
            assertArrayEquals(snapshotBefore, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun absentCorruptOrMismatchedSnapshotNeverConsumesMarker() = runBlocking {
        for (raw in listOf<String?>(null, "{broken", "")) {
            val store = object : ActiveTripSnapshotStorage {
                override fun read() = raw
                override fun write(value: String) { fail("Source changed") }
                override fun remove() { fail("Source deleted") }
            }
            val queue = PendingWriteRepository(InMemoryPendingWriteStore())
            queue.configureReplayScope { PendingWriteRepository.ReplayScope("A", 1) }
            val sync = TripTankSync(null, queue, ActiveTripStore(store), { fail("Probe"); null }, { _, _, _, _, _ -> error("Send") })
            val original = sync.enqueue(local)
            sync.replayAll { fail("Publish") }
            assertEquals(listOf(original), queue.list())
        }
    }

    @Test(timeout = 10000) fun revokedTripResponseKeepsExactClaimAndNeverPublishes() = runBlocking {
        val root = Files.createTempDirectory("tank-late").toFile()
        try {
            val guard = AuthRetentionGuard({ false }, { true })
            var user: String? = "A"
            val access = requireNotNull(guard.captureAccount(user))
            var epoch = 1L
            val queueFile = File(root, "queue")
            val queue = PendingWriteRepository(ReviewWriteDisk(queueFile))
            queue.configureReplayScope { user?.takeIf { !guard.isLocked }?.let { PendingWriteRepository.ReplayScope(it, epoch) } }
            var snapshot: String? = null
            val active = ActiveTripStore(object : ActiveTripSnapshotStorage {
                override fun read() = snapshot
                override fun write(value: String) { snapshot = value }
                override fun remove() { snapshot = null }
            })
            active.save("A", "vineyard-A", local)
            val started = CompletableDeferred<Unit>()
            val response = CompletableDeferred<Trip>()
            val sync = TripTankSync(null, queue, active, { server }, { _, _, _, _, _ -> started.complete(Unit); response.await() })
            sync.enqueue(local)
            val job = async { sync.replayAll(accountAccess = access,
                withAccountAccess = { action -> guard.withAccount(access, { user }, action) }) { fail("Late publication") } }
            started.await()
            val claimed = queueFile.readBytes()
            guard.rejectSession { user = null }; epoch++
            user = "B"
            response.complete(local)
            job.await()
            assertArrayEquals(claimed, queueFile.readBytes())
            assertEquals(local, active.load()?.trip)
            assertEquals(PendingWriteStatus.IN_PROGRESS, PendingWriteRepository(ReviewWriteDisk(queueFile)).list().single().status)
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun actualSuccessAfterRevocationRetainsFrozenValuesAndPendingAcrossRestart() = runBlocking {
        val root = Files.createTempDirectory("actual-late").toFile()
        try {
            val file = File(root, "actuals")
            fun store() = SprayTankActualStore({ if (file.exists()) file.readText() else null },
                { commitReviewBytes(file, it.toByteArray()); true })
            val guard = AuthRetentionGuard({ false }, { true })
            var user: String? = "A"
            val access = requireNotNull(guard.captureAccount(user))
            val actuals = store()
            actuals.configureAccountAccess { guard.captureAccount(user) }
            assertTrue(actuals.save(actual))
            val bytes = file.readBytes()
            val started = CompletableDeferred<Unit>()
            val response = CompletableDeferred<Unit>()
            val sync = ScopedTankActualSync(actuals,
                { owner, action -> guard.withAccount(owner, { user }, action) },
                { sent, owner -> assertEquals(actual, sent); assertEquals(access, owner); started.complete(Unit); response.await() },
                { _, _ -> fail("Fetch after revocation"); emptyList() })
            val job = async { sync.replay(access, "vineyard-A", { false }, { true }) }
            started.await()
            guard.rejectSession { user = null }; user = "B"
            response.complete(Unit); job.await()
            assertArrayEquals(bytes, file.readBytes())
            assertEquals(listOf(actual), store().pending())
            assertEquals(123.45, store().pending().single().waterVolumeL!!, 0.0)
            assertTrue(store().pendingOwned(requireNotNull(AuthRetentionGuard({ false }, { true }).captureAccount("B"))).isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun actualReplacementIsNotAcknowledgedByEarlierSuccess() = runBlocking {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        val access = requireNotNull(guard.captureAccount("A"))
        store.configureAccountAccess { access }
        assertTrue(store.save(actual))
        val started = CompletableDeferred<Unit>(); val response = CompletableDeferred<Unit>()
        val sync = ScopedTankActualSync(store, { owner, action -> guard.withAccount(owner, { "A" }, action) },
            { _, _ -> started.complete(Unit); response.await() }, { _, _ -> emptyList() })
        val job = async { sync.replay(access, null, { false }, { true }) }
        started.await()
        val replacement = actual.copy(waterVolumeL = 234.56, clientUpdatedAt = "2026-10-10T01:00:00Z")
        assertTrue(store.save(replacement))
        response.complete(Unit); job.await()
        assertEquals(listOf(replacement), store.pending())
    }

    @Test(timeout = 10000) fun delayedRemoteActualsCannotMergeAfterRevocation() = runBlocking {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        var user: String? = "A"
        val access = requireNotNull(guard.captureAccount(user))
        val started = CompletableDeferred<Unit>(); val response = CompletableDeferred<List<SprayTankActual>>()
        val sync = ScopedTankActualSync(store, { owner, action -> guard.withAccount(owner, { user }, action) },
            { _, _ -> fail("Upload") }, { _, _ -> started.complete(Unit); response.await() })
        val job = async { sync.replay(access, "vineyard-A", { false }, { true }) }
        started.await(); guard.rejectSession { user = null }; user = "B"
        response.complete(listOf(actual)); job.await()
        assertNull(bytes); assertTrue(store.load().isEmpty())
    }

    @Test(timeout = 10000) fun authorlessOrLaterCorrectedActualsAreNotAdoptedFromConfirmedBy() = runBlocking {
        for (unproven in listOf(actual.copy(confirmedBy = ""), actual.copy(correctionVersion = 1),
            actual.copy(clientUpdatedAt = "2026-10-10T01:00:00Z"))) {
        var bytes: String? = null
        val original = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertTrue(original.save(unproven))
        val guard = AuthRetentionGuard({ false }, { true })
        val access = requireNotNull(guard.captureAccount("A"))
        val recreated = SprayTankActualStore({ bytes }, { bytes = it; true })
        recreated.configureAccountAccess { access }
        val before = bytes
        ScopedTankActualSync(recreated, { owner, action -> guard.withAccount(owner, { "A" }, action) },
            { _, _ -> fail("Unproven upload") }, { _, _ -> emptyList() })
            .replay(access, null, { false }, { true })
        assertEquals(before, bytes); assertEquals(listOf(unproven), recreated.pending())
        }
    }

    @Test(timeout = 10000) fun unchangedOriginalConfirmationReplaysForReturningActorAfterRestart() = runBlocking {
        var bytes: String? = null
        val original = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertTrue(original.save(actual))
        val recreated = SprayTankActualStore({ bytes }, { bytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        val owner = requireNotNull(guard.captureAccount("A"))
        val foreign = requireNotNull(guard.captureAccount("B"))
        assertTrue(recreated.pendingOwned(foreign).isEmpty())
        var uploads = 0
        ScopedTankActualSync(recreated, { access, action -> guard.withAccount(access, { "A" }, action) },
            { sent, access -> assertEquals(actual, sent); assertEquals(owner, access); uploads++ }, { _, _ -> emptyList() })
            .replay(owner, null, { false }, { true })
        assertEquals(1, uploads)
        assertTrue(recreated.pending().isEmpty())
        assertEquals(listOf(actual), recreated.load())
    }

    @Test(timeout = 10000) fun corruptActualEvidenceIsHeldWithoutFetchMergeOrReset() = runBlocking {
        var bytes: String? = "{corrupt"
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        val owner = requireNotNull(guard.captureAccount("A"))
        ScopedTankActualSync(store, { access, action -> guard.withAccount(access, { "A" }, action) },
            { _, _ -> fail("Upload corrupt evidence") }, { _, _ -> fail("Fetch over corrupt evidence"); emptyList() })
            .replay(owner, "vineyard-A", { false }, { true })
        assertEquals("{corrupt", bytes)
    }

    @Test(timeout = 10000) fun sameVineyardRemoteCorrectionCannotConsumeAnotherActorsPendingActual() = runBlocking {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        assertTrue(store.save(actual))
        val before = bytes
        val guard = AuthRetentionGuard({ false }, { true })
        val foreign = requireNotNull(guard.captureAccount("B"))
        ScopedTankActualSync(store, { access, action -> guard.withAccount(access, { "B" }, action) },
            { _, _ -> fail("Foreign upload") }, { _, _ -> listOf(actual.copy(correctionVersion = 2, waterVolumeL = 999.0)) })
            .replay(foreign, "vineyard-A", { false }, { true })
        assertEquals(before, bytes)
        assertEquals(listOf(actual), store.pending())
    }

    @Test fun revocationBetweenSaveAdmissionAndCommitCannotWriteAnActual() {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        val admitted = requireNotNull(guard.captureAccount("A"))
        store.configureAccountAccess {
            guard.rejectSession { }
            admitted
        }
        assertFalse(store.save(actual))
        assertNull(bytes)
    }

    @Test(timeout = 10000) fun serverVineyardConflictBlocksExactClaimWithoutStrandingOrSending() = runBlocking {
        var snapshot: String? = null
        val active = ActiveTripStore(object : ActiveTripSnapshotStorage {
            override fun read() = snapshot
            override fun write(value: String) { snapshot = value }
            override fun remove() { snapshot = null }
        })
        active.save("A", "vineyard-A", local)
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        queue.configureReplayScope { PendingWriteRepository.ReplayScope("A", 1) }
        val sync = TripTankSync(null, queue, active, { server.copy(vineyardId = "vineyard-B") },
            { _, _, _, _, _ -> error("Conflicting target was patched") })
        val original = sync.enqueue(local)
        sync.replayAll { fail("Conflicting target was published") }
        val held = queue.list().single()
        assertEquals(original.id, held.id)
        assertEquals(original.payloadJson, held.payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, held.status)
        assertEquals(0, held.attemptCount)
        assertTrue(held.lastError!!.contains("retained for review"))
    }

    @Test fun authenticatedIdentityAloneCannotUnlockLegacyHoldOrReuseOldIncarnation() {
        val locked = AuthRetentionGuard({ true }, { true })
        assertNull(locked.captureAccount("verified-original-account"))
        assertFalse(locked.canSignOut())
        val old = AuthRetentionGuard({ false }, { true })
        val access = requireNotNull(old.captureAccount("A"))
        val restarted = AuthRetentionGuard({ false }, { true })
        assertFalse(restarted.withAccount(access, { "A" }) { fail("Reused old incarnation") })
        assertFalse(old.withAccount(access, { "B" }) { fail("Rebound original account") })
    }
}
