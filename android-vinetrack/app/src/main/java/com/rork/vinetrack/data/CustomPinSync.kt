package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CustomPinCreateParams
import com.rork.vinetrack.data.model.CustomPinType
import com.rork.vinetrack.data.model.CustomPinTypeCreateParams
import com.rork.vinetrack.data.model.ManualIssue
import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for the unified pin composer (sql/170):
 * vineyard custom pin type creates, Custom pin creates, and the row-segment
 * persistence for Repair/Growth pins saved with a ROW location.
 *
 * Replay ordering inside one flush is type -> custom pin -> segments, so a
 * pin referencing an offline-created custom type never replays before its
 * catalogue row, and a segments write never replays before its pin insert
 * (the pin create rides the existing [PinCreateSync] outbox, which the
 * ViewModel replays first).
 *
 * Idempotency: both creates are keyed by stable client-generated UUIDs — a
 * retried type create converges server-side (same id, or same trimmed
 * case-insensitive active name), and a retried pin create returns the
 * existing canonical row. Segments replace atomically, so a replay is safe.
 */
class CustomPinSync(
    private val repo: CustomPinTypeRepository,
    private val pinRepo: PinRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    /** Envelope stored as the outbox payload — carries exactly one op kind. */
    @Serializable
    data class QueuedOp(
        val kind: String,
        @SerialName("type_params") val typeParams: CustomPinTypeCreateParams? = null,
        @SerialName("pin_params") val pinParams: CustomPinCreateParams? = null,
        @SerialName("pin_id") val pinId: String? = null,
        val segments: List<ManualIssueSegment>? = null,
    ) {
        companion object {
            const val KIND_TYPE_CREATE = "type_create"
            const val KIND_PIN_CREATE = "pin_create"
            const val KIND_SEGMENTS = "segments"

            /** A referenced custom type must land before its pin; segments last. */
            fun replayOrder(kind: String): Int = when (kind) {
                KIND_TYPE_CREATE -> 0
                KIND_PIN_CREATE -> 1
                KIND_SEGMENTS -> 2
                else -> 3
            }
        }
    }

    fun enqueueTypeCreate(params: CustomPinTypeCreateParams): PendingWrite =
        enqueue(params.id, PendingOpType.CREATE, QueuedOp(QueuedOp.KIND_TYPE_CREATE, typeParams = params))

    fun enqueuePinCreate(params: CustomPinCreateParams): PendingWrite =
        enqueue(params.id, PendingOpType.CREATE, QueuedOp(QueuedOp.KIND_PIN_CREATE, pinParams = params))

    /** Queue the ROW-scope segment write for a Repair/Growth pin. */
    fun enqueueSegments(pinId: String, segments: List<ManualIssueSegment>): PendingWrite =
        enqueue(pinId, PendingOpType.UPDATE, QueuedOp(QueuedOp.KIND_SEGMENTS, pinId = pinId, segments = segments))

    /**
     * Replay every retry-eligible queued composer write in dependency order.
     * [onTypeSynced] / [onPinSynced] fire with the canonical server rows so
     * the ViewModel can reconcile optimistic state. Stops early on a
     * transient failure (still offline) so the queue isn't hammered.
     */
    suspend fun replayAll(
        permittedWriteIds: Set<String>? = null,
        permittedWrites: Map<String, PendingWrite>? = null,
        onTypeSynced: (CustomPinType) -> Unit,
        onPinSynced: (ManualIssue) -> Unit,
    ) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list()
                .filter {
                    it.entityType == PendingEntityType.CUSTOM_PIN &&
                        (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
                        (permittedWriteIds == null || it.id in permittedWriteIds) &&
                        (permittedWrites == null || permittedWrites[it.id] == it)
                }
                .sortedWith(
                    compareBy(
                        { write -> decode(write)?.kind?.let { QueuedOp.replayOrder(it) } ?: 9 },
                        { it.createdAt },
                    ),
                )
            for (candidate in candidates) {
                val write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val op = decode(write)
                if (op == null) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved item.")
                    continue
                }
                try {
                    when (op.kind) {
                        QueuedOp.KIND_TYPE_CREATE -> {
                            val params = op.typeParams ?: error("missing type params")
                            val result = repo.createType(params)
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write)) onTypeSynced(result)
                        }
                        QueuedOp.KIND_PIN_CREATE -> {
                            val params = op.pinParams ?: error("missing pin params")
                            val result = repo.createCustomPin(params)
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write)) onPinSynced(result)
                        }
                        QueuedOp.KIND_SEGMENTS -> {
                            val pinId = op.pinId ?: error("missing pin id")
                            pinRepo.setRowSegments(pinId, op.segments.orEmpty())
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            pending.removeIfCurrent(write)
                        }
                        else -> error("unknown op kind ${op.kind}")
                    }
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this item.")
                } catch (e: BackendError.Server) {
                    val retryablePinMissing =
                        op.kind == QueuedOp.KIND_SEGMENTS && e.message?.contains("PIN_NOT_FOUND") == true
                    when {
                        // The parent pin insert hasn't replayed/landed yet —
                        // retry after the pin outbox flushes.
                        retryablePinMissing -> retryOrBlock(write, "Waiting for the pin to sync.")
                        e.code in 400..499 -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The item was rejected (${e.code}).",
                        )
                        else -> retryOrBlock(write, "Server error (${e.code}).")
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Custom pin sync was interrupted. Ready to retry.")
                    throw e
                } catch (e: Exception) {
                    // Still offline / transient — leave for next time and stop.
                    retryOrBlock(write, e.message ?: "No connection.")
                    break
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    private fun enqueue(clientId: String, opType: String, op: QueuedOp): PendingWrite =
        pending.enqueue(
            entityType = PendingEntityType.CUSTOM_PIN,
            opType = opType,
            payloadJson = json.encodeToString(QueuedOp.serializer(), op),
            clientId = clientId,
        )

    private fun decode(write: PendingWrite): QueuedOp? = runCatching {
        json.decodeFromString(QueuedOp.serializer(), write.payloadJson)
    }.getOrNull()

    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    private companion object {
        const val MAX_ATTEMPTS = 8
    }
}
