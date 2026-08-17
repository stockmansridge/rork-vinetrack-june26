package com.rork.vinetrack.data

import com.rork.vinetrack.data.resistance.InMemoryResistancePlanLocalStore
import com.rork.vinetrack.data.resistance.RESISTANCE_PLANS_ENTITY
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanRemote
import com.rork.vinetrack.data.resistance.ResistancePlanRepository
import com.rork.vinetrack.data.resistance.ResistancePlanSyncState
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import com.rork.vinetrack.data.sync.SyncRevisionContract
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Sync Integrity Stage 2: the mobile half of the sql/198 revision contract.
 *
 * Every test here targets a failure that ACTUALLY HAPPENED under the old
 * `client_updated_at` contract, or a regression that would silently reintroduce it. The
 * fake server below arbitrates purely on `server_revision` and never on a clock — so a
 * test that passes because the timestamps happened to line up cannot exist in this file.
 *
 * Mirrored on iOS by `ResistancePlanRevisionSyncTests.swift`; the cross-platform parity
 * assertions live in `SyncRevisionParityTest`.
 */
class ResistancePlanRevisionSyncTest {

    // ------------------------------------------------------------------
    // Fake server — revision-authoritative, clock-blind
    // ------------------------------------------------------------------

    /**
     * In-memory stand-in for `public.resistance_plans` under sql/198.
     *
     * Contract enforced:
     *  - `base_revision` must equal the stored `server_revision`, else conflict;
     *  - the server issues the next revision on every accepted write;
     *  - `client_updated_at` is recorded but NEVER arbitrates;
     *  - a client-supplied `server_revision` is ignored (unforgeable token).
     */
    private class RevisionServer : ResistancePlanRemote {
        val rows = mutableMapOf<String, ResistancePlan>()
        var upsertCalls = 0
        var lastBaseRevisionSent: Long? = null
        val baseRevisionsSent = mutableListOf<Long?>()
        private var lagSnapshot: List<ResistancePlan> = emptyList()
        var serveStaleReadNext: Boolean = false
        var failNextFetch: Boolean = false

        override suspend fun fetchAll(vineyardId: String): List<ResistancePlan> {
            if (failNextFetch) {
                failNextFetch = false
                throw IllegalStateException("offline")
            }
            if (serveStaleReadNext) {
                serveStaleReadNext = false
                return lagSnapshot.filter { it.vineyardId == vineyardId }
            }
            return rows.values.filter { it.vineyardId == vineyardId }
        }

        override suspend fun upsert(
            plans: List<ResistancePlan>,
        ): List<VersionedWriteOutcome<ResistancePlan>> {
            lagSnapshot = rows.values.toList()
            upsertCalls++
            return plans.map { plan ->
                lastBaseRevisionSent = plan.serverRevision
                baseRevisionsSent += plan.serverRevision
                val existing = rows[plan.id]
                if (existing != null && plan.serverRevision != existing.serverRevision) {
                    return@map VersionedWriteOutcome.Conflict(
                        rowId = plan.id,
                        baseRevision = plan.serverRevision,
                        serverRevision = existing.serverRevision,
                    )
                }
                val stored = plan.copy(
                    createdBy = existing?.createdBy ?: plan.createdBy,
                    deletedAtEpochMs = existing?.deletedAtEpochMs,
                    serverRevision = (existing?.serverRevision ?: 0L) + 1L,
                )
                rows[plan.id] = stored
                VersionedWriteOutcome.Applied(stored)
            }
        }

        override suspend fun softDelete(planId: String) {
            val existing = rows[planId] ?: return
            rows[planId] = existing.copy(
                deletedAtEpochMs = existing.updatedAtEpochMs + 1,
                serverRevision = (existing.serverRevision ?: 0L) + 1L,
            )
        }

        /** Another device or the portal saves over the row, advancing the revision. */
        fun writeAsOtherDevice(planId: String, notes: String, atEpochMs: Long) {
            val existing = rows[planId] ?: return
            rows[planId] = existing.copy(
                notes = notes,
                updatedAtEpochMs = atEpochMs,
                serverRevision = (existing.serverRevision ?: 0L) + 1L,
            )
        }

