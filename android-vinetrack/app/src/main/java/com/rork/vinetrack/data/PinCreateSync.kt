package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for pin CREATE only (Stage 4A-iv).
 *
 * This is the first — and deliberately the only — write path wired into the
 * pending-write outbox. It is intentionally NOT a general SyncManager: it
 * replays additive, non-destructive `pin` / `create` rows and nothing else.
 * Pin update, complete/toggle, delete, photos, trips, rows, tanks, sprays,
 * fuel, and every other entity remain online-only and untouched.
 *
 * Idempotency: a queued pin carries the client-generated UUID (`PinInput.id`)
 * minted when the user created it offline. Replaying re-uses that same id, so
 * a 409 is acknowledged only after an account-bound read proves the original
 * stable target, vineyard and explicit creator. Unproven conflicts retain the payload.
 */
class PinCreateSync private constructor(
    private val createRemote: (suspend (PinRepository.PinInput) -> Pin)?,
    private val pending: PendingWriteRepository,
    private val fetchDuplicate: (suspend (PinRepository.PinInput, String) -> Pin?)?,
    private val withDuplicateAccount: ((String, () -> Unit) -> Boolean)?,
) {
    constructor(pinRepo: PinRepository, pending: PendingWriteRepository) : this(
        createRemote = { input -> pinRepo.createPin(input) },
        pending = pending,
        fetchDuplicate = pinRepo::fetchCreateDuplicate,
        withDuplicateAccount = pinRepo::withCreateAccount,
    )

    /** Queue-only constructor used by durable production-payload tests. */
    internal constructor(pending: PendingWriteRepository) : this(null, pending, null, null)

    /** Production replay seam for executable persistence/network tests. */
    internal constructor(
        pending: PendingWriteRepository,
        createRemote: suspend (PinRepository.PinInput) -> Pin,
    ) : this(createRemote, pending, null, null)

    /** Focused conflict verification seam; production uses SessionStore's revocation monitor. */
    internal constructor(
        pending: PendingWriteRepository,
        createRemote: suspend (PinRepository.PinInput) -> Pin,
        fetchDuplicate: suspend (PinRepository.PinInput, String) -> Pin?,
        withDuplicateAccount: (String, () -> Unit) -> Boolean = { _, action -> action(); true },
    ) : this(createRemote, pending, fetchDuplicate, withDuplicateAccount)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Queue a pin create for later replay. The [input] must already carry its
     * client-generated [PinRepository.PinInput.id]; that id is also stored as
     * the outbox idempotency key.
     */
    fun enqueue(input: PinRepository.PinInput): PendingWrite {
        val clientId = input.id ?: error("Queued pin create requires a client id")
        val payload = json.encodeToString(PinRepository.PinInput.serializer(), input)
        return pending.enqueue(
            entityType = PendingEntityType.PIN,
            opType = PendingOpType.CREATE,
            payloadJson = payload,
            clientId = clientId,
        )
    }

    /**
     * Replay every retry-eligible queued pin create. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, POST it, then
     * resolve the outcome:
     *  - success / verified duplicate -> conditional removal; [onSynced] fires
     *    only for POST success, never publishing a conflict probe over local data,
     *  - unverified 409 -> retained for review; interrupted read -> retained for retry,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap hit ->
     *    blocked so it never loops forever.
     *
     * Caller is responsible for only invoking this when a session token exists.
     */
    suspend fun replayAll(permittedWriteIds: Set<String>? = null, permittedWrites: Map<String, PendingWrite>? = null, onSynced: (Pin) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
                    (permittedWriteIds == null || it.id in permittedWriteIds) &&
                    (permittedWrites == null || permittedWrites[it.id] == it)
            }
            for (candidate in candidates) {
                val write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val input = runCatching {
                    json.decodeFromString(PinRepository.PinInput.serializer(), write.payloadJson)
                }.getOrNull()
                if (input == null) {
                    // Unreplayable payload — block it so it can't loop.
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved pin.")
                    continue
                }
                val replayScope = pending.currentReplayScope()
                try {
                    val pin = requireNotNull(createRemote) { "Pin repository is required for replay." }(input)
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (pending.removeIfCurrent(write)) onSynced(pin)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this pin.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code == 409 -> verifyConflict(write, input, replayScope)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The pin was rejected (${e.code}).",
                        )
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Pin sync was interrupted. Ready to retry.")
                    throw e
                } catch (e: Exception) {
                    // Still offline / transient network failure — leave for next time.
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    private suspend fun verifyConflict(
        write: PendingWrite,
        input: PinRepository.PinInput,
        scope: PendingWriteRepository.ReplayScope?,
    ) {
        val held = "Pin conflict could not be verified. The original pin is retained for review; keep this installation and contact support."
        if (!pending.isCurrent(write)) return
        if (scope == null || input.id.isNullOrBlank() || input.vineyardId.isBlank() ||
            !input.id.equals(write.clientId, true) || input.createdBy.isNullOrBlank() ||
            !input.createdBy.equals(scope.userId, true) || fetchDuplicate == null || withDuplicateAccount == null) {
            pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, held)
            return
        }
        try {
            if (pending.currentReplayScope() != scope) return
            val remote = fetchDuplicate.invoke(input, scope.userId)
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (!pending.isCurrent(write) || pending.currentReplayScope() != scope) return
            val verified = remote != null && remote.deletedAt == null &&
                remote.id.equals(input.id, true) && remote.vineyardId.equals(input.vineyardId, true) &&
                !remote.createdBy.isNullOrBlank() && remote.createdBy.equals(input.createdBy, true)
            if (!verified) {
                pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, held)
                return
            }
            withDuplicateAccount.invoke(scope.userId) {
                if (pending.currentReplayScope() == scope) pending.removeIfCurrent(write)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED,
                "Pin conflict verification was interrupted. The original pin is retained for retry.")
            throw e
        } catch (_: Exception) {
            retryOrBlock(write, "Pin conflict verification is unavailable. The original pin is retained; retry when connected with account access.")
        }
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    private companion object {
        /** Cap retries so a persistently-failing pin can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
