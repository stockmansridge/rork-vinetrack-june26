package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for block-damage record soft-DELETE only (Android Stage M-3).
 *
 * The operator deleted an already-synced damage record offline (or a transient
 * online delete failed) and the optimistic hide is already showing locally. This
 * replays the soft-delete RPC ([DamageRecordRepository.softDeleteDamageRecord])
 * and nothing else: it never inserts, never edits, and never touches any other
 * entity. Create is owned by [DamageRecordCreateSync] (DAMAGE_RECORD / CREATE)
 * and edit by [DamageRecordUpdateSync] (DAMAGE_RECORD / UPDATE).
 *
 * Discriminator: delete markers use [PendingEntityType.DAMAGE_RECORD] / DELETE
 * so they can never be picked up by the create or update coordinators, and this
 * coordinator only ever processes DAMAGE_RECORD / DELETE rows.
 *
 * Local-only safety: a damage record still queued for CREATE is never deleted
 * via a server marker — the caller
 * ([com.rork.vinetrack.ui.AppViewModel.deleteDamageRecord]) cancels the create
 * (and any same-record update) locally instead, so an offline-created record the
 * operator deleted can't be resurrected by a later [DamageRecordCreateSync]
 * replay. This coordinator only ever runs against records the server already
 * knows about.
 *
 * Dependency gate (safety net): a delete is never finalised while same-record
 * create / update work is still unresolved — such a marker is deferred (kept
 * FAILED, retry-eligible, no attempt consumed) until the dependencies clear.
 *
 * Idempotency / coalescing: the outbox row is keyed on the damage-record id
 * ([PendingWrite.clientId] = damageRecordId) and only one unresolved delete is
 * ever kept per record. An already-deleted / not-found (404) row is treated as
 * success so a delete can never loop forever.
 *
 * Role / permission: server soft-delete is RLS-restricted (owner / manager /
 * supervisor may delete; operators may not). A permission/validation rejection
 * is BLOCKED (needs attention) rather than retried forever.
 */
class DamageRecordDeleteSync(
    private val damageRepo: DamageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target damage-record id — nothing else. */
    @Serializable
    data class Payload(val damageRecordId: String)

    /**
     * Queue (or replace) a soft-delete for [damageRecordId]. Coalesces by record
     * id: any earlier unresolved delete write for the same record is removed
     * first so only one is ever replayed. Callers must only enqueue this for a
     * record that exists server-side — a local-only pending-create record is
     * cancelled in place rather than queued for delete.
     */
    fun enqueue(damageRecordId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == damageRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(damageRecordId))
        return pending.enqueue(
            entityType = PendingEntityType.DAMAGE_RECORD,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = damageRecordId,
        )
    }

    /**
     * Cancel a never-synced damage record locally (Android Stage M-3). When the
     * operator deletes a record whose original CREATE hasn't synced yet, there is
     * no server row to delete — instead the queued create (and any same-record
     * update) marker is dropped so no insert/patch ever fires and no DELETE
     * marker is queued. Returns true when a pending create existed and was
     * cancelled; false when the record is already synced server-side (the caller
     * should then take the normal optimistic-hide + enqueue path).
     */
    fun cancelLocalCreate(damageRecordId: String): Boolean {
        val pendingCreate = pending.list().firstOrNull {
            it.entityType == PendingEntityType.DAMAGE_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == damageRecordId &&
                it.status != PendingWriteStatus.SYNCED
        } ?: return false
        pending.remove(pendingCreate.id)
        pending.list()
            .filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == damageRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Replay every retry-eligible queued damage-record delete. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, then
     * resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-record create / update still unresolved -> deferred (FAILED,
     *    retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller keeps it hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (damageRecordId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved damage record delete.")
                    continue
                }
                if (hasUnresolvedDependencies(payload.damageRecordId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this damage record's other changes to sync first.",
                    )
                    continue
                }
                try {
                    damageRepo.softDeleteDamageRecord(payload.damageRecordId)
                    pending.remove(write.id)
                    onDeleted(payload.damageRecordId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this damage record.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.damageRecordId)
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
        } finally {
            replayLock.unlock()
        }
    }

    /**
     * True when the same damage record still has an unresolved create or update
     * marker (pending / in-progress / failed / blocked). The delete waits for
     * those to land rather than racing an insert or PATCH / delete in the wrong
     * order.
     */
    private fun hasUnresolvedDependencies(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
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
        /** Cap retries so a persistently-failing delete can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
