package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for work-task LABOUR lines (Android Stage J-4) —
 * create, update and delete, all on [PendingEntityType.WORK_TASK_LABOUR].
 *
 * Labour lines are the first work-task CHILD records to gain an offline queue.
 * The operator added / edited / removed a labour costing line offline (or a
 * transient online write failed) and the optimistic line is already showing
 * locally. This replays the line upsert ([WorkTaskLineRepository.upsertLabourLine])
 * and soft-delete ([WorkTaskLineRepository.deleteLabourLine]) and nothing else:
 * it never touches the work-task header (owned by the
 * [WorkTaskCreateSync]/[WorkTaskUpdateSync]/[WorkTaskDeleteSync] header queues)
 * and never any machine line (parked for J-5) or any other entity.
 *
 * Discriminator: every labour marker is WORK_TASK_LABOUR keyed by the line id
 * ([PendingWrite.clientId] = labourLineId), so the header queues can never pick
 * one up and this coordinator only ever processes WORK_TASK_LABOUR rows.
 *
 * Parent dependency gate (mandatory): a labour line references a `work_task_id`.
 * Every create/update/delete replay is DEFERRED (kept FAILED, retry-eligible, no
 * attempt consumed) while the SAME work task still has an unresolved
 * [PendingEntityType.WORK_TASK] / CREATE marker — a child line is never POSTed
 * or deleted against a parent the server doesn't have yet. Replay ordering in
 * the ViewModel places labour (create -> update -> delete) AFTER the header
 * create/update passes (so the parent lands first) and BEFORE the header delete
 * pass.
 *
 * Edit-before-create folding (caller side): when the same line still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [foldCreate] and never queues an UPDATE — so a create+edit pair replays as a
 * single edited insert. Delete-before-create cancellation ([cancelLocalCreate])
 * drops a never-synced line's create/update markers locally instead of queueing
 * a server delete for a row that never existed.
 *
 * Idempotency / coalescing: only one unresolved marker of each op is ever kept
 * per line — [enqueueCreate]/[enqueueUpdate]/[enqueueDelete] drop earlier
 * unresolved same-line writes of the same op first (latest wins via the queued
 * [UpsertPayload.clientUpdatedAt]). A queued delete also clears any same-line
 * unresolved update (deleting supersedes editing). The upsert uses
 * merge-duplicates so a retried insert is idempotent, and an already-deleted /
 * not-found delete is treated as success so a line write can't loop forever.
 *
 * Role / permission: labour soft-delete is RLS-restricted
 * (owner/manager/supervisor). A permission/validation rejection is BLOCKED
 * (needs attention) rather than retried forever.
 */
