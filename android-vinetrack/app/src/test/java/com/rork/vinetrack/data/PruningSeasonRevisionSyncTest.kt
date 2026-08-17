package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningSeasonIds
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `pruning_seasons` under the sql/198 revision contract.
 *
 * The season write path is HTTP-shaped, so these tests drive the two production pieces that
 * actually make the decisions — the shared classifier that turns a response into an outcome,
 * and the real `SeasonRow` / `SeasonUpsert` codecs — using canonical PostgREST payloads. The
 * queue half asserts the same conflict semantics the replay coordinator applies.
 *
 * Nothing here compares a timestamp, because nothing in the production path is allowed to.
 *
 * Mirrored on iOS by `PruningRevisionSyncTests.swift`.
 */
class PruningSeasonRevisionSyncTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val block = "22222222-2222-4222-8222-222222222222"
    private val seasonId: String get() = PruningSeasonIds.make(vineyard, block, 2026)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val serverTime = "2026-08-17T02:00:00Z"
    private val slowClockTime = "2026-08-16T20:00:00Z"
    private val fastClockTime = "2026-08-17T10:00:00Z"

    private fun setup(serverRevision: Long? = null, crew: String = "Crew A") = PruningBlockSetup(
        id = seasonId,
        vineyardId = vineyard,
        paddockId = block,
        seasonYear = 2026,
        startDate = "2026-07-01",
        dueDate = "2026-09-15",
        method = "spur",
        crew = crew,
        estimatedLabourHours = 48.0,
        notes = "north end first",
        serverRevision = serverRevision,
    )

    /** A canonical PostgREST representation of a stored season at a given revision. */
    private fun seasonRowJson(revision: Long?, crew: String = "Crew A"): String {
        val revisionField = if (revision == null) "" else ""","server_revision":$revision"""
        return """
            [{"id":"$seasonId","vineyard_id":"$vineyard","paddock_id":"$block",
              "season_year":2026,"start_date":"2026-07-01","due_date":"2026-09-15",
              "pruning_method":"spur","assigned_crew":"$crew","working_days":[1,2,3,4,5],
              "manual_row_count":null,"estimated_labour_hours":48.0,
              "notes":"north end first","status":"active","deleted_at":null,
              "updated_at":"2026-08-17T02:00:00Z"$revisionField}]
        """.trimIndent()
    }

    /** The sql/198 refusal body, exactly as `reject_stale_client_write()` raises it. */
    private fun conflictBody(serverRevision: Long, baseRevision: Long): String =
        """{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"table\": \"pruning_seasons\", \"server_revision\": $serverRevision, \"base_revision\": $baseRevision}","hint":"Reload the row and reapply the change","message":"REVISION_CONFLICT"}"""

    /** Runs a season write response through the REAL production classification. */
    private fun classify(
        setup: PruningBlockSetup,
        status: Int,
        body: String?,
    ): VersionedWriteOutcome<PruningBlockSetup> =
        com.rork.vinetrack.data.sync.VersionedWriteClassifier.classify(
            rowId = setup.id,
            baseRevision = setup.serverRevision,
            status = status,
            body = body,
        ) { text ->
            runCatching {
                json.decodeFromString<List<PruningSyncRepository.SeasonRow>>(text)
            }.getOrDefault(emptyList()).firstOrNull()?.toModel()
        }

    private fun upsertJson(setup: PruningBlockSetup, clientUpdatedAt: String): String =
        json.encodeToString(
            PruningSyncRepository.SeasonUpsert.serializer(),
            PruningSyncRepository.SeasonUpsert.from(setup, clientUpdatedAt, createdBy = null),
        )

    // ==================================================================
    // 1. Successful current-version edit
    // ==================================================================

    @Test
    fun `an edit at the current revision is applied and adopts the returned revision`() {
        val local = setup(serverRevision = 4L)

        // base_revision = N is what goes out...
        assertTrue(upsertJson(local, serverTime).contains(""""base_revision":4"""))

        // ...and the server's response is the only source of the new revision.
        val outcome = classify(local, 200, seasonRowJson(revision = 5L))

        assertTrue(outcome is VersionedWriteOutcome.Applied)
        val applied = (outcome as VersionedWriteOutcome.Applied).row
        assertEquals(5L, applied.serverRevision)
        assertEquals(seasonId, applied.id)
        assertEquals("north end first", applied.notes)
    }

    @Test
    fun `a create omits base_revision entirely rather than sending zero or null`() {
        val body = upsertJson(setup(serverRevision = null), serverTime)

        // sql/198 reads an ABSENT base_revision as a create. A literal null or a 0 would be a
        // claim about a version this device was never issued.
        assertFalse("base_revision must be omitted, not null", body.contains("base_revision"))
        assertTrue(body.contains(""""client_updated_at":"$serverTime""""))

        val outcome = classify(setup(serverRevision = null), 201, seasonRowJson(revision = 1L))
        assertEquals(1L, (outcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    @Test
    fun `the returned revision is believed even when the server jumps`() {
        // Any actor — portal, RPC, maintenance — can advance a row, so base+1 is not the
        // client's to predict. A client that assumed 5 here would be wrong by 7 forever.
        val outcome = classify(setup(serverRevision = 4L), 200, seasonRowJson(revision = 12L))

        assertEquals(12L, (outcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    // ==================================================================
    // 2 & 3. Clock skew must be irrelevant
    // ==================================================================

    @Test
    fun `a device hours BEHIND the server still writes successfully`() {
        val local = setup(serverRevision = 4L)
        val body = upsertJson(local, slowClockTime)

        // The stamp is six hours older than the row being replaced — fatal under sql/185.
        assertTrue(body.contains(""""client_updated_at":"$slowClockTime""""))
        assertTrue("the revision, not the stamp, is the claim", body.contains(""""base_revision":4"""))

        val outcome = classify(local, 200, seasonRowJson(revision = 5L))
        assertTrue("a slow clock must not manufacture a conflict", outcome is VersionedWriteOutcome.Applied)
        assertEquals(5L, (outcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    @Test
    fun `a device hours AHEAD is accepted and does not lock out the next writer`() {
        val fast = setup(serverRevision = 4L)
        assertTrue(upsertJson(fast, fastClockTime).contains(""""client_updated_at":"$fastClockTime""""))
        val fastOutcome = classify(fast, 200, seasonRowJson(revision = 5L))
        assertEquals(5L, (fastOutcome as VersionedWriteOutcome.Applied).row.serverRevision)

        // The NEXT device, with an honest clock, edits from revision 5. Under the timestamp
        // contract the fast device's future stamp made this look stale for eight hours.
        val next = setup(serverRevision = 5L)
        val nextOutcome = classify(next, 200, seasonRowJson(revision = 6L))
        assertTrue("a parked future stamp must not block anyone", nextOutcome is VersionedWriteOutcome.Applied)
        assertEquals(6L, (nextOutcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    // ==================================================================
    // 4. Genuine stale write
    // ==================================================================

    @Test
    fun `a write based on a superseded revision is refused as a conflict`() {
        val stale = setup(serverRevision = 4L)

        val outcome = classify(stale, 409, conflictBody(serverRevision = 5L, baseRevision = 4L))

        assertTrue(outcome is VersionedWriteOutcome.Conflict)
        val conflict = outcome as VersionedWriteOutcome.Conflict
        assertEquals(seasonId, conflict.rowId)
        assertEquals("the rejected base must be recorded", 4L, conflict.baseRevision)
        assertEquals("so must what the server was actually at", 5L, conflict.serverRevision)
    }

    @Test
    fun `an empty 2xx representation is a conflict and never a success`() {
        // The legacy silent-skip signature: a BEFORE UPDATE trigger returned NULL, so nothing
        // was written while HTTP said 200. Reporting this as saved is how season setups
        // vanished.
        val outcome = classify(setup(serverRevision = 4L), 200, "[]")

        assertTrue(outcome is VersionedWriteOutcome.Conflict)
        assertEquals(4L, (outcome as VersionedWriteOutcome.Conflict).baseRevision)
        assertNull("no server revision is knowable from a silent skip", outcome.serverRevision)
    }

    // ==================================================================
    // 5, 6. Outbox retention and no blind retry
    // ==================================================================

    @Test
    fun `a conflicted season write is retained and excluded from the retry set`() {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val queued = pending.enqueue(
            entityType = PendingEntityType.PRUNING_SEASON,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(PruningBlockSetup.serializer(), setup(4L, crew = "My Crew")),
            clientId = seasonId,
        )

        // What the coordinator does on RevisionConflictException: mark, never remove.
        pending.updateStatus(queued.id, PendingWriteStatus.CONFLICT, "Also changed on another device.")

        val write = pending.list().single()
        assertEquals(PendingWriteStatus.CONFLICT, write.status)
        assertTrue("the authored setup must survive", write.payloadJson.contains("My Crew"))
        assertEquals("it still counts as waiting to sync", 1, pending.currentPendingCount())

        // The replay loop's own filter must skip it: replaying resends the same stale
        // base_revision and is refused every time.
        assertFalse(PendingWriteStatus.retryable.contains(PendingWriteStatus.CONFLICT))
        val replayable = pending.list().filter { PendingWriteStatus.retryable.contains(it.status) }
        assertTrue("a conflicted write must never be picked up", replayable.isEmpty())

        // Nor may a user-triggered "Retry all" resurrect it.
        assertEquals(0, pending.retryEligibleCount())
        assertEquals(0, pending.resetFailedForRetry())
        assertEquals(PendingWriteStatus.CONFLICT, pending.list().single().status)
    }

    @Test
    fun `a conflicted season write survives a restart and still does not auto retry`() {
        val store = InMemoryPendingWriteStore()
        val firstRun = PendingWriteRepository(store)
        val queued = firstRun.enqueue(
            entityType = PendingEntityType.PRUNING_SEASON,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(PruningBlockSetup.serializer(), setup(4L, crew = "My Crew")),
            clientId = seasonId,
        )
        firstRun.updateStatus(queued.id, PendingWriteStatus.CONFLICT, "Also changed on another device.")

        // App killed; a brand-new repository over the SAME persisted store.
        val secondRun = PendingWriteRepository(store)

        val restored = secondRun.list().single()
        assertEquals(PendingWriteStatus.CONFLICT, restored.status)
        assertTrue(restored.payloadJson.contains("My Crew"))
        assertNotNull(restored.lastError)
        assertEquals(1, secondRun.currentPendingCount())
        assertEquals("still not retryable after a restart", 0, secondRun.retryEligibleCount())

        // The queued setup decodes back with its base revision intact, so the eventual
        // resolution knows exactly which version the edit was made against.
        val decoded = json.decodeFromString(PruningBlockSetup.serializer(), restored.payloadJson)
        assertEquals(4L, decoded.serverRevision)
        assertEquals("My Crew", decoded.crew)
    }

    // ==================================================================
    // 7. Failures must stay failures
    // ==================================================================

    @Test
    fun `auth and server failures are thrown rather than disguised as conflicts`() {
        val local = setup(serverRevision = 4L)

        // A refused session is a permission problem — retryable after signing in, and there
        // is no second version for anyone to review.
        assertThrows(BackendError.Unauthorized::class.java) {
            classify(local, 401, """{"message":"JWT expired"}""")
        }
        assertThrows(BackendError.Unauthorized::class.java) {
            classify(local, 403, """{"message":"permission denied for table pruning_seasons"}""")
        }

        // 5xx is transport-shaped: retry is exactly the right remedy.
        val server = assertThrows(BackendError.Server::class.java) {
            classify(local, 503, "upstream unavailable")
        }
        assertEquals(503, server.code)

        // A unique-key violation is ALSO a 409, and is emphatically not a revision conflict.
        // Labelling it "also changed on another device" would send the grower hunting for a
        // second version that does not exist while the real cause went unreported.
        val duplicate = assertThrows(BackendError.Server::class.java) {
            classify(local, 409, """{"code":"23505","message":"duplicate key value violates unique constraint"}""")
        }
        assertEquals(409, duplicate.code)
    }

    // ==================================================================
    // 8. Legacy rows and old clients
    // ==================================================================

    @Test
    fun `a season row written by an old client decodes and becomes versioned on first edit`() {
        // No server_revision at all — a pre-sql/198 row.
        val pulled = json
            .decodeFromString<List<PruningSyncRepository.SeasonRow>>(seasonRowJson(revision = null))
            .single()
            .toModel()

        assertNull("a missing revision must decode, not throw", pulled.serverRevision)
        assertEquals("Crew A", pulled.crew)
        assertEquals(2026, pulled.seasonYear)

        // Editing it sends no base_revision, and the write brings it onto the contract.
        assertFalse(upsertJson(pulled, serverTime).contains("base_revision"))
        val outcome = classify(pulled, 200, seasonRowJson(revision = 1L))
        assertEquals(1L, (outcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    @Test
    fun `a season response from a path that omits the revision still decodes`() {
        val terse = """[{"id":"$seasonId","vineyard_id":"$vineyard","paddock_id":"$block","season_year":2026}]"""

        val row = json.decodeFromString<List<PruningSyncRepository.SeasonRow>>(terse).single()

        assertNull(row.serverRevision)
        assertEquals("spur", row.toModel().method)
    }

    // ==================================================================
    // Timestamps must never decide the winner
    // ==================================================================

    @Test
    fun `a far future stamp cannot rescue a stale revision`() {
        val stale = setup(serverRevision = 4L)
        // Deliberate temptation: the newest stamp imaginable on a superseded revision.
        assertTrue(upsertJson(stale, "2099-01-01T00:00:00Z").contains(""""base_revision":4"""))

        val outcome = classify(stale, 409, conflictBody(serverRevision = 5L, baseRevision = 4L))

        assertTrue("a newer clock must not win", outcome is VersionedWriteOutcome.Conflict)
    }

    @Test
    fun `an ancient stamp does not spoil a current revision`() {
        val current = setup(serverRevision = 4L)
        assertTrue(upsertJson(current, "1999-01-01T00:00:00Z").contains(""""base_revision":4"""))

        val outcome = classify(current, 200, seasonRowJson(revision = 5L))

        assertTrue("an older clock must not lose", outcome is VersionedWriteOutcome.Applied)
        assertEquals(5L, (outcome as VersionedWriteOutcome.Applied).row.serverRevision)
    }

    @Test
    fun `a revision newer row with an older looking timestamp still wins`() {
        // The server's updated_at looks OLD while its revision is NEWER. Revision decides.
        val oldLookingButNewer = """
            [{"id":"$seasonId","vineyard_id":"$vineyard","paddock_id":"$block",
              "season_year":2026,"pruning_method":"spur","assigned_crew":"Crew B",
              "updated_at":"1999-01-01T00:00:00Z","server_revision":9}]
        """.trimIndent()

        val outcome = classify(setup(serverRevision = 8L), 200, oldLookingButNewer)

        val applied = (outcome as VersionedWriteOutcome.Applied).row
        assertEquals("the revision is the authority, not updated_at", 9L, applied.serverRevision)
        assertEquals("Crew B", applied.crew)
    }

    /** Local helper so the file needs no extra test dependency. */
    private fun <T : Throwable> assertThrows(type: Class<T>, block: () -> Unit): T {
        try {
            block()
        } catch (t: Throwable) {
            if (type.isInstance(t)) {
                @Suppress("UNCHECKED_CAST")
                return t as T
            }
            throw AssertionError("Expected ${type.simpleName} but got ${t::class.java.simpleName}", t)
        }
        throw AssertionError("Expected ${type.simpleName} but nothing was thrown")
    }
}
