package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningYieldSettings
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `pruning_yield_settings` under the sql/198 revision contract.
 *
 * Drives the REAL replay loop ([PruningYieldSettingsSync]) over the real outbox
 * ([PendingWriteRepository]) against a fake server that arbitrates purely on `server_revision`
 * and never on a clock. A test in this file cannot pass because two timestamps happened to
 * line up.
 *
 * What is at stake: these are the grower's per-block yield assumptions. Losing them silently
 * — the pre-sql/198 behaviour — means a harvest forecast built on numbers nobody typed.
 *
 * Mirrored on iOS by `PruningRevisionSyncTests.swift`.
 */
class PruningYieldSettingsRevisionSyncTest {

    // ------------------------------------------------------------------
    // Fake server — revision-authoritative, clock-blind
    // ------------------------------------------------------------------

    /**
     * In-memory stand-in for `public.pruning_yield_settings` under sql/198.
     *
     * Keyed on (vineyard_id, paddock_id) like the real unique index, so two devices that
     * minted different row ids for one block converge on a single record — the upsert target
     * that makes this entity different from the others.
     */
    private class RevisionServer : PruningYieldSettingsWriting {
        val rows = mutableMapOf<String, PruningYieldSettings>()
        val baseRevisionsSent = mutableListOf<Long?>()
        val clientStampsSent = mutableListOf<String>()
        var writeCalls = 0
        var failNextWith: Exception? = null
        var returnEmptyRepresentationNext = false

        override suspend fun upsertSettings(
            settings: PruningYieldSettings,
            clientUpdatedAt: String,
        ): VersionedWriteOutcome<PruningYieldSettings> {
            writeCalls++
            failNextWith?.let { failNextWith = null; throw it }
            baseRevisionsSent += settings.serverRevision
            clientStampsSent += clientUpdatedAt
            if (returnEmptyRepresentationNext) {
                returnEmptyRepresentationNext = false
                // 2xx with an empty representation: the legacy silent-skip signature.
                return VersionedWriteOutcome.Conflict(settings.id, settings.serverRevision, null)
            }
            val key = key(settings.vineyardId, settings.paddockId)
            val existing = rows[key]
            if (existing != null && settings.serverRevision != existing.serverRevision) {
                return VersionedWriteOutcome.Conflict(
                    rowId = settings.id,
                    baseRevision = settings.serverRevision,
                    serverRevision = existing.serverRevision,
                )
            }
            val stored = settings.copy(
                id = existing?.id ?: settings.id,
                serverRevision = (existing?.serverRevision ?: 0L) + 1L,
            )
            rows[key] = stored
            return VersionedWriteOutcome.Applied(stored)
        }

        /** Another device or the portal saves over the block, advancing the revision. */
        fun writeAsOtherDevice(vineyardId: String, paddockId: String, bunchWeight: Double) {
            val key = key(vineyardId, paddockId)
            val existing = rows[key] ?: return
            rows[key] = existing.copy(
                bunchWeightGrams = bunchWeight,
                serverRevision = (existing.serverRevision ?: 0L) + 1L,
            )
        }

        /** Seeds the block exactly as a pre-sql/198 client left it: no revision at all. */
        fun seedLegacyRow(settings: PruningYieldSettings) {
            rows[key(settings.vineyardId, settings.paddockId)] = settings.copy(serverRevision = null)
        }

        fun stored(vineyardId: String, paddockId: String): PruningYieldSettings =
            rows.getValue(key(vineyardId, paddockId))

        private fun key(vineyardId: String, paddockId: String) = "$vineyardId|$paddockId"
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val block = "22222222-2222-4222-8222-222222222222"

    /** An honest, server-clamped stamp. */
    private val serverTime = "2026-08-17T02:00:00Z"

    /** Device clock six hours BEHIND: the case that silently lost edits under sql/185. */
    private val slowClockTime = "2026-08-16T20:00:00Z"

    /** Device clock eight hours AHEAD: the case that poisoned a row against later writers. */
    private val fastClockTime = "2026-08-17T10:00:00Z"

    private fun settings(
        id: String = "33333333-3333-4333-8333-333333333333",
        bunchWeightGrams: Double = 120.0,
        vinesPerHa: Double? = 2200.0,
        serverRevision: Long? = null,
    ) = PruningYieldSettings(
        id = id,
        vineyardId = vineyard,
        paddockId = block,
        pruneMethod = "spur",
        bunchesPerBud = 1.5,
        budsPerSpur = 2.0,
        spursPerVine = 6.0,
        budsPerCane = 10.0,
        canesPerVine = 4.0,
        vinesPerHa = vinesPerHa,
        bunchWeightGrams = bunchWeightGrams,
        serverRevision = serverRevision,
    )

    private fun outbox() = PendingWriteRepository(InMemoryPendingWriteStore())

