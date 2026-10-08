package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/** Exact server values; retain timestamp precision rather than round-tripping milliseconds. */
@Serializable
data class PruningResourceSnapshot(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("client_updated_at") val clientUpdatedAt: String?,
    @SerialName("external_resource_id") val externalResourceId: String?,
    @SerialName("worker_user_id") val workerUserId: String?,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/** Durable resource intent, separate from allocation replay and never rebased on retry. */
@Serializable
data class PruningResourceLink(
    val externalResourceId: String?,
    val workerUserId: String?,
    val name: String,
    val authoredBy: String,
    val generation: String = UUID.randomUUID().toString(),
    val expected: PruningResourceSnapshot? = null,
    val conflict: PruningResourceSnapshot? = null,
    val acknowledged: Boolean = false,
    val failure: String? = null,
) {
    val isPending: Boolean get() = !acknowledged
    val message: String? get() = when {
        acknowledged -> null
        conflict != null -> "Resource conflict: another device or Portal changed this activity. Your selection is retained; review the server selection before saving again."
        else -> failure ?: "Activity saved locally. Resource selection is pending sync."
    }

    fun request(activityId: String, vineyardId: String): PruningResourceCASArgs {
        val base = requireNotNull(expected) { "Resource selection needs a verified server record." }
        require(base.id == activityId && base.vineyardId == vineyardId && base.deletedAt == null && conflict == null)
        require(externalResourceId == null || workerUserId == null)
        return PruningResourceCASArgs(activityId, externalResourceId, workerUserId,
            base.clientUpdatedAt, base.externalResourceId, base.workerUserId)
    }

    /** HTTP success alone is not acknowledgement of the captured generation. */
    fun accepting(result: PruningResourceCASResult, activityId: String): PruningResourceLink {
        require(result.activityId == activityId) { "Wrong resource acknowledgement." }
        return when {
            result.applied && result.conflict != true && result.externalResourceId == externalResourceId && result.workerUserId == workerUserId ->
                copy(acknowledged = true, failure = null)
            !result.applied && result.conflict == true && result.canonical?.id == activityId && result.canonical.vineyardId == expected?.vineyardId ->
                copy(conflict = result.canonical, failure = null)
            else -> error("Activity saved; resource selection was not acknowledged. Retry safely.")
        }
    }
}

/** Encode using explicitNulls=true: the deployed function requires every key. */
@Serializable
data class PruningResourceCASArgs(
    @SerialName("p_activity_id") val activityId: String,
    @SerialName("p_external_resource_id") val externalResourceId: String?,
    @SerialName("p_worker_user_id") val workerUserId: String?,
    @SerialName("p_expected_client_updated_at") val expectedClientUpdatedAt: String?,
    @SerialName("p_expected_external_resource_id") val expectedExternalResourceId: String?,
    @SerialName("p_expected_worker_user_id") val expectedWorkerUserId: String?,
)

@Serializable
data class PruningResourceCASResult(
    @SerialName("activity_id") val activityId: String,
    val applied: Boolean,
    @SerialName("external_resource_id") val externalResourceId: String?,
    @SerialName("worker_user_id") val workerUserId: String?,
    val conflict: Boolean? = null,
    val idempotent: Boolean? = null,
    val canonical: PruningResourceSnapshot? = null,
)
