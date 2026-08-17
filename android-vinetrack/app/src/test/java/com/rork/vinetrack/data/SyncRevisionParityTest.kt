package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningYieldSettings
import com.rork.vinetrack.data.resistance.ResistancePlanSyncState
import com.rork.vinetrack.data.sync.SyncRevisionContract
import com.rork.vinetrack.data.sync.VersionedWriteClassifier
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CANONICAL CROSS-PLATFORM FIXTURE for the sql/198 revision contract.
 *
 * Every input here is a fixed literal, mirrored byte-for-byte by
 * `ios/VineTrackTests/SyncRevisionParityTests.swift`. When both files execute, the pair
 * mechanically proves the property that matters:
 *
 *   the SAME server response produces the SAME client concurrency decision on iOS and Android.
 *
 * That claim used to rest on "we wrote them the same way", which is not evidence. Two
 * platforms drifting apart on this is not a cosmetic bug: one of them would report a refused
 * write as saved, and a grower's edit would be gone with a tick beside it.
 *
 * These are contract assertions on the real classifier and the real codecs — deliberately NOT
 * repository behaviour tests, so a repository refactor cannot quietly change what a PT409
 * means.
 *
 * RULE FOR EDITING: never change a fixture value on one platform alone. If a constant here
 * changes, the Swift mirror changes in the same commit, or the parity guarantee is void.
 */
class SyncRevisionParityTest {

    /**
     * The shared fixture vector. Identical literals exist in the Swift mirror.
     *
     * Platform-specific formatting (JSON key order, date rendering, integer width) is
     * deliberately NOT asserted — only the concurrency-relevant semantics are.
     */
    object Fixture {
        const val ROW_ID = "9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f"
        const val VINEYARD_ID = "11111111-1111-4111-8111-111111111111"
        const val PADDOCK_ID = "22222222-2222-4222-8222-222222222222"

        /** Metadata only. Present in every fixture precisely so it can be proved inert. */
        const val CLIENT_UPDATED_AT = "2026-08-17T02:00:00Z"

        /** The revision the client observed and will assert as `base_revision`. */
        const val OBSERVED_REVISION = 7L

        /** What the server issues when it accepts that write. */
        const val ACCEPTED_REVISION = 8L

        /** Where the row had actually moved on to when it refused the write. */
        const val CONFLICTING_SERVER_REVISION = 12L

        /** A stamp far in the FUTURE, to tempt a timestamp comparison into passing a stale write. */
        const val FUTURE_STAMP = "2099-01-01T00:00:00Z"

        /** A stamp far in the PAST, to tempt one into failing a current write. */
        const val ANCIENT_STAMP = "1999-01-01T00:00:00Z"

        // ---------- Canonical server representations (2xx bodies) ----------

        /** A stored `pruning_yield_settings` row at [ACCEPTED_REVISION]. */
        const val SETTINGS_ROW = """
            [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
              "vineyard_id":"11111111-1111-4111-8111-111111111111",
              "paddock_id":"22222222-2222-4222-8222-222222222222",
              "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
              "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
              "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
              "client_updated_at":"2026-08-17T02:00:00Z","server_revision":8}]
        """

        /** The same row as an older client left it: no revision column at all. */
        const val SETTINGS_ROW_LEGACY = """
            [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
              "vineyard_id":"11111111-1111-4111-8111-111111111111",
              "paddock_id":"22222222-2222-4222-8222-222222222222",
              "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
              "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
              "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
              "client_updated_at":"2026-08-17T02:00:00Z"}]
        """

        /**
         * A row whose `client_updated_at` looks ANCIENT while its `server_revision` is NEWER.
         * The revision must win.
         */
        const val SETTINGS_ROW_OLD_STAMP_NEWER_REVISION = """
            [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
              "vineyard_id":"11111111-1111-4111-8111-111111111111",
              "paddock_id":"22222222-2222-4222-8222-222222222222",
              "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
              "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
              "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
              "client_updated_at":"1999-01-01T00:00:00Z","server_revision":12}]
        """

        /** 2xx with NO row: the legacy silent-skip signature. */
        const val EMPTY_REPRESENTATION = "[]"

        // ---------- Canonical failure bodies ----------

        /** Exactly what `reject_stale_client_write()` raises under sql/198. */
        const val CONFLICT_BODY = """{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 7}","hint":"Reload the row and reapply the change","message":"REVISION_CONFLICT"}"""

        /** The marker surviving a status rewrite by a gateway or proxy. */
        const val CONFLICT_BODY_MARKER_ONLY = """{"message":"REVISION_CONFLICT"}"""

        /** A unique-key violation, which PostgREST ALSO reports as 409. Not a conflict. */
        const val UNIQUE_VIOLATION_BODY = """{"code":"23505","details":"Key (vineyard_id, paddock_id) already exists.","message":"duplicate key value violates unique constraint"}"""

