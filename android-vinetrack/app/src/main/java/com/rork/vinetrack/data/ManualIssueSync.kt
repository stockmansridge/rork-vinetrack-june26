package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ManualIssue
import com.rork.vinetrack.data.model.ManualIssueCreateParams
import com.rork.vinetrack.data.model.ManualIssueUpdateParams
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import java.time.Instant
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for Manual Issues (sql/169), mirroring the iOS
 * `ManualIssueSyncService` outbox.
 *
 * Every queued write replays through the server-authoritative RPCs:
 *  - CREATE is idempotent by the client-generated issue id — a duplicate
 *    replay returns the existing issue instead of creating a second one,
 *  - UPDATE / STATUS are last-write-wins on `client_updated_at`, so a stale
 *    replay can never clobber a newer edit made elsewhere,
 *  - CANCEL / DELETE resolve on the existing soft-delete/cancel path.
 *
 * Replay ordering is create → update → status → cancel → delete so a
 * dependent write never targets a not-yet-created issue.
 */
class ManualIssueSync(
    private val repo: ManualIssueRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    /** Envelope stored as the outbox payload — carries exactly one op kind. */
    @Serializable
    data class QueuedOp(
        val kind: String,
        @SerialName("create_params") val createParams: ManualIssueCreateParams? = null,
        @SerialName("update_params") val updateParams: ManualIssueUpdateParams? = null,
        val status: String? = null,
    ) {
        companion object {
            const val KIND_CREATE = "create"
            const val KIND_UPDATE = "update"
            const val KIND_STATUS = "status"
            const val KIND_CANCEL = "cancel"
            const val KIND_DELETE = "delete"

            /** Creates must land before dependent edits/status changes. */
            fun replayOrder(kind: String): Int = when (kind) {
                KIND_CREATE -> 0
                KIND_UPDATE -> 1
                KIND_STATUS -> 2
                KIND_CANCEL -> 3
                KIND_DELETE -> 4
                else -> 5
            }
        }
    }

    fun enqueueCreate(params: ManualIssueCreateParams): PendingWrite =
        enqueue(params.id, PendingOpType.CREATE, QueuedOp(QueuedOp.KIND_CREATE, createParams = params))

    fun enqueueUpdate(params: ManualIssueUpdateParams): PendingWrite {
        // Coalesce: the latest queued edit for an issue wins.
        removeQueued(params.id, QueuedOp.KIND_UPDATE)
        return enqueue(params.id, PendingOpType.UPDATE, QueuedOp(QueuedOp.KIND_UPDATE, updateParams = params))
    }

    fun enqueueStatus(issueId: String, status: String): PendingWrite {
        removeQueued(issueId, QueuedOp.KIND_STATUS)
        return enqueue(issueId, PendingOpType.UPDATE, QueuedOp(QueuedOp.KIND_STATUS, status = status))
    }

    fun enqueueCancel(issueId: String): PendingWrite =
        enqueue(issueId, PendingOpType.UPDATE, QueuedOp(QueuedOp.KIND_CANCEL))

    fun enqueueDelete(issueId: String): PendingWrite =
        enqueue(issueId, PendingOpType.DELETE, QueuedOp(QueuedOp.KIND_DELETE))

    /** True when the issue still has an unresolved queued write. */
    fun isPending(issueId: String): Boolean = pending.list().any {
        it.entityType == PendingEntityType.MANUAL_ISSUE &&
            it.clientId == issueId &&
            it.status in PendingWriteStatus.unresolved
    }

    fun pendingCount(): Int = pending.list().count {
        it.entityType == PendingEntityType.MANUAL_ISSUE && it.status in PendingWriteStatus.unresolved
    }

    /**
     * Replay every retry-eligible queued manual-issue write in dependency
     * order. [onSynced] fires with the canonical server issue after each
     * successful create/update/status/cancel; [onDeleted] after a delete.
     * Stops early on a transient failure (still offline) so the queue isn't
     * hammered.
     */
    suspend fun replayAll(onSynced: (ManualIssue) -> Unit, onDeleted: (String) -> Unit,
        permittedWrites: Map<String, PendingWrite>? = null) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list()
                .filter {
                    it.entityType == PendingEntityType.MANUAL_ISSUE &&
                        (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
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
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved issue.")
                    continue
                }
                try {
                    when (op.kind) {
                        QueuedOp.KIND_CREATE -> {
                            val params = op.createParams ?: error("missing create params")
                            val result = repo.create(params)
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write) && !isPending(write.clientId)) onSynced(result)
                        }
                        QueuedOp.KIND_UPDATE -> {
                            val params = op.updateParams ?: error("missing update params")
                            val result = repo.update(params)
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write) && !isPending(write.clientId)) onSynced(result)
                        }
                        QueuedOp.KIND_STATUS -> {
                            val status = op.status ?: error("missing status")
                            val result = repo.setStatus(write.clientId, status, Instant.ofEpochMilli(write.createdAt).toString())
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write) && !isPending(write.clientId)) onSynced(result)
                        }
                        QueuedOp.KIND_CANCEL -> {
                            val result = repo.deleteOrCancel(write.clientId, "cancel")
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write) && !isPending(write.clientId)) onSynced(result)
                        }
                        QueuedOp.KIND_DELETE -> {
                            repo.deleteOrCancel(write.clientId, "delete")
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            if (pending.removeIfCurrent(write) && !isPending(write.clientId)) onDeleted(write.clientId)
                        }
                        else -> error("unknown op kind ${op.kind}")
                    }
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this issue.")
                } catch (e: BackendError.Server) {
                    when {
                        // Permanent rejection (validation/permission) — a retry
                        // can never succeed, so block it with the reason.
                        e.code in 400..499 -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The issue was rejected (${e.code}).",
                        )
                        else -> retryOrBlock(write, "Server error (${e.code}).")
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Issue sync was interrupted. Ready to retry.")
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

    private fun enqueue(issueId: String, opType: String, op: QueuedOp): PendingWrite =
        pending.enqueue(
            entityType = PendingEntityType.MANUAL_ISSUE,
            opType = opType,
            payloadJson = json.encodeToString(QueuedOp.serializer(), op),
            clientId = issueId,
        )

    private fun removeQueued(issueId: String, kind: String) {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.MANUAL_ISSUE &&
                    it.clientId == issueId &&
                    it.status in PendingWriteStatus.unresolved &&
                    decode(it)?.kind == kind
            }
            .forEach { pending.remove(it.id) }
    }

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
