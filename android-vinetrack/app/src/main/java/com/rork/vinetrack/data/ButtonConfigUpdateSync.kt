package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for per-vineyard launcher button configuration
 * UPDATE only (Android Stage N).
 *
 * An owner/manager edited the Repairs or Growth launcher buttons offline (or a
 * transient online upsert failed) and the optimistic layout is already showing
 * locally. This replays the merge-duplicates upsert
 * ([ButtonConfigRepository.upsert]) and nothing else: it never touches any other
 * entity. `vineyard_button_configs` is keyed by (vineyard_id, config_type) and
 * Android only ever upserts it, so there is no create/delete op — UPDATE is the
 * single discriminator.
 *
 * Coalescing / idempotency: the outbox row is keyed on
 * ([PendingWrite.clientId] = "$vineyardId|$configType") and only one unresolved
 * update is ever kept per (vineyard, config type) — [enqueue] drops any earlier
 * unresolved update so the latest layout wins (last-writer-wins via the queued
 * [Payload.clientUpdatedAt]). Re-applying the same upsert is itself idempotent
 * server-side. No auth/session/tokens are stored; `created_by` is resolved from
 * the signed-in session at upsert time.
 *
 * Role / permission: server insert/update is RLS-restricted to owners and
 * managers. A permission/validation rejection is BLOCKED (needs attention)
 * rather than retried forever.
 */
class ButtonConfigUpdateSync(
    private val buttonConfigRepo: ButtonConfigRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full upsert payload needed to replay the edit. Carries the vineyard scope,
     * config type, the full button list, and the [clientUpdatedAt] the owner
     * saved the layout at (last-writer-wins stamp).
     */
    @Serializable
    data class Payload(
        val vineyardId: String,
        val configType: String,
        val buttons: List<LauncherButton>,
        val clientUpdatedAt: String,
    )

    /** Stable coalescing key for one (vineyard, config type) pair. */
    private fun keyFor(vineyardId: String, configType: String): String = "$vineyardId|$configType"

    /**
     * Queue (or replace) a launcher-button config update for later replay.
     * Coalesces by (vineyard, config type): any earlier unresolved update for the
     * same key is removed first so only the latest layout is ever replayed.
     */
    fun enqueue(
        vineyardId: String,
        configType: String,
        buttons: List<LauncherButton>,
        clientUpdatedAt: String,
    ): PendingWrite {
        val key = keyFor(vineyardId, configType)
        pending.list()
            .filter {
                it.entityType == PendingEntityType.BUTTON_CONFIG &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == key &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            vineyardId = vineyardId,
            configType = configType,
            buttons = buttons,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.BUTTON_CONFIG,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = key,
        )
    }

    /**
     * Replay every retry-eligible queued button-config update. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, then
     * resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - upsert succeeds -> removed from the outbox; [onSynced] fires with the
     *    payload so the caller can reflect the synced layout,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Payload) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.BUTTON_CONFIG &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved button layout.")
                    continue
                }
                try {
                    buttonConfigRepo.upsert(
                        vineyardId = payload.vineyardId,
                        configType = payload.configType,
                        buttons = payload.buttons,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(payload)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync these buttons.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The button layout was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing button layout can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
