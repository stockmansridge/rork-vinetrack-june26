package com.rork.vinetrack.data.resistance

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Local cache contract for Resistance Plans.
 *
 * An interface rather than a concrete SharedPreferences class so the repository —
 * where every conflict, adoption and merge decision actually lives — is testable in
 * a plain JVM test with no Android framework and no network. Those decisions are the
 * part that can silently lose a grower's season plan, so they must be the part under
 * test.
 */
interface ResistancePlanLocalStore {
    /** Every cached plan for a vineyard, INCLUDING soft-deleted tombstones. */
    fun loadAll(vineyardId: String): List<ResistancePlan>

    fun saveAll(vineyardId: String, plans: List<ResistancePlan>)

    /** Ids of plans with local changes not yet accepted by the server (the outbox). */
    fun loadPending(vineyardId: String): Set<String>

    fun savePending(vineyardId: String, ids: Set<String>)

    /** Whether the one-time adoption of Planner v1 local-only plans has completed. */
    fun isAdopted(vineyardId: String): Boolean

    fun markAdopted(vineyardId: String)
}

/**
 * Server contract for Resistance Plans (`public.resistance_plans`, sql/196).
 *
 * Deliberately narrow: fetch the vineyard slice, upsert whole plan documents, tombstone
 * one plan. The Planner UI never sees this type — it talks to [ResistancePlanRepository]
 * — so a screen can never issue an ad-hoc query or depend on network availability to
 * render.
 */
interface ResistancePlanRemote {
    /**
     * The full vineyard slice, INCLUDING tombstoned plans.
     *
     * Tombstones are not an implementation detail that can be filtered server-side: a
     * delete performed on another device is only observable to this one as a tombstone
     * arriving in a pull. Hiding them would make the deleted plan look merely absent,
     * and this device would helpfully push it back.
     */
    suspend fun fetchAll(vineyardId: String): List<ResistancePlan>

    /** Upsert whole plan documents. Idempotent on plan id. */
    suspend fun upsert(plans: List<ResistancePlan>)

    /** Tombstone one plan via the sql/196 soft-delete RPC. */
    suspend fun softDelete(planId: String)
}

/** Outcome of one sync pass. Returned rather than logged so tests can assert on it. */
data class ResistancePlanSyncResult(
    val pushed: Int = 0,
    val pulled: Int = 0,
    /** Plans uploaded by the one-time local-only adoption path. */
    val adopted: Int = 0,
    /** Remote plans ignored because a newer local edit is still pending. */
    val keptLocal: Int = 0,
    val deletesPushed: Int = 0,
    /** Non-null when the pass could not complete. Local state is always still usable. */
    val failure: String? = null,
) {
    val isSuccess: Boolean get() = failure == null
}

/** Where the plans currently on screen came from. Drives the sync badge in the list. */
enum class ResistancePlanSyncState {
    /** No server configured / not signed in — plans are on this device only. */
    LOCAL_ONLY,

    /** Everything local has been accepted by the server. */
    SYNCED,

    /** Local changes are waiting to upload. */
    PENDING_UPLOAD,

    /** The last sync attempt failed. Plans remain readable and editable. */
    FAILED,
}

/**
 * Offline-first, server-authoritative repository for Resistance Plans.
 *
 * ARCHITECTURE (audited against VineTrack's existing sync patterns before writing):
 * this follows the same shape as the picking-record and pruning services — a local
 * cache, an id-keyed outbox of pending writes, push-then-pull, and `client_updated_at`
 * last-write-wins arbitrated by the sql/185 stale-write trigger. No new sync framework
 * was invented, and the Planner UI is unchanged in its dependency direction: it holds a
 * repository, never a Supabase client.
 *
 * WHY WRITES NEVER WAIT FOR THE SERVER: a grower plans a season standing in a block
 * with no signal. Every mutation commits to the local cache first and returns
 * immediately; the id is minted on the device, so a plan created offline already has
 * its final identity and can be edited, reordered and reopened before it has ever been
 * uploaded. Waiting on Supabase to allocate an id would make the entire feature
 * unusable exactly where it is used.
 *
 * WHAT IS NEVER SYNCED: engine output. No status, warning, counter or explanation is
 * cached or uploaded — only the plan definition. Verdicts are recomputed from current
 * spray history on every load, because the history changes underneath a saved plan
 * (see `ResistancePlanner`). A cached "Good fit" would be a stale compliance claim.
 */
