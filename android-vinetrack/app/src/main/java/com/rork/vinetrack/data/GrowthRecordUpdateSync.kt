package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for growth-stage record UPDATE only (Android Stage N-2).
 *
 * The operator edited an existing, already-synced growth observation offline
 * (changed stage/paddock/variety/observed-at/row/notes), or a transient online
 * PATCH failed, and the optimistic edit is already showing locally. This replays
 * the growth PATCH ([GrowthStageRecordRepository.updateGrowthStageRecord]) and
 * nothing else: it never inserts, never deletes, and never touches photo
 * uploads/removals or any other entity. Growth delete remains online-only /
 * parked for N-3; growth photo writes stay online-only.
 *
 * Discriminator: update markers use [PendingEntityType.GROWTH_RECORD] / UPDATE so
 * they can never be picked up by the create coordinator (GROWTH_RECORD / CREATE)
 * and this coordinator only ever processes GROWTH_RECORD / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same record still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [GrowthRecordCreateSync.foldEdit] and never queues an UPDATE — so a create+edit
 * pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-record create (e.g. ordering races), it is deferred (kept
 * FAILED, retry-eligible, no attempt consumed) until the create resolves —
 * PATCHing a row the server doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the record id
 * ([PendingWrite.clientId] = growthRecordId) and only one unresolved update is
 * ever kept per record — [enqueue] drops any earlier unresolved update for the
 * same id so the latest edit wins (last-writer-wins via the queued
 * [Payload.clientUpdatedAt]). Only the form-owned columns travel in the payload;
 * pin/geo/side, photo paths, `created_by`, `updated_by` and server-managed
 * audit/sync columns are never carried. No auth/session/tokens are stored.
 */
class GrowthRecordUpdateSync(
    private val growthRepo: GrowthStageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full patch payload needed to replay the edit. Carries the editable
     * growth-stage fields plus the stable client id, vineyard scope and the
     * [clientUpdatedAt] the operator saved the edit at (last-writer-wins stamp).
     * Pin/geo/side, photo paths, `created_by`/`updated_by` and server-managed
     * audit/sync columns are deliberately NOT carried.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val paddockId: String? = null,
        val stageCode: String,
        val stageLabel: String? = null,
        val variety: String? = null,
        val observedAt: String,
        val rowNumber: Int? = null,
        val notes: String? = null,
        val clientUpdatedAt: String,
    )

    private fun Payload.toInput(): GrowthStageRecordRepository.GrowthInput =
        GrowthStageRecordRepository.GrowthInput(
            paddockId = paddockId,
            stageCode = stageCode,
            stageLabel = stageLabel,
            variety = variety,
            observedAt = observedAt,
            rowNumber = rowNumber,
            notes = notes,
        )

    /**
     * Queue (or replace) a growth-record update for later replay. Coalesces by
     * record id: any earlier unresolved update for the same id is removed first
     * so only the latest edit is ever replayed. The [record] id must be the same
     * id used for the optimistic local row and the eventual server PATCH.
     */
    fun enqueue(record: GrowthStageRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = record.id,
            vineyardId = record.vineyardId,
            paddockId = record.paddockId,
            stageCode = record.stageCode,
            stageLabel = record.stageLabel,
            variety = record.variety,
            observedAt = record.observedAt ?: clientUpdatedAt,
            rowNumber = record.rowNumber,
            notes = record.notes,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.GROWTH_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Replay every retry-eligible queued growth-record update. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, then
     * resolve:
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
    suspend fun replayAll(onSynced: (GrowthStageRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved observation edit.")
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
                        "Waiting for this observation to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = growthRepo.updateGrowthStageRecord(
                        id = payload.id,
                        input = payload.toInput(),
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this observation edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The observation edit was rejected (${e.code}).",
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
     * True when the same growth record still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.GROWTH_RECORD &&
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
