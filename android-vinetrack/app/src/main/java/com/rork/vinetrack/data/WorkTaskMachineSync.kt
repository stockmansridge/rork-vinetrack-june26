package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for work-task MACHINE lines (Android Stage J-5) —
 * create, update and delete, all on [PendingEntityType.WORK_TASK_MACHINE].
 *
 * Machine lines are the second work-task CHILD records to gain an offline queue
 * (after labour, Stage J-4). The operator added / edited / removed a machine
 * costing line offline (or a transient online write failed) and the optimistic
 * line is already showing locally. This replays the line upsert
 * ([WorkTaskLineRepository.upsertMachineLine]) and soft-delete
 * ([WorkTaskLineRepository.deleteMachineLine]) and nothing else: it never
 * touches the work-task header (owned by the
 * [WorkTaskCreateSync]/[WorkTaskUpdateSync]/[WorkTaskDeleteSync] header queues)
 * and never any labour line (owned by [WorkTaskLabourSync]) or any other entity.
 *
 * Discriminator: every machine marker is WORK_TASK_MACHINE keyed by the line id
 * ([PendingWrite.clientId] = machineLineId), so the header and labour queues can
 * never pick one up and this coordinator only ever processes WORK_TASK_MACHINE
 * rows.
 *
 * Parent dependency gate (mandatory): a machine line references a `work_task_id`.
 * Every create/update/delete replay is DEFERRED (kept FAILED, retry-eligible, no
 * attempt consumed) while the SAME work task still has an unresolved
 * [PendingEntityType.WORK_TASK] / CREATE marker — a child line is never POSTed
 * or deleted against a parent the server doesn't have yet. Replay ordering in
 * the ViewModel places machine (create -> update -> delete) AFTER the header
 * create/update passes and the labour pass, and BEFORE the header delete pass.
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
 * Role / permission: machine soft-delete is RLS-restricted
 * (owner/manager/supervisor). A permission/validation rejection is BLOCKED
 * (needs attention) rather than retried forever.
 */
