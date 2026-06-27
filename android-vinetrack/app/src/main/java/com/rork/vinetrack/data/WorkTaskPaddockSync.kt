package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.WorkTaskPaddock
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for work-task -> paddock join rows (Android Stage R)
 * — create and delete, both on [PendingEntityType.WORK_TASK_PADDOCK].
 *
 * A single work task can span multiple paddocks. When the operator changes a
 * task's block set offline (or a transient online write failed), the optimistic
 * join rows are already reflected locally. This replays the join insert
 * ([WorkTaskPaddockRepository.insert]) and soft-delete
 * ([WorkTaskPaddockRepository.softDelete]) and nothing else: it never touches the
 * work-task header (owned by the create/update/delete header queues) or any
 * labour / machine line.
 *
 * Discriminator: every join marker is WORK_TASK_PADDOCK keyed by the join-row id
 * ([PendingWrite.clientId] = workTaskPaddockId), so no other queue can pick one
 * up and this coordinator only ever processes WORK_TASK_PADDOCK rows. There is
 * no UPDATE op — a join row is immutable apart from its area, and a changed area
 * re-inserts the same id (merge-duplicates upsert).
 *
 * Parent dependency gate (mandatory): a join row references a `work_task_id`.
 * Every create/delete replay is DEFERRED (kept FAILED, retry-eligible, no
 * attempt consumed) while the SAME work task still has an unresolved
 * [PendingEntityType.WORK_TASK] / CREATE marker — a child join is never POSTed
 * or deleted against a parent the server doesn't have yet. Replay ordering in
 * the ViewModel places paddock joins AFTER the header create/update passes and
 * BEFORE the header delete pass.
 *
 * Create/delete cancellation: a never-synced join row removed before it synced
 * has its create dropped locally ([cancelLocalCreate]) instead of queueing a
 * server delete for a row that never existed.
 *
 * Idempotency / coalescing: only one unresolved marker of each op is kept per
 * join id — a queued create drops earlier unresolved same-id creates, and a
 * queued delete drops any same-id unresolved create (delete supersedes a
 * never-synced create — but only AFTER [cancelLocalCreate] returned false,
 * i.e. the row was already synced). The insert uses merge-duplicates so a
 * retried create is idempotent, and an already-deleted / not-found delete is
 * treated as success so a join write can't loop forever.
 */
