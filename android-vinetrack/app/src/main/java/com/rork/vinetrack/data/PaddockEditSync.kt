package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for block (paddock) edits.
 *
 * Blocks were the one domain whose edits were direct-only network calls: an
 * offline save rolled back and the operator's work was lost. This coordinator
 * queues the three block write shapes and replays them on reconnect:
 *
 *  - [KIND_UPSERT]      — full-row save from the block editor
 *                         ([PaddockRepository.upsertPaddock], merge-duplicates
 *                         on `id`, replay-safe).
 *  - [KIND_ALLOCATIONS] — variety-allocations-only PATCH ("Fix Block
 *                         Varieties"), never touching geometry/rows.
 *  - [KIND_PHENOLOGY]   — phenology-dates-only PATCH.
 *
 * Allocation identity: the queued snapshot carries every
 * `variety_allocations[].id` verbatim and the repository encodes them back
 * out on replay — a replayed block edit can never regenerate or erase the
 * planting identities the picking log links to (sql/184).
 *
 * Coalescing: one marker per (block id, kind) — the LATEST edit of each kind
 * wins. A queued full upsert supersedes older partial markers for the same
 * block (its snapshot already contains the optimistic allocations/dates),
 * and a partial edit arriving while a full upsert is queued is folded into a
 * refreshed upsert snapshot by the caller passing the current block.
 *
 * Replay is mutex-guarded, ordered oldest-first, retries transient failures
 * (max 8 attempts), resolves a block deleted elsewhere as moot via
 * `onMissing`, and BLOCKS on permanent rejections. Payloads carry no
 * auth/session/tokens; `created_by` resolves from the live session at replay.
 */
class PaddockEditSync(
    private val paddockRepo: PaddockRepository,
    private val pending: PendingWriteRepository,
    private val session: SessionStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** One queued block edit; `kind` selects which write shape to replay. */
    @Serializable
    data class Payload(
        val kind: String,
        val paddockId: String,
        val vineyardId: String,
        /** Full snapshot for [KIND_UPSERT]; allocation ids preserved verbatim. */
        val paddock: Paddock? = null,
        /** Allocations for [KIND_ALLOCATIONS]; ids preserved verbatim. */
        val allocations: List<PaddockVarietyAllocation>? = null,
        val budburstDate: String? = null,
        val floweringDate: String? = null,
        val veraisonDate: String? = null,
        val harvestDate: String? = null,
    )

    /**
     * Queue (or replace) a full-row block save. Supersedes ALL older
     * unresolved markers for this block — the snapshot already contains the
     * latest allocations and phenology dates.
     */
    fun enqueueUpsert(paddock: Paddock): PendingWrite {
        removeUnresolved(paddock.id) { true }
        val payload = Payload(
            kind = KIND_UPSERT,
            paddockId = paddock.id,
            vineyardId = paddock.vineyardId,
            paddock = paddock,
        )
        return enqueue(paddock.id, payload)
    }

    /**
     * Queue (or replace) an allocations-only edit. If a full upsert is
     * already queued for this block, the edit folds into a refreshed upsert
     * snapshot instead (the caller passes the current optimistic block).
     */
    fun enqueueAllocations(paddock: Paddock, allocations: List<PaddockVarietyAllocation>): PendingWrite {
        if (hasUnresolvedKind(paddock.id, KIND_UPSERT)) {
            return enqueueUpsert(paddock.copy(varietyAllocations = allocations))
        }
        removeUnresolved(paddock.id) { it.kind == KIND_ALLOCATIONS }
        val payload = Payload(
            kind = KIND_ALLOCATIONS,
            paddockId = paddock.id,
            vineyardId = paddock.vineyardId,
            allocations = allocations,
        )
        return enqueue(paddock.id, payload)
    }

    /**
     * Queue (or replace) a phenology-dates-only edit; folds into a queued
     * full upsert the same way as [enqueueAllocations].
     */
    fun enqueuePhenology(paddock: Paddock, dates: PaddockRepository.PhenologyDates): PendingWrite {
        if (hasUnresolvedKind(paddock.id, KIND_UPSERT)) {
            return enqueueUpsert(
                paddock.copy(
                    budburstDate = dates.budburstDate,
                    floweringDate = dates.floweringDate,
                    veraisonDate = dates.veraisonDate,
                    harvestDate = dates.harvestDate,
                ),
            )
        }
        removeUnresolved(paddock.id) { it.kind == KIND_PHENOLOGY }
        val payload = Payload(
            kind = KIND_PHENOLOGY,
            paddockId = paddock.id,
            vineyardId = paddock.vineyardId,
            budburstDate = dates.budburstDate,
            floweringDate = dates.floweringDate,
            veraisonDate = dates.veraisonDate,
            harvestDate = dates.harvestDate,
        )
        return enqueue(paddock.id, payload)
    }

    /**
     * Replay every retry-eligible queued block edit, oldest first. [onSynced]
     * fires with the authoritative server row; [onMissing] fires when the
     * block no longer exists (deleted elsewhere) so the caller can drop the
     * stale local copy.
     */
    suspend fun replayAll(
        onSynced: (Paddock) -> Unit,
        onMissing: (paddockId: String) -> Unit = {},
    ) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PADDOCK &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = decode(write)
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved block edit.")
                    continue
                }
                try {
                    val saved = when (payload.kind) {
                        KIND_UPSERT -> payload.paddock?.let {
                            paddockRepo.upsertPaddock(it, createdBy = session.userId)
                        }
                        KIND_ALLOCATIONS -> paddockRepo.updateVarietyAllocations(
                            payload.paddockId,
                            payload.allocations.orEmpty(),
                        )
                        KIND_PHENOLOGY -> paddockRepo.updatePhenologyDates(
                            payload.paddockId,
                            PaddockRepository.PhenologyDates(
                                budburstDate = payload.budburstDate,
                                floweringDate = payload.floweringDate,
                                veraisonDate = payload.veraisonDate,
                                harvestDate = payload.harvestDate,
                            ),
                        )
                        else -> null
                    }
                    pending.remove(write.id)
                    if (saved != null) onSynced(saved)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this block edit.")
                } catch (e: BackendError.Server) {
                    when {
                        // A partial PATCH that matched no live row (or a 404)
                        // means the block was deleted on another device — the
                        // edit is moot.
                        e.code == 404 || e.body.contains("Empty response") -> {
                            pending.remove(write.id)
                            onMissing(payload.paddockId)
                        }
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The block edit was rejected (${e.code}).",
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

    /** True while any unresolved marker of [kind] is queued for [paddockId]. */
    private fun hasUnresolvedKind(paddockId: String, kind: String): Boolean =
        pending.list().any {
            it.entityType == PendingEntityType.PADDOCK &&
                it.clientId == paddockId &&
                it.status in PendingWriteStatus.unresolved &&
                decode(it)?.kind == kind
        }

    private fun removeUnresolved(paddockId: String, match: (Payload) -> Boolean) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PADDOCK &&
                    it.clientId == paddockId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .filter { write -> decode(write)?.let(match) ?: true }
            .forEach { pending.remove(it.id) }
    }

    private fun enqueue(paddockId: String, payload: Payload): PendingWrite =
        pending.enqueue(
            entityType = PendingEntityType.PADDOCK,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = paddockId,
        )

    private fun decode(write: PendingWrite): Payload? =
        runCatching { json.decodeFromString(Payload.serializer(), write.payloadJson) }.getOrNull()

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    companion object {
        const val KIND_UPSERT = "upsert"
        const val KIND_ALLOCATIONS = "allocations"
        const val KIND_PHENOLOGY = "phenology"
        private const val MAX_ATTEMPTS = 8
    }
}
