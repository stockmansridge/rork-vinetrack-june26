package com.rork.vinetrack.data.material

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.math.BigDecimal

/**
 * Offline replay coordinator for work-task MATERIAL lines (sql/247) — the
 * Android twin of the iOS `WorkTaskMaterialSyncService`.
 *
 * Modelled directly on [com.rork.vinetrack.data.WorkTaskLabourSync], which is
 * the established shape for a work-task CHILD queue:
 *
 *  * **Discriminator.** Every marker is [PendingEntityType.WORK_TASK_MATERIAL]
 *    keyed by the material line id ([PendingWrite.clientId] = materialId), so
 *    the header queues and the labour / machine / paddock queues can never pick
 *    one up, and this coordinator only ever processes material rows.
 *
 *  * **Parent dependency gate (mandatory).** A material line references a
 *    `work_task_id`. Every create/update/delete replay is DEFERRED (kept FAILED,
 *    retry-eligible, no attempt consumed) while the SAME work task still has an
 *    unresolved [PendingEntityType.WORK_TASK] / CREATE marker — a child line is
 *    never POSTed or deleted against a parent the server does not have yet.
 *
 *  * **Stable identity before the network.** The line id is minted by the caller
 *    BEFORE any request and is the eventual server row id. Combined with the
 *    merge-duplicates upsert, a replayed create updates the same row: an
 *    offline-created material line can never become a SECOND material line.
 *
 *  * **Coalescing.** Only one unresolved marker of each op is kept per line;
 *    the latest queued payload wins. A queued delete also clears any same-line
 *    unresolved update (deleting supersedes editing).
 *
 *  * **Edit-before-create folding / delete-before-create cancellation.** A line
 *    edited before its create has synced rewrites the queued create ([foldCreate]);
 *    a never-synced line that is removed drops its markers locally
 *    ([cancelLocalCreate]) instead of asking the server to delete a row that
 *    never existed.
 *
 * Nothing here knows about System Admin. The temporary gate lives only in
 * [WorkTaskMaterialCostsAccess].
 */
