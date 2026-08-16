package com.rork.vinetrack.data

import com.rork.vinetrack.data.resistance.InMemoryResistancePlanLocalStore
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceGroupSignature
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanRemote
import com.rork.vinetrack.data.resistance.ResistancePlanRepository
import com.rork.vinetrack.data.resistance.ResistancePlanSyncState
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Persistence, offline and multi-device tests for [ResistancePlanRepository].
 *
 * The fake server below is not a rubber stamp: it enforces the same rules sql/196 and
 * sql/185 enforce (vineyard isolation, whole-document upsert, tombstone-on-RPC and the
 * stale-write guard). A fake that accepted everything would let a conflict bug pass here
 * and only surface as a lost season plan in a vineyard.
 *
 * Mirrored on iOS by `ResistancePlanRepositoryTests.swift`.
 */
class ResistancePlanRepositoryTest {

    // ------------------------------------------------------------------
    // Fake server
    // ------------------------------------------------------------------

    /**
     * In-memory stand-in for `public.resistance_plans`.
     *
     * Enforces:
     *  - vineyard isolation on read;
     *  - whole-document upsert keyed on plan id (so a repeated push is idempotent);
     *  - `created_by` write-once (the sql/196 attribution guard);
     *  - the sql/185 STALE-WRITE GUARD: an upsert whose updatedAt is older than the
     *    stored row's is silently skipped, exactly as the trigger does.
     */
    private class FakeServer(
        var failNextUpsert: Boolean = false,
        var failNextFetch: Boolean = false,
        /**
         * Serve the NEXT read from the state captured before the last upsert.
         *
         * Models read-after-write replica lag, which is a real PostgREST/Postgres
         * behaviour and not a hypothetical: the push genuinely succeeded, but the
         * follow-up read lands on a replica that has not caught up and returns the
         * PREVIOUS row. That stale row must never be allowed to overwrite the newer edit
         * the grower is looking at. A fake that only ever threw could not reproduce this.
         */
        var serveStaleReadNext: Boolean = false,
    ) : ResistancePlanRemote {
        /** State captured immediately before the most recent upsert applied. */
        private var lagSnapshot: List<ResistancePlan> = emptyList()
        val rows = mutableMapOf<String, ResistancePlan>()
        var upsertCalls = 0
        var softDeleteCalls = 0
        val upsertedIds = mutableListOf<String>()

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

        override suspend fun upsert(plans: List<ResistancePlan>) {
            if (failNextUpsert) {
                failNextUpsert = false
                throw IllegalStateException("offline")
            }
            lagSnapshot = rows.values.toList()
            upsertCalls++
            for (plan in plans) {
                upsertedIds += plan.id
                val existing = rows[plan.id]
                if (existing != null && plan.updatedAtEpochMs < existing.updatedAtEpochMs) {
                    // sql/185: a late offline replay must not overwrite a newer edit.
                    continue
                }
                rows[plan.id] = plan.copy(
                    // sql/196 attribution guard: created_by is write-once.
                    createdBy = existing?.createdBy ?: plan.createdBy,
                    // The server owns the tombstone; an upsert never sets it.
                    deletedAtEpochMs = existing?.deletedAtEpochMs,
                )
            }
        }

        override suspend fun softDelete(planId: String) {
            softDeleteCalls++
            val existing = rows[planId] ?: return
            rows[planId] = existing.copy(deletedAtEpochMs = existing.updatedAtEpochMs + 1)
        }
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    private val vineyard = "vy-1"
    private val otherVineyard = "vy-2"

    private fun product(vararg codes: String, chemicalId: String? = null) = ResistancePlannedProduct(
        id = "prod-${codes.joinToString("-")}-${chemicalId ?: "g"}",
        groupCodes = codes.toList(),
        source = if (chemicalId == null) ResistancePlannedChemistrySource.GROUP
        else ResistancePlannedChemistrySource.SAVED_CHEMICAL,
        savedChemicalId = chemicalId,
        productName = chemicalId?.let { "Product $it" },
    )

    private fun position(id: String, vararg codes: String) =
        ResistancePlannedPosition(id = id, products = listOf(product(*codes)))

    private fun plan(
        id: String = "plan-1",
        vineyardId: String = vineyard,
        seasonId: String = "2026/27",
        disease: ResistanceDisease = ResistanceDisease.POWDERY_MILDEW,
        positions: List<ResistancePlannedPosition> = listOf(
            position("pos-1", "3"), position("pos-2", "7"), position("pos-3", "11"),
        ),
        blockIds: List<String> = listOf("block-a"),
        rulesetVersion: String? = "2026.07.22",
        updatedAt: Long = 1_000L,
    ) = ResistancePlan(
        id = id,
        vineyardId = vineyardId,
        seasonId = seasonId,
        seasonStartYear = 2026,
        disease = disease,
        jurisdiction = ResistanceJurisdiction.AUSTRALIA,
        crop = ResistanceCrop.GRAPE,
        blockIds = blockIds,
        positions = positions,
        rulesetId = "AU_GRAPE_POWDERY_2026_07_22",
        rulesetVersion = rulesetVersion,
        createdAtEpochMs = 1_000L,
        updatedAtEpochMs = updatedAt,
    )

    private var now = 10_000L

    private fun repo(
        server: ResistancePlanRemote?,
        store: InMemoryResistancePlanLocalStore = InMemoryResistancePlanLocalStore(),
        userId: String? = "user-1",
    ) = ResistancePlanRepository(
        local = store,
        remote = server,
        clock = { now },
        currentUserId = { userId },
    )

    // ==================================================================
    // Create / save / reload
    // ==================================================================

    @Test
    fun `a saved plan reloads with its positions in order`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(plan())

        val reloaded = repo(null, store)
        reloaded.load(vineyard)

        val loaded = reloaded.plans.value.single()
        assertEquals("plan-1", loaded.id)
        assertEquals(listOf("pos-1", "pos-2", "pos-3"), loaded.positions.map { it.id })
        assertEquals(listOf("3", "7", "11"), loaded.positions.map { it.products.single().groupCodes.single() })
    }