class WorkTaskMachineSync(
    private val lineRepo: WorkTaskLineRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full upsert payload for a machine line create/update. Carries the editable
     * inputs plus the stable client id, parent work-task id, vineyard scope and
     * the [clientUpdatedAt] stamp. The DB-recomputed `equipment_source` is also
     * carried for diagnostics but the repository re-derives it from
     * [equipmentRefId] on replay. No auth/session/secrets and no copy of the
     * parent work task.
     */
    @Serializable
    data class UpsertPayload(
        val id: String,
        val workTaskId: String,
        val vineyardId: String,
        val workDate: String,
        val equipmentSource: String? = null,
        val equipmentRefId: String? = null,
        val equipmentNameSnapshot: String,
        val operatorCategoryId: String? = null,
        val durationHours: Double? = null,
        val fuelLitres: Double? = null,
        val fuelCost: Double? = null,
        val hourlyMachineRate: Double? = null,
        val totalMachineCost: Double? = null,
        val notes: String,
        val clientUpdatedAt: String,
    )

    /** Soft-delete-only payload — just the target line id and its parent task id. */
    @Serializable
    data class DeletePayload(val machineLineId: String, val workTaskId: String)

    /**
     * Queue (or replace) a machine-line create. Coalesces by line id: any earlier
     * unresolved create for the same id is removed first so only one is replayed.
     * The [id] must be the client-generated id shared by the optimistic local
     * line and the eventual server insert.
     */
    fun enqueueCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.CREATE, id, workTaskId, vineyardId, workDate, equipmentRefId,
        equipmentNameSnapshot, operatorCategoryId, durationHours, fuelLitres, fuelCost,
        hourlyMachineRate, totalMachineCost, notes, clientUpdatedAt,
    )

    /**
     * Queue (or replace) a machine-line update for an already-synced line.
     * Coalesces by line id so the latest edit wins.
     */
    fun enqueueUpdate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.UPDATE, id, workTaskId, vineyardId, workDate, equipmentRefId,
        equipmentNameSnapshot, operatorCategoryId, durationHours, fuelLitres, fuelCost,
        hourlyMachineRate, totalMachineCost, notes, clientUpdatedAt,
    )

    private fun enqueueUpsert(
        op: String,
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                    it.opType == op &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        // `equipment_source` is recomputed by the repository on replay; carry it
        // for diagnostics only (linked machine vs free-text snapshot).
        val source = if (equipmentRefId != null) "vineyard_machine" else "free_text"
        val payload = UpsertPayload(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            workDate = workDate,
            equipmentSource = source,
            equipmentRefId = equipmentRefId,
            equipmentNameSnapshot = equipmentNameSnapshot,
            operatorCategoryId = operatorCategoryId,
            durationHours = durationHours,
            fuelLitres = fuelLitres,
            fuelCost = fuelCost,
            hourlyMachineRate = hourlyMachineRate,
            totalMachineCost = totalMachineCost,
            notes = notes ?: "",
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_MACHINE,
            opType = op,
            payloadJson = json.encodeToString(UpsertPayload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create for the same line. When the
     * operator edits a machine line whose original create hasn't synced yet,
     * there is no server row to PATCH — the queued create payload is rewritten in
     * place with the latest inputs and a fresh [clientUpdatedAt], so the eventual
     * insert carries the edited values directly. Returns true when a pending
     * create existed and was updated; false when there's nothing to fold into
     * (the caller should then queue a normal WORK_TASK_MACHINE / UPDATE).
     */
    fun foldCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        clientUpdatedAt: String,
    ): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        enqueueCreate(
            id, workTaskId, vineyardId, workDate, equipmentRefId, equipmentNameSnapshot,
            operatorCategoryId, durationHours, fuelLitres, fuelCost, hourlyMachineRate,
            totalMachineCost, notes, clientUpdatedAt,
        )
        return true
    }

    /**
     * Cancel a never-synced machine line locally. If the line still has an
     * unresolved create, remove that create and any same-line unresolved update,
     * and return true so the caller drops the optimistic line without ever
     * sending a server delete for a row that never existed. Returns false when
     * the line is already synced (the caller should queue a real delete instead).
     */
    fun cancelLocalCreate(lineId: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == lineId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                    (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == lineId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Queue (or replace) a soft-delete for an already-synced machine line.
     * Coalesces by line id and also clears any same-line unresolved update
     * (deleting supersedes editing). Callers must only enqueue this for a line
     * that exists server-side — a never-synced line is cancelled via
     * [cancelLocalCreate].
     */
    fun enqueueDelete(machineLineId: String, workTaskId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                    (it.opType == PendingOpType.DELETE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == machineLineId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(DeletePayload.serializer(), DeletePayload(machineLineId, workTaskId))
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_MACHINE,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = machineLineId,
        )
    }

    /**
     * Remove every unresolved machine marker (create/update/delete) for the given
     * work task. Used by the header delete's local-create cancellation: when an
     * offline-created work task is deleted before it ever synced, its machine
     * lines never existed server-side either, so their queued markers are dropped
     * locally rather than replayed against a parent that will never exist.
     */
    fun cleanupForWorkTask(workTaskId: String) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                    it.status != PendingWriteStatus.SYNCED &&
                    workTaskIdOf(it) == workTaskId
            }
            .forEach { pending.remove(it.id) }
    }

    /**
     * Replay every retry-eligible machine write. No-ops (returns) if a replay is
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
        onUpserted: (WorkTaskMachineLine) -> Unit,
        onDeleted: (machineLineId: String, workTaskId: String) -> Unit,
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

    private suspend fun replayUpserts(op: String, onUpserted: (WorkTaskMachineLine) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                it.opType == op &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(UpsertPayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved machine line.")
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
                val saved = lineRepo.upsertMachineLine(
                    id = payload.id,
                    workTaskId = payload.workTaskId,
                    vineyardId = payload.vineyardId,
                    workDate = payload.workDate,
                    equipmentRefId = payload.equipmentRefId,
                    equipmentNameSnapshot = payload.equipmentNameSnapshot,
                    operatorCategoryId = payload.operatorCategoryId,
                    durationHours = payload.durationHours,
                    fuelLitres = payload.fuelLitres,
                    fuelCost = payload.fuelCost,
                    hourlyMachineRate = payload.hourlyMachineRate,
                    totalMachineCost = payload.totalMachineCost,
                    notes = payload.notes,
                    clientUpdatedAt = payload.clientUpdatedAt,
                )
                pending.remove(write.id)
                onUpserted(saved)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync this machine line.")
            } catch (e: BackendError.Server) {
                when {
                    // Upsert is merge-duplicates, so a duplicate just updates;
                    // treat any 409 as idempotent success.
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The machine line was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private suspend fun replayDeletes(onDeleted: (machineLineId: String, workTaskId: String) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MACHINE &&
                it.opType == PendingOpType.DELETE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(DeletePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved machine line delete.")
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
                lineRepo.deleteMachineLine(payload.machineLineId)
                pending.remove(write.id)
                onDeleted(payload.machineLineId, payload.workTaskId)
            } catch (e: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to delete this machine line.")
            } catch (e: BackendError.Server) {
                when {
                    // Already deleted / never existed — the delete intent is met.
                    e.code == 404 -> {
                        pending.remove(write.id)
                        onDeleted(payload.machineLineId, payload.workTaskId)
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
        /** Cap retries so a persistently-failing machine line can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
