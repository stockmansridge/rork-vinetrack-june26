package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for plan-originated spray-job CREATE only
 * (sql/201, Stage 5B).
 *
 * The manager created a Spray Job from a Resistance Plan position offline (or
 * a transient online insert failed) and the optimistic row is already showing
 * in the planner. This replays the additive insert
 * ([SprayJobPlanRepository.createJob]) — job row plus its proposed paddock
 * links — and nothing else. The plan provenance (plan id, position id,
 * VERBATIM frozen snapshot, source revision) rides INSIDE the queued create,
 * never a follow-up patch, so the linkage survives any sync ordering: the
 * server accepts a link whose plan hasn't landed yet and resolves it when the
 * plan arrives (sql/201 pending-plan contract).
 *
 * Discriminator: [PendingEntityType.SPRAY_JOB] / CREATE, keyed by the
 * client-minted job id, so no other queue can pick up a job write.
 *
 * Idempotency: the client mints the job UUID up front; a duplicate insert on
 * retry surfaces as 409 which [SprayJobPlanRepository.createJob] already
 * treats as success, so a retried replay can never create a second job.
 *
 * Replay ordering: run BEFORE [SprayRecordCreateSync] in every replay
 * pipeline. A queued spray RECORD may carry `spray_job_id` referencing a
 * queued JOB, and sql/033 requires the job row to exist — the job must land
 * first.
 */
class SprayJobCreateSync(
    private val jobRepo: SprayJobPlanRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full replay payload: the insert plus its proposed paddock links. */
    @Serializable
    data class Payload(
        val insert: PlanSprayJobInsert,
        val paddockIds: List<String> = emptyList(),
    )

    /**
     * Queue (or replace) a job create for later replay. Coalesces by job id so
     * only one marker per job is ever replayed.
     */
    fun enqueue(insert: PlanSprayJobInsert, paddockIds: List<String>): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.SPRAY_JOB &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == insert.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(insert = insert, paddockIds = paddockIds)
        return pending.enqueue(
            entityType = PendingEntityType.SPRAY_JOB,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = insert.id,
        )
    }

    /**
     * Unresolved queued creates, decoded — used to overlay optimistic job rows
     * onto fetched lists so an offline-created job never vanishes.
     */
    fun pendingPayloads(): List<Payload> =
        pending.list()
            .filter {
                it.entityType == PendingEntityType.SPRAY_JOB &&
                    it.opType == PendingOpType.CREATE &&
                    it.status in PendingWriteStatus.unresolved
            }
            .mapNotNull { write ->
                runCatching { json.decodeFromString(Payload.serializer(), write.payloadJson) }.getOrNull()
            }

    /**
     * Replay every retry-eligible queued job create. Success or duplicate
     * removes the marker; transient failures retry (bounded); permanent
     * rejections block so they never loop. Caller must only invoke when online
     * with a session token.
     */
    suspend fun replayAll(onSynced: (PlanSprayJobInsert) -> Unit = {}) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.SPRAY_JOB &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved spray job.")
                    continue
                }
                try {
                    jobRepo.createJob(payload.insert, payload.paddockIds)
                    pending.remove(write.id)
                    onSynced(payload.insert)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this spray job.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The spray job was rejected (${e.code}).",
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