    @Test
    fun `an edit survives a reload`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(plan())
        repository.save(repository.plans.value.single().settingNotes("mildew pressure high", now))

        val reloaded = repo(null, store)
        reloaded.load(vineyard)
        assertEquals("mildew pressure high", reloaded.plans.value.single().notes)
    }

    @Test
    fun `a reorder is persisted and position ids are unchanged`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(plan())

        val moved = repository.plans.value.single().movingPositionUp("pos-3", now)
        repository.save(moved)

        val reloaded = repo(null, store)
        reloaded.load(vineyard)
        val loaded = reloaded.plans.value.single()

        // Sequence changed...
        assertEquals(listOf("pos-1", "pos-3", "pos-2"), loaded.positions.map { it.id })
        // ...identity did not. This is the seam a future actual-spray association hangs
        // off: if reordering minted new ids, every past association would silently break.
        assertEquals(setOf("pos-1", "pos-2", "pos-3"), loaded.positions.map { it.id }.toSet())
    }

    @Test
    fun `plan ids are stable across every edit`() {
        val repository = repo(null)
        repository.load(vineyard)
        repository.save(plan())
        val original = repository.plans.value.single().id

        repository.save(repository.plans.value.single().settingNotes("a", now))
        repository.save(repository.plans.value.single().movingPositionDown("pos-1", now))
        repository.save(repository.plans.value.single().settingBlockIds(listOf("block-b"), now))

        assertEquals(original, repository.plans.value.single().id)
    }

    // ==================================================================
    // Multiple plans, isolation
    // ==================================================================

    @Test
    fun `a vineyard may hold two plans for the same season and disease`() {
        // A grower legitimately keeps "conservative" and "aggressive" plans side by side.
        // Keying plans by season+disease+blocks would have silently overwritten one.
        val repository = repo(null)
        repository.load(vineyard)
        repository.save(plan(id = "plan-a"))
        repository.save(plan(id = "plan-b"))

        val same = repository.plans("2026/27", ResistanceDisease.POWDERY_MILDEW)
        assertEquals(2, same.size)
        assertEquals(setOf("plan-a", "plan-b"), same.map { it.id }.toSet())
    }

    @Test
    fun `different vineyards are isolated in the cache`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)

        repository.load(vineyard)
        repository.save(plan(id = "plan-a", vineyardId = vineyard))

        repository.load(otherVineyard)
        repository.save(plan(id = "plan-b", vineyardId = otherVineyard))
        assertEquals(listOf("plan-b"), repository.plans.value.map { it.id })

        repository.load(vineyard)
        assertEquals(listOf("plan-a"), repository.plans.value.map { it.id })
    }

    @Test
    fun `the server slice is scoped to the vineyard`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val a = repo(server, store)
        a.load(vineyard)
        a.save(plan(id = "plan-a", vineyardId = vineyard))
        a.sync(vineyard)

        val b = repo(server, InMemoryResistancePlanLocalStore())
        b.load(otherVineyard)
        b.sync(otherVineyard)
        assertTrue("another vineyard's plan leaked", b.plans.value.isEmpty())
    }

    // ==================================================================
    // Offline
    // ==================================================================

    @Test
    fun `a plan created offline gets its id immediately and is editable`() {
        // No server at all: the id must come from the device, not from Supabase.
        val repository = repo(null)
        repository.load(vineyard)
        val created = plan(id = "offline-plan")
        repository.save(created)

        assertEquals("offline-plan", repository.plans.value.single().id)

        repository.save(repository.plans.value.single().addingPosition(position("pos-4", "40"), now))
        assertEquals(4, repository.plans.value.single().positions.size)
    }

    @Test
    fun `an offline create is queued and replays on the next sync`() = runBlocking {
        val server = FakeServer(failNextUpsert = true)
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(server, store)
        repository.load(vineyard)
        repository.save(plan(id = "queued"))

        // First pass: the network is down.
        val failed = repository.sync(vineyard)
        assertFalse(failed.isSuccess)
        assertTrue("server should hold nothing yet", server.rows.isEmpty())
        // The plan is still there and still queued — nothing was dropped.
        assertEquals("queued", repository.plans.value.single().id)
        assertEquals(ResistancePlanSyncState.FAILED, repository.syncState.value)
        assertEquals(1, repository.pendingCount())

        // Second pass: back online.
        val ok = repository.sync(vineyard)
        assertTrue("replay failed: ${ok.failure}", ok.isSuccess)
        assertEquals(1, server.rows.size)
        assertEquals("queued", server.rows.values.single().id)
        assertEquals(0, repository.pendingCount())
        assertEquals(ResistancePlanSyncState.SYNCED, repository.syncState.value)
    }

    @Test
    fun `an offline edit to a previously synced plan replays`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(server, store)
        repository.load(vineyard)
        repository.save(plan(id = "p"))
        repository.sync(vineyard)

        // Offline edit.
        now = 20_000L
        server.failNextUpsert = true
        repository.save(repository.plans.value.single().settingNotes("added offline", now))
        repository.sync(vineyard)
        assertEquals("edit must not reach the server yet", null, server.rows["p"]?.notes)

        // Reconnect.
        val ok = repository.sync(vineyard)
        assertTrue(ok.isSuccess)
        assertEquals("added offline", server.rows["p"]?.notes)
    }

    @Test
    fun `only the plan definition is queued - no evaluation output`() {
        // Structural guarantee: the plan model has no field that could carry a verdict,
        // so the outbox physically cannot contain one. If someone later adds a
        // `lastStatus` to ResistancePlan, this test is what should stop them.
        val fields = ResistancePlan::class.java.declaredFields.map { it.name.lowercase() }
        val forbidden = listOf("status", "verdict", "warning", "finding", "evaluation", "goodfit")
        for (word in forbidden) {
            assertFalse(
                "ResistancePlan must not persist derived evaluation output ($word)",
                fields.any { it.contains(word) },
            )
        }
    }

    // ==================================================================
    // Multi-device
    // ==================================================================

    @Test
    fun `device B sees the plan device A created and A converges on B's edit`() = runBlocking {
        val server = FakeServer()
        val deviceA = repo(server, InMemoryResistancePlanLocalStore())
        val deviceB = repo(server, InMemoryResistancePlanLocalStore())

        // 1-2. A creates and syncs.
        deviceA.load(vineyard)
        deviceA.save(plan(id = "shared", updatedAt = 1_000L))
        assertTrue(deviceA.sync(vineyard).isSuccess)

        // 3. B loads.
        deviceB.load(vineyard)
        assertTrue(deviceB.sync(vineyard).isSuccess)
        val onB = deviceB.plans.value.single()
        assertEquals("shared", onB.id)
        assertEquals(listOf("pos-1", "pos-2", "pos-3"), onB.positions.map { it.id })

        // 4-5. B reorders a planned position and syncs.
        now = 30_000L
        deviceB.save(onB.movingPositionUp("pos-3", now))
        assertTrue(deviceB.sync(vineyard).isSuccess)

        // 6-7. A refreshes: SAME plan id, updated content.
        assertTrue(deviceA.sync(vineyard).isSuccess)
        val onA = deviceA.plans.value.single()
        assertEquals("shared", onA.id)
        assertEquals(listOf("pos-1", "pos-3", "pos-2"), onA.positions.map { it.id })
    }

    @Test
    fun `a stale offline replay does not overwrite a newer edit from another device`() = runBlocking {
        val server = FakeServer()
        val deviceA = repo(server, InMemoryResistancePlanLocalStore())
        val deviceB = repo(server, InMemoryResistancePlanLocalStore())

        deviceA.load(vineyard)
        deviceA.save(plan(id = "shared", updatedAt = 1_000L))
        deviceA.sync(vineyard)
        deviceB.load(vineyard)
        deviceB.sync(vineyard)

        // A edits OFFLINE at T1.
        now = 2_000L
        server.failNextUpsert = true
        deviceA.save(deviceA.plans.value.single().settingNotes("A offline at T1", 2_000L))
        deviceA.sync(vineyard)

        // B edits ONLINE at T2 > T1.
        now = 3_000L
        deviceB.save(deviceB.plans.value.single().settingNotes("B online at T2", 3_000L))
        assertTrue(deviceB.sync(vineyard).isSuccess)
        assertEquals("B online at T2", server.rows["shared"]?.notes)

        // A reconnects and replays its older edit: the guard skips it.
        deviceA.sync(vineyard)
        assertEquals(
            "a late offline replay overwrote a newer edit",
            "B online at T2",
            server.rows["shared"]?.notes,
        )

        // And A converges on the authoritative version rather than keeping its own.
        assertEquals("B online at T2", deviceA.plans.value.single().notes)
    }

    @Test
    fun `a newer local edit is kept when the remote copy is older`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(server, store)
        repository.load(vineyard)
        repository.save(plan(id = "p", updatedAt = 1_000L))
        repository.sync(vineyard)

        // The push succeeds, but the pull in the same pass lands on a LAGGING REPLICA and
        // returns the pre-push row. That older row must not clobber the newer local edit
        // the grower is looking at, and the plan must stay queued so the next pass retries.
        now = 5_000L
        server.serveStaleReadNext = true
        repository.save(repository.plans.value.single().settingNotes("newer local", 5_000L))
        val result = repository.sync(vineyard)

        assertTrue("sync should have completed", result.isSuccess)
        assertEquals("newer local", repository.plans.value.single().notes)
        assertEquals(1, result.keptLocal)
        assertEquals("the kept plan must stay queued", 1, repository.pendingCount())

        // And the next pass, reading a caught-up replica, converges without losing the edit.
        assertTrue(repository.sync(vineyard).isSuccess)
        assertEquals("newer local", repository.plans.value.single().notes)
        assertEquals(0, repository.pendingCount())
    }

    @Test
    fun `position arrays from two devices are never merged element-wise`() = runBlocking {
        val server = FakeServer()
        val deviceA = repo(server, InMemoryResistancePlanLocalStore())
        val deviceB = repo(server, InMemoryResistancePlanLocalStore())

        deviceA.load(vineyard)
        deviceA.save(plan(id = "shared", updatedAt = 1_000L))
        deviceA.sync(vineyard)
        deviceB.load(vineyard)
        deviceB.sync(vineyard)

        // A removes a position; B reorders. One whole document must win.
        deviceA.save(deviceA.plans.value.single().removingPosition("pos-2", 2_000L))
        deviceA.sync(vineyard)
        deviceB.save(deviceB.plans.value.single().movingPositionUp("pos-3", 3_000L))
        deviceB.sync(vineyard)

        deviceA.sync(vineyard)
        val winner = deviceA.plans.value.single().positions.map { it.id }
        // B's document won outright. Critically it is one of the two AUTHORED sequences,
        // not a spliced third one like [pos-1, pos-3] that nobody chose.
        assertEquals(listOf("pos-1", "pos-3", "pos-2"), winner)
    }

    // ==================================================================
    // Delete / archive
    // ==================================================================

    @Test
    fun `delete archives locally and tombstones on the server`() = runBlocking {
        val server = FakeServer()
        val repository = repo(server, InMemoryResistancePlanLocalStore())
        repository.load(vineyard)
        repository.save(plan(id = "doomed"))
        repository.sync(vineyard)

        now = 40_000L
        repository.delete("doomed")
        assertTrue("archived plan must leave the live list", repository.plans.value.isEmpty())

        assertTrue(repository.sync(vineyard).isSuccess)
        assertEquals(1, server.softDeleteCalls)
        assertNotNull("server row must be tombstoned, not removed", server.rows["doomed"])
        assertNotNull(server.rows["doomed"]?.deletedAtEpochMs)
    }

    @Test
    fun `a delete propagates to the other device instead of being resurrected`() = runBlocking {
        val server = FakeServer()
        val deviceA = repo(server, InMemoryResistancePlanLocalStore())
        val deviceB = repo(server, InMemoryResistancePlanLocalStore())

        deviceA.load(vineyard)
        deviceA.save(plan(id = "shared"))
        deviceA.sync(vineyard)
        deviceB.load(vineyard)
        deviceB.sync(vineyard)
        assertEquals(1, deviceB.plans.value.size)

        now = 50_000L
        deviceA.delete("shared")
        deviceA.sync(vineyard)

        // B pulls the tombstone and stops showing the plan. It must NOT push it back.
        deviceB.sync(vineyard)
        assertTrue("the deleted plan came back on device B", deviceB.plans.value.isEmpty())
        assertNotNull(server.rows["shared"]?.deletedAtEpochMs)
    }

    @Test
    fun `a plan created and deleted while offline still deletes on reconnect`() = runBlocking {
        val server = FakeServer()
        val repository = repo(server, InMemoryResistancePlanLocalStore())
        repository.load(vineyard)
        // Never synced.
        repository.save(plan(id = "ghost"))
        now = 60_000L
        repository.delete("ghost")

        assertTrue(repository.sync(vineyard).isSuccess)
        // The row had to be created before it could be tombstoned, otherwise the delete
        // would silently target nothing and the plan would reappear from the outbox.
        assertNotNull(server.rows["ghost"])
        assertNotNull(server.rows["ghost"]?.deletedAtEpochMs)
        assertTrue(repository.plans.value.isEmpty())
    }

    @Test
    fun `restore brings an archived plan back`() {
        val repository = repo(null)
        repository.load(vineyard)
        repository.save(plan(id = "p"))
        repository.delete("p")
        assertTrue(repository.plans.value.isEmpty())

        repository.restore("p")
        assertEquals("p", repository.plans.value.single().id)
    }

    // ==================================================================
    // Local-only adoption (Planner v1 -> synced)
    // ==================================================================

    @Test
    fun `existing local-only plans are uploaded once and keep their ids`() = runBlocking {
        val store = InMemoryResistancePlanLocalStore()

        // Planner v1: two plans saved with no server at all.
        val legacy = repo(null, store)
        legacy.load(vineyard)
        legacy.save(plan(id = "legacy-1"))
        legacy.save(plan(id = "legacy-2", seasonId = "2025/26"))

        // First synced launch.
        val server = FakeServer()
        val synced = repo(server, store)
        synced.load(vineyard)
        val result = synced.sync(vineyard)

        assertTrue(result.isSuccess)
        assertEquals(2, result.adopted)
        assertEquals(setOf("legacy-1", "legacy-2"), server.rows.keys)
        // Ids preserved — this is what makes the upload idempotent rather than a second
        // copy of the same season.
        assertEquals(2, server.rows.size)
    }

    @Test
    fun `a second migration run does not duplicate the adopted plans`() = runBlocking {
        val store = InMemoryResistancePlanLocalStore()
        val legacy = repo(null, store)
        legacy.load(vineyard)
        legacy.save(plan(id = "legacy-1"))

        val server = FakeServer()
        val synced = repo(server, store)
        synced.load(vineyard)
        synced.sync(vineyard)
        val callsAfterFirst = server.upsertCalls

        // Relaunch, sync again, and again.
        val relaunched = repo(server, store)
        relaunched.load(vineyard)
        val second = relaunched.sync(vineyard)
        relaunched.sync(vineyard)

        assertEquals(0, second.adopted)
        assertEquals(1, server.rows.size)
        assertEquals("legacy-1", server.rows.values.single().id)
        assertTrue("adoption re-ran and re-pushed", server.upsertCalls <= callsAfterFirst)
    }

    @Test
    fun `a local plan stays usable when the network fails during migration`() = runBlocking {
        val store = InMemoryResistancePlanLocalStore()
        val legacy = repo(null, store)
        legacy.load(vineyard)
        legacy.save(plan(id = "legacy-1"))

        val server = FakeServer(failNextUpsert = true)
        val synced = repo(server, store)
        synced.load(vineyard)
        val failed = synced.sync(vineyard)

        assertFalse(failed.isSuccess)
        // Still readable, still editable, still queued.
        assertEquals("legacy-1", synced.plans.value.single().id)
        synced.save(synced.plans.value.single().settingNotes("still editable", now))
        assertEquals("still editable", synced.plans.value.single().notes)
        assertFalse("migration must not be marked done after a failure", store.isAdopted(vineyard))

        // And it completes later.
        assertTrue(synced.sync(vineyard).isSuccess)
        assertEquals(1, server.rows.size)
        assertTrue(store.isAdopted(vineyard))
    }

    @Test
    fun `a fresh install with no local plans marks adoption complete without uploading`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(server, store)
        repository.load(vineyard)
        val result = repository.sync(vineyard)

        assertEquals(0, result.adopted)
        assertEquals(0, server.upsertCalls)
        assertTrue(store.isAdopted(vineyard))
    }

    // ==================================================================
    // Ruleset metadata
    // ==================================================================

    @Test
    fun `ruleset id and version survive a save and reload`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(plan())

        val reloaded = repo(null, store)
        reloaded.load(vineyard)
        val loaded = reloaded.plans.value.single()
        assertEquals("AU_GRAPE_POWDERY_2026_07_22", loaded.rulesetId)
        assertEquals("2026.07.22", loaded.rulesetVersion)
    }

    @Test
    fun `a plan stamped with the current version reports no update available`() {
        val registry = com.rork.vinetrack.data.resistance.ResistanceRulesets.registry
        val current = registry.current(
            ResistanceJurisdiction.AUSTRALIA, ResistanceCrop.GRAPE, ResistanceDisease.POWDERY_MILDEW,
        )
        assertNotNull(current)
        val saved = plan(rulesetVersion = current!!.rulesetVersion)
        assertFalse(saved.isStrategyOutdated(registry))
    }

    @Test
    fun `a plan stamped with an older version reports an update available`() {
        val registry = com.rork.vinetrack.data.resistance.ResistanceRulesets.registry
        val saved = plan(rulesetVersion = "2019.01.01")
        assertTrue(saved.isStrategyOutdated(registry))
        // And the stored stamp is NOT rewritten by asking the question.
        assertEquals("2019.01.01", saved.rulesetVersion)
    }

    @Test
    fun `syncing never rewrites a plan's stamped ruleset version`() = runBlocking {
        val server = FakeServer()
        val repository = repo(server, InMemoryResistancePlanLocalStore())
        repository.load(vineyard)
        repository.save(plan(id = "old", rulesetVersion = "2019.01.01"))
        repository.sync(vineyard)

        assertEquals("2019.01.01", server.rows["old"]?.rulesetVersion)
        assertEquals("2019.01.01", repository.plans.value.single().rulesetVersion)
    }

    // ==================================================================
    // Tolerance for deleted references
    // ==================================================================

    @Test
    fun `a position keeps its planned group when the saved chemical is gone`() {
        // The Chemical Store product was deleted after planning. The plan must still know
        // WHAT CHEMISTRY it intended, which is why group codes are stored alongside the
        // product id rather than being re-derived from today's product record.
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(
            plan(
                positions = listOf(
                    ResistancePlannedPosition(
                        id = "pos-1",
                        products = listOf(product("7", chemicalId = "chem-deleted")),
                    ),
                ),
            ),
        )

        val reloaded = repo(null, store)
        reloaded.load(vineyard)
        val loaded = reloaded.plans.value.single().positions.single().products.single()

        assertEquals(listOf("7"), loaded.groupCodes)
        assertEquals("chem-deleted", loaded.savedChemicalId)
        assertEquals(ResistancePlannedChemistrySource.SAVED_CHEMICAL, loaded.source)
        // The intent is intact even though nothing can resolve the product any more.
        assertEquals(ResistanceGroupSignature.of(listOf("7")), loaded.groups)
    }

    @Test
    fun `a plan keeps a block id that no longer resolves`() {
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(null, store)
        repository.load(vineyard)
        repository.save(plan(blockIds = listOf("block-a", "block-archived")))

        val reloaded = repo(null, store)
        reloaded.load(vineyard)
        assertEquals(listOf("block-a", "block-archived"), reloaded.plans.value.single().blockIds)
    }

    // ==================================================================
    // Sync state reporting
    // ==================================================================

    @Test
    fun `sync state reports local-only when there is no server`() {
        val repository = repo(null)
        repository.load(vineyard)
        repository.save(plan())
        assertEquals(ResistancePlanSyncState.LOCAL_ONLY, repository.syncState.value)
    }

    @Test
    fun `sync state reports pending upload after an offline edit`() {
        val repository = repo(FakeServer())
        repository.load(vineyard)
        repository.save(plan())
        assertEquals(ResistancePlanSyncState.PENDING_UPLOAD, repository.syncState.value)
    }

    @Test
    fun `a failed fetch leaves the cache intact`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val repository = repo(server, store)
        repository.load(vineyard)
        repository.save(plan(id = "p"))
        repository.sync(vineyard)

        server.failNextFetch = true
        val result = repository.sync(vineyard)
        assertFalse(result.isSuccess)
        assertEquals("p", repository.plans.value.single().id)
    }

    // ==================================================================
    // Cross-platform JSON parity
    // ==================================================================

    @Test
    fun `the positions document uses the shared snake_case wire contract`() {
        // These exact keys are asserted on iOS too. A silent rename on one platform is
        // how "the plan I made on my phone is empty on the iPad" happens.
        val json = kotlinx.serialization.json.Json { encodeDefaults = true; explicitNulls = false }
        val encoded = json.encodeToString(
            ResistancePlannedPosition(
                id = "pos-1",
                products = listOf(product("11", "3", chemicalId = "chem-1")),
                targetDateEpochMs = 1_790_000_000_000L,
                growthStage = "flowering",
                note = "n",
            ),
        )

        for (key in listOf(
            "\"id\"", "\"products\"", "\"group_codes\"", "\"source\"",
            "\"saved_chemical_id\"", "\"product_name\"",
            "\"target_date_epoch_ms\"", "\"growth_stage\"", "\"note\"",
        )) {
            assertTrue("missing wire key $key in $encoded", encoded.contains(key))
        }
        // camelCase must never appear.
        assertFalse(encoded.contains("groupCodes"))
        assertFalse(encoded.contains("savedChemicalId"))
        assertFalse(encoded.contains("targetDateEpochMs"))
        assertEquals("saved_chemical", ResistancePlannedChemistrySource.SAVED_CHEMICAL.raw)
    }

    @Test
    fun `a plan document decodes from the shared wire form`() {
        // Byte-for-byte what iOS emits, decoded here.
        val wire = """
        {
          "id": "plan-x",
          "vineyard_id": "vy-1",
          "season_id": "2026/27",
          "season_start_year": 2026,
          "disease": "powdery_mildew",
          "jurisdiction": "AU",
          "crop": "grape",
          "block_ids": ["block-a", "block-b"],
          "positions": [
            {"id":"pos-1","products":[{"id":"pr-1","group_codes":["3"],"source":"group"}]},
            {"id":"pos-2","products":[{"id":"pr-2","group_codes":["11","3"],"source":"saved_chemical","saved_chemical_id":"c1","product_name":"Mix","chemical_availability":"available_verified"}],"target_date_epoch_ms":1790000000000,"growth_stage":"flowering"}
          ],
          "notes": "n",
          "ruleset_id": "AU_GRAPE_POWDERY_2026_07_22",
          "ruleset_version": "2026.07.22",
          "created_by": "user-1",
          "created_at_epoch_ms": 1000,
          "updated_at_epoch_ms": 2000
        }
        """.trimIndent()

        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val decoded = json.decodeFromString<ResistancePlan>(wire)

        assertEquals("plan-x", decoded.id)
        assertEquals(2026, decoded.seasonStartYear)
        assertEquals(ResistanceDisease.POWDERY_MILDEW, decoded.disease)
        assertEquals(ResistanceJurisdiction.AUSTRALIA, decoded.jurisdiction)
        assertEquals(listOf("block-a", "block-b"), decoded.blockIds)
        assertEquals(listOf("pos-1", "pos-2"), decoded.positions.map { it.id })
        assertEquals(listOf("11", "3"), decoded.positions[1].products.single().groupCodes)
        assertEquals("c1", decoded.positions[1].products.single().savedChemicalId)
        assertEquals(1_790_000_000_000L, decoded.positions[1].targetDateEpochMs)
        assertEquals("2026.07.22", decoded.rulesetVersion)
        assertEquals("user-1", decoded.createdBy)
        assertNull(decoded.deletedAtEpochMs)
    }

    @Test
    fun `created_by is stamped once and not rewritten by a later editor`() = runBlocking {
        val server = FakeServer()
        val store = InMemoryResistancePlanLocalStore()
        val author = ResistancePlanRepository(store, server, { now }, { "author" })
        author.load(vineyard)
        author.save(plan(id = "p"))
        author.sync(vineyard)
        assertEquals("author", server.rows["p"]?.createdBy)

        // A colleague edits the same plan from their own device.
        val colleagueStore = InMemoryResistancePlanLocalStore()
        val colleague = ResistancePlanRepository(colleagueStore, server, { now }, { "colleague" })
        colleague.load(vineyard)
        colleague.sync(vineyard)
        now = 70_000L
        colleague.save(colleague.plans.value.single().settingNotes("colleague edit", now))
        colleague.sync(vineyard)

        assertEquals("colleague edit", server.rows["p"]?.notes)
        assertEquals("attribution was overwritten", "author", server.rows["p"]?.createdBy)
    }
}
