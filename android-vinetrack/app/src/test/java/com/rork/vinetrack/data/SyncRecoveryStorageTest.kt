package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SyncRecoveryStorageTest {
    private val json = Json { encodeDefaults = true }
    private fun evidence(id: String) = PinCaptureEvidenceStore.Evidence(
        pinId = id, vineyardId = "A", tripId = null, buttonName = "Repair", mode = "Repair",
        latitude = 0.0, longitude = 0.0, fixTimeEpochMs = 1, accuracyMetres = 1.0,
        observationTimeIso = "2026-10-14T00:00:00Z", headingDegrees = null, paddockId = null,
        pinRowNumber = null, pinSide = null, snappedLatitude = null, snappedLongitude = null,
        alongRowDistanceMetres = null, snappedToRow = false)
    private fun encode(vararg rows: PinCaptureEvidenceStore.Evidence) =
        json.encodeToString(ListSerializer(PinCaptureEvidenceStore.Evidence.serializer()), rows.toList())

    @Test fun interruptedAtomicSourcesMergeWithoutChangingAnyOriginalBytes() {
        val directory = Files.createTempDirectory("capture-recovery").toFile()
        try {
            val base = File(directory, "evidence")
            val backup = File(directory, "evidence.bak")
            val pending = File(directory, "evidence.new")
            base.writeText(encode(evidence("first")))
            backup.writeText(encode(evidence("first").copy(uploaded = true)))
            pending.writeText(encode(evidence("second")))
            val before = listOf(base, backup, pending).map { it.readBytes().toList() }
            val result = PinCaptureEvidenceStore.readRetainedEvidence(null, listOf(base, backup, pending))
            assertEquals(setOf("first", "second"), result.map { it.pinId }.toSet())
            assertTrue(result.single { it.pinId == "first" }.uploaded)
            assertEquals(before, listOf(base, backup, pending).map { it.readBytes().toList() })
        } finally { directory.deleteRecursively() }
    }

    @Test fun tornAtomicSourceHoldsEvidenceAndRetainsReadableAndUnreadableBytes() {
        val directory = Files.createTempDirectory("capture-torn").toFile()
        try {
            val backup = File(directory, "evidence.bak").apply { writeText(encode(evidence("original"))) }
            val torn = File(directory, "evidence.new").apply { writeText("[{\"pinId\":") }
            val before = listOf(backup.readText(), torn.readText())
            assertTrue(runCatching { PinCaptureEvidenceStore.readRetainedEvidence(null, listOf(backup, torn)) }.isFailure)
            assertEquals(before, listOf(backup.readText(), torn.readText()))
        } finally { directory.deleteRecursively() }
    }

    @Test fun conflictingImmutableObservationIsNotMistakenForAnUploadFlagDifference() {
        val directory = Files.createTempDirectory("capture-conflict").toFile()
        try {
            val source = File(directory, "evidence.bak").apply { writeText(encode(evidence("pin").copy(latitude = 1.0))) }
            val before = source.readText()
            assertTrue(runCatching { PinCaptureEvidenceStore.readRetainedEvidence(encode(evidence("pin")), listOf(source)) }.isFailure)
            assertEquals(before, source.readText())
        } finally { directory.deleteRecursively() }
    }

    private val original = PendingWrite("delete", PendingEntityType.PIN, PendingOpType.DELETE,
        "{\"pinId\":\"pin\"}", "pin", 1, 1, attemptCount = 2, status = PendingWriteStatus.BLOCKED,
        lastError = "This saved change couldn't be linked to a vineyard")
    private val tombstone = PinDeleteSync.DeleteState("pin", "A", "2026-10-01T01:36:00Z")
    private fun photos() = PendingPhotoRepository(File("synthetic-unused"), object : PendingPhotoStoring {
        override fun load() = emptyList<PendingPhotoAttachment>()
        override fun save(attachments: List<PendingPhotoAttachment>) = Unit
        override fun loadCompletedCache() = emptyList<CompletedPhotoCacheEntry>()
        override fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>) = Unit
        override fun clear() = Unit
    })
    private fun queue() = PendingWriteRepository(InMemoryPendingWriteStore().apply { save(listOf(original)) }).apply {
        configureReplayScope { PendingWriteRepository.ReplayScope("owner", 1) }
    }
    private fun gateway(read: suspend () -> PinDeleteSync.DeleteState?) = object : PinDeleteGateway {
        override suspend fun softDeletePin(id: String) { fail("Reconciliation must never write a server delete") }
        override suspend fun readDeleteState(id: String): PinDeleteSync.DeleteState? { assertEquals("pin", id); return read() }
    }

    @Test fun exactAuthorisedPreservedTombstoneRetainsPayloadAndAttemptsAsAcknowledged() = runBlocking {
        val queue = queue()
        var preserved = false
        PinDeleteSync(gateway { tombstone }, queue, photos()).reconcileTombstones { write, state ->
            assertEquals(original, write); assertEquals(tombstone, state); preserved = true
            queue.freezeReplayVersions(listOf(write))
        }
        assertTrue(preserved)
        val result = queue.list().single()
        assertEquals(original.payloadJson, result.payloadJson)
        assertEquals(original.id, result.id)
        assertEquals(original.clientId, result.clientId)
        assertEquals(2, result.attemptCount)
        assertEquals(PendingWriteStatus.SYNCED, result.status)
    }

    @Test fun missingLiveMismatchedAndFailedPreservationTombstonesStayByteForByteHeld() = runBlocking {
        for (state in listOf(null, tombstone.copy(deletedAt = null), tombstone.copy(id = "different"), tombstone)) {
            val queue = queue()
            PinDeleteSync(gateway { state }, queue, photos()).reconcileTombstones { _, _ -> null }
            assertEquals(listOf(original), queue.list())
        }
    }

    @Test fun accountSwitchDuringReadCannotAcknowledgeOriginalHeldDelete() = runBlocking {
        val queue = queue()
        var scope = PendingWriteRepository.ReplayScope("owner", 1)
        queue.configureReplayScope { scope }
        PinDeleteSync(gateway { scope = PendingWriteRepository.ReplayScope("other", 2); tombstone }, queue, photos())
            .reconcileTombstones { _, _ -> fail("Foreign scope reached preservation"); null }
        assertEquals(listOf(original), queue.list())
    }

    @Test fun tombstoneReceiptFalseCommitCannotBecomeDurableFromPreferenceMemory() {
        val values = mutableMapOf<String, String>()
        var durable = false
        val store = RecoverySnapshotStore({ values[it] }, { key, value -> values[key] = value; durable },
            { key, value -> values[key] = value; durable }, mutableMapOf())
        val receipt = RecoverySnapshotStore.TombstoneReceipt("owner", original, tombstone)
        assertFalse(store.preserveTombstone(receipt))
        assertFalse(store.preserveTombstone(receipt))
        durable = true
        assertTrue(store.preserveTombstone(receipt))
        assertEquals(1, values.size)
    }

    @Test fun payloadAndCachedOwnershipConflictHoldsOnlyConflictingWrite() {
        val bad = original.copy(id = "bad", opType = PendingOpType.CREATE, payloadJson = "{\"vineyard_id\":\"B\"}")
        val good = bad.copy(id = "good", clientId = "other", payloadJson = "{\"vineyard_id\":\"A\"}")
        val result = RecoveryPreservation.preserveSelective(listOf(bad, good), emptyMap(), mapOf("pin" to "A"), null) { true }
        assertEquals(setOf("good"), result.permittedWriteIds)
        assertEquals(setOf("bad"), result.unresolvedWriteIds)
    }

    @Test fun failedTerminalAcknowledgementCanRetryButSuspendedClaimCannotBeReclaimed() {
        var failSave = false
        val disk = object : PendingWriteStoring {
            var rows = emptyList<PendingWrite>()
            override fun load() = rows
            override fun save(writes: List<PendingWrite>): Boolean {
                if (failSave) throw java.io.IOException("synthetic full storage")
                rows = writes; return true
            }
            override fun clear() = false
        }
        val queue = PendingWriteRepository(disk)
        val first = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "original", "first")
        val suspended = queue.claimReplay(first)!!
        queue.recoverRetainedClaims()
        assertEquals(suspended, queue.list().single())
        failSave = true
        assertFalse(queue.removeIfCurrent(suspended))
        queue.recoverRetainedClaims()
        assertEquals(suspended, queue.list().single())
        failSave = false
        queue.recoverRetainedClaims()
        val retryable = queue.list().single()
        assertEquals(PendingWriteStatus.FAILED, retryable.status)
        assertEquals(first.payloadJson, retryable.payloadJson)
        assertEquals(0, retryable.attemptCount)
        assertNotNull(queue.claimReplay(retryable))
    }

    @Test fun failedTerminalOutcomesRetainPermissionBlockCapAndExactRetryIncrement() {
        for ((attempts, forbidden) in listOf(0 to false, 7 to false, 2 to true)) {
            var failSave = false
            val initial = original.copy(opType = PendingOpType.CREATE, status = PendingWriteStatus.FAILED, attemptCount = attempts)
            val disk = object : PendingWriteStoring {
                var rows = listOf(initial)
                override fun load() = rows
                override fun save(writes: List<PendingWrite>): Boolean {
                    if (failSave) throw java.io.IOException("synthetic full storage")
                    rows = writes; return true
                }
                override fun clear() = false
            }
            val queue = PendingWriteRepository(disk)
            val claim = queue.claimReplay(initial)!!
            failSave = true
            val reason = if (forbidden) "Permission denied; original retained" else "Transient server failure"
            assertFalse(if (forbidden) queue.updateStatusIfCurrent(claim, PendingWriteStatus.BLOCKED, reason)
                else queue.retryIfCurrent(claim, reason))
            queue.recoverRetainedClaims()
            assertEquals(listOf(claim), disk.rows)
            failSave = false
            queue.recoverRetainedClaims()
            val result = queue.list().single()
            val expectedAttempts = if (forbidden) attempts else attempts + 1
            val expectedStatus = if (forbidden || expectedAttempts >= 8) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
            assertEquals(claim.copy(attemptCount = expectedAttempts, status = expectedStatus,
                lastError = reason, updatedAt = result.updatedAt), result)
            assertEquals(listOf(result), disk.rows)
            queue.recoverRetainedClaims()
            assertEquals(listOf(result), queue.list())
            if (expectedStatus == PendingWriteStatus.BLOCKED) assertNull(queue.claimReplay(result))
        }
    }

    @Test fun unknownEvidenceFieldsHoldOriginalPrimaryAndAllAtomicSources() {
        val directory = Files.createTempDirectory("capture-newer-fields").toFile()
        try {
            val primary = encode(evidence("first")).replace("\"pinId\":", "\"newerImmutableEvidence\":{\"version\":2},\"pinId\":")
            val backup = File(directory, "evidence.bak").apply { writeText(encode(evidence("second"))) }
            val before = backup.readBytes()
            assertTrue(runCatching { PinCaptureEvidenceStore.readRetainedEvidence(primary, listOf(backup)) }.isFailure)
            assertArrayEquals(before, backup.readBytes())
            backup.writeText(primary)
            val unknownBytes = backup.readBytes()
            assertTrue(runCatching { PinCaptureEvidenceStore.readRetainedEvidence(encode(evidence("first")), listOf(backup)) }.isFailure)
            assertArrayEquals(unknownBytes, backup.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun cancellationReturningFromPreservationNeverAcknowledgesTombstone() = runBlocking {
        val queue = queue()
        val replay = launch(start = CoroutineStart.UNDISPATCHED) {
            PinDeleteSync(gateway { tombstone }, queue, photos()).reconcileTombstones { write, _ ->
                val permit = queue.freezeReplayVersions(listOf(write))
                currentCoroutineContext().cancel()
                permit
            }
        }
        replay.join()
        assertTrue(replay.isCancelled)
        assertEquals(listOf(original), queue.list())
    }

    @Test fun evidenceAccountSwitchOrMissingOriginalOwnerCannotUploadOrAcknowledge() = runBlocking {
        var currentOwner = "owner"
        val observations = listOf(evidence("unknown"), evidence("foreign").copy(captureUserId = "other"),
            evidence("first").copy(captureUserId = "owner"), evidence("second").copy(captureUserId = "owner"))
        val uploads = mutableListOf<String>()
        val acknowledgements = mutableListOf<String>()
        replayPinCaptureEvidence(observations, { uploads += it.pinId; currentOwner = "other" },
            { id, _ -> acknowledgements += id; true },
            { currentOwner == "owner" && it.captureUserId == "owner" })
        assertEquals(listOf("first"), uploads)
        assertTrue(acknowledgements.isEmpty())
        assertTrue(observations.none { it.uploaded })
    }

    @Test fun unreadableInitialOutboxHoldsMutationsUntilExactOriginalsCanBeReloaded() {
        var readable = false
        var saves = 0
        val disk = object : PendingWriteStoring {
            var rows = listOf(original.copy(status = PendingWriteStatus.IN_PROGRESS))
            override fun load(): List<PendingWrite> {
                if (!readable) throw java.io.IOException("synthetic read unavailable")
                return rows
            }
            override fun save(writes: List<PendingWrite>): Boolean { saves++; rows = writes; return true }
            override fun clear() = false
        }
        val originalBytes = disk.rows
        val queue = PendingWriteRepository(disk)
        assertNotNull(queue.readIssue.value)
        assertTrue(runCatching { queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "new", "new") }.isFailure)
        queue.recoverRetainedClaims()
        assertEquals(0, saves)
        assertEquals(originalBytes, disk.rows)
        readable = true
        queue.recoverRetainedClaims()
        assertNull(queue.readIssue.value)
        val restored = queue.list().single()
        assertEquals(PendingWriteStatus.FAILED, restored.status)
        assertEquals(originalBytes.single().copy(status = restored.status, lastError = restored.lastError,
            updatedAt = restored.updatedAt), restored)
        assertEquals(listOf(restored), disk.rows)
        assertEquals(1, saves)
    }

    @Test fun decodedSnapshotCacheNeverHidesChangedBytesCorruptionOrOwnership() {
        var raw: String? = null
        val storage = object : ActiveTripSnapshotStorage {
            override fun read() = raw
            override fun write(value: String) { raw = value }
            override fun remove() { raw = null }
        }
        val store = ActiveTripStore(storage)
        store.save("owner", "A", Trip("trip", "A", isActive = true))
        val first = store.load()
        assertSame(first, store.load())
        raw = "unreadable-original"
        assertNull(store.load())
        assertTrue(store.hasActiveClaim())
        assertEquals("unreadable-original", raw)
        raw = json.encodeToString(ActiveTripStore.Snapshot.serializer(),
            ActiveTripStore.Snapshot("foreign", "B", Trip("other", "B"), 2))
        assertEquals("foreign", store.load()?.ownerUserId)
        assertEquals("B", store.load()?.vineyardId)
    }
}
