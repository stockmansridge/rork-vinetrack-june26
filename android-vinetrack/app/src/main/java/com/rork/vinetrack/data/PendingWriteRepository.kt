package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * Sole access point for the local pending-write outbox (Stage 4A-ii — skeleton).
 *
 * Wraps [PendingWriteStore] and exposes an observable in-memory view so the UI
 * can react to the pending count. Screens and repositories must use this rather
 * than touching the store directly.
 *
 * IMPORTANT (this slice): the mutating methods exist for future offline-queue
 * work and are NOT called by any production write path. Until a write flow
 * enqueues through [enqueue], the outbox stays empty and [pendingCount] is 0.
 * No replay, retry, or backoff logic lives here.
 */
class PendingWriteRepository(private val store: PendingWriteStoring) {

    /** Production entry point — persists to SharedPreferences via [PendingWriteStore]. */
    constructor(context: Context) : this(PendingWriteStore(context))

    private class FrozenVersions(
        rows: Map<String, PendingWrite>, val scope: ReplayScope?,
    ) : Map<String, PendingWrite> by rows

    /** Bind the preserved bytes to the account incarnation that authorised them. */
    @Synchronized
    fun freezeReplayVersions(writes: Collection<PendingWrite>): Map<String, PendingWrite> =
        FrozenVersions(writes.associateBy { it.id }, scopeProvider?.invoke())

    /** Runtime-only account boundary; never persisted in or added to queued record formats. */
    data class ReplayScope(val userId: String, val sessionEpoch: Long)
    private var scopeProvider: (() -> ReplayScope?)? = null
    private val claimedScopes = mutableMapOf<PendingWrite, ReplayScope>()

    /** Bind production claims to the signed-in account incarnation, allowing same-account token refresh. */
    @Synchronized
    fun configureReplayScope(provider: () -> ReplayScope?) { scopeProvider = provider }

    /** Read-only runtime scope for snapshot-owner admission; not durable operation provenance. */
    @Synchronized
    fun currentReplayScope(): ReplayScope? = scopeProvider?.invoke()

    private val _writes = MutableStateFlow(store.load())
    /** Live view of every persisted pending write. */
    val writes: StateFlow<List<PendingWrite>> = _writes.asStateFlow()

    private val _pendingCount = MutableStateFlow(countUnresolved(_writes.value))
    /**
     * Observable count of writes still waiting to sync (pending / in-progress /
     * failed / blocked). Synced rows are excluded. Recomputed on every mutation.
     */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

    init {
        // A terminated process cannot still own an in-flight Work Task upload.
        // Retain the frozen payload and make just these header writes retryable.
        _writes.value.filter {
            it.entityType == com.rork.vinetrack.data.model.PendingEntityType.WORK_TASK &&
                it.status == PendingWriteStatus.IN_PROGRESS
        }.forEach { updateStatus(it.id, PendingWriteStatus.FAILED, "Work task sync was interrupted. Ready to retry.") }
    }

    /** Current pending count without collecting the flow. */
    fun currentPendingCount(): Int = countUnresolved(_writes.value)

    /** Snapshot of all pending writes. */
    fun list(): List<PendingWrite> = _writes.value

    /**
     * Enqueue a new pending write. Returns the created row. Unused by real write
     * paths in this slice — present so future offline flows can defer a write.
     */
    fun enqueue(
        entityType: String,
        opType: String,
        payloadJson: String,
        clientId: String = UUID.randomUUID().toString(),
    ): PendingWrite {
        val now = System.currentTimeMillis()
        val write = PendingWrite(
            id = UUID.randomUUID().toString(),
            entityType = entityType,
            opType = opType,
            payloadJson = payloadJson,
            clientId = clientId,
            createdAt = now,
            updatedAt = now,
        )
        check(update { it + write }) { "Pending write could not be committed durably." }
        return write
    }

