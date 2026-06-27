package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTask
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Write path for work tasks, mirroring the iOS work-task sync contract
 * (`work_tasks` table + `soft_delete_work_task` RPC). RLS scopes everything to
 * the signed-in user's vineyard role: owner/manager/supervisor/operator may
 * insert and update; only owner/manager/supervisor may soft-delete.
 *
 * Online-first — there is no local queue yet. Every mutation sends only the
 * columns Android edits, leaving the iOS-managed `resources` JSONB and the
 * Phase-16 costing fields (start_date, end_date, area_ha, description, …)
 * intact.
 */
class WorkTaskRepository(private val session: SessionStore) {

    /** Insert payload when logging a new work task. */
    @Serializable
    data class WorkTaskInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String,
        val date: String,
        @SerialName("task_type") val taskType: String,
        @SerialName("duration_hours") val durationHours: Double,
        val notes: String,
        @SerialName("is_finalized") val isFinalized: Boolean = false,
        @SerialName("finalized_at") val finalizedAt: String? = null,
        @SerialName("finalized_by") val finalizedBy: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Metadata edit without disturbing the iOS-managed JSONB / costing fields. */
    @Serializable
    private data class WorkTaskMetadataPatch(
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String,
        val date: String,
        @SerialName("task_type") val taskType: String,
        @SerialName("duration_hours") val durationHours: Double,
        val notes: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Combined metadata + finalize patch used by the offline UPDATE replay
     * ([WorkTaskUpdateSync]). A coalesced offline marker can carry both a
     * metadata edit and a finalize/reopen flip, so replay applies them in one
     * PATCH. `created_by` and the iOS-managed JSONB / costing fields are never
     * sent, so they stay intact.
     */
    @Serializable
    private data class WorkTaskHeaderPatch(
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("paddock_name") val paddockName: String,
        val date: String,
        @SerialName("task_type") val taskType: String,
        @SerialName("duration_hours") val durationHours: Double,
        val notes: String,
        @SerialName("is_finalized") val isFinalized: Boolean,
        @SerialName("finalized_at") val finalizedAt: String? = null,
        @SerialName("finalized_by") val finalizedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Complete / reopen patch — toggles the iOS `is_finalized` convention. */
    @Serializable
    private data class WorkTaskFinalizePatch(
        @SerialName("is_finalized") val isFinalized: Boolean,
        @SerialName("finalized_at") val finalizedAt: String? = null,
        @SerialName("finalized_by") val finalizedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    /** Mint a stable client-side work-task id (used for optimistic rows + offline replay). */
    fun newId(): String = UUID.randomUUID().toString()

    /**
     * Insert a work task. By default (online, live create) the id and
     * client_updated_at are minted here. The optional [id] / [clientUpdatedAt]
     * let the offline create queue ([WorkTaskCreateSync]) replay the original
     * insert with the same client-generated id (idempotency key) and the moment
     * the operator actually saved it. `created_by` always resolves from the live
     * session, never from a frozen payload.
     */
    suspend fun createWorkTask(
        vineyardId: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        id: String? = null,
        clientUpdatedAt: String? = null,
        isFinalized: Boolean = false,
    ): WorkTask = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val stamp = clientUpdatedAt ?: nowIso()
        val body = WorkTaskInsert(
            id = id ?: UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName ?: "",
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes ?: "",
            isFinalized = isFinalized,
            finalizedAt = if (isFinalized) stamp else null,
            finalizedBy = if (isFinalized) session.userId else null,
            createdBy = session.userId,
            clientUpdatedAt = stamp,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("work_tasks")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    suspend fun updateMetadata(
        id: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        clientUpdatedAt: String? = null,
    ): WorkTask = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = WorkTaskMetadataPatch(
            paddockId = paddockId,
            paddockName = paddockName ?: "",
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes ?: "",
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        patchTask(id, patch, token)
    }

    /** Mark complete (finalize) or reopen a work task. */
    suspend fun setFinalized(
        id: String,
        finalized: Boolean,
        clientUpdatedAt: String? = null,
    ): WorkTask = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val stamp = clientUpdatedAt ?: nowIso()
        val patch = WorkTaskFinalizePatch(
            isFinalized = finalized,
            finalizedAt = if (finalized) stamp else null,
            finalizedBy = if (finalized) session.userId else null,
            clientUpdatedAt = stamp,
        )
        patchTask(id, patch, token)
    }

    /**
     * Replay a coalesced offline header UPDATE marker ([WorkTaskUpdateSync]):
     * applies the latest metadata and finalize/reopen state in a single PATCH
     * using the operator's original [clientUpdatedAt]. `created_by` and the
     * iOS-managed JSONB / costing fields are never sent, so they stay intact.
     */
    suspend fun applyHeaderUpdate(
        id: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        isFinalized: Boolean,
        finalizedAt: String?,
        finalizedBy: String?,
        clientUpdatedAt: String,
    ): WorkTask = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = WorkTaskHeaderPatch(
            paddockId = paddockId,
            paddockName = paddockName ?: "",
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes ?: "",
            isFinalized = isFinalized,
            finalizedAt = finalizedAt,
            finalizedBy = finalizedBy,
            clientUpdatedAt = clientUpdatedAt,
        )
        patchTask(id, patch, token)
    }

    suspend fun softDeleteWorkTask(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_work_task")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend inline fun <reified T> patchTask(
        id: String,
        patch: T,
        token: String,
    ): WorkTask {
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("work_tasks?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        return firstRow(response)
    }

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): WorkTask = when {
        response.status.isSuccess() -> response.body<List<WorkTask>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