        const val AUTH_BODY = """{"message":"JWT expired"}"""
        const val FORBIDDEN_BODY = """{"message":"permission denied for table pruning_yield_settings"}"""
        const val SERVER_ERROR_BODY = """{"message":"upstream unavailable"}"""
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun classifySettings(
        baseRevision: Long?,
        status: Int,
        body: String?,
    ): VersionedWriteOutcome<PruningYieldSettings> = VersionedWriteClassifier.classify(
        rowId = Fixture.ROW_ID,
        baseRevision = baseRevision,
        status = status,
        body = body,
    ) { text ->
        runCatching { json.decodeFromString<List<PruningYieldSettings>>(text) }
            .getOrDefault(emptyList())
            .firstOrNull()
    }

    // ==================================================================
    // 1. Unsynced revision representation
    // ==================================================================

    @Test
    fun `an unsynced row carries a null revision and asserts no base revision`() {
        val unsynced = PruningBlockSetup(
            id = Fixture.ROW_ID,
            vineyardId = Fixture.VINEYARD_ID,
            paddockId = Fixture.PADDOCK_ID,
            seasonYear = 2026,
        )

        assertNull("never synced means never versioned", unsynced.serverRevision)

        val body = json.encodeToString(
            PruningSyncRepository.SeasonUpsert.serializer(),
            PruningSyncRepository.SeasonUpsert.from(unsynced, Fixture.CLIENT_UPDATED_AT, createdBy = null),
        )
        // OMITTED, not null and not 0. sql/198 reads an absent base_revision as a create;
        // any literal value would be a claim about a version never issued to this device.
        assertFalse("base_revision must be absent", body.contains("base_revision"))
    }

    // ==================================================================
    // 2. server_revision decode
    // ==================================================================

    @Test
    fun `the canonical server row decodes to the canonical revision`() {
        val row = json
            .decodeFromString<List<PruningYieldSettings>>(Fixture.SETTINGS_ROW)
            .single()

        assertEquals(Fixture.ROW_ID, row.id)
        assertEquals(Fixture.ACCEPTED_REVISION, row.serverRevision)
        assertEquals(120.0, row.bunchWeightGrams, 0.0001)
    }

    @Test
    fun `a legacy row with no revision column decodes to null rather than throwing`() {
        val row = json
            .decodeFromString<List<PruningYieldSettings>>(Fixture.SETTINGS_ROW_LEGACY)
            .single()

        assertNull(row.serverRevision)
        assertEquals(Fixture.ROW_ID, row.id)
    }

    // ==================================================================
    // 3. base_revision encoding
    // ==================================================================