        /** Seeds a row exactly as a pre-sql/198 client left it: no revision at all. */
        fun seedLegacyRow(plan: ResistancePlan) {
            rows[plan.id] = plan.copy(serverRevision = null)
        }
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    private val vineyard = "vy-1"
    private var now = 10_000L

    private fun position(id: String, code: String) = ResistancePlannedPosition(
        id = id,
        products = listOf(
            ResistancePlannedProduct(
                id = "prod-$id",
                groupCodes = listOf(code),
                source = ResistancePlannedChemistrySource.GROUP,
            ),
        ),
    )

    private fun plan(
        id: String = "plan-1",
        notes: String? = null,
        updatedAt: Long = 1_000L,
        positions: List<ResistancePlannedPosition> = listOf(position("pos-1", "3")),
    ) = ResistancePlan(
        id = id,
        vineyardId = vineyard,
        seasonId = "2026/27",
        seasonStartYear = 2026,
        disease = ResistanceDisease.POWDERY_MILDEW,
        jurisdiction = ResistanceJurisdiction.AUSTRALIA,
        crop = ResistanceCrop.GRAPE,
        blockIds = listOf("block-a"),
        positions = positions,
        notes = notes,
        rulesetId = "AU_GRAPE_POWDERY_2026_07_22",
        rulesetVersion = "2026.07.22",
        createdAtEpochMs = 1_000L,
        updatedAtEpochMs = updatedAt,
    )

    private fun repo(
        server: ResistancePlanRemote?,
        store: InMemoryResistancePlanLocalStore = InMemoryResistancePlanLocalStore(),
    ) = ResistancePlanRepository(
        local = store,
        remote = server,
        clock = { now },
        currentUserId = { "user-1" },
    )

    // ==================================================================
    // 1. Successful create — no base revision, server issues one
    // ==================================================================

    @Test
    fun `a brand new plan is created with no base revision and adopts the server revision`() =
        runBlocking {
            val server = RevisionServer()
            val repository = repo(server)
            repository.load(vineyard)
            repository.save(plan())

            // Before the push this device has never been given a revision. It must send
            // NOTHING rather than invent one: a fabricated base_revision would either be
            // refused forever or match by luck and overwrite an unseen edit.
            assertNull(repository.plans.value.single().serverRevision)
            assertTrue(repository.plans.value.single().isUnsynced)

            val result = repository.sync(vineyard)

            assertTrue(result.isSuccess)
            assertEquals(1, result.pushed)
            assertEquals(0, result.conflicted)
            assertNull("create must not assert a base revision", server.baseRevisionsSent.single())
            assertEquals(
                "the server-issued revision must be persisted locally",
                1L,
                repository.plans.value.single().serverRevision,
            )
            assertEquals(0, repository.pendingCount())
            assertEquals(ResistancePlanSyncState.SYNCED, repository.syncState.value)
        }

    // ==================================================================
    // 2. Successful edit — base revision N, row advances
    // ==================================================================

    @Test
    fun `an edit sends the observed revision and adopts the advanced one`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan())
        repository.sync(vineyard)
        assertEquals(1L, repository.plans.value.single().serverRevision)

