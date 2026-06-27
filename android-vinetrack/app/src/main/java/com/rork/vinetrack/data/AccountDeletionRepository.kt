package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** A vineyard owned by the current user, as reported by the deletion preflight. */
@Serializable
data class OwnedVineyard(
    @SerialName("vineyard_id") val vineyardId: String = "",
    @SerialName("vineyard_name") val vineyardName: String = "",
    @SerialName("other_active_members") val otherActiveMembers: Int = 0,
    @SerialName("transfer_required") val transferRequired: Boolean = false,
)

/** Result of `account_deletion_preflight`. */
@Serializable
data class AccountDeletionPreflight(
    @SerialName("owned_vineyards") val ownedVineyards: List<OwnedVineyard> = emptyList(),
    @SerialName("blocker_count") val blockerCount: Int = 0,
    @SerialName("safe_to_delete") val safeToDelete: Boolean = false,
)

/** Result of `submit_account_deletion_request`. */
@Serializable
data class AccountDeletionRequestResult(
    val submitted: Boolean = false,
    @SerialName("blocker_count") val blockerCount: Int? = null,
    val message: String? = null,
    @SerialName("request_id") val requestId: String? = null,
)

/**
 * Account-deletion flow, mirroring the iOS `SupabaseVineyardRepository`
 * preflight + request methods. Backed by the `account_deletion_preflight` /
 * `submit_account_deletion_request` RPCs (sql/016_ownership_safety.sql).
 */
class AccountDeletionRepository(private val session: SessionStore) {

    @Serializable
    private data class SubmitArgs(@SerialName("p_reason") val reason: String?)

    suspend fun preflight(): AccountDeletionPreflight = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("account_deletion_preflight")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
        }
        decode(response)
    }

    suspend fun submitRequest(reason: String? = null): AccountDeletionRequestResult =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("submit_account_deletion_request")
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(SubmitArgs(reason))
            }
            decode(response)
        }

    private suspend inline fun <reified T> decode(response: HttpResponse): T = when {
        response.status.isSuccess() -> response.body()
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
