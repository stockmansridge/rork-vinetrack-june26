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
 * Offline replay coordinator for growth-stage record CREATE only (Android Stage N-1).
 *
 * The operator logged a growth-stage observation offline (or a transient online
 * insert failed) and the optimistic row is already showing locally. This replays
 * the additive insert ([GrowthStageRecordRepository.createGrowthStageRecord]) and
 * nothing else: it never edits an existing record, never deletes, and never
 * touches photo uploads/removals or any other entity. Growth update and delete,
 * and growth photo writes, remain online-only in N-1 (parked for N-2/N-3).
 *
 * Discriminator: create markers use [PendingEntityType.GROWTH_RECORD] / CREATE so
 * a future growth update/delete queue (different op type) can never pick them up,
 * and this coordinator only ever processes GROWTH_RECORD / CREATE rows.
 *
 * Idempotency: the client mints the final record UUID up front and uses it as
 * both [PendingWrite.clientId] and the inserted row id, so a retried insert is
 * safe — if the server reports a duplicate primary key (409) the row is already
 * there and we treat it as synced rather than inserting a second record. The
 * original [Payload.clientUpdatedAt] travels in the payload so replay preserves
 * the moment the operator actually saved the observation, not when it later
 * synced. `created_by` is never carried — it is resolved from the signed-in
 * session at insert time; pin/geo/side/photo columns are never sent (Android
 * authors direct records with `pin_id` null). No auth/session/tokens are stored.
 */
class GrowthRecordCreateSync(
    private val growthRepo: GrowthStageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable
     * growth-stage fields plus the stable client id, vineyard scope and original
     * client_updated_at. `created_by`, pin/geo/side/photo and server-managed
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
     * Queue (or replace) a growth-record create for later replay. Coalesces by
     * record id: any earlier unresolved create for the same id is removed first
     * so only one is ever replayed. The [record] id must be the same
     * client-generated id used for the optimistic local row and the eventual
     * server insert.
     */
    fun enqueue(record: GrowthStageRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.CREATE &&
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
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Android Stage N-2). When the
     * operator edits a growth observation whose original create hasn't synced
     * yet, there is no server row to PATCH — instead the queued create payload is
     * rewritten in place with the latest editable values (paddock, stage, variety,
     * observed-at, row, notes) and a fresh [clientUpdatedAt], so the eventual
     * insert carries the edited observation directly. The stable record id travels
     * with the [record] snapshot the caller built. Returns true when a pending
     * create existed and was folded; false when there's nothing to fold into (the
     * caller should then queue a normal GROWTH_RECORD / UPDATE instead).
     */
    fun foldEdit(record: GrowthStageRecord, clientUpdatedAt: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.GROWTH_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == record.id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        enqueue(record, clientUpdatedAt)
        return true
    }

    /**
     * Replay every retry-eligible queued growth-record create. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, POST it,
     * then resolve the outcome:
     *  - success / duplicate (409) -> removed from the outbox; [onSynced] fires
     *    with the server row (success only) so callers can reconcile state,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap hit ->
     *    blocked so it never loops forever.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (GrowthStageRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved observation.")
                    continue
                }
                try {
                    val created = growthRepo.createGrowthStageRecord(
                        vineyardId = payload.vineyardId,
                        input = payload.toInput(),
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this observation.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the record exists. Idempotent success; the
                        // optimistic row stays as-is.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The observation was rejected (${e.code}).",
                        )
                    }
                } catch (e: Exception) {
                    // Still offline / transient network failure — leave for next time.
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing observation can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