    private fun sync(server: RevisionServer, pending: PendingWriteRepository) =
        PruningYieldSettingsSync(server, pending)

    /** Replays and returns whatever the server acknowledged. */
    private suspend fun replay(
        sync: PruningYieldSettingsSync,
    ): MutableList<PruningYieldSettings> {
        val applied = mutableListOf<PruningYieldSettings>()
        sync.replayAll { applied += it }
        return applied
    }

    private fun statuses(pending: PendingWriteRepository): List<String> =
        pending.list().map { it.status }

    // ==================================================================
    // 1. Successful current-version edit
    // ==================================================================

    @Test
    fun `a create sends no base revision and adopts the server issued one`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)

        queue.enqueue(settings(), serverTime)
        val applied = replay(queue)

        assertNull("a create must not assert a base revision", server.baseRevisionsSent.single())
        assertEquals(1, applied.size)
        assertEquals(
            "the server-issued revision is the only source of truth",
            1L,
            applied.single().serverRevision,
        )
        assertEquals("an applied write leaves the outbox clean", 0, pending.list().size)
    }

    @Test
    fun `an edit at the current revision succeeds and advances it`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()
        assertEquals(1L, created.serverRevision)

        // Loaded at revision N, written with base_revision = N.
        queue.enqueue(created.copy(bunchWeightGrams = 135.0), serverTime)
        val edited = replay(queue).single()

        assertEquals("must send the revision it READ", 1L, server.baseRevisionsSent.last())
        assertEquals(
            "the authoritative revision comes back from the server, never local+1 arithmetic",
            2L,
            edited.serverRevision,
        )
        assertEquals(135.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals(0, pending.list().size)
    }

    // ==================================================================
    // 2 & 3. Clock skew — the entire reason for the migration
    // ==================================================================

    @Test
    fun `a device hours BEHIND the server still saves`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()

        // The honest edit is stamped SIX HOURS EARLIER than the row it is replacing. Under
        // the timestamp contract this was discarded while the app reported success.
        queue.enqueue(created.copy(bunchWeightGrams = 150.0), slowClockTime)
        val edited = replay(queue).single()

        assertEquals(2L, edited.serverRevision)
        assertEquals(150.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals("a slow clock must not manufacture a conflict", 0, pending.list().size)
        assertFalse(statuses(pending).contains(PendingWriteStatus.CONFLICT))
    }

    @Test
    fun `a device hours AHEAD does not lock out the next honest writer`() = runBlocking {
        val server = RevisionServer()
        val fastPending = outbox()
        val fastQueue = sync(server, fastPending)

        // Fast device parks a far-future client_updated_at on the block.
        fastQueue.enqueue(settings(), fastClockTime)
        val poisoned = replay(fastQueue).single()
        assertEquals(1L, poisoned.serverRevision)

        // A second device with a correct clock edits from the current revision. Under sql/185
        // this write looked stale for eight hours; under sql/198 the clock is irrelevant.
        val normalPending = outbox()
        val normalQueue = sync(server, normalPending)
        normalQueue.enqueue(poisoned.copy(bunchWeightGrams = 111.0), serverTime)
        val edited = replay(normalQueue).single()

        assertEquals("the fast clock must not block this write", 2L, edited.serverRevision)
        assertEquals(111.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals(0, normalPending.list().size)
    }

    // ==================================================================
    // 4, 5, 6. Genuine stale write, outbox retention, no blind retry
    // ==================================================================

    @Test
    fun `a genuinely stale write conflicts and is never reported as saved`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()

        // Another device saves: the block is now at revision 2, this device still holds 1.
        server.writeAsOtherDevice(vineyard, block, bunchWeight = 99.0)

        queue.enqueue(created.copy(bunchWeightGrams = 175.0), serverTime)
        val applied = replay(queue)

        assertTrue("a refused write must not be acknowledged as applied", applied.isEmpty())
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(pending))
        assertEquals(
            "the server's value must not be silently overwritten",
            99.0,
            server.stored(vineyard, block).bunchWeightGrams,
            0.0001,
        )
    }

    @Test
    fun `a conflict retains the authored values in the outbox`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()
        server.writeAsOtherDevice(vineyard, block, bunchWeight = 99.0)

        queue.enqueue(created.copy(bunchWeightGrams = 175.0, vinesPerHa = 2500.0), serverTime)
        replay(queue)

        // The grower's numbers exist on this device and NOWHERE else. Dropping the row is the
        // silent data loss the revision contract exists to end.
        val write = pending.list().single()
        assertEquals(PendingWriteStatus.CONFLICT, write.status)
        assertTrue(write.payloadJson.contains("175"))
        assertTrue("vines/ha must survive too", write.payloadJson.contains("2500"))
        assertNotNull("a conflict must explain itself", write.lastError)
        assertEquals(
            "a conflicted write still counts as waiting to sync",
            1,
            pending.currentPendingCount(),
        )
    }

    @Test
    fun `a conflicted write is never blindly replayed`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()
        server.writeAsOtherDevice(vineyard, block, bunchWeight = 99.0)
        queue.enqueue(created.copy(bunchWeightGrams = 175.0), serverTime)
        replay(queue)
        val callsAfterConflict = server.writeCalls

        // Three further passes. Replaying would resend the same stale base_revision and be
        // refused every single time — a loop that burns battery and can never converge.
        replay(queue)
        replay(queue)
        replay(queue)

        assertEquals(
            "CONFLICT must be excluded from the retry set",
            callsAfterConflict,
            server.writeCalls,
        )
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(pending))
        assertEquals(0, pending.retryEligibleCount())
        assertEquals(
            "a user-triggered Retry all must not resurrect it either",
            0,
            pending.resetFailedForRetry(),
        )
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(pending))
    }

    // ==================================================================
    // 7. A network failure must stay a network failure
    // ==================================================================

    @Test
    fun `transport auth and server failures stay retryable and distinct from a conflict`() =
        runBlocking {
            val server = RevisionServer()
            val pending = outbox()
            val queue = sync(server, pending)

            // Transport failure -> FAILED (retryable), NOT conflict.
            server.failNextWith = IllegalStateException("No connection.")
            queue.enqueue(settings(), serverTime)
            replay(queue)
            assertEquals(listOf(PendingWriteStatus.FAILED), statuses(pending))
            assertEquals(1, pending.retryEligibleCount())

            // 5xx -> FAILED (retryable).
            server.failNextWith = BackendError.Server(503, "upstream unavailable")
            pending.resetFailedForRetry()
            replay(queue)
            assertEquals(listOf(PendingWriteStatus.FAILED), statuses(pending))

            // Expired session -> FAILED (retryable once signed in again).
            server.failNextWith = BackendError.Unauthorized
            pending.resetFailedForRetry()
            replay(queue)
            assertEquals(listOf(PendingWriteStatus.FAILED), statuses(pending))

            // A 4xx that is NOT a revision conflict -> BLOCKED, never CONFLICT: no second
            // version exists, so telling the grower to compare two copies would be a lie.
            server.failNextWith = BackendError.Server(422, "invalid payload")
            pending.resetFailedForRetry()
            replay(queue)
            assertEquals(listOf(PendingWriteStatus.BLOCKED), statuses(pending))

            // Then it finally lands, proving none of the above dropped the payload.
            pending.list().forEach { pending.updateStatus(it.id, PendingWriteStatus.PENDING) }
            val applied = replay(queue)
            assertEquals(1, applied.size)
            assertEquals(1L, applied.single().serverRevision)
        }

    @Test
    fun `an empty 2xx representation is treated as a conflict and not as success`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        server.returnEmptyRepresentationNext = true

        queue.enqueue(settings(bunchWeightGrams = 168.0), serverTime)
        val applied = replay(queue)

        assertTrue("a silent skip is not a save", applied.isEmpty())
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(pending))
        assertTrue(pending.list().single().payloadJson.contains("168"))
    }

    // ==================================================================
    // 8. Legacy rows
    // ==================================================================

    @Test
    fun `a block last written by an old client stays readable and editable`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        // Pre-sql/198 row: no revision. Legitimate migrated state, never corruption.
        server.seedLegacyRow(settings(bunchWeightGrams = 118.0))
        assertNull(server.stored(vineyard, block).serverRevision)

        // A new client edits it, correctly sending NO base_revision (it has never been
        // issued one). Fabricating a number here would either be refused forever or match by
        // luck and overwrite an edit this device never saw.
        queue.enqueue(settings(bunchWeightGrams = 126.0, serverRevision = null), serverTime)
        val applied = replay(queue)

        assertNull(server.baseRevisionsSent.single())
        assertEquals(1, applied.size)
        assertEquals(
            "the first versioned write brings a legacy row onto the contract",
            1L,
            applied.single().serverRevision,
        )
        assertEquals(126.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals(0, pending.list().size)
    }

    @Test
    fun `a settings row cached by an older build decodes without a revision`() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val legacy = """
            {"id":"33333333-3333-4333-8333-333333333333",
             "vineyard_id":"$vineyard","paddock_id":"$block",
             "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
             "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
             "vines_per_ha":2200.0,"bunch_weight_grams":120.0}
        """.trimIndent()

        val decoded = json.decodeFromString(PruningYieldSettings.serializer(), legacy)

        assertNull("a missing revision must decode, not throw", decoded.serverRevision)
        assertEquals(120.0, decoded.bunchWeightGrams, 0.0001)
    }

    // ==================================================================
    // Requirement 2 — client_updated_at is still legitimate METADATA
    // ==================================================================

    @Test
    fun `client_updated_at is still sent verbatim so soft delete resurrection keeps working`() =
        runBlocking {
            val server = RevisionServer()
            val pending = outbox()
            val queue = sync(server, pending)

            // sql/181's resurrection trigger un-deletes a block's settings when a genuine
            // client upsert arrives, and detects "genuine" from a CHANGE in this value. That
            // is change DETECTION, not ordering — demoting timestamps as the concurrency
            // authority must not strip the field or collapse it to a constant.
            queue.enqueue(settings(), "2026-08-17T02:00:00Z")
            val created = replay(queue).single()
            queue.enqueue(created.copy(bunchWeightGrams = 130.0), "2026-08-17T03:30:00Z")
            replay(queue)

            assertEquals(
                listOf("2026-08-17T02:00:00Z", "2026-08-17T03:30:00Z"),
                server.clientStampsSent,
            )
            assertNotEquals(
                "two distinct saves must present two distinct stamps",
                server.clientStampsSent[0],
                server.clientStampsSent[1],
            )
        }

    @Test
    fun `an offline replay presents the ORIGINAL edit time not the time of the replay`() =
        runBlocking {
            val server = RevisionServer()
            val pending = outbox()
            val queue = sync(server, pending)

            // Queued at 02:00 while offline; replayed much later. The stamp must still say
            // when the grower actually typed it — that is the whole point of the field now
            // that it no longer arbitrates anything.
            queue.enqueue(settings(), "2026-08-17T02:00:00Z")
            replay(queue)

            assertEquals("2026-08-17T02:00:00Z", server.clientStampsSent.single())
        }

    // ==================================================================
    // Requirement 3 — conflict persistence across a restart
    // ==================================================================

    @Test
    fun `a pruning conflict survives an app restart and still does not auto retry`() = runBlocking {
        val server = RevisionServer()
        val store = InMemoryPendingWriteStore()
        val firstRun = PendingWriteRepository(store)
        val firstQueue = sync(server, firstRun)
        firstQueue.enqueue(settings(), serverTime)
        val created = replay(firstQueue).single()
        server.writeAsOtherDevice(vineyard, block, bunchWeight = 99.0)
        firstQueue.enqueue(created.copy(bunchWeightGrams = 175.0), serverTime)
        replay(firstQueue)
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(firstRun))

        // App killed. A brand-new repository over the SAME persisted store.
        val secondRun = PendingWriteRepository(store)
        val secondQueue = sync(server, secondRun)

        // The authored payload is still here...
        val restored = secondRun.list().single()
        assertEquals(PendingWriteStatus.CONFLICT, restored.status)
        assertTrue("the grower's authored value must survive the process dying", restored.payloadJson.contains("175"))
        assertEquals(1, secondRun.currentPendingCount())

        // ...the repository still knows it is conflicted, not merely "pending"...
        assertEquals(0, secondRun.retryEligibleCount())

        // ...and a replay pass after the restart still refuses to resend it.
        val callsBefore = server.writeCalls
        replay(secondQueue)
        assertEquals("no automatic retry after a restart", callsBefore, server.writeCalls)
        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(secondRun))

        // The server's current copy remains fetchable — the deterministic re-fetch half of
        // the documented pruning behaviour (the local copy is stored, the server copy is read
        // back on demand rather than being frozen beside it).
        assertEquals(99.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals(2L, server.stored(vineyard, block).serverRevision)
    }

    // ==================================================================
    // Requirement 8 — timestamps must never decide the winner
    // ==================================================================

    @Test
    fun `a NEWER clock with a stale revision still conflicts`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()
        server.writeAsOtherDevice(vineyard, block, bunchWeight = 99.0)

        // Deliberate temptation: the local stamp is far NEWER than anything the server has.
        // If any code path compared timestamps it would let this through and destroy the
        // other device's save.
        queue.enqueue(created.copy(bunchWeightGrams = 175.0), "2099-01-01T00:00:00Z")
        replay(queue)

        assertEquals(listOf(PendingWriteStatus.CONFLICT), statuses(pending))
        assertEquals(99.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
    }

    @Test
    fun `an OLDER clock with a current revision still succeeds`() = runBlocking {
        val server = RevisionServer()
        val pending = outbox()
        val queue = sync(server, pending)
        queue.enqueue(settings(), serverTime)
        val created = replay(queue).single()

        // The mirror-image temptation: an ancient stamp on a perfectly current edit.
        queue.enqueue(created.copy(bunchWeightGrams = 175.0), "1999-01-01T00:00:00Z")
        val applied = replay(queue)

        assertEquals(1, applied.size)
        assertEquals(2L, applied.single().serverRevision)
        assertEquals(175.0, server.stored(vineyard, block).bunchWeightGrams, 0.0001)
        assertEquals(0, pending.list().size)
    }
}
