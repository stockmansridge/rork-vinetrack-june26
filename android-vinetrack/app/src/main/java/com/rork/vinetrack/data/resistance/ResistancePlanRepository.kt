package com.rork.vinetrack.data.resistance

import com.rork.vinetrack.data.sync.SyncRevisionConflict
import com.rork.vinetrack.data.sync.VersionedWriteOutcome
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A Resistance Plan write the server refused because the row had moved on (sql/198). */
typealias ResistancePlanConflict = SyncRevisionConflict<ResistancePlan>

/** Table name used in conflict records and audit trails. */
const val RESISTANCE_PLANS_ENTITY: String = "resistance_plans"

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

    /**
     * Unresolved revision conflicts, with BOTH authored documents intact.
     *
     * Persisted rather than in-memory: a conflict means the grower's version exists
     * nowhere but this device, so it has to survive the app being killed.
     */
    fun loadConflicts(vineyardId: String): List<ResistancePlanConflict>

    fun saveConflicts(vineyardId: String, conflicts: List<ResistancePlanConflict>)
}

/**
 * Server contract for Resistance Plans (`public.resistance_plans`, sql/196 + sql/198).
 *
 * Deliberately narrow: fetch the vineyard slice, write whole plan documents, tombstone
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

    /**
     * Versioned whole-document write, ONE OUTCOME PER PLAN.
     *
     * Per-plan outcomes rather than one batch result because conflicts are per-row: a
     * single multi-row statement is one transaction, so one conflicting plan would abort
     * the write of every other plan in the batch and strand edits that had nothing wrong
     * with them. Plans are a handful per vineyard per season — correctness is worth the
     * extra round trips (see the sync contract doc, "Fetch after successful write").
     *
     * Each returned outcome is either [VersionedWriteOutcome.Applied] carrying the
     * authoritative server row (with its NEW `server_revision`) or
     * [VersionedWriteOutcome.Conflict]. Implementations MUST NOT throw for a conflict —
     * a thrown conflict gets counted as a transport failure and blindly retried.
     */
    suspend fun upsert(plans: List<ResistancePlan>): List<VersionedWriteOutcome<ResistancePlan>>

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
    /**
     * Plans the server refused on revision grounds. NOT failures: the pass itself
     * succeeded, and these plans are queued with both versions preserved.
     */
    val conflicted: Int = 0,
    /**
     * Remote rows ignored because they were OLDER than a revision this device has
     * already had confirmed — read-after-write replica lag, decided by revision and
     * never by a clock.
     */
    val staleRemoteIgnored: Int = 0,
    /** Non-null when the pass could not complete. Local state is always still usable. */
    val failure: String? = null,
) {
    val isSuccess: Boolean get() = failure == null

    /** True when this pass produced or left behind an unresolved conflict. */
    val hasConflicts: Boolean get() = conflicted > 0
}

/** Where the plans currently on screen came from. Drives the sync badge in the list. */
enum class ResistancePlanSyncState {
    /** No server configured / not signed in — plans are on this device only. */
    LOCAL_ONLY,

    /** Everything local has been accepted by the server. */
    SYNCED,

    /** Local changes are waiting to upload. */
    PENDING_UPLOAD,

    /** A push is in flight. */
    SYNCING,

    /** The last sync attempt failed. Plans remain readable and editable. */
    FAILED,

    /**
     * Someone else edited a plan this device had also edited. Both versions are kept.
     *
     * Distinct from [FAILED] because the remedies are opposites: a failure wants a
     * retry, a conflict CANNOT be fixed by retrying — the same `base_revision` will be
     * refused every time — and needs a person to choose a version.
     */
    CONFLICT,
}