    @Test
    fun `an observed revision is encoded as base_revision verbatim`() {
        val versioned = PruningBlockSetup(
            id = Fixture.ROW_ID,
            vineyardId = Fixture.VINEYARD_ID,
            paddockId = Fixture.PADDOCK_ID,
            seasonYear = 2026,
            serverRevision = Fixture.OBSERVED_REVISION,
        )

        val body = json.encodeToString(
            PruningSyncRepository.SeasonUpsert.serializer(),
            PruningSyncRepository.SeasonUpsert.from(versioned, Fixture.CLIENT_UPDATED_AT, createdBy = null),
        )

        assertTrue(body.contains(""""base_revision":${Fixture.OBSERVED_REVISION}"""))
        // The stamp still travels — it is legitimate metadata and audit, just not authority.
        assertTrue(body.contains(""""client_updated_at":"${Fixture.CLIENT_UPDATED_AT}""""))
    }

    // ==================================================================
    // 4 & 5. PT409 and REVISION_CONFLICT classification
    // ==================================================================

    @Test
    fun `the canonical PT409 body classifies as a revision conflict on both platforms`() {
        assertTrue(SyncRevisionContract.isRevisionConflict(409, Fixture.CONFLICT_BODY))
        assertEquals(
            Fixture.CONFLICTING_SERVER_REVISION,
            SyncRevisionContract.serverRevisionFrom(Fixture.CONFLICT_BODY),
        )
        assertEquals(
            Fixture.OBSERVED_REVISION,
            SyncRevisionContract.baseRevisionFrom(Fixture.CONFLICT_BODY),
        )

        val outcome = classifySettings(Fixture.OBSERVED_REVISION, 409, Fixture.CONFLICT_BODY)
        assertTrue(outcome is VersionedWriteOutcome.Conflict)
        val conflict = outcome as VersionedWriteOutcome.Conflict
        assertEquals(Fixture.ROW_ID, conflict.rowId)
        assertEquals(Fixture.OBSERVED_REVISION, conflict.baseRevision)
        assertEquals(Fixture.CONFLICTING_SERVER_REVISION, conflict.serverRevision)
    }

    @Test
    fun `the marker alone is conclusive even when the status was rewritten`() {
        // A gateway can rewrite a status code; the message travels in the body.
        assertTrue(SyncRevisionContract.isRevisionConflict(200, Fixture.CONFLICT_BODY_MARKER_ONLY))
        assertTrue(SyncRevisionContract.isRevisionConflict(500, Fixture.CONFLICT_BODY_MARKER_ONLY))
    }

    @Test
    fun `a bare 409 with no usable body is still treated as a conflict`() {
        // No evidence either way. The fail-safe reading is the one that keeps the edit queued:
        // a conflict misread as a failure is retried forever and can never converge.
        assertTrue(SyncRevisionContract.isRevisionConflict(409, null))
        assertTrue(SyncRevisionContract.isRevisionConflict(409, ""))
        assertNull(SyncRevisionContract.serverRevisionFrom(null))
    }

    // ==================================================================
    // 6. Other statuses keep their own meanings
    // ==================================================================

    @Test
    fun `a non revision 409 is not classified as a revision conflict`() {
        // A duplicate key means nobody edited concurrently. Reporting "also changed on
        // another device" would send the grower looking for a version that does not exist.
        assertFalse(SyncRevisionContract.isRevisionConflict(409, Fixture.UNIQUE_VIOLATION_BODY))
    }

    @Test
    fun `auth server and transport failures never become conflicts`() {
        assertFalse(SyncRevisionContract.isRevisionConflict(401, Fixture.AUTH_BODY))
        assertFalse(SyncRevisionContract.isRevisionConflict(403, Fixture.FORBIDDEN_BODY))
        assertFalse(SyncRevisionContract.isRevisionConflict(500, Fixture.SERVER_ERROR_BODY))
        assertFalse(SyncRevisionContract.isRevisionConflict(503, Fixture.SERVER_ERROR_BODY))

        // ...and the classifier turns them into throwables, so the caller's retry path runs.
        assertThrows(BackendError.Unauthorized::class.java) {
            classifySettings(Fixture.OBSERVED_REVISION, 401, Fixture.AUTH_BODY)
        }
        assertThrows(BackendError.Unauthorized::class.java) {
            classifySettings(Fixture.OBSERVED_REVISION, 403, Fixture.FORBIDDEN_BODY)
        }
        assertEquals(
            503,
            assertThrows(BackendError.Server::class.java) {
                classifySettings(Fixture.OBSERVED_REVISION, 503, Fixture.SERVER_ERROR_BODY)
            }.code,
        )
        assertEquals(
            409,
            assertThrows(BackendError.Server::class.java) {
                classifySettings(Fixture.OBSERVED_REVISION, 409, Fixture.UNIQUE_VIOLATION_BODY)
            }.code,
        )
    }

    // ==================================================================
    // 7. Success carries the returned revision
    // ==================================================================

    @Test
    fun `a valid representation is applied with the servers revision`() {
        val outcome = classifySettings(Fixture.OBSERVED_REVISION, 200, Fixture.SETTINGS_ROW)

        assertTrue(outcome is VersionedWriteOutcome.Applied)
        val row = (outcome as VersionedWriteOutcome.Applied).row
        assertEquals(Fixture.ACCEPTED_REVISION, row.serverRevision)
        assertNotEquals(
            "the new revision must come from the response, not from base+1 arithmetic",
            Fixture.OBSERVED_REVISION,
            row.serverRevision,
        )
    }

    // ==================================================================
    // 8. An empty 2xx representation is NOT success
    // ==================================================================

    @Test
    fun `an empty 2xx representation is a conflict and never a success`() {
        val outcome = classifySettings(Fixture.OBSERVED_REVISION, 200, Fixture.EMPTY_REPRESENTATION)

        assertTrue("HTTP 200 with no row is a silent skip, not a save", outcome is VersionedWriteOutcome.Conflict)
        val conflict = outcome as VersionedWriteOutcome.Conflict
        assertEquals(Fixture.OBSERVED_REVISION, conflict.baseRevision)
        assertNull(conflict.serverRevision)
    }

    @Test
    fun `a 201 with no row is treated the same way`() {
        val outcome = classifySettings(null, 201, Fixture.EMPTY_REPRESENTATION)
        assertTrue(outcome is VersionedWriteOutcome.Conflict)
    }

    // ==================================================================
    // 9. Conflict sync state
    // ==================================================================

    @Test
    fun `conflict is a state of its own and is excluded from every retry path`() {
        // Not FAILED (which is retried) and not BLOCKED (which hides that the user's authored
        // value is still recoverable). The remedies are opposites.
        assertFalse(PendingWriteStatus.retryable.contains(PendingWriteStatus.CONFLICT))
        assertTrue(PendingWriteStatus.unresolved.contains(PendingWriteStatus.CONFLICT))
        assertTrue(PendingWriteStatus.retryable.contains(PendingWriteStatus.PENDING))
        assertTrue(PendingWriteStatus.retryable.contains(PendingWriteStatus.FAILED))
        assertNotEquals(PendingWriteStatus.CONFLICT, PendingWriteStatus.FAILED)
        assertNotEquals(PendingWriteStatus.CONFLICT, PendingWriteStatus.BLOCKED)

        // The whole-document entity has the same distinction on its own sync state.
        assertNotEquals(ResistancePlanSyncState.CONFLICT, ResistancePlanSyncState.FAILED)
        assertNotEquals(ResistancePlanSyncState.CONFLICT, ResistancePlanSyncState.SYNCED)
    }

    // ==================================================================
    // 10. Outbox retention
    // ==================================================================

    @Test
    fun `a conflicted write is retained with its payload and stays unretryable`() {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val write = pending.enqueue(
            entityType = PendingEntityType.PRUNING_YIELD_SETTINGS,
            opType = PendingOpType.UPDATE,
            payloadJson = """{"bunch_weight_grams":175.0}""",
            clientId = "${Fixture.VINEYARD_ID}|${Fixture.PADDOCK_ID}",
        )
        pending.updateStatus(write.id, PendingWriteStatus.CONFLICT, "Also changed on another device.")

        val retained = pending.list().single()
        assertEquals(PendingWriteStatus.CONFLICT, retained.status)
        assertTrue("the authored value must survive", retained.payloadJson.contains("175"))
        assertEquals(1, pending.currentPendingCount())
        assertEquals(0, pending.retryEligibleCount())
        assertEquals(0, pending.resetFailedForRetry())
    }

    // ==================================================================
    // 11. Timestamps must never choose the winner
    // ==================================================================

    @Test
    fun `a future stamp cannot turn a conflict into a success`() {
        // The body says the revision was superseded. Nothing about the local clock may
        // override that — this is the exact substitution that lost data under sql/185.
        assertTrue(SyncRevisionContract.isRevisionConflict(409, Fixture.CONFLICT_BODY))

        val outcome = classifySettings(Fixture.OBSERVED_REVISION, 409, Fixture.CONFLICT_BODY)
        assertTrue(outcome is VersionedWriteOutcome.Conflict)

        // And the classifier is not even given a stamp to consult: its inputs are the row id,
        // the base revision, the status and the body. There is no clock in the signature.
        assertNotEquals(Fixture.FUTURE_STAMP, Fixture.CLIENT_UPDATED_AT)
    }

    @Test
    fun `an ancient stamp cannot turn a success into a failure`() {
        val outcome = classifySettings(Fixture.OBSERVED_REVISION, 200, Fixture.SETTINGS_ROW)
        assertTrue(outcome is VersionedWriteOutcome.Applied)
        assertNotEquals(Fixture.ANCIENT_STAMP, Fixture.CLIENT_UPDATED_AT)
    }

    @Test
    fun `a newer revision wins even when its timestamp looks older`() {
        val outcome = classifySettings(
            Fixture.OBSERVED_REVISION,
            200,
            Fixture.SETTINGS_ROW_OLD_STAMP_NEWER_REVISION,
        )

        val row = (outcome as VersionedWriteOutcome.Applied).row
        assertEquals(
            "revision ordering must survive a misleading timestamp",
            Fixture.CONFLICTING_SERVER_REVISION,
            row.serverRevision,
        )
    }

    @Test
    fun `revision ordering is numeric and independent of any stamp`() {
        // The comparison the repositories use for replica lag. Asserted here so both
        // platforms agree on the ordering primitive itself, not just on its callers.
        assertTrue(Fixture.ACCEPTED_REVISION > Fixture.OBSERVED_REVISION)
        assertTrue(Fixture.CONFLICTING_SERVER_REVISION > Fixture.ACCEPTED_REVISION)
        // A null revision is NOT "behind": a legacy row with no revision is not evidence of
        // replica lag, and treating it as stale would make such rows permanently unpullable.
        val legacyRevision: Long? = null
        assertFalse(isStrictlyBehind(legacyRevision, Fixture.ACCEPTED_REVISION))
        assertFalse(isStrictlyBehind(Fixture.ACCEPTED_REVISION, legacyRevision))
        assertTrue(isStrictlyBehind(Fixture.OBSERVED_REVISION, Fixture.ACCEPTED_REVISION))
        assertFalse(isStrictlyBehind(Fixture.ACCEPTED_REVISION, Fixture.ACCEPTED_REVISION))
    }

    /** The parity definition of "the remote copy is older than what we have confirmed". */
    private fun isStrictlyBehind(remote: Long?, known: Long?): Boolean {
        if (remote == null || known == null) return false
        return remote < known
    }

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