class ResistancePlanRepository(
    private val local: ResistancePlanLocalStore,
    private val remote: ResistancePlanRemote?,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val currentUserId: () -> String? = { null },
) {

    private val _plans = MutableStateFlow<List<ResistancePlan>>(emptyList())

    /** Live (non-deleted) plans for the loaded vineyard, newest first. */
    val plans: StateFlow<List<ResistancePlan>> = _plans.asStateFlow()

    private val _syncState = MutableStateFlow(
        if (remote == null) ResistancePlanSyncState.LOCAL_ONLY else ResistancePlanSyncState.SYNCED,
    )
    val syncState: StateFlow<ResistancePlanSyncState> = _syncState.asStateFlow()

    private var vineyardId: String? = null

    /** Every cached plan including tombstones. Internal to sync bookkeeping. */
    private fun allCached(vineyard: String): List<ResistancePlan> = local.loadAll(vineyard)

    // ------------------------------------------------------------------
    // Loading
    // ------------------------------------------------------------------

    /**
     * Load a vineyard's plans from the local cache. Synchronous and offline-safe: the
     * Planner opens on cached data and never blocks on a network round trip.
     */
    fun load(vineyardId: String) {
        this.vineyardId = vineyardId
        publish(allCached(vineyardId))
        refreshSyncState()
    }

    /** Plans for a season and disease, newest first. Live plans only. */
    fun plans(seasonId: String, disease: ResistanceDisease): List<ResistancePlan> =
        _plans.value.filter { it.seasonId == seasonId && it.disease == disease }

    fun plan(planId: String): ResistancePlan? = _plans.value.firstOrNull { it.id == planId }

    // ------------------------------------------------------------------
    // Mutations — always local-first
    // ------------------------------------------------------------------

    /**
     * Create or update a plan.
     *
     * Commits locally and enqueues the id. Works identically online and offline; the
     * caller gets no error to handle and no spinner to show, because nothing about the
     * grower's edit depends on connectivity.
     */
    fun save(plan: ResistancePlan) {
        val vineyard = vineyardId ?: return
        val stamped = if (plan.createdBy == null) plan.copy(createdBy = currentUserId()) else plan
        val merged = allCached(vineyard).filterNot { it.id == stamped.id } + stamped
        local.saveAll(vineyard, merged)
        local.savePending(vineyard, local.loadPending(vineyard) + stamped.id)
        publish(merged)
        refreshSyncState()
    }

    /**
     * Soft-delete (archive) a plan.
     *
     * A tombstone, never a local erasure. Dropping the row locally would leave this
     * device with nothing to tell the server about, so the plan would return on the
     * next pull — and if this device were offline at the time, the delete would simply
     * never happen. Deleting a plan removes advisory planning data only: no spray
     * record, chemical or resistance history is touched, on the server (sql/196 has no
     * FK into operational data) or here.
     */
    fun delete(planId: String) {
        val vineyard = vineyardId ?: return
        val now = clock()
        val updated = allCached(vineyard).map {
            if (it.id == planId) it.copy(deletedAtEpochMs = now, updatedAtEpochMs = now) else it
        }
        local.saveAll(vineyard, updated)
        local.savePending(vineyard, local.loadPending(vineyard) + planId)
        publish(updated)
        refreshSyncState()
    }

    /** Undo an archive. */
    fun restore(planId: String) {
        val vineyard = vineyardId ?: return
        val now = clock()
        val updated = allCached(vineyard).map {
            if (it.id == planId) it.copy(deletedAtEpochMs = null, updatedAtEpochMs = now) else it
        }
        local.saveAll(vineyard, updated)
        local.savePending(vineyard, local.loadPending(vineyard) + planId)
        publish(updated)
        refreshSyncState()
    }

    // ------------------------------------------------------------------
    // Sync
    // ------------------------------------------------------------------

    /**
     * One sync pass: adopt legacy local plans, push the outbox, pull and merge.
     *
     * Order matters. Pushing BEFORE pulling means a local edit is offered to the server
     * (and arbitrated by the sql/185 stale-write guard) before any remote version can
     * overwrite the cache, so an offline edit is never discarded by the very sync that
     * was supposed to deliver it.
     */
    suspend fun sync(vineyardId: String): ResistancePlanSyncResult {
        val server = remote ?: return ResistancePlanSyncResult(failure = null).also {
            _syncState.value = ResistancePlanSyncState.LOCAL_ONLY
        }
        this.vineyardId = vineyardId

        val adopted = adoptLocalOnlyPlans(vineyardId)

        var pushed = 0
        var deletesPushed = 0
        try {
            // Captured BEFORE the push and used for the merge decision below. The outbox
            // is deliberately NOT cleared until after the pull has been merged: a read that
            // lands on a lagging replica can return the pre-push row, and if the outbox were
            // already empty that stale row would look authoritative and overwrite the newer
            // edit the grower is looking at.
            val pending = local.loadPending(vineyardId)
            var remainingPending = pending
            if (pending.isNotEmpty()) {
                val cached = allCached(vineyardId)
                val toPush = cached.filter { pending.contains(it.id) }

                // Upsert the full document for every pending plan, tombstoned or not.
                // The tombstone must reach the server as a row update first, so a plan
                // created AND deleted while offline still exists to be soft-deleted.
                val live = toPush.filterNot { it.isDeleted }
                if (live.isNotEmpty()) {
                    server.upsert(live)
                    pushed = live.size
                }
                for (tombstoned in toPush.filter { it.isDeleted }) {
                    server.upsert(listOf(tombstoned.copy(deletedAtEpochMs = null)))
                    server.softDelete(tombstoned.id)
                    deletesPushed++
                }

                // Only ids we actually attempted are dropped. An id that vanished from
                // the cache is dropped too, so a deleted-then-purged plan cannot wedge
                // the outbox forever.
                remainingPending =
                    pending - toPush.map { it.id }.toSet() - orphanIds(pending, cached)
            }

            if (adopted > 0) local.markAdopted(vineyardId)

            val remotePlans = server.fetchAll(vineyardId)
            val merge = merge(local = allCached(vineyardId), remote = remotePlans, pending = pending)
            local.saveAll(vineyardId, merge.plans)
            // Safe to shrink the outbox only now that the pull has been reconciled. A plan
            // whose newer local copy was kept stays queued, so the next pass retries it
            // instead of leaving this device permanently ahead of the server.
            local.savePending(vineyardId, remainingPending + merge.keptLocalIds)
            publish(merge.plans)
            // `force` because a pass that has just SUCCEEDED must be able to clear a
            // previous FAILED state. Without it the badge stays red forever after one
            // dropout and stops meaning anything.
            refreshSyncState(force = true)

            return ResistancePlanSyncResult(
                pushed = pushed,
                pulled = merge.acceptedRemote,
                adopted = adopted,
                keptLocal = merge.keptLocal,
                deletesPushed = deletesPushed,
            )
        } catch (error: Exception) {
            // Everything stays in the cache and in the outbox. The grower keeps working;
            // the next successful pass replays.
            _syncState.value = ResistancePlanSyncState.FAILED
            return ResistancePlanSyncResult(
                pushed = pushed,
                adopted = adopted,
                deletesPushed = deletesPushed,
                failure = error.message ?: "Sync failed",
            )
        }
    }

    /**
     * One-time adoption of Planner v1 local-only plans.
     *
     * Existing users have plans in SharedPreferences that the server has never seen, so
     * only this device can supply them — there is no SQL backfill that could. Each keeps
     * its EXISTING id, which is what makes the upload idempotent: a repeated run upserts
     * the same primary key instead of minting a second copy of the same season plan.
     *
     * Returns the number of plans enqueued. The adopted flag is set only AFTER the push
     * succeeds (see [sync]), so a mid-migration network failure leaves the plans local,
     * usable and still queued rather than marked done and silently unsynced.
     */
    private fun adoptLocalOnlyPlans(vineyardId: String): Int {
        if (remote == null) return 0
        if (local.isAdopted(vineyardId)) return 0
        val existing = allCached(vineyardId)
        if (existing.isEmpty()) {
            // Nothing to carry across; record completion so this never runs again.
            local.markAdopted(vineyardId)
            return 0
        }
        local.savePending(vineyardId, local.loadPending(vineyardId) + existing.map { it.id }.toSet())
        return existing.size
    }

    private fun orphanIds(pending: Set<String>, cached: List<ResistancePlan>): Set<String> {
        val cachedIds = cached.map { it.id }.toSet()
        return pending.filterNot { cachedIds.contains(it) }.toSet()
    }

    private data class MergeOutcome(
        val plans: List<ResistancePlan>,
        val acceptedRemote: Int,
        val keptLocal: Int,
        val keptLocalIds: Set<String> = emptySet(),
    )

    /**
     * Whole-document last-write-wins.
     *
     * A remote plan is adopted UNLESS this device still holds an unpushed edit that is
     * strictly newer. Position arrays are NEVER merged element-by-element: there is no
     * defensible automatic reconciliation of "A moved the Group 11 spray earlier"
     * against "B removed that spray", and any row-wise merge could produce a spray
     * sequence that neither operator authored and then present it as resistance-compliant.
     * Losing the older edit is visible and recoverable; inventing a third plan is not.
     */
    private fun merge(
        local: List<ResistancePlan>,
        remote: List<ResistancePlan>,
        pending: Set<String>,
    ): MergeOutcome {
        val localById = local.associateBy { it.id }
        val result = linkedMapOf<String, ResistancePlan>()
        local.forEach { result[it.id] = it }

        var accepted = 0
        val keptIds = mutableSetOf<String>()
        for (row in remote) {
            val mine = localById[row.id]
            val hasNewerLocalEdit = mine != null &&
                pending.contains(row.id) &&
                mine.updatedAtEpochMs > row.updatedAtEpochMs
            if (hasNewerLocalEdit) {
                keptIds += row.id
                continue
            }
            result[row.id] = row
            accepted++
        }
        return MergeOutcome(result.values.toList(), accepted, keptIds.size, keptIds)
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private fun publish(all: List<ResistancePlan>) {
        _plans.value = all
            .filterNot { it.isDeleted }
            .sortedByDescending { it.updatedAtEpochMs }
    }

    private fun refreshSyncState(force: Boolean = false) {
        val vineyard = vineyardId ?: return
        if (remote == null) {
            _syncState.value = ResistancePlanSyncState.LOCAL_ONLY
            return
        }
        // A local edit must not silently downgrade a FAILED badge to "pending": the last
        // attempt really did fail, and the grower should keep seeing that until a pass
        // actually succeeds.
        if (!force && _syncState.value == ResistancePlanSyncState.FAILED) return
        _syncState.value =
            if (local.loadPending(vineyard).isEmpty()) ResistancePlanSyncState.SYNCED
            else ResistancePlanSyncState.PENDING_UPLOAD
    }

    /** Pending-upload count, for the plan list badge. */
    fun pendingCount(): Int = vineyardId?.let { local.loadPending(it).size } ?: 0

    companion object {
        /**
         * Shown when no server is configured. The honest version of the v1 notice: the
         * limitation is the session, not the feature.
         */
        const val LOCAL_ONLY_NOTICE =
            "Resistance plans are saved on this device only until you sign in. " +
                "Once signed in they sync to your vineyard and your team."

        const val SYNCED_NOTICE =
            "Resistance plans are shared with your vineyard team and sync across devices."

        const val PENDING_NOTICE =
            "Changes are saved on this device and will upload when you are back online."

        const val FAILED_NOTICE =
            "Could not sync resistance plans. Your changes are saved on this device and will retry."
    }
}
