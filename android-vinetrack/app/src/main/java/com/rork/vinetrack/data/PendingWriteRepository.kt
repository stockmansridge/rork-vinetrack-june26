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
class PendingWriteRepository(context: Context) {

    private val store = PendingWriteStore(context)

    private val _writes = MutableStateFlow(store.load())
    /** Live view of every persisted pending write. */
    val writes: StateFlow<List<PendingWrite>> = _writes.asStateFlow()

    private val _pendingCount = MutableStateFlow(countUnresolved(_writes.value))
    /**
     * Observable count of writes still waiting to sync (pending / in-progress /
     * failed / blocked). Synced rows are excluded. Recomputed on every mutation.
     */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

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
        update { it + write }
        return write
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
    fun clearAll() {
        store.clear()
        _writes.value = emptyList()
        _pendingCount.value = 0
    }

    private fun update(transform: (List<PendingWrite>) -> List<PendingWrite>) {
        val next = transform(_writes.value)
        _writes.value = next
        _pendingCount.value = countUnresolved(next)
        store.save(next)
    }

    private fun countUnresolved(list: List<PendingWrite>): Int =
        list.count { it.status in PendingWriteStatus.unresolved }
}