class WorkTaskMaterialSync(
    private val repo: WorkTaskMaterialWriting,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full upsert payload for a material line create/update.
     *
     * Carries the FROZEN snapshot (name, category, unit, quantity, unit cost)
     * plus the stable client id, parent task, vineyard scope, provenance ids and
     * the [clientUpdatedAt] stamp. Quantity and cost travel as plain decimal
     * STRINGS so an offline payload never loses precision to a binary double.
     * The DB-generated `total_cost` is never carried — it is read back.
     */
    @Serializable
    data class UpsertPayload(
        val id: String,
        val workTaskId: String,
        val vineyardId: String,
        val baseMaterialId: String? = null,
        val vineyardMaterialId: String? = null,
        val materialName: String,
        val category: String,
        val unit: String,
        val quantity: String,
        val unitCost: String,
        val notes: String,
        val clientUpdatedAt: String,
    )

    /** Soft-delete-only payload — the target line id and its parent task id. */
    @Serializable
    data class DeletePayload(val materialId: String, val workTaskId: String)

    // -----------------------------------------------------------------
    // Enqueue
    // -----------------------------------------------------------------

    /**
     * Queue (or replace) a material-line create. [id] must be the
     * client-generated id shared by the optimistic local line and the eventual
     * server insert.
     */
    fun enqueueCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.CREATE, id, workTaskId, vineyardId, baseMaterialId, vineyardMaterialId,
        materialName, category, unit, quantity, unitCost, notes, clientUpdatedAt,
    )

    /** Queue (or replace) an update for an already-synced material line. */
    fun enqueueUpdate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite = enqueueUpsert(
        PendingOpType.UPDATE, id, workTaskId, vineyardId, baseMaterialId, vineyardMaterialId,
        materialName, category, unit, quantity, unitCost, notes, clientUpdatedAt,
    )

    private fun enqueueUpsert(
        op: String,
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                    it.opType == op &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = UpsertPayload(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            baseMaterialId = baseMaterialId,
            vineyardMaterialId = vineyardMaterialId,
            materialName = materialName,
            category = category,
            unit = MaterialUnitCatalog.normalised(unit),
            quantity = MaterialMoney.wire(quantity.max(BigDecimal.ZERO)),
            unitCost = MaterialMoney.wire(unitCost.max(BigDecimal.ZERO)),
            notes = notes ?: "",
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_MATERIAL,
            opType = op,
            payloadJson = json.encodeToString(UpsertPayload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create for the same line.
     *
     * When the operator edits a material line whose original create has not
     * synced, there is no server row to PATCH — the queued create payload is
     * rewritten in place with the latest snapshot and a fresh [clientUpdatedAt],
     * so the eventual insert carries the edited values directly. Returns true
     * when a pending create existed; false when the caller should queue a
     * normal UPDATE.
     */
    fun foldCreate(
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String,
    ): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        enqueueCreate(
            id, workTaskId, vineyardId, baseMaterialId, vineyardMaterialId,
            materialName, category, unit, quantity, unitCost, notes, clientUpdatedAt,
        )
        return true
    }

    /**
     * Cancel a never-synced material line locally. Returns true when the line
     * still had an unresolved create (its create/update markers are dropped and
     * no server delete is sent for a row that never existed); false when the
     * line is already synced and the caller should queue a real delete.
     */
    fun cancelLocalCreate(materialId: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == materialId &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                    (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == materialId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Queue (or replace) a soft-delete for an already-synced material line.
     * Coalesces by line id and clears any same-line unresolved update.
     */
    fun enqueueDelete(materialId: String, workTaskId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                    (it.opType == PendingOpType.DELETE || it.opType == PendingOpType.UPDATE) &&
                    it.clientId == materialId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(DeletePayload.serializer(), DeletePayload(materialId, workTaskId))
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK_MATERIAL,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = materialId,
        )
    }

    /**
     * Remove every unresolved material marker for a work task. Used by the
     * header delete's local-create cancellation: an offline-created task
     * deleted before it ever synced never had server-side material lines
     * either, so their markers are dropped rather than replayed against a
     * parent that will never exist.
     */
    fun cleanupForWorkTask(workTaskId: String) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                    it.status != PendingWriteStatus.SYNCED &&
                    workTaskIdOf(it) == workTaskId
            }
            .forEach { pending.remove(it.id) }
    }

    // -----------------------------------------------------------------
    // Replay
    // -----------------------------------------------------------------

    /**
     * Replay every retry-eligible material write: creates, then updates, then
     * deletes — a line must exist before it can be edited or removed. No-ops if
     * a replay is already running. Caller must only invoke this when online with
     * a session token.
     */
    suspend fun replayAll(
        onUpserted: (WorkTaskMaterial) -> Unit,
        onDeleted: (materialId: String, workTaskId: String) -> Unit,
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

    private suspend fun replayUpserts(op: String, onUpserted: (WorkTaskMaterial) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                it.opType == op &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(UpsertPayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved material line.")
                continue
            }
            // Parent gate: never write a child line while the parent task's
            // create is unresolved. Defer without consuming a retry attempt.
            if (hasUnresolvedParentCreate(payload.workTaskId)) {
                pending.updateStatus(
                    write.id,
                    PendingWriteStatus.FAILED,
                    "Waiting for this work task to finish saving first.",
                )
                continue
            }
            try {
                val saved = repo.upsertTaskMaterial(
                    id = payload.id,
                    workTaskId = payload.workTaskId,
                    vineyardId = payload.vineyardId,
                    baseMaterialId = payload.baseMaterialId,
                    vineyardMaterialId = payload.vineyardMaterialId,
                    materialName = payload.materialName,
                    category = payload.category,
                    unit = payload.unit,
                    quantity = MaterialMoney.decimal(payload.quantity),
                    unitCost = MaterialMoney.decimal(payload.unitCost),
                    notes = payload.notes,
                    clientUpdatedAt = payload.clientUpdatedAt,
                )
                pending.remove(write.id)
                onUpserted(saved)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync this material line.")
            } catch (e: BackendError.Server) {
                when {
                    // The upsert is merge-duplicates, so a duplicate just
                    // updates; treat any 409 as idempotent success.
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The material line was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private suspend fun replayDeletes(onDeleted: (materialId: String, workTaskId: String) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL &&
                it.opType == PendingOpType.DELETE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(DeletePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved material delete.")
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
                repo.softDeleteTaskMaterial(payload.materialId)
                pending.remove(write.id)
                onDeleted(payload.materialId, payload.workTaskId)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to remove this material line.")
            } catch (e: BackendError.Server) {
                when {
                    // Already deleted / never existed — the intent is met.
                    e.code == 404 -> {
                        pending.remove(write.id)
                        onDeleted(payload.materialId, payload.workTaskId)
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
     * True when the parent work task still has an unresolved create marker.
     * Child line writes wait for the parent insert to land rather than racing it.
     */
    private fun hasUnresolvedParentCreate(workTaskId: String): Boolean =
        pending.list().any {
            it.clientId == workTaskId &&
                it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Decode the parent work-task id from either payload shape. */
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
        /** Cap retries so a persistently-failing material line can't loop forever. */
        const val MAX_ATTEMPTS = 8
    }
}

/**
 * Offline replay coordinator for the vineyard MATERIAL LIBRARY (sql/247).
 *
 * The library is vineyard CONFIGURATION, not a work-task child: there is no
 * parent gate, and create and edit both fold into a single UPDATE (the write is
 * a merge-duplicates upsert), coalesced one-per row so the latest values win.
 * DELETE is the RLS-restricted soft-delete RPC, so a permission rejection
 * BLOCKS rather than retrying forever.
 *
 * Repricing or retiring a library row here never rewrites a
 * [WorkTaskMaterial]: task lines own their own frozen snapshot.
 */
class VineyardMaterialSync(
    private val repo: WorkTaskMaterialWriting,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    @Serializable
    data class UpsertPayload(
        val id: String,
        val vineyardId: String,
        val baseMaterialId: String? = null,
        val name: String,
        val category: String,
        val unit: String,
        val defaultUnitCost: String? = null,
        val isCustom: Boolean,
        val isActive: Boolean = true,
        val clientUpdatedAt: String,
    )

    @Serializable
    data class DeletePayload(val vineyardMaterialId: String, val vineyardId: String)

    /** Queue (or replace) a library upsert. Create and edit both land here. */
    fun enqueueUpsert(
        id: String,
        vineyardId: String,
        baseMaterialId: String?,
        name: String,
        category: String,
        unit: String,
        defaultUnitCost: BigDecimal?,
        isCustom: Boolean,
        isActive: Boolean,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.VINEYARD_MATERIAL &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = UpsertPayload(
            id = id,
            vineyardId = vineyardId,
            baseMaterialId = if (isCustom) null else baseMaterialId,
            name = name.trim(),
            category = category,
            unit = MaterialUnitCatalog.normalised(unit),
            defaultUnitCost = defaultUnitCost?.let { MaterialMoney.wire(it.max(BigDecimal.ZERO)) },
            isCustom = isCustom,
            isActive = isActive,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.VINEYARD_MATERIAL,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(UpsertPayload.serializer(), payload),
            clientId = id,
        )
    }

    /** Queue a soft-delete, clearing any same-row unresolved upsert. */
    fun enqueueDelete(vineyardMaterialId: String, vineyardId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.VINEYARD_MATERIAL &&
                    it.clientId == vineyardMaterialId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            DeletePayload.serializer(),
            DeletePayload(vineyardMaterialId, vineyardId),
        )
        return pending.enqueue(
            entityType = PendingEntityType.VINEYARD_MATERIAL,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = vineyardMaterialId,
        )
    }

    suspend fun replayAll(
        onUpserted: (VineyardMaterial) -> Unit,
        onDeleted: (vineyardMaterialId: String) -> Unit,
    ) {
        if (!replayLock.tryLock()) return
        try {
            replayUpserts(onUpserted)
            replayDeletes(onDeleted)
        } finally {
            replayLock.unlock()
        }
    }

    private suspend fun replayUpserts(onUpserted: (VineyardMaterial) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.VINEYARD_MATERIAL &&
                it.opType == PendingOpType.UPDATE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(UpsertPayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved material.")
                continue
            }
            try {
                val saved = repo.upsertVineyardMaterial(
                    id = payload.id,
                    vineyardId = payload.vineyardId,
                    baseMaterialId = payload.baseMaterialId,
                    name = payload.name,
                    category = payload.category,
                    unit = payload.unit,
                    defaultUnitCost = MaterialMoney.decimalOrNull(payload.defaultUnitCost),
                    isCustom = payload.isCustom,
                    isActive = payload.isActive,
                    clientUpdatedAt = payload.clientUpdatedAt,
                )
                pending.remove(write.id)
                onUpserted(saved)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync this material.")
            } catch (e: BackendError.Server) {
                when {
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(
                        write.id,
                        PendingWriteStatus.BLOCKED,
                        "The material was rejected (${e.code}).",
                    )
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    private suspend fun replayDeletes(onDeleted: (vineyardMaterialId: String) -> Unit) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.VINEYARD_MATERIAL &&
                it.opType == PendingOpType.DELETE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            val payload = runCatching {
                json.decodeFromString(DeletePayload.serializer(), write.payloadJson)
            }.getOrNull()
            if (payload == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved material delete.")
                continue
            }
            try {
                repo.softDeleteVineyardMaterial(payload.vineyardMaterialId)
                pending.remove(write.id)
                onDeleted(payload.vineyardMaterialId)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to remove this material.")
            } catch (e: BackendError.Server) {
                when {
                    e.code == 404 -> {
                        pending.remove(write.id)
                        onDeleted(payload.vineyardMaterialId)
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

    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        const val MAX_ATTEMPTS = 8
    }
}
