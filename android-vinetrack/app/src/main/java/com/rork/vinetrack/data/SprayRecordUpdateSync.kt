package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for spray-record UPDATE only (Android Stage I-2).
 *
 * The operator edited an existing, already-synced spray record offline (or a
 * transient online PATCH failed) and the optimistic edit is already showing
 * locally. This replays the editable-column PATCH
 * ([SprayRecordRepository.updateSprayRecord]) and nothing else: it never
 * inserts, never deletes, and never touches any other entity. Spray create is
 * owned by [SprayRecordCreateSync] (SPRAY_RECORD / CREATE); spray delete remains
 * online-only in I-2.
 *
 * Discriminator: update markers use [PendingEntityType.SPRAY_RECORD] / UPDATE so
 * they can never be picked up by the create coordinator (SPRAY_RECORD / CREATE)
 * and this coordinator only ever processes SPRAY_RECORD / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same record still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [SprayRecordCreateSync.foldEdit] and never queues an UPDATE — so a create+edit
 * pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-record create (e.g. ordering races), it is deferred (kept
 * FAILED, retry-eligible, no attempt consumed) until the create resolves —
 * PATCHing a row the server doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the spray-record id
 * ([PendingWrite.clientId] = sprayRecordId) and only one unresolved update is
 * ever kept per record — [enqueue] drops any earlier unresolved update for the
 * same id so the latest edit wins (last-writer-wins via the queued
 * [Payload.clientUpdatedAt]).
 */
class SprayRecordUpdateSync(
    private val sprayRepo: SprayRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full editable update payload. Carries the spray form's editable columns
     * plus the stable client id and the [clientUpdatedAt] the operator saved the
     * edit at (last-writer-wins stamp). No auth/session/secrets — `created_by` is
     * left untouched server-side on edit.
     */
    @Serializable
    data class Payload(
        val id: String,
        val date: String,
        val startTime: String,
        val temperature: Double? = null,
        val windSpeed: Double? = null,
        val windDirection: String? = null,
        val humidity: Double? = null,
        val sprayReference: String? = null,
        val notes: String? = null,
        val numberOfFansJets: String? = null,
        val averageSpeed: Double? = null,
        val equipmentType: String? = null,
        val tractor: String? = null,
        val tractorGear: String? = null,
        val machineId: String? = null,
        val sprayEquipmentId: String? = null,
        val operationType: String? = null,
        val tripId: String? = null,
        val isTemplate: Boolean = false,
        val tanks: List<SprayTank> = emptyList(),
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a spray-record update for later replay. Coalesces by
     * record id: any earlier unresolved update for the same id is removed first
     * so only the latest edit is ever replayed. The [id] must be the same id used
     * for the optimistic local row and the eventual server PATCH.
     */
    fun enqueue(
        id: String,
        input: SprayRecordRepository.SprayInput,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            date = input.date,
            startTime = input.startTime,
            temperature = input.temperature,
            windSpeed = input.windSpeed,
            windDirection = input.windDirection,
            humidity = input.humidity,
            sprayReference = input.sprayReference,
            notes = input.notes,
            numberOfFansJets = input.numberOfFansJets,
            averageSpeed = input.averageSpeed,
            equipmentType = input.equipmentType,
            tractor = input.tractor,
            tractorGear = input.tractorGear,
            machineId = input.machineId,
            sprayEquipmentId = input.sprayEquipmentId,
            operationType = input.operationType,
            tripId = input.tripId,
            isTemplate = input.isTemplate,
            tanks = input.tanks,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.SPRAY_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Replay every retry-eligible queued spray-record update. No-ops (returns) if
     * a replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-record create still unresolved -> deferred (FAILED, retry-eligible,
     *    no attempt consumed), never PATCHed against a missing row,
     *  - PATCH succeeds -> removed from the outbox; [onSynced] fires with the
     *    server row so the caller reconciles by id,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (SprayRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved spray record edit.")
                    continue
                }
                // Dependency gate: never PATCH while the same record's create is
                // still unresolved (the server row may not exist yet). Defer
                // without consuming a retry attempt. Normally the ViewModel folds
                // edits into a pending create so this is only a safety net.
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this spray record to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = sprayRepo.updateSprayRecord(
                        id = payload.id,
                        input = SprayRecordRepository.SprayInput(
                            date = payload.date,
                            startTime = payload.startTime,
                            temperature = payload.temperature,
                            windSpeed = payload.windSpeed,
                            windDirection = payload.windDirection,
                            humidity = payload.humidity,
                            sprayReference = payload.sprayReference,
                            notes = payload.notes,
                            numberOfFansJets = payload.numberOfFansJets,
                            averageSpeed = payload.averageSpeed,
                            equipmentType = payload.equipmentType,
                            tractor = payload.tractor,
                            tractorGear = payload.tractorGear,
                            machineId = payload.machineId,
                            sprayEquipmentId = payload.sprayEquipmentId,
                            operationType = payload.operationType,
                            tripId = payload.tripId,
                            isTemplate = payload.isTemplate,
                            tanks = payload.tanks,
                        ),
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this spray record edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The spray record edit was rejected (${e.code}).",
                        )
                    }
                } catch (e: Exception) {
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /**
     * True when the same spray record still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing edit can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