/**
 * Offline-first, server-authoritative repository for Resistance Plans.
 *
 * CONCURRENCY (sql/198): the authority for "is this edit stale?" is the server-issued
 * `server_revision`, never a device clock. Each cached plan remembers the revision it
 * was based on; an update sends that as `base_revision`; the server either applies the
 * write and advances the revision, or raises REVISION_CONFLICT. Wall-clock timestamps
 * remain ONLY for display, audit and "when did the grower edit this" — they no longer
 * decide who wins, because a clock records WHEN someone edited and not WHICH version
 * they started from.
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
    /**
     * Device clock. Still used — for the grower's edit time, which is real metadata —
     * but NOT for deciding whether a write is stale. See the class doc.
     */
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

    private val _conflicts = MutableStateFlow<List<ResistancePlanConflict>>(emptyList())

    /**
     * Unresolved conflicts, both versions intact. Exposed so a future review screen can
     * present them; nothing here resolves a conflict automatically.
     */
    val conflicts: StateFlow<List<ResistancePlanConflict>> = _conflicts.asStateFlow()

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
        _conflicts.value = local.loadConflicts(vineyardId)
        publish(allCached(vineyardId))
        refreshSyncState()
    }

    /** Plans for a season and disease, newest first. Live plans only. */
    fun plans(seasonId: String, disease: ResistanceDisease): List<ResistancePlan> =
        _plans.value.filter { it.seasonId == seasonId && it.disease == disease }

    fun plan(planId: String): ResistancePlan? = _plans.value.firstOrNull { it.id == planId }

    /** The unresolved conflict for a plan, if any. */
    fun conflict(planId: String): ResistancePlanConflict? =
        _conflicts.value.firstOrNull { it.rowId == planId }

    // ------------------------------------------------------------------
    // Mutations — always local-first
    // ------------------------------------------------------------------

    /**
     * Create or update a plan.
     *
     * Commits locally and enqueues the id. Works identically online and offline; the
     * caller gets no error to handle and no spinner to show, because nothing about the
     * grower's edit depends on connectivity.
     *
     * The cached `server_revision` is re-stamped from the cache rather than trusted from
     * the incoming plan. The revision is SERVER state: if an editor, a stale view model
     * or a copied object could carry a different number into a save, this device would
     * end up asserting a `base_revision` it never actually read.
     */
    fun save(plan: ResistancePlan) {
        val vineyard = vineyardId ?: return
        val cached = allCached(vineyard)
        val knownRevision = cached.firstOrNull { it.id == plan.id }?.serverRevision
        val stamped = plan.copy(
            createdBy = plan.createdBy ?: currentUserId(),
            serverRevision = knownRevision,
        )
        val merged = cached.filterNot { it.id == stamped.id } + stamped
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
    // Conflict resolution — explicit, never automatic
    // ------------------------------------------------------------------

    /**
     * Resolve a conflict by keeping THIS device's authored plan.
     *
     * Rebases the local document onto the server's current revision, so the next push
     * carries a `base_revision` the server will accept. The document itself is untouched
     * — this is the grower saying "my version is the one I want", not a merge.
     */
    fun resolveKeepingLocal(planId: String) {
        val vineyard = vineyardId ?: return
        val conflict = _conflicts.value.firstOrNull { it.rowId == planId } ?: return
        val rebased = conflict.localPending.copy(
            serverRevision = conflict.serverRevision ?: conflict.localPending.serverRevision,
        )
        val updated = allCached(vineyard).map { if (it.id == planId) rebased else it }
        local.saveAll(vineyard, updated)
        local.savePending(vineyard, local.loadPending(vineyard) + planId)
        clearConflicts(vineyard, setOf(planId))
        publish(updated)
        refreshSyncState(force = true)
    }

    /**
     * Resolve a conflict by accepting the server's version and DISCARDING the local edit.
     *
     * Only ever called from an explicit user choice. Nothing in this repository decides
     * this on the grower's behalf, and in particular never by comparing timestamps: both
     * versions descend from the same revision, so "later" says nothing about which one is
     * right (see sql/198 rationale).
     */
    fun resolveKeepingServer(planId: String) {
        val vineyard = vineyardId ?: return
        val conflict = _conflicts.value.firstOrNull { it.rowId == planId } ?: return
        val serverCopy = conflict.serverCurrent
        val updated = if (serverCopy == null) {
            allCached(vineyard)
        } else {
            allCached(vineyard).map { if (it.id == planId) serverCopy else it }
        }
        local.saveAll(vineyard, updated)
        // Dequeued: the local edit has been deliberately abandoned, so there is nothing
        // left to push.
        local.savePending(vineyard, local.loadPending(vineyard) - planId)
        clearConflicts(vineyard, setOf(planId))
        publish(updated)
        refreshSyncState(force = true)
    }

    // ------------------------------------------------------------------
    // Sync
    // ------------------------------------------------------------------

    /**
     * One sync pass: adopt legacy local plans, push the outbox, pull and merge.
     *
     * Order matters. Pushing BEFORE pulling means a local edit is offered to the server
     * (and arbitrated by the sql/198 revision guard) before any remote version can
     * overwrite the cache, so an offline edit is never discarded by the very sync that
     * was supposed to deliver it.
     *
     * The push set is the outbox MINUS plans with an unresolved conflict: those stay
     * queued (their authored document exists nowhere else) but are not re-offered,
     * because the same stale `base_revision` would be refused on every pass. Explicit
     * resolution is what returns them to the push set.
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
            _syncState.value = ResistancePlanSyncState.SYNCING
            // Captured BEFORE the push and used for the merge decision below. The outbox
            // is deliberately NOT cleared until after the pull has been merged: a read that
            // lands on a lagging replica can return the pre-push row, and if the outbox were
            // already empty that stale row would look authoritative and overwrite the newer
            // edit the grower is looking at.
            val pending = local.loadPending(vineyardId)
            var remainingPending = pending
            // Ids the server ACCEPTED this pass, mapped to the authoritative row it
            // returned. Those rows carry the new `server_revision`, which is the only way
            // this device learns what version its edit became.
            val applied = mutableMapOf<String, ResistancePlan>()
            val conflictedRevisions = mutableMapOf<String, Pair<Long?, Long?>>()

            if (pending.isNotEmpty()) {
                val cached = allCached(vineyardId)
                // A plan with an UNRESOLVED CONFLICT is not re-offered. Replaying it would
                // resend the same stale `base_revision`, which the server refuses every
                // time — a retry loop that burns battery, keeps the badge flickering and
                // can never converge. The plan STAYS QUEUED (its authored edit exists
                // nowhere else); it re-enters the push set only when an explicit
                // resolution either rebases it (keep local) or dequeues it (keep server).
                val conflictedIds = local.loadConflicts(vineyardId).map { it.rowId }.toSet()
                val toPush = cached.filter {
                    pending.contains(it.id) && !conflictedIds.contains(it.id)
                }

                // Write the full document for every pending plan, tombstoned or not.
                // The tombstone must reach the server as a row update first, so a plan
                // created AND deleted while offline still exists to be soft-deleted.
                val live = toPush.filterNot { it.isDeleted }
                if (live.isNotEmpty()) {
                    for (outcome in server.upsert(live)) {
                        when (outcome) {
                            is VersionedWriteOutcome.Applied -> {
                                applied[outcome.row.id] = outcome.row
                                pushed++
                            }
                            is VersionedWriteOutcome.Conflict -> {
                                conflictedRevisions[outcome.rowId] =
                                    outcome.baseRevision to outcome.serverRevision
                            }
                        }
                    }
                }
                for (tombstoned in toPush.filter { it.isDeleted }) {
                    val revive = server.upsert(listOf(tombstoned.copy(deletedAtEpochMs = null)))
                    val conflict = revive.firstOrNull() as? VersionedWriteOutcome.Conflict
                    if (conflict != null) {
                        // A delete that lost a race is still a conflict: the other device's
                        // edit may be exactly what the grower would want to keep.
                        conflictedRevisions[tombstoned.id] =
                            conflict.baseRevision to conflict.serverRevision
                        continue
                    }
                    server.softDelete(tombstoned.id)
                    deletesPushed++
                    applied.remove(tombstoned.id)
                    remainingPending = remainingPending - tombstoned.id
                }

                // Only ids the server ACCEPTED are dropped from the outbox. A conflicted id
                // stays queued — its edit exists nowhere else. An id that vanished from the
                // cache is dropped too, so a deleted-then-purged plan cannot wedge the
                // outbox forever.
                remainingPending = remainingPending -
                    applied.keys -
                    orphanIds(pending, cached)
            }

            if (adopted > 0) local.markAdopted(vineyardId)

            // Apply the authoritative returned rows immediately. This is what teaches the
            // cache its new `server_revision`; without it the next edit would resend the
            // OLD base_revision and be refused for no reason.
            if (applied.isNotEmpty()) {
                local.saveAll(
                    vineyardId,
                    allCached(vineyardId).map { applied[it.id] ?: it },
                )
            }

            val remotePlans = server.fetchAll(vineyardId)
            // Plans whose local copy must survive the pull: still-queued edits (never
            // offered, or offered and refused). A just-accepted plan is NOT in this set —
            // its server row is the authority now.
            val keepLocalIds = (pending - applied.keys) + conflictedRevisions.keys
            val merge = merge(
                local = allCached(vineyardId),
                remote = remotePlans,
                keepLocalIds = keepLocalIds,
            )
            local.saveAll(vineyardId, merge.plans)

            // Record conflicts with BOTH documents. The server copy comes from the pull we
            // just did, so the grower can see what the other device actually saved.
            if (conflictedRevisions.isNotEmpty()) {
                recordConflicts(
                    vineyardId = vineyardId,
                    revisions = conflictedRevisions,
                    localById = merge.plans.associateBy { it.id },
                    remoteById = remotePlans.associateBy { it.id },
                )
            }

            // Safe to shrink the outbox only now that the pull has been reconciled. A plan
            // whose newer local copy was kept stays queued, so the next pass retries it
            // instead of leaving this device permanently ahead of the server.
            local.savePending(
                vineyardId,
                remainingPending + merge.keptLocalIds + conflictedRevisions.keys,
            )
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
                conflicted = conflictedRevisions.size,
                staleRemoteIgnored = merge.staleRemoteIgnored,
            )
        } catch (error: Exception) {
            // Everything stays in the cache and in the outbox. The grower keeps working;
            // the next successful pass replays. A conflict never arrives here — the remote
            // returns it as an outcome precisely so it cannot be mistaken for this.
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

    private fun recordConflicts(
        vineyardId: String,
        revisions: Map<String, Pair<Long?, Long?>>,
        localById: Map<String, ResistancePlan>,
        remoteById: Map<String, ResistancePlan>,
    ) {
        val now = clock()
        val existing = local.loadConflicts(vineyardId).associateBy { it.rowId }.toMutableMap()
        for ((planId, pair) in revisions) {
            val localPlan = localById[planId] ?: continue
            existing[planId] = ResistancePlanConflict(
                rowId = planId,
                entity = RESISTANCE_PLANS_ENTITY,
                localPending = localPlan,
                serverCurrent = remoteById[planId],
                baseRevision = pair.first,
                serverRevision = pair.second ?: remoteById[planId]?.serverRevision,
                detectedAtEpochMs = now,
            )
        }
        val all = existing.values.toList()
        local.saveConflicts(vineyardId, all)
        _conflicts.value = all
    }

    private fun clearConflicts(vineyardId: String, ids: Set<String>) {
        val remaining = local.loadConflicts(vineyardId).filterNot { ids.contains(it.rowId) }
        local.saveConflicts(vineyardId, remaining)
        _conflicts.value = remaining
    }

    private data class MergeOutcome(
        val plans: List<ResistancePlan>,
        val acceptedRemote: Int,
        val keptLocal: Int,
        val keptLocalIds: Set<String> = emptySet(),
        val staleRemoteIgnored: Int = 0,
    )

    /**
     * Whole-document reconciliation, arbitrated by REVISION.
     *
     * Two independent reasons to keep the local copy:
     *
     *  1. [keepLocalIds] — the grower has an edit that the server has not accepted. It
     *     exists on this device and nowhere else, so a pull must not paint over it.
     *  2. The remote row is at an OLDER revision than one this device has already had
     *     confirmed. That is read-after-write replica lag, and it used to be detected by
     *     comparing device timestamps — which failed in exactly the case it mattered,
     *     because a slow phone's "newer" edit looks older than the row it just wrote.
     *     Revisions are monotonic and server-issued, so the comparison is now sound.
     *
     * Position arrays are NEVER merged element-by-element: there is no defensible
     * automatic reconciliation of "A moved the Group 11 spray earlier" against "B removed
     * that spray", and any row-wise merge could produce a spray sequence that neither
     * operator authored and then present it as resistance-compliant. Preserving both
     * authored documents is recoverable; inventing a third plan is not.
     */
    private fun merge(
        local: List<ResistancePlan>,
        remote: List<ResistancePlan>,
        keepLocalIds: Set<String>,
    ): MergeOutcome {
        val localById = local.associateBy { it.id }
        val result = linkedMapOf<String, ResistancePlan>()
        local.forEach { result[it.id] = it }

        var accepted = 0
        var staleRemote = 0
        val keptIds = mutableSetOf<String>()
        for (row in remote) {
            val mine = localById[row.id]
            if (mine != null && keepLocalIds.contains(row.id)) {
                keptIds += row.id
                continue
            }
            if (mine != null && isRemoteBehind(mine, row)) {
                staleRemote++
                continue
            }
            result[row.id] = row
            accepted++
        }
        return MergeOutcome(result.values.toList(), accepted, keptIds.size, keptIds, staleRemote)
    }

    /**
     * True when the pulled row is at a strictly OLDER server revision than the copy this
     * device already holds — i.e. the read went to a replica that has not caught up.
     *
     * Returns false when either side has no revision: a legacy row (written by an old
     * client, or cached before sql/198) is NOT evidence of lag, and treating an unknown
     * revision as "behind" would make such rows permanently unpullable.
     */
    private fun isRemoteBehind(mine: ResistancePlan, row: ResistancePlan): Boolean {
        val localRevision = mine.serverRevision ?: return false
        val remoteRevision = row.serverRevision ?: return false
        return remoteRevision < localRevision
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
        // A conflict outranks every other state. It is the only one that needs a person,
        // and showing "will retry" over the top of it would promise something the app
        // cannot deliver: the same base_revision is refused every time.
        if (_conflicts.value.isNotEmpty()) {
            _syncState.value = ResistancePlanSyncState.CONFLICT
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

    /**
     * True when this plan has local changes the server has not yet accepted.
     * Per-row companion to [pendingCount], for the plan list's row badge.
     */
    fun isPending(planId: String): Boolean =
        vineyardId?.let { local.loadPending(it).contains(planId) } ?: false

    /** Unresolved-conflict count, for the plan list badge. */
    fun conflictCount(): Int = _conflicts.value.size

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

        const val SYNCING_NOTICE = "Syncing resistance plans…"

        const val FAILED_NOTICE =
            "Could not sync resistance plans. Your changes are saved on this device and will retry."

        /**
         * Conflict wording. Deliberately NOT "sync failed — retry": retrying is the one
         * thing that cannot work here, and offering it would train the grower to tap a
         * button that silently does nothing.
         */
        const val CONFLICT_NOTICE =
            "Changes need review. This plan was also edited on another device — " +
                "both versions are saved, so you can choose which one to keep."
    }
}
