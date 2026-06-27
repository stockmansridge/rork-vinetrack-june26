package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTaskPaddock
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
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
 * Read/write path for work-task -> paddock join rows, mirroring the iOS
 * `SupabaseWorkTaskPaddockSyncRepository` contract: the `work_task_paddocks`
 * table (sql/051) + `soft_delete_work_task_paddock` RPC.
 *
 * A single work task can span multiple paddocks. Each active join row is one
 * (work_task_id, paddock_id) pair; the unique partial index keeps at most one
 * active row per pair so a re-add after delete is conflict-free. Insert is an
 * upsert keyed on `id` (merge-duplicates) so a retried create is idempotent and
 * an unchanged area re-inserts cleanly. Soft-delete goes through the RPC, which
 * RLS-restricts to owner/manager/supervisor; standard membership RLS gates
 * insert. Online-first; offline replay lives in [WorkTaskPaddockSync].
 */
class WorkTaskPaddockRepository(private val session: SessionStore) {

    @Serializable
    private data class JoinUpsert(
        val id: String,
        @SerialName("work_task_id") val workTaskId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("area_ha") val areaHa: Double? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_by") val updatedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    /** Stable client-generated id for a new join row, minted before the network call. */
    fun newId(): String = UUID.randomUUID().toString()

    /** All active (non-deleted) join rows for a vineyard. */
    suspend fun listForVineyard(vineyardId: String): List<WorkTaskPaddock> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "work_task_paddocks?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Insert (upsert by id) a join row. Idempotent — a retried create or an
     * unchanged-area re-save merges into the same row. [clientUpdatedAt] defaults
     * to now for the online path; offline replay passes the original save moment.
     */
    suspend fun insert(
        id: String,
        workTaskId: String,
        vineyardId: String,
        paddockId: String,
        areaHa: Double?,
        clientUpdatedAt: String? = null,
    ): WorkTaskPaddock = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = JoinUpsert(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            paddockId = paddockId,
            areaHa = areaHa,
            createdBy = session.userId,
            updatedBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("work_task_paddocks?on_conflict=id"),
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() ->
                response.body<List<WorkTaskPaddock>>().firstOrNull()
                    ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Soft-delete a join row via the RLS-restricted RPC (owner/manager/supervisor). */
    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("soft_delete_work_task_paddock"),
        ) {
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