class WorkTaskPaddockSync(
    private val repo: WorkTaskPaddockRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full insert payload for a join create. Carries the stable client id, parent
     * work-task id, vineyard scope, paddock id, optional area and the
     * [clientUpdatedAt] stamp. No auth/session/secrets. */
    @Serializable
    data class CreatePayload(
        val id: String,
        val workTaskId: String,
        val vineyardId: String,
        val paddockId: String,
        val areaHa: Double? = null,
        val clientUpdatedAt: String,
    )

    /** Soft-delete-only payload — just the target join id and its parent task id. */
    @Serializable
    data class DeletePayload(val workTaskPaddockId: String, val workTaskId: String)

    /**
     * Queue (or replace) a join create. Coalesces by join id: any earlier
     * unresolved create for the same id is removed first so only one is replayed.
     * The [id] must be the client-generated id shared by the optimistic local row
     * and the eventual server insert.
     */
    fun enqueueCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        paddockId: String,
        areaHa: Double?,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = CreatePayload(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            paddockId = paddockId,
            areaHa = areaHa,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_PADDOCK,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(CreatePayload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Cancel a never-synced join row locally. If the row still has an unresolved
     * create, remove that create and return true so the caller drops the
     * optimistic row without ever sending a server delete for a row that never
     * existed. Returns false when the row is already synced (the caller should
     * queue a real delete instead).
     */
    fun cancelLocalCreate(joinId: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == joinId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                    it.clientId == joinId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Queue (or replace) a soft-delete for an already-synced join row. Coalesces
     * by join id. Callers must only enqueue this for a row that exists
     * server-side — a never-synced row is cancelled via [cancelLocalCreate].
     */
    fun enqueueDelete(workTaskPaddockId: String, workTaskId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == workTaskPaddockId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            DeletePayload.serializer(),
            DeletePayload(workTaskPaddockId, workTaskId),
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_PADDOCK,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = workTaskPaddockId,
        )
    }

    /**
     * Remove every unresolved join marker (create/delete) for the given work
     * task. Used by the header delete's local-create cancellation: when an
     * offline-created work task is deleted before it ever synced, its paddock
     * join rows never existed server-side either, so their queued markers are
     * dropped locally rather than replayed against a parent that will never exist.
     */
    fun cleanupForWorkTask(workTaskId: String) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                    it.status != PendingWriteStatus.SYNCED &&
                    workTaskIdOf(it) == workTaskId
            }
            .forEach { pending.remove(it.id) }
    }

    /**
     * Replay every retry-eligible join write. No-ops (returns) if a replay is
     * already running. Processes creates first, then deletes. For each item:
     * defer behind an unresolved parent create (no attempt consumed), otherwise
     * insert/delete and resolve success / transient / permanent as the header
     * queues do. [onCreated] fires with the server row so the caller reconciles
     * by id; [onDeleted] fires so the caller keeps the row hidden.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(
        onCreated: (WorkTaskPaddock) -> Unit,
        onDeleted: (workTaskPaddockId: String, workTaskId: String) -> Unit,
    ) {
        if (!replayLock.tryLock()) return
        try {
            replayCreates(onCreated)
            replayDeletes(onDeleted)
        } finally {
            replayLock.unlock()
        }
    }

    private suspend fun replayCreates(onCreated: (WorkTaskPaddock) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                it.opType == PendingOpType.CREATE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(CreatePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved block link.")
                continue
            }
            if (hasUnresolvedParentCreate(payload.workTaskId)) {
                pending.updateStatus(
                    write.id,
                    PendingWriteStatus.FAILED,
                    "Waiting for this work task to finish saving first.",
                )
                continue
            }
            try {
                val saved = repo.insert(
                    id = payload.id,
                    workTaskId = payload.workTaskId,
                    vineyardId = payload.vineyardId,
                    paddockId = payload.paddockId,
                    areaHa = payload.areaHa,
                    clientUpdatedAt = payload.clientUpdatedAt,
                )
                pending.remove(write.id)
                onCreated(saved)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync this block link.")
            } catch (e: BackendError.Server) {
                when {
                    // Merge-duplicates upsert — a duplicate just updates; treat 409 as success.
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The block link was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private suspend fun replayDeletes(onDeleted: (workTaskPaddockId: String, workTaskId: String) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_PADDOCK &&
                it.opType == PendingOpType.DELETE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(DeletePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved block-link delete.")
                continue
            }
            if (hasUnresolvedParentCreate(payload.workTaskId)) {
                pending.updateStatus(
                    write.id,
                    PendingWriteStatus.FAILED,
                    "Waiting for this work task to finish saving first.",
                )
                continue
            }
            try {
                repo.softDelete(payload.workTaskPaddockId)
                pending.remove(write.id)
                onDeleted(payload.workTaskPaddockId, payload.workTaskId)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to delete this block link.")
            } catch (e: BackendError.Server) {
                when {
                    // Already deleted / never existed — the delete intent is met.
                    e.code == 404 -> {
                        pending.remove(write.id)
                        onDeleted(payload.workTaskPaddockId, payload.workTaskId)
                    }
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The delete was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    /**
     * True when the parent work task still has an unresolved create marker
     * (pending / in-progress / failed / blocked). Child join writes wait for the
     * parent insert to land rather than racing it.
     */
    private fun hasUnresolvedParentCreate(workTaskId: String): Boolean =
        pending.list().any {
            it.clientId == workTaskId &&
                it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Decode the parent work-task id from either payload shape (or null if unreadable). */
    private fun workTaskIdOf(write: PendingWrite): String? = when (write.opType) {
        PendingOpType.DELETE -> runCatching {
            json.decodeFromString(DeletePayload.serializer(), write.payloadJson).workTaskId
        }.getOrNull()
        else -> runCatching {
            json.decodeFromString(CreatePayload.serializer(), write.payloadJson).workTaskId
        }.getOrNull()
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing block link can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