    /** Atomically replace one unresolved marker's payload, keeping its identity and earliest baseline. */
    @Synchronized
    fun upsertCoalesced(entityType: String, clientId: String, payloadJson: String, opType: String = com.rork.vinetrack.data.model.PendingOpType.UPDATE): PendingWrite {
        val now = System.currentTimeMillis()
        val existing = _writes.value.firstOrNull {
            it.entityType == entityType && it.clientId == clientId &&
                it.opType == opType &&
                it.status in PendingWriteStatus.unresolved
        }
        val next = existing?.copy(payloadJson = payloadJson, status = PendingWriteStatus.PENDING,
            lastError = null, updatedAt = now) ?: PendingWrite(
            id = UUID.randomUUID().toString(), entityType = entityType,
            opType = opType,
            payloadJson = payloadJson, clientId = clientId, createdAt = now, updatedAt = now,
        )
        check(update { rows -> rows.filterNot { it.entityType == entityType && it.clientId == clientId &&
            it.opType == next.opType && it.status in PendingWriteStatus.unresolved } + next }) {
            "Pending write could not be committed durably."
        }
        return next
    }

    /** Replace matching unresolved rows with a fresh operation in one durable commit.
     * The payload factory reads the same locked snapshot used for replacement (tank baseline).
     * Failed persistence publishes nothing and retains every prior row unchanged.
     */
    @Synchronized
    internal fun enqueueReplacingUnresolved(
        entityType: String,
        opType: String,
        clientId: String,
        payload: (List<PendingWrite>) -> String,
    ): PendingWrite {
        val existing = _writes.value.filter { it.entityType == entityType && it.opType == opType &&
            it.clientId == clientId && it.status in PendingWriteStatus.unresolved }
        val encoded = payload(existing)
        val now = System.currentTimeMillis()
        val next = PendingWrite(id = UUID.randomUUID().toString(), entityType = entityType,
            opType = opType, clientId = clientId, payloadJson = encoded, createdAt = now, updatedAt = now)
        check(update { rows -> rows.filterNot { it in existing } + next }) {
            "Pending write could not be committed durably."
        }
        existing.forEach { claimedScopes.remove(it) }
        return next
    }

