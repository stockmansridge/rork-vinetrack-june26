package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningYieldSettings
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for the shared per-block Pruning Yield
 * Calculator configuration (sql/181). PRUNING_YIELD_SETTINGS / UPDATE only.
 *
 * A block's configuration is a merge-duplicates UPSERT keyed by the
 * (vineyard_id, paddock_id) unique key, so create and edit both fold into a
 * single UPDATE op coalesced one-per block
 * ([PendingWrite.clientId] = "vineyardId|paddockId") — the latest saved
 * values win and a burst of autosaves never produces one pending row per
 * keystroke. Replaying is idempotent: the upsert converges on the block's
 * single server row regardless of which device minted the row id.
 *
 * No delete op is carried — a block's configuration is only ever overwritten;
 * the soft-delete RPC exists server-side for administrative cleanup.
 */
class PruningYieldSettingsSync(
    private val settingsRepo: PruningYieldSettingsRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full upsert payload needed to replay the save. */
    @Serializable
    data class Payload(
        val settings: PruningYieldSettings,
        val clientUpdatedAt: String,
    )

    private fun clientId(settings: PruningYieldSettings): String =
        "${settings.vineyardId}|${settings.paddockId}"

    /**
     * Queue (or replace) a block-configuration save for later replay.
     * Coalesced by block so only the LATEST values are ever replayed.
     */
    fun enqueue(settings: PruningYieldSettings, clientUpdatedAt: String): PendingWrite {
        val key = clientId(settings)
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PRUNING_YIELD_SETTINGS &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == key &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return pending.enqueue(
            entityType = PendingEntityType.PRUNING_YIELD_SETTINGS,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), Payload(settings, clientUpdatedAt)),
            clientId = key,
        )
    }

    /**
     * Replay every retry-eligible queued save. [onSynced] fires with the
     * server row so the caller can reconcile the authoritative record (and
     * its converged id) into state.
     */
    suspend fun replayAll(onSynced: (PruningYieldSettings) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PRUNING_YIELD_SETTINGS &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved calculator settings.")
                    continue
                }
                try {
                    val saved = settingsRepo.upsertSettings(payload.settings, payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(saved)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync calculator settings.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The calculator settings were rejected (${e.code}).",
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

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
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
