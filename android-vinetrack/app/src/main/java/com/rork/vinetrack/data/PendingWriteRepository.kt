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
    /** Resolve only explicit operation scope; never substitute the selected vineyard. */
    private fun vineyardOf(payload: String): String? {
        fun find(value: kotlinx.serialization.json.JsonElement): Set<String> = when (value) {
            is kotlinx.serialization.json.JsonObject -> value.flatMap { (key, child) ->
                if (key in setOf("vineyard_id", "vineyardId", "p_vineyard_id"))
                    listOfNotNull((child as? kotlinx.serialization.json.JsonPrimitive)?.content?.takeIf { it != "null" })
                else find(child).toList()
            }.toSet()
            is kotlinx.serialization.json.JsonArray -> value.flatMap { find(it) }.toSet()
            else -> emptySet()
        }
        return runCatching { find(kotlinx.serialization.json.Json.parseToJsonElement(payload)).singleOrNull() }.getOrNull()
    }
    private fun requirePayloadWrite(payload: String) { vineyardOf(payload)?.let(OperationalWrites::requireWrite) }
    private val fieldAccess = (store as? PendingWriteStore)?.fieldAccess
    private fun <T> admitted(action: () -> T): T = if (fieldAccess == null) action() else fieldAccess.admitted(action)

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
    private data class RetainedOutcome(val expected: PendingWrite, val retryOutcome: PendingWrite)
    private val retainedClaims = mutableMapOf<String, RetainedOutcome>()

    private inline fun <T> storageResult(fallback: T, action: () -> T): T = try {
        action()
    } catch (cancelled: kotlinx.coroutines.CancellationException) {
        throw cancelled
    } catch (_: Exception) { fallback }

    /** Only terminal claims whose durable acknowledgement/outcome failed may
     * retry in this process. Never reclaims a suspended transport operation. */
    fun recoverRetainedClaims(): Unit = storageResult(Unit) { admitted { synchronized(this) {
        if (_readIssue.value != null) {
            val restored = readStore()
            _readIssue.value = restored.issue
            if (restored.issue != null) return@synchronized
            _writes.value = restored.items
            _pendingCount.value = countUnresolved(restored.items)
            recoverInterruptedStartupClaims()
        }
        retainedClaims.values.toList().forEach { outcome ->
            if (!isCurrent(outcome.expected)) return@forEach
            // Preserve a computed block/failure and its attempts verbatim. A
            // failed permission/conflict block must never become an automatic retry.
            mutateIfCurrent(outcome.expected) { outcome.retryOutcome }
        }
    } } }

    /** Bind production claims to the signed-in account incarnation, allowing same-account token refresh. */
    @Synchronized
    fun configureReplayScope(provider: () -> ReplayScope?) { scopeProvider = provider }

    /** Read-only runtime scope for snapshot-owner admission; not durable operation provenance. */
    @Synchronized
    fun currentReplayScope(): ReplayScope? = scopeProvider?.invoke()

    private fun readStore(): LocalEvidenceRead<PendingWrite> = try {
        if (store is PendingWriteStore) store.loadForRecovery() else LocalEvidenceRead(store.load())
    } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled
    } catch (_: Exception) {
        LocalEvidenceRead(emptyList(), "Saved sync evidence couldn't be read. Original storage was retained; check storage and retry. Do not clear app data.")
    }
    private val initialRead = readStore()
    private val _readIssue = MutableStateFlow(initialRead.issue)
    val readIssue: StateFlow<String?> = _readIssue.asStateFlow()
    private val _writes = MutableStateFlow(initialRead.items)
    /** Live view of every persisted pending write. */
    val writes: StateFlow<List<PendingWrite>> = _writes.asStateFlow()

    private val _pendingCount = MutableStateFlow(countUnresolved(_writes.value))
    /**
     * Observable count of writes still waiting to sync (pending / in-progress /
     * failed / blocked). Synced rows are excluded. Recomputed on every mutation.
     */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

    init { recoverInterruptedStartupClaims() }

    private fun recoverInterruptedStartupClaims() {
        // No upload survives process death. One durable commit retains every
        // identity, original payload, timestamp baseline and attempt count.
        if (_writes.value.any { it.status == PendingWriteStatus.IN_PROGRESS }) {
            val interrupted = _writes.value.filter { it.status == PendingWriteStatus.IN_PROGRESS }.associate { write ->
                write.id to RetainedOutcome(write, write.copy(
                    status = PendingWriteStatus.FAILED, updatedAt = System.currentTimeMillis(),
                    lastError = when (write.entityType) {
                        com.rork.vinetrack.data.model.PendingEntityType.PIN -> "Pin sync was interrupted. Ready to retry the original saved change."
                        com.rork.vinetrack.data.model.PendingEntityType.TRIP_GPS -> "Trip GPS sync was interrupted. Retry to verify retained evidence against the server."
                        com.rork.vinetrack.data.model.PendingEntityType.WORK_TASK -> "Work task sync was interrupted. Ready to retry."
                        else -> "Saved change sync was interrupted. Ready to retry the original saved change."
                    },
                ))
            }
            retainedClaims.putAll(interrupted)
            if (update { rows -> rows.map { interrupted[it.id]?.retryOutcome ?: it } }) retainedClaims.clear()
        }
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
        requirePayloadWrite(payloadJson)
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
    fun upsertCoalesced(entityType: String, clientId: String, payloadJson: String, opType: String = com.rork.vinetrack.data.model.PendingOpType.UPDATE): PendingWrite =
        admitted { upsertCoalescedLocked(entityType, clientId, payloadJson, opType) }

    @Synchronized
    private fun upsertCoalescedLocked(entityType: String, clientId: String, payloadJson: String, opType: String = com.rork.vinetrack.data.model.PendingOpType.UPDATE): PendingWrite {
        requirePayloadWrite(payloadJson)
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
    internal fun enqueueReplacingUnresolved(entityType: String, opType: String, clientId: String, payload: (List<PendingWrite>) -> String): PendingWrite =
        admitted { enqueueReplacingUnresolvedLocked(entityType, opType, clientId, payload) }

    @Synchronized
    private fun enqueueReplacingUnresolvedLocked(
        entityType: String,
        opType: String,
        clientId: String,
        payload: (List<PendingWrite>) -> String,
    ): PendingWrite {
        val existing = _writes.value.filter { it.entityType == entityType && it.opType == opType &&
            it.clientId == clientId && it.status in PendingWriteStatus.unresolved }
        val encoded = payload(existing)
        requirePayloadWrite(encoded)
        val now = System.currentTimeMillis()
        val next = PendingWrite(id = UUID.randomUUID().toString(), entityType = entityType,
            opType = opType, clientId = clientId, payloadJson = encoded, createdAt = now, updatedAt = now)
        check(update { rows -> rows.filterNot { it in existing } + next }) {
            "Pending write could not be committed durably."
        }
        existing.forEach { claimedScopes.remove(it) }
        return next
    }

    /** One-commit edit of unsent CREATE intent; blocked or in-flight evidence is immutable. */
    internal fun coalesceUnstartedCreate(entityType: String, clientId: String, requireExisting: Boolean = false,
        payload: (PendingWrite?) -> String): PendingWrite? = admitted {
        coalesceUnstartedCreateLocked(entityType, clientId, requireExisting, payload)
    }

    @Synchronized
    private fun coalesceUnstartedCreateLocked(entityType: String, clientId: String, requireExisting: Boolean,
        payload: (PendingWrite?) -> String): PendingWrite? {
        val matches = _writes.value.filter { it.entityType == entityType && it.clientId == clientId &&
            it.opType == com.rork.vinetrack.data.model.PendingOpType.CREATE && it.status in PendingWriteStatus.unresolved }
        check(matches.size <= 1) { "Multiple retained spray operations require review." }
        val existing = matches.singleOrNull()
        if (existing == null && requireExisting) return null
        check(existing == null || existing.status in setOf(PendingWriteStatus.PENDING, PendingWriteStatus.FAILED)) {
            "This spray operation is blocked or syncing. Its original evidence is retained for review."
        }
        val encoded = payload(existing)
        requirePayloadWrite(encoded)
        val now = System.currentTimeMillis()
        val next = existing?.copy(payloadJson = encoded, status = PendingWriteStatus.PENDING, lastError = null, updatedAt = now)
            ?: PendingWrite(id = UUID.randomUUID().toString(), entityType = entityType,
                opType = com.rork.vinetrack.data.model.PendingOpType.CREATE, clientId = clientId,
                payloadJson = encoded, createdAt = now, updatedAt = now)
        check(update { rows -> rows.filterNot { it == existing } + next }) { "Pending write could not be committed durably." }
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
    fun clearAll(): Unit = admitted { clearAllLocked() }

    @Synchronized
    private fun clearAllLocked() {
        if (store.clear()) {
            _writes.value = emptyList()
            _pendingCount.value = 0
        }
    }

    /** Claim exactly the preserved candidate; replacements and duplicate replay cannot claim it. */
    fun claimReplay(expected: PendingWrite, permittedWrites: Map<String, PendingWrite>? = null): PendingWrite? =
        storageResult(null) { admitted { claimReplayLocked(expected, permittedWrites) } }

    @Synchronized
    private fun claimReplayLocked(expected: PendingWrite, permittedWrites: Map<String, PendingWrite>? = null): PendingWrite? {
        if (vineyardOf(expected.payloadJson)?.let { !OperationalWrites.canWrite(it) } == true) return null
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

    /** Retain additional owned GPS evidence before transport; original payload is embedded
     * by the GPS coordinator. Never upgrades another entity or an unclaimed version. */
    internal fun retainGpsPayloadIfCurrent(expected: PendingWrite, payload: String): PendingWrite? = admitted {
        synchronized(this) {
            if (expected.entityType != com.rork.vinetrack.data.model.PendingEntityType.TRIP_GPS ||
                expected.status != PendingWriteStatus.IN_PROGRESS || !isCurrent(expected)) return@synchronized null
            val scope = claimedScopes[expected]
            val next = expected.copy(payloadJson = payload, updatedAt = System.currentTimeMillis())
            if (!mutateIfCurrent(expected) { next }) return@synchronized null
            if (scope != null) claimedScopes[next] = scope
            next
        }
    }

    /** A blocked tombstone acknowledgement consumes only the exact preserved,
     * account-bound version; retains original payload/identity and all photos. */
    internal fun acknowledgePreservedIfCurrent(expected: PendingWrite, versions: Map<String, PendingWrite>, message: String): Boolean =
        storageResult(false) { admitted { synchronized(this) {
            if (versions[expected.id] != expected ||
                (versions is FrozenVersions && versions.scope != scopeProvider?.invoke())) return@synchronized false
            mutateIfCurrent(expected) { it.copy(status = PendingWriteStatus.SYNCED, lastError = message,
                updatedAt = System.currentTimeMillis()) }
        } } }

    /** Durable compare-and-remove under the same lock as every queue write. */
    fun removeIfCurrent(expected: PendingWrite): Boolean = storageResult(false) { admitted { mutateIfCurrent(expected) { null } } }

    /** Durable compare-and-status: a stale response cannot fail or block newer intent. */
    fun updateStatusIfCurrent(expected: PendingWrite, status: String, lastError: String? = null): Boolean =
        storageResult(false) { admitted { mutateIfCurrent(expected) { it.copy(status = status, lastError = lastError,
            updatedAt = System.currentTimeMillis()) } } }

    /** One durable mutation for the attempt and outcome; no intermediate persistence window. */
    fun retryIfCurrent(expected: PendingWrite, error: String, maxAttempts: Int = 8): Boolean =
        storageResult(false) { admitted { retryIfCurrentLocked(expected, error, maxAttempts) } }

    private fun retryIfCurrentLocked(expected: PendingWrite, error: String, maxAttempts: Int): Boolean {
        val vineyard = vineyardOf(expected.payloadJson)
        if (vineyard != null) {
            val code = runCatching {
                (kotlinx.serialization.json.Json.parseToJsonElement(error) as? kotlinx.serialization.json.JsonObject)
                    ?.get("code")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
            }.getOrNull()
            OperationalWrites.authority?.handleServerCode(code, vineyard)
            if (!OperationalWrites.canWrite(vineyard)) {
                // Keep the original evidence and retry budget. Status alone releases a completed claim.
                return mutateIfCurrent(expected) { it.copy(status = PendingWriteStatus.PENDING) }
            }
        }
        return mutateIfCurrent(expected) {
            val attempts = it.attemptCount + 1
            it.copy(attemptCount = attempts,
                status = if (attempts >= maxAttempts) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED,
                lastError = error, updatedAt = System.currentTimeMillis())
        }
    }

    @Synchronized
    private fun mutateIfCurrent(expected: PendingWrite, transform: (PendingWrite) -> PendingWrite?): Boolean {
        if (!isCurrent(expected)) return false
        val desired = transform(expected)
        val committed = update { rows -> rows.mapNotNull { if (it == expected) desired else it } }
        if (committed) {
            claimedScopes.remove(expected)
            retainedClaims.remove(expected.id)
        } else if (expected.status == PendingWriteStatus.IN_PROGRESS) {
            val outcome = desired?.takeIf { it.status in setOf(PendingWriteStatus.BLOCKED, PendingWriteStatus.FAILED) }
                ?: expected.copy(status = PendingWriteStatus.FAILED, updatedAt = System.currentTimeMillis(),
                    lastError = "Local acknowledgement couldn't be saved. Original change retained; retry verifies the server.")
            retainedClaims[expected.id] = RetainedOutcome(expected, outcome)
        }
        return committed
    }

    private fun update(transform: (List<PendingWrite>) -> List<PendingWrite>): Boolean =
        storageResult(false) { admitted { updateLocked(transform) } }

    @Synchronized
    private fun updateLocked(transform: (List<PendingWrite>) -> List<PendingWrite>): Boolean {
        if (_readIssue.value != null) return false // Never replace unreadable evidence with an empty view.
        val next = transform(_writes.value)
        if (!store.save(next)) return false
        _writes.value = next
        _pendingCount.value = countUnresolved(next)
        return true
    }

    private fun countUnresolved(list: List<PendingWrite>): Int =
        list.count { it.status in PendingWriteStatus.unresolved }
}