    /** Update the status and optional error of a pending write by id. */
    fun updateStatus(id: String, status: String, lastError: String? = null) {
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.id == id) it.copy(status = status, lastError = lastError, updatedAt = now) else it
            }
        }
    }

    /** Increment the attempt counter for a pending write (future replay use). */
    fun incrementAttempt(id: String) {
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.id == id) it.copy(attemptCount = it.attemptCount + 1, updatedAt = now) else it
            }
        }
    }

    /** Mark a write as synced (kept in the list but excluded from the count). */
    fun markSynced(id: String) = updateStatus(id, PendingWriteStatus.SYNCED)

    /**
     * Count of rows currently eligible for a user-triggered retry (Tier-A Stage
     * F-2). Conservative: only [PendingWriteStatus.FAILED] rows qualify —
     * dependency-deferred rows are represented as FAILED, while genuinely
     * [PendingWriteStatus.BLOCKED] rows (non-retryable or attempt-capped) are
     * deliberately excluded. Read-only.
     */
    fun retryEligibleCount(): Int =
        _writes.value.count { it.status == PendingWriteStatus.FAILED }

    /**
     * Reset every retry-eligible FAILED row back to PENDING for an explicit
     * user-triggered "Retry all" (Tier-A Stage F-2). Conservative and
     * non-destructive:
     *  - only FAILED rows are touched (covers real transient failures AND
     *    dependency-deferred rows, which are stored as FAILED),
     *  - BLOCKED rows are left untouched (non-retryable / attempt-capped),
     *  - no row is removed, no payload is changed,
     *  - the attempt counter is preserved so the retry cap still applies,
     *  - the stale error is cleared so the row reads cleanly as "waiting".
     *
     * Resetting status does not itself perform any server write — the caller
     * then triggers the existing ordered replay pipeline, whose per-coordinator
     * dependency gates and attempt caps remain fully in force. Returns the
     * number of rows reset.
     */
    fun resetFailedForRetry(): Int {
        var count = 0
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.status == PendingWriteStatus.FAILED) {
                    count++
                    it.copy(status = PendingWriteStatus.PENDING, lastError = null, updatedAt = now)
                } else {
                    it
                }
            }
        }
        return count
    }

    /**
     * Reset a single retry-eligible FAILED row back to PENDING by id for an
     * explicit per-item "Retry this item" (Tier-A Stage F-2b). Same
     * conservative, non-destructive contract as [resetFailedForRetry] but
     * scoped to one row:
     *  - only acts when the row exists AND is currently FAILED (no-op
     *    otherwise, so BLOCKED / PENDING / IN_PROGRESS / SYNCED are never
     *    touched),
     *  - the attempt counter is preserved so the retry cap still applies,
     *  - the stale error is cleared so the row reads cleanly as "waiting",
     *  - no row is removed and no payload is changed.
     *
     * Resetting status performs no server write — the caller then runs the
     * existing ordered replay pipeline, whose dependency gates and attempt
     * caps remain in force. Returns true when the row was reset.
     */
    fun resetFailedRowForRetry(id: String): Boolean {
        var changed = false
        val now = System.currentTimeMillis()
        update { list ->
            list.map {
                if (it.id == id && it.status == PendingWriteStatus.FAILED) {
                    changed = true
                    it.copy(status = PendingWriteStatus.PENDING, lastError = null, updatedAt = now)
                } else {
                    it
                }
            }
        }
        return changed
    }

    /** Remove a pending write from the outbox entirely. */
    fun remove(id: String) {
        update { list -> list.filterNot { it.id == id } }
    }

    /** Drop all synced rows from the outbox. */
    fun pruneSynced() {
        update { list -> list.filterNot { it.status == PendingWriteStatus.SYNCED } }
    }

    /**
     * Clear the entire outbox (Stage 8 — sign-out cleanup hygiene). Local-only:
     * drops every persisted pending write and zeroes the observable count. No
     * server/replay side effects.
     */
    @Synchronized
    fun clearAll() {
        if (store.clear()) {
            _writes.value = emptyList()
            _pendingCount.value = 0
        }
    }

    /** Claim exactly the preserved candidate; replacements and duplicate replay cannot claim it. */
    @Synchronized
    fun claimReplay(expected: PendingWrite, permittedWrites: Map<String, PendingWrite>? = null): PendingWrite? {
        if (permittedWrites != null && permittedWrites[expected.id] != expected) return null
        if (permittedWrites is FrozenVersions && permittedWrites.scope != scopeProvider?.invoke()) return null
        if (expected.status !in setOf(PendingWriteStatus.PENDING, PendingWriteStatus.FAILED)) return null
        val scope = scopeProvider?.invoke()
        if (scopeProvider != null && scope == null) return null
        val claimed = expected.copy(status = PendingWriteStatus.IN_PROGRESS,
            lastError = null, updatedAt = System.currentTimeMillis())
        if (!mutateIfCurrent(expected) { claimed }) return null
        if (scope != null) claimedScopes[claimed] = scope
        return claimed
    }

    /** Exact queue-version check. Includes identity, payload, status, attempts and timestamps. */
    @Synchronized
    fun isCurrent(expected: PendingWrite): Boolean = _writes.value.any { it == expected } &&
        (claimedScopes[expected]?.let { it == scopeProvider?.invoke() } ?: true)

    /** Durable compare-and-remove under the same lock as every queue write. */
    @Synchronized
    fun removeIfCurrent(expected: PendingWrite): Boolean = mutateIfCurrent(expected) { null }

    /** Durable compare-and-status: a stale response cannot fail or block newer intent. */
    @Synchronized
    fun updateStatusIfCurrent(expected: PendingWrite, status: String, lastError: String? = null): Boolean =
        mutateIfCurrent(expected) { it.copy(status = status, lastError = lastError,
            updatedAt = System.currentTimeMillis()) }

    /** One durable mutation for the attempt and outcome; no intermediate persistence window. */
    @Synchronized
    fun retryIfCurrent(expected: PendingWrite, error: String, maxAttempts: Int = 8): Boolean =
        mutateIfCurrent(expected) {
            val attempts = it.attemptCount + 1
            it.copy(attemptCount = attempts,
                status = if (attempts >= maxAttempts) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED,
                lastError = error, updatedAt = System.currentTimeMillis())
        }

    @Synchronized
    private fun mutateIfCurrent(expected: PendingWrite, transform: (PendingWrite) -> PendingWrite?): Boolean {
        if (!isCurrent(expected)) return false
        val committed = update { rows -> rows.mapNotNull { if (it == expected) transform(it) else it } }
        if (committed) claimedScopes.remove(expected)
        return committed
    }

    @Synchronized
    private fun update(transform: (List<PendingWrite>) -> List<PendingWrite>): Boolean {
        val next = transform(_writes.value)
        if (!store.save(next)) return false
        _writes.value = next
        _pendingCount.value = countUnresolved(next)
        return true
    }

    private fun countUnresolved(list: List<PendingWrite>): Int =
        list.count { it.status in PendingWriteStatus.unresolved }
}
