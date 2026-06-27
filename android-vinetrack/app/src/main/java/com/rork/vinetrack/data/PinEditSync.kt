package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import java.time.OffsetDateTime
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for descriptive pin EDITS only (Stage 9B-3).
 *
 * The fourth narrow write path wired into the pending-write outbox, alongside
 * [PinCreateSync] (create), [PinCompletionSync] (Done/Open toggle), and
 * [PinPhotoSync] (photo). It replays the descriptive-only write shape
 * ([PinRepository.updatePinFields]) — title/category/mode/notes and nothing
 * else. Completion, delete, photo, paddock reassignment, and row/side/snap
 * fields stay online-only and untouched.
 *
 * Discriminator: edit writes use [PendingEntityType.PIN_EDIT] / UPDATE so they
 * never collide with the Stage 9A completion queue (which owns PIN / UPDATE).
 *
 * Idempotency / coalescing: the outbox row is keyed on the pin id
 * ([PendingWrite.clientId] = pinId) and only one unresolved edit write is ever
 * kept per pin — [enqueue] drops any earlier unresolved edit writes for the
 * same pin so the latest edit wins, while preserving the original
 * [Payload.baseClientUpdatedAt] so the stale-guard still compares against the
 * server state the user first edited from.
 *
 * Conflict strategy: stale-guard + block. Before each replay the current server
 * pin is read; if its `client_updated_at` is newer than the queued
 * [Payload.baseClientUpdatedAt], the server changed while we were offline and
 * the edit is BLOCKED (Needs attention) rather than blindly overwritten. With
 * no conflict it PATCHes the descriptive fields with the queued
 * [Payload.clientUpdatedAt].
 */
class PinEditSync(
    private val pinRepo: PinRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Descriptive-only replay payload. Carries the user's edited descriptive
     * fields, the last-write-wins [clientUpdatedAt] stamp, and the
     * [baseClientUpdatedAt] the edit was made from for the stale-guard. No
     * completion, photo, paddock, side, or row/snap fields.
     */
    @Serializable
    data class Payload(
        val pinId: String,
        val title: String? = null,
        val category: String? = null,
        val mode: String? = null,
        val notes: String? = null,
        val clientUpdatedAt: String,
        val baseClientUpdatedAt: String? = null,
    )

    /**
     * Queue (or replace) a descriptive edit for [pinId]. Coalesces by pin: any
     * earlier unresolved edit write for the same pin is removed first so only
     * the latest edit is ever replayed (latest edit wins). The original
     * [baseClientUpdatedAt] from a still-pending earlier edit is preserved when
     * the caller doesn't supply one, so the stale-guard keeps comparing against
     * the server state the user first edited from. Returns the created row.
     */
    fun enqueue(
        pinId: String,
        title: String?,
        category: String?,
        mode: String?,
        notes: String?,
        baseClientUpdatedAt: String?,
    ): PendingWrite {
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.PIN_EDIT &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == pinId &&
                it.status != PendingWriteStatus.SYNCED
        }
        // Preserve the earliest known base so coalescing repeated offline edits
        // never moves the conflict baseline forward past where the user started.
        val preservedBase = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
            .firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: baseClientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                pinId = pinId,
                title = title,
                category = category,
                mode = mode,
                notes = notes,
                clientUpdatedAt = java.time.Instant.now().toString(),
                baseClientUpdatedAt = preservedBase,
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.PIN_EDIT,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = pinId,
        )
    }

    /**
     * Replay every retry-eligible queued edit. No-ops (returns) if a replay is
     * already running. For each item: mark in-progress, read the live server
     * pin, then resolve the outcome:
     *  - server pin missing/deleted -> blocked (can't edit a vanished pin),
     *  - server `client_updated_at` newer than the queued base -> blocked
     *    (Needs attention) so a stale edit never overwrites newer data,
     *  - otherwise PATCH the descriptive fields; on success the row is removed
     *    and [onSynced] fires with the server pin so the caller reconciles,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt payload) or attempt cap
     *    hit -> blocked so it never loops forever.
     *
     * Caller is responsible for only invoking this when online and a session
     * token exists.
     */
    suspend fun replayAll(onSynced: (Pin) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PIN_EDIT &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    // Unreplayable payload — block it so it can't loop.
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved edit.")
                    continue
                }
                try {
                    // Stale-guard: read the live row and block if the server
                    // changed while we were offline.
                    val server = pinRepo.fetchPin(payload.pinId)
                    if (server == null) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "This pin no longer exists.")
                        continue
                    }
                    if (isServerNewer(server.clientUpdatedAt, payload.baseClientUpdatedAt)) {
                        pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "This pin was changed elsewhere. Open it to review.",
                        )
                        continue
                    }
                    val pin = pinRepo.updatePinFields(
                        id = payload.pinId,
                        title = payload.title,
                        category = payload.category,
                        mode = payload.mode,
                        notes = payload.notes,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(pin)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The edit was rejected (${e.code}).",
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

    /**
     * True when the server's last client edit stamp is strictly newer than the
     * base the queued edit was made from (i.e. someone changed the pin while we
     * were offline). A null on either side can't prove a conflict, so the edit
     * is allowed through (last-write-wins for an un-stamped pin).
     */
    private fun isServerNewer(serverClientUpdatedAt: String?, base: String?): Boolean {
        val server = parseInstant(serverClientUpdatedAt) ?: return false
        val baseInstant = parseInstant(base) ?: return false
        return server.isAfter(baseInstant)
    }

    /** Tolerant ISO-8601 parse for both `...Z` and `...+00:00` timestamp shapes. */
    private fun parseInstant(value: String?): java.time.Instant? {
        if (value.isNullOrBlank()) return null
        return runCatching { OffsetDateTime.parse(value).toInstant() }
            .recoverCatching { java.time.Instant.parse(value) }
            .getOrNull()
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
