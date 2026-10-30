package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable
enum class TaskWritePhase { UNSENT, DISPATCHED, CONFIRMED, REJECTED, UNKNOWN }
@Serializable
enum class TaskWriteStage { VALIDATION, INTENT_PERSISTENCE, SESSION, MEMBERSHIP, ASSIGNMENT, TRANSPORT, SERVER_REJECTION, ACKNOWLEDGEMENT, LOCAL_PERSISTENCE, SERVER_REVIEW, BLOCK_ALLOCATION, CLEANUP }

/** Sidecar: old intent bytes and 3.1.8 task records need no migration. Missing sidecar means UNKNOWN. */
@Serializable
data class TaskWriteRecovery(
    val original: WorkTaskWriteIntent,
    val phase: TaskWritePhase = TaskWritePhase.UNKNOWN,
    val stage: TaskWriteStage = TaskWriteStage.SERVER_REVIEW,
    val status: Int? = null,
    val code: String? = null,
    val detail: String? = null,
    val confirmed: WorkTask? = null,
    val followUpComplete: Boolean = false,
)

class TaskWriteFailure(
    val stage: TaskWriteStage,
    val phase: TaskWritePhase,
    val status: Int? = null,
    val code: String? = null,
    cause: Throwable? = null,
    val savedTask: WorkTask? = null,
) : IllegalStateException("Work task $stage (${phase.name})", cause) {
    val userMessage: String get() = when {
        savedTask != null || phase == TaskWritePhase.CONFIRMED -> "Task saved online. A remaining device or block-allocation step needs attention. Choose Check saved task to continue without saving it again."
        stage == TaskWriteStage.SESSION || status == 401 -> "Sign in again with the original account, then check this saved request. Your draft is retained."
        code == "VERSION_CONFLICT" -> "The server task differs from this request. Nothing was overwritten. Keep this draft and ask your manager to review the task."
        code == "ABSENCE_OR_ACCESS_UNVERIFIED" -> "The task is not visible to this account. Its save outcome cannot be verified. Ask your vineyard manager to review access and this request; do not create a replacement."
        phase == TaskWritePhase.UNSENT -> "The task request was not sent. Check your connection, assignment and vineyard access, then choose Retry original request. Your original draft is retained."
        phase == TaskWritePhase.REJECTED -> "The server rejected the save. Check vineyard access and the selected assignment, then check the saved request. Your draft is retained."
        else -> "The save response could not be confirmed. Choose Check saved task before continuing. Your original request is retained."
    }
    fun diagnostic(): String = "stage=$stage phase=$phase http=${status ?: "none"} code=${code ?: "none"} error=" +
        generateSequence(cause) { it.cause }.take(8).joinToString(" <- ") {
            "${it.javaClass.simpleName}: ${it.message.orEmpty()}" +
                (if (it is BackendError.Server) " response=${it.body.take(4096)}" else "")
        }
}

/** Exact payload + preserved header/version proof. An invisible row is never an absence receipt. */
object WorkTaskRecoveryProof {
    fun verify(intent: WorkTaskWriteIntent, row: JsonObject): WorkTask {
        check(WorkTaskWriteContract.equivalent(JsonPrimitive(intent.taskId), row["id"], "id") &&
            WorkTaskWriteContract.equivalent(JsonPrimitive(intent.vineyardId), row["vineyard_id"], "vineyard_id"))
        WorkTaskWriteContract.verify(intent.baselineJson?.let { Json.parseToJsonElement(it).jsonObject }, intent.payload, row, WorkTaskPlanningRepository.observedKeys)
        check(row["deleted_at"] == JsonNull)
        return Json { ignoreUnknownKeys = true }.decodeFromJsonElement(row)
    }
}
