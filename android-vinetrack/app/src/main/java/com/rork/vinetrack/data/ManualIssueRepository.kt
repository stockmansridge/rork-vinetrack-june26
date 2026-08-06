package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ManualIssue
import com.rork.vinetrack.data.model.ManualIssueCreateParams
import com.rork.vinetrack.data.model.ManualIssueUpdateParams
import io.ktor.client.call.body
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

/**
 * Server-authoritative access to the sql/169 manual-issue RPCs, mirroring the
 * iOS `ManualIssueRepository`. Every write (create / update / status / cancel
 * / delete) goes through an RPC so the database — not Kotlin — enforces
 * permissions, validation, and the no-labour/no-Work-Task contract.
 *
 * Idempotency: `create_manual_issue` is keyed by the client-generated issue
 * id (a replay returns the existing canonical issue); update/status carry a
 * `client_updated_at` stamp for server-side last-write-wins.
 */
class ManualIssueRepository(private val session: SessionStore) {

    @Serializable
    private data class GetArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class ListArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_statuses") val statuses: List<String>? = null,
        @SerialName("p_paddock_id") val paddockId: String? = null,
        @SerialName("p_include_deleted") val includeDeleted: Boolean = false,
    )

    @Serializable
    private data class StatusArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_status") val status: String,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class DeleteArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_action") val action: String,
    )

    suspend fun create(params: ManualIssueCreateParams): ManualIssue =
        rpc("create_manual_issue", params)

    suspend fun update(params: ManualIssueUpdateParams): ManualIssue =
        rpc("update_manual_issue", params)

    suspend fun get(id: String): ManualIssue =
        rpc("get_manual_issue", GetArgs(id))

    /** null statuses = server default (open + in_progress). */
    suspend fun list(
        vineyardId: String,
        statuses: List<String>? = null,
        paddockId: String? = null,
        includeDeleted: Boolean = false,
    ): List<ManualIssue> =
        rpc("list_manual_issues", ListArgs(vineyardId, statuses, paddockId, includeDeleted))

    suspend fun setStatus(id: String, status: String, clientUpdatedAt: String): ManualIssue =
        rpc("set_manual_issue_status", StatusArgs(id, status, clientUpdatedAt))

    /** action = "cancel" (keeps history) or "delete" (soft delete, managers). */
    suspend fun deleteOrCancel(id: String, action: String): ManualIssue =
        rpc("delete_or_cancel_manual_issue", DeleteArgs(id, action))

    private suspend inline fun <reified Body, reified Result> rpc(name: String, body: Body): Result =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            when {
                response.status.isSuccess() -> response.body<Result>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }
}
