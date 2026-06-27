package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for yield-record CREATE only (Android Stage L-1).
 *
 * The operator archived a seasonal yield record offline (an actual-yield record
 * or a sampling estimate), or a transient online insert failed, and the
 * optimistic row is already showing locally. This replays the additive insert
 * ([YieldRepository.insertYieldRecord]) and nothing else: it never edits an
 * existing record, never re-authors actuals/estimates, never deletes, and never
 * touches estimation sessions or any other entity. Yield update and delete
 * remain online-only in L-1 (parked for L-2/L-3).
 *
 * Discriminator: create markers use [PendingEntityType.YIELD_RECORD] / CREATE so
 * a future yield update/delete queue (different op type) can never pick them up,
 * and this coordinator only ever processes YIELD_RECORD / CREATE rows.
 *
 * Idempotency: the client mints the final record UUID (and block-result id) up
 * front and uses the record id as both [PendingWrite.clientId] and the inserted
 * row id, so a retried insert is safe — if the server reports a duplicate
 * primary key (409) the row is already there and we treat it as synced rather
 * than inserting a second record. The full computed `block_results` array,
 * totals and the original [Payload.clientUpdatedAt] travel in the payload so
 * replay preserves the record byte-for-byte and the moment the operator saved
 * it. `created_by` is never carried — it is resolved from the signed-in session
 * at insert time. No auth/session/tokens are stored.
 */
class YieldRecordCreateSync(
    private val yieldRepo: YieldRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the computed
     * record fields plus the stable client id, vineyard scope, block results and
     * original client_updated_at. `created_by` and server-managed audit/sync
     * columns are deliberately NOT carried.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val season: String,
        val year: Int,
        val archivedAt: String,
        val totalYieldTonnes: Double,
        val totalAreaHectares: Double,
        val notes: String,
        val blockResults: List<HistoricalBlockResult>,
        val clientUpdatedAt: String,
    )

    private fun Payload.toRecord(): HistoricalYieldRecord = HistoricalYieldRecord(
        id = id,
        vineyardId = vineyardId,
        season = season,
        year = year,
        archivedAt = archivedAt,
        totalYieldTonnes = totalYieldTonnes,
        totalAreaHectares = totalAreaHectares,
        notes = notes,
        blockResults = blockResults,
    )

    /**
     * Queue (or replace) a yield-record create for later replay. Coalesces by
     * record id: any earlier unresolved create for the same id is removed first
     * so only one is ever replayed. The [record] id must be the same
     * client-generated id used for the optimistic local row and the eventual
     * server insert.
     */
    fun enqueue(record: HistoricalYieldRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.YIELD_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = record.id,
            vineyardId = record.vineyardId,
            season = record.season,
            year = record.year,
            archivedAt = record.archivedAt ?: clientUpdatedAt,
            totalYieldTonnes = record.totalYieldTonnes,
            totalAreaHectares = record.totalAreaHectares,
            notes = record.notes,
            blockResults = record.blocks,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.YIELD_RECORD,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Android Stage L-2). When the
     * operator edits a yield record whose original create hasn't synced yet,
     * there is no server row to PATCH — instead the queued create payload is
     * rewritten in place with the latest editable values (season, year, totals,
     * notes, block results) and a fresh [clientUpdatedAt], so the eventual insert
     * carries the edited record directly. The stable record id and original
     * archived-at travel with the [record] snapshot the caller built. Returns
     * true when a pending create existed and was folded; false when there's
     * nothing to fold into (the caller should then queue a normal
     * YIELD_RECORD / UPDATE instead).
     */
    fun foldEdit(record: HistoricalYieldRecord, clientUpdatedAt: String): Boolean {
        val hasCreate = pending.list().any {
            it.entityType == PendingEntityType.YIELD_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == record.id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!hasCreate) return false
        enqueue(record, clientUpdatedAt)
        return true
    }

    /**
     * Replay every retry-eligible queued yield-record create. No-ops (returns)
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
    suspend fun replayAll(onSynced: (HistoricalYieldRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.YIELD_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved yield record.")
                    continue
                }
                try {
                    val created = yieldRepo.insertYieldRecord(payload.toRecord(), payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this yield record.")
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
                            "The yield record was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing yield record can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