class WorkTaskLabourSync(
    private val lineRepo: WorkTaskLineRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full upsert payload for a labour line create/update. Carries the editable
     * inputs plus the stable client id, parent work-task id, vineyard scope and
     * the [clientUpdatedAt] stamp. DB-generated `total_hours`/`total_cost` are
     * never carried (read back from the server). No auth/session/secrets and no
     * copy of the parent work task.
     */
    @Serializable
    data class UpsertPayload(
        val id: String,
        val workTaskId: String,
        val vineyardId: String,
        val workDate: String,
        val operatorCategoryId: String? = null,
        val workerType: String,
        val workerCount: Int,
        val hoursPerWorker: Double,
        val hourlyRate: Double? = null,
        val notes: String,
        val clientUpdatedAt: String,
    )

    /** Soft-delete-only payload — just the target line id and its parent task id. */
    @Serializable
    data class DeletePayload(val labourLineId: String, val workTaskId: String)

    /**
     * Queue (or replace) a labour-line create. Coalesces by line id: any earlier
     * unresolved create for the same id is removed first so only one is replayed.
     * The [id] must be the client-generated id shared by the optimistic local
     * line and the eventual server insert.
     */
    fun enqueueCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.CREATE, id, workTaskId, vineyardId, workDate, operatorCategoryId,
        workerType, workerCount, hoursPerWorker, hourlyRate, notes, clientUpdatedAt,
    )

    /**
     * Queue (or replace) a labour-line update for an already-synced line.
     * Coalesces by line id so the latest edit wins.
     */
    fun enqueueUpdate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.UPDATE, id, workTaskId, vineyardId, workDate, operatorCategoryId,
        workerType, workerCount, hoursPerWorker, hourlyRate, notes, clientUpdatedAt,
    )

    private fun enqueueUpsert(
        op: String,
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                    it.opType == op &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = UpsertPayload(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            workDate = workDate,
            operatorCategoryId = operatorCategoryId,
            workerType = workerType,
            workerCount = workerCount,
            hoursPerWorker = hoursPerWorker,
            hourlyRate = hourlyRate,
            notes = notes ?: "",
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_LABOUR,
            opType = op,
            payloadJson = json.encodeToString(UpsertPayload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create for the same line. When the
     * operator edits a labour line whose original create hasn't synced yet, there
     * is no server row to PATCH — the queued create payload is rewritten in place
     * with the latest inputs and a fresh [clientUpdatedAt], so the eventual
     * insert carries the edited values directly. Returns true when a pending
     * create existed and was updated; false when there's nothing to fold into
     * (the caller should then queue a normal WORK_TASK_LABOUR / UPDATE).
     */
    fun foldCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        enqueueCreate(
            id, workTaskId, vineyardId, workDate, operatorCategoryId,
            workerType, workerCount, hoursPerWorker, hourlyRate, notes, clientUpdatedAt,
        )
        return true
    }

    /**
     * Cancel a never-synced labour line locally. If the line still has an
     * unresolved create, remove that create and any same-line unresolved update,
     * and return true so the caller drops the optimistic line without ever
     * sending a server delete for a row that never existed. Returns false when
     * the line is already synced (the caller should queue a real delete instead).
     */
    fun cancelLocalCreate(lineId: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == lineId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                    (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == lineId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Queue (or replace) a soft-delete for an already-synced labour line.
     * Coalesces by line id and also clears any same-line unresolved update
     * (deleting supersedes editing). Callers must only enqueue this for a line
     * that exists server-side — a never-synced line is cancelled via
     * [cancelLocalCreate].
     */
    fun enqueueDelete(labourLineId: String, workTaskId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                    (it.opType == PendingOpType.DELETE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == labourLineId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(DeletePayload.serializer(), DeletePayload(labourLineId, workTaskId))
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_LABOUR,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = labourLineId,
        )
    }

    /**
     * Remove every unresolved labour marker (create/update/delete) for the given
     * work task. Used by the header delete's local-create cancellation: when an
     * offline-created work task is deleted before it ever synced, its labour
     * lines never existed server-side either, so their queued markers are dropped
     * locally rather than replayed against a parent that will never exist.
     */
    fun cleanupForWorkTask(workTaskId: String) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                    it.status != PendingWriteStatus.SYNCED &&
                    workTaskIdOf(it) == workTaskId
            }
            .forEach { pending.remove(it.id) }
    }

    /**
     * Replay every retry-eligible labour write. No-ops (returns) if a replay is
     * already running. Processes creates first, then updates, then deletes — a
     * line must exist before it can be edited or removed. For each item: defer
     * behind an unresolved parent create (no attempt consumed), otherwise
     * upsert/delete and resolve success / transient / permanent as the header
     * queues do. [onUpserted] fires with the server row (DB totals) so the caller
     * reconciles by id; [onDeleted] fires so the caller keeps the line hidden.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(
        onUpserted: (WorkTaskLabourLine) -> Unit,
        onDeleted: (labourLineId: String, workTaskId: String) -> Unit,
    ) {
        if (!replayLock.tryLock()) return
        try {
            replayUpserts(PendingOpType.CREATE, onUpserted)
            replayUpserts(PendingOpType.UPDATE, onUpserted)
            replayDeletes(onDeleted)
        } finally {
            replayLock.unlock()
        }
    }

    private suspend fun replayUpserts(op: String, onUpserted: (WorkTaskLabourLine) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                it.opType == op &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(UpsertPayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved labour line.")
                continue
            }
            // Parent gate: never write a child line while the parent task's create
            // is still unresolved. Defer without consuming a retry attempt.
            if (hasUnresolvedParentCreate(payload.workTaskId)) {
                pending.updateStatus(
                    write.id,
                    PendingWriteStatus.FAILED,
                    "Waiting for this work task to finish saving first.",
                )
                continue
            }
            try {
                val saved = lineRepo.upsertLabourLine(
                    id = payload.id,
                    workTaskId = payload.workTaskId,
                    vineyardId = payload.vineyardId,
                    workDate = payload.workDate,
                    operatorCategoryId = payload.operatorCategoryId,
                    workerType = payload.workerType,
                    workerCount = payload.workerCount,
                    hoursPerWorker = payload.hoursPerWorker,
                    hourlyRate = payload.hourlyRate,
                    notes = payload.notes,
                    clientUpdatedAt = payload.clientUpdatedAt,
                )
                pending.remove(write.id)
                onUpserted(saved)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync this labour line.")
            } catch (e: BackendError.Server) {
                when {
                    // Upsert is merge-duplicates, so a duplicate just updates;
                    // treat any 409 as idempotent success.
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The labour line was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private suspend fun replayDeletes(onDeleted: (labourLineId: String, workTaskId: String) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_LABOUR &&
                it.opType == PendingOpType.DELETE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(DeletePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved labour line delete.")
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
                lineRepo.deleteLabourLine(payload.labourLineId)
                pending.remove(write.id)
                onDeleted(payload.labourLineId, payload.workTaskId)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to delete this labour line.")
            } catch (e: BackendError.Server) {
                when {
                    // Already deleted / never existed — the delete intent is met.
                    e.code == 404 -> {
                        pending.remove(write.id)
                        onDeleted(payload.labourLineId, payload.workTaskId)
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
     * (pending / in-progress / failed / blocked). Child line writes wait for the
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
            json.decodeFromString(UpsertPayload.serializer(), write.payloadJson).workTaskId
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
        /** Cap retries so a persistently-failing labour line can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