        now = 20_000L
        repository.save(repository.plans.value.single().settingNotes("edited", now))
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals("must send the revision it READ, not a guess", 1L, server.lastBaseRevisionSent)
        assertEquals(
            "the local copy must take the server's new revision, not local+1 arithmetic",
            2L,
            repository.plans.value.single().serverRevision,
        )
        assertEquals(2L, server.rows.getValue("plan-1").serverRevision)
        assertEquals("edited", repository.plans.value.single().notes)
        assertEquals(0, repository.pendingCount())
    }

    @Test
    fun `the revision comes from the server response and is never computed locally`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan())
        repository.sync(vineyard)

        // A server that jumps revisions (perfectly legal — any write by any actor advances
        // it) must be believed. If the client assumed base+1 it would now be wrong by 8 and
        // every later edit would be refused.
        server.rows["plan-1"] = server.rows.getValue("plan-1").copy(serverRevision = 9L)
        now = 30_000L
        repository.save(repository.plans.value.single().settingNotes("second", now))
        val conflictPass = repository.sync(vineyard)
        assertEquals("the jump must be seen as a conflict, not guessed around", 1, conflictPass.conflicted)

        repository.resolveKeepingLocal("plan-1")
        assertEquals(9L, repository.plans.value.single().serverRevision)
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals(0, result.conflicted)
        assertEquals(10L, repository.plans.value.single().serverRevision)
    }

    // ==================================================================
    // 3 & 4. Clock skew — the whole point of the migration
    // ==================================================================

    @Test
    fun `an edit from a device hours BEHIND the server still succeeds`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        now = 10_000_000L
        repository.save(plan(updatedAt = now))
        repository.sync(vineyard)
        assertEquals(1L, repository.plans.value.single().serverRevision)

        // The device clock jumps BACKWARDS by six hours — the exact case that silently lost
        // a grower's edit under sql/185: the honest new edit was dated before the stored row
        // and was discarded while the app reported success.
        now = 10_000_000L - 6 * 60 * 60 * 1000L
        repository.save(repository.plans.value.single().settingNotes("slow clock edit", now))
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals("a slow clock must not manufacture a conflict", 0, result.conflicted)
        assertEquals(1, result.pushed)
        assertEquals("slow clock edit", server.rows.getValue("plan-1").notes)
        assertEquals(2L, repository.plans.value.single().serverRevision)
        assertEquals(0, repository.pendingCount())
        assertEquals(ResistancePlanSyncState.SYNCED, repository.syncState.value)
    }

    @Test
    fun `a device hours AHEAD of the server does not lock later writers out`() = runBlocking {
        val server = RevisionServer()
        val fastStore = InMemoryResistancePlanLocalStore()
        val fastDevice = repo(server, fastStore)
        fastDevice.load(vineyard)

        // Fast device parks a far-future client_updated_at on the row. Under sql/185 this
        // poisoned the row: every honest later edit looked stale until the server clock
        // caught up.
        now = 10_000_000L + 8 * 60 * 60 * 1000L
        fastDevice.save(plan(updatedAt = now))
        fastDevice.sync(vineyard)
        assertEquals(1L, server.rows.getValue("plan-1").serverRevision)

        // A second device with a correct clock now edits, based on the current revision.
        val normalStore = InMemoryResistancePlanLocalStore()
        val normalDevice = repo(server, normalStore)
        now = 10_000_000L
        normalDevice.load(vineyard)
        normalDevice.sync(vineyard)
        val pulled = normalDevice.plans.value.single()
        assertEquals("second device must learn the current revision", 1L, pulled.serverRevision)

        normalDevice.save(pulled.settingNotes("honest later edit", now))
        val result = normalDevice.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals("the fast clock must not block this write", 0, result.conflicted)
        assertEquals("honest later edit", server.rows.getValue("plan-1").notes)
        assertEquals(2L, server.rows.getValue("plan-1").serverRevision)
    }

    // ==================================================================
    // 5, 6, 7. Genuine conflict — and what must survive it
    // ==================================================================

    @Test
    fun `a genuine stale edit is reported as a conflict and never as success`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan(notes = "original"))
        repository.sync(vineyard)

        // Another device saves. The row is now at revision 2; this device still holds 1.
        server.writeAsOtherDevice("plan-1", notes = "other device wins the race", atEpochMs = 50_000L)

        now = 60_000L
        repository.save(repository.plans.value.single().settingNotes("my offline edit", now))
        val result = repository.sync(vineyard)

        // The pass itself completed — this is NOT a failure.
        assertTrue("a conflict is not a transport failure", result.isSuccess)
        assertNull(result.failure)
        assertEquals(1, result.conflicted)
        assertTrue(result.hasConflicts)
        assertEquals("nothing was pushed", 0, result.pushed)

        // ...and it is NOT reported as a successful sync.
        assertEquals(ResistancePlanSyncState.CONFLICT, repository.syncState.value)
        assertFalse(repository.syncState.value == ResistancePlanSyncState.SYNCED)
    }

    @Test
    fun `a conflict is classified separately from a network failure`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan())
        repository.sync(vineyard)

        // Network failure: FAILED, no conflict recorded, retryable.
        server.failNextFetch = true
        now = 20_000L
        repository.save(repository.plans.value.single().settingNotes("edit", now))
        val failure = repository.sync(vineyard)
        assertFalse(failure.isSuccess)
        assertNotNull(failure.failure)
        assertEquals(0, failure.conflicted)
        assertEquals(ResistancePlanSyncState.FAILED, repository.syncState.value)
        assertEquals(0, repository.conflictCount())

        // Revision conflict: SUCCESS with a conflict, NOT retryable.
        server.writeAsOtherDevice("plan-1", notes = "other", atEpochMs = 30_000L)
        now = 40_000L
        repository.save(repository.plans.value.single().settingNotes("mine", now))
        val conflict = repository.sync(vineyard)
        assertTrue(conflict.isSuccess)
        assertNull(conflict.failure)
        assertEquals(1, conflict.conflicted)
        assertEquals(ResistancePlanSyncState.CONFLICT, repository.syncState.value)
        assertEquals(1, repository.conflictCount())
    }

    @Test
    fun `a conflict leaves the local mutation queued and both documents intact`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(
            plan(positions = listOf(position("p1", "3"), position("p2", "7"), position("p3", "11"))),
        )
        repository.sync(vineyard)

        server.writeAsOtherDevice("plan-1", notes = "server copy", atEpochMs = 50_000L)
        now = 60_000L
        val myVersion = repository.plans.value.single().settingNotes("my authored plan", now)
        repository.save(myVersion)
        repository.sync(vineyard)

        // OUTBOX RETAINED. The edit exists on this device and nowhere else; dropping it
        // would be the silent data loss this whole contract exists to prevent.
        assertEquals("the conflicted edit must stay queued", 1, repository.pendingCount())

        // LOCAL PENDING COPY PRESERVED — on screen and in the conflict record.
        assertEquals("my authored plan", repository.plans.value.single().notes)
        val conflict = repository.conflict("plan-1")
        assertNotNull(conflict)
        assertEquals(RESISTANCE_PLANS_ENTITY, conflict!!.entity)
        assertEquals("my authored plan", conflict.localPending.notes)
        assertEquals(3, conflict.localPending.positions.size)

        // LATEST SERVER COPY PRESERVED.
        assertNotNull("the other device's version must be kept too", conflict.serverCurrent)
        assertEquals("server copy", conflict.serverCurrent!!.notes)

        // Both revisions recorded, so a resolver knows what it is reconciling.
        assertEquals(1L, conflict.baseRevision)
        assertEquals(2L, conflict.serverRevision)
    }

    @Test
    fun `a conflict is not blindly retried`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan())
        repository.sync(vineyard)
        server.writeAsOtherDevice("plan-1", notes = "server", atEpochMs = 50_000L)
        now = 60_000L
        repository.save(repository.plans.value.single().settingNotes("mine", now))
        repository.sync(vineyard)
        assertEquals(ResistancePlanSyncState.CONFLICT, repository.syncState.value)

        // A further pass must not re-offer the same stale base_revision. Retrying it is
        // guaranteed to be refused, so a retry loop would burn battery and never converge —
        // and, worse, would keep the badge flickering as if progress were possible.
        val basesBefore = server.baseRevisionsSent.size
        val second = repository.sync(vineyard)
        assertEquals(
            "the same stale base_revision must not be resent",
            basesBefore,
            server.baseRevisionsSent.size,
        )
        assertEquals(ResistancePlanSyncState.CONFLICT, repository.syncState.value)
        assertEquals(1, repository.pendingCount())
        assertEquals("mine", repository.plans.value.single().notes)
        assertTrue(second.isSuccess)

        // The ONLY way out is an explicit resolution.
        repository.resolveKeepingLocal("plan-1")
        assertEquals(0, repository.conflictCount())
        val resolved = repository.sync(vineyard)
        assertTrue(resolved.isSuccess)
        assertEquals(0, resolved.conflicted)
        assertEquals("mine", server.rows.getValue("plan-1").notes)
    }

    @Test
    fun `resolving in favour of the server discards the local edit only when asked`() =
        runBlocking {
            val server = RevisionServer()
            val repository = repo(server)
            repository.load(vineyard)
            repository.save(plan(notes = "original"))
            repository.sync(vineyard)
            server.writeAsOtherDevice("plan-1", notes = "server version", atEpochMs = 50_000L)
            now = 60_000L
            repository.save(repository.plans.value.single().settingNotes("mine", now))
            repository.sync(vineyard)

            repository.resolveKeepingServer("plan-1")

            assertEquals("server version", repository.plans.value.single().notes)
            assertEquals("the abandoned edit must be dequeued", 0, repository.pendingCount())
            assertEquals(0, repository.conflictCount())
            assertEquals(ResistancePlanSyncState.SYNCED, repository.syncState.value)
        }

    // ==================================================================
    // 8. Whole-document semantics
    // ==================================================================

    @Test
    fun `conflicting position arrays are never element-merged`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan(positions = listOf(position("p1", "3"))))
        repository.sync(vineyard)

        // Server: 3 -> 11. Local: 3 -> 7 -> 11. A row-wise merge could yield 3 -> 7 -> 11 -> ?
        // and present a spray sequence NEITHER operator authored as resistance-compliant.
        val stored = server.rows.getValue("plan-1")
        server.rows["plan-1"] = stored.copy(
            positions = listOf(position("p1", "3"), position("p9", "11")),
            serverRevision = 2L,
        )
        now = 60_000L
        repository.save(
            repository.plans.value.single().copy(
                positions = listOf(position("p1", "3"), position("p2", "7"), position("p3", "11")),
                updatedAtEpochMs = now,
            ),
        )
        repository.sync(vineyard)

        val conflict = repository.conflict("plan-1")
        assertNotNull(conflict)
        // Each side is whole and unaltered.
        assertEquals(
            listOf("p1", "p2", "p3"),
            conflict!!.localPending.positions.map { it.id },
        )
        assertEquals(listOf("p1", "p9"), conflict.serverCurrent!!.positions.map { it.id })
        // And nothing invented a union.
        assertEquals(3, repository.plans.value.single().positions.size)
    }

    // ==================================================================
    // 9. Replica lag decided by revision, not by a clock
    // ==================================================================

    @Test
    fun `a lagging replica read cannot overwrite a revision-newer confirmed write`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan(notes = "first"))
        repository.sync(vineyard)

        // Slow device clock AND a lagging replica together — the combination that made the
        // old timestamp-based lag guard actively harmful: the "newer" local edit looked
        // older than the row it had just written, so the stale replica row won.
        now = 1_000L
        server.serveStaleReadNext = true
        repository.save(repository.plans.value.single().settingNotes("confirmed second", now))
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals(1, result.staleRemoteIgnored)
        assertEquals("confirmed second", repository.plans.value.single().notes)
        assertEquals(2L, repository.plans.value.single().serverRevision)
        assertEquals(0, repository.pendingCount())
        assertEquals(0, result.conflicted)
    }

    @Test
    fun `normal merging resumes once the replica catches up`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan(notes = "first"))
        repository.sync(vineyard)

        // The confirmed write is at revision 2 while the replica still serves revision 1.
        now = 1_000L
        server.serveStaleReadNext = true
        repository.save(repository.plans.value.single().settingNotes("confirmed second", now))
        val lagged = repository.sync(vineyard)
        assertEquals(1, lagged.staleRemoteIgnored)
        assertEquals(2L, repository.plans.value.single().serverRevision)

        // The replica catches up AND another device has since written, so the row is now at
        // revision 3. A read at-or-ahead of what this device has confirmed must be merged
        // normally — the lag guard is a guard, not a permanent refusal to accept remote state.
        server.writeAsOtherDevice("plan-1", notes = "third from elsewhere", atEpochMs = 2L)
        assertEquals(3L, server.rows.getValue("plan-1").serverRevision)
        val caughtUp = repository.sync(vineyard)

        assertTrue(caughtUp.isSuccess)
        assertEquals("a caught-up read is not stale", 0, caughtUp.staleRemoteIgnored)
        assertEquals(0, caughtUp.conflicted)
        assertEquals(
            "normal merging must resume",
            "third from elsewhere",
            repository.plans.value.single().notes,
        )
        assertEquals(3L, repository.plans.value.single().serverRevision)

        // ...and note the local clock was pinned to the PAST throughout. Under the old
        // timestamp guard the remote row looked newer than a local edit made after it, which
        // is precisely how the stale replica row used to win.
        assertEquals(1_000L, now)
    }

    @Test
    fun `an equal revision read is merged rather than rejected as stale`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan(notes = "first"))
        repository.sync(vineyard)
        assertEquals(1L, repository.plans.value.single().serverRevision)

        // A read at EXACTLY the confirmed revision is the normal steady state, not lag.
        // Treating it as stale would stop the device ever accepting remote state again.
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals(0, result.staleRemoteIgnored)
        assertEquals(1L, repository.plans.value.single().serverRevision)
    }

    // ==================================================================
    // 10. Restart durability
    // ==================================================================

    @Test
    fun `an unresolved conflict and both documents survive a repository reload`() = runBlocking {
        val server = RevisionServer()
        val store = InMemoryResistancePlanLocalStore()
        val first = repo(server, store)
        first.load(vineyard)
        first.save(plan(notes = "original"))
        first.sync(vineyard)
        server.writeAsOtherDevice("plan-1", notes = "server version", atEpochMs = 50_000L)
        now = 60_000L
        first.save(first.plans.value.single().settingNotes("my authored version", now))
        first.sync(vineyard)
        assertEquals(1, first.conflictCount())

        // App killed. A brand-new repository over the SAME store — the durability boundary.
        val reloaded = repo(server, store)
        reloaded.load(vineyard)

        assertEquals("the conflict must survive a restart", 1, reloaded.conflictCount())
        assertEquals(ResistancePlanSyncState.CONFLICT, reloaded.syncState.value)
        val conflict = reloaded.conflict("plan-1")
        assertNotNull(conflict)
        // Not just a flag: the authored payload is what matters.
        assertEquals("my authored version", conflict!!.localPending.notes)
        assertEquals("server version", conflict.serverCurrent!!.notes)
        assertEquals(1L, conflict.baseRevision)
        assertEquals(2L, conflict.serverRevision)
        assertEquals("still queued after restart", 1, reloaded.pendingCount())
        assertEquals("my authored version", reloaded.plans.value.single().notes)
    }

    // ==================================================================
    // Legacy rows and old clients
    // ==================================================================

    @Test
    fun `a row last written by an old client decodes and becomes versioned safely`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        // A pre-sql/198 row: no revision at all. Legitimate migrated state, not corruption.
        server.seedLegacyRow(plan(notes = "written by an old client"))

        repository.load(vineyard)
        val pull = repository.sync(vineyard)

        assertTrue(pull.isSuccess)
        val pulled = repository.plans.value.single()
        assertEquals("written by an old client", pulled.notes)
        assertNull("a missing revision must decode, not throw", pulled.serverRevision)
        assertEquals("a legacy row is not a conflict", 0, pull.conflicted)

        // Editing it works, and the write brings it onto the versioned contract.
        now = 70_000L
        repository.save(pulled.settingNotes("edited by a new client", now))
        val result = repository.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals(0, result.conflicted)
        assertEquals("edited by a new client", server.rows.getValue("plan-1").notes)
        assertEquals(1L, repository.plans.value.single().serverRevision)
    }

    @Test
    fun `a silent 2xx with no returned row is treated as a conflict and not as success`() =
        runBlocking {
            // The legacy silent-skip signature: HTTP success, no row, edit discarded. Under
            // sql/185 this was indistinguishable from a successful save and is exactly how
            // growers' plans disappeared.
            val silent = object : ResistancePlanRemote {
                var rows = mutableMapOf<String, ResistancePlan>()
                override suspend fun fetchAll(vineyardId: String) =
                    rows.values.filter { it.vineyardId == vineyardId }

                override suspend fun upsert(
                    plans: List<ResistancePlan>,
                ): List<VersionedWriteOutcome<ResistancePlan>> = plans.map {
                    VersionedWriteOutcome.Conflict(it.id, it.serverRevision, null)
                }

                override suspend fun softDelete(planId: String) = Unit
            }
            val repository = repo(silent)
            repository.load(vineyard)
            repository.save(plan(notes = "must not vanish"))
            val result = repository.sync(vineyard)

            assertTrue(result.isSuccess)
            assertEquals(1, result.conflicted)
            assertEquals("must not vanish", repository.plans.value.single().notes)
            assertEquals("the edit must stay queued", 1, repository.pendingCount())
            assertEquals(ResistancePlanSyncState.CONFLICT, repository.syncState.value)
        }

    // ==================================================================
    // Revision is server state, not editable content
    // ==================================================================

    @Test
    fun `a caller cannot smuggle a forged revision in through save`() = runBlocking {
        val server = RevisionServer()
        val repository = repo(server)
        repository.load(vineyard)
        repository.save(plan())
        repository.sync(vineyard)
        assertEquals(1L, repository.plans.value.single().serverRevision)

        // A stale view model, a copied object or a hand-built plan tries to assert a
        // revision. The repository must re-stamp from its own cache: a save is content, and
        // the revision is server state that no screen is allowed to author.
        now = 20_000L
        repository.save(repository.plans.value.single().copy(serverRevision = 99L, notes = "edit"))
        assertEquals(
            "the forged revision must be discarded on save",
            1L,
            repository.plans.value.single().serverRevision,
        )

        val result = repository.sync(vineyard)
        assertTrue(result.isSuccess)
        assertEquals(1L, server.baseRevisionsSent.last())
        assertEquals(0, result.conflicted)
        assertEquals(2L, repository.plans.value.single().serverRevision)
    }

    // ==================================================================
    // Conflict-body parsing
    // ==================================================================

    @Test
    fun `a PostgREST revision conflict body is recognised and mined for revisions`() {
        val body = """
            {"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 7}","hint":"Reload the row","message":"REVISION_CONFLICT"}
        """.trimIndent()

        assertTrue(SyncRevisionContract.isRevisionConflict(409, body))
        assertEquals(12L, SyncRevisionContract.serverRevisionFrom(body))
        assertEquals(7L, SyncRevisionContract.baseRevisionFrom(body))

        // Tolerance: the marker alone is enough even if the status was rewritten...
        assertTrue(SyncRevisionContract.isRevisionConflict(200, """{"message":"REVISION_CONFLICT"}"""))
        // ...and a bare 409 with no usable body is still a conflict, never a success.
        assertTrue(SyncRevisionContract.isRevisionConflict(409, null))
        assertNull(SyncRevisionContract.serverRevisionFrom(null))

        // And an ordinary server error must NOT be mistaken for one.
        assertFalse(
            SyncRevisionContract.isRevisionConflict(500, """{"message":"internal error"}"""),
        )
        assertFalse(SyncRevisionContract.isRevisionConflict(401, """{"message":"JWT expired"}"""))
    }
}
