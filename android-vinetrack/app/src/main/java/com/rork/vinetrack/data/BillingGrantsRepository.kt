package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ManualUnlimitedGrant
import io.ktor.client.request.HttpRequestBuilder
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * System-admin-only access to manual / internal unlimited licensing grants,
 * mirroring the iOS `SupabaseBillingGrantsRepository`. All RPCs enforce
 * `public.is_system_admin()` server-side; this is a thin transport layer. No
 * Stripe / Apple / RevenueCat involvement.
 */
class BillingGrantsRepository(private val session: SessionStore) {

    private val json = SupabaseClient.json

    /** All current and historical manual unlimited grants. */
    suspend fun listGrants(): List<ManualUnlimitedGrant> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("admin_list_manual_unlimited_grants", buildJsonObject {})))
    }

    /** Grant or reactivate unlimited access for an owner. Returns the subscription id. */
    suspend fun grantUnlimited(
        ownerUserId: String,
        vineyardId: String?,
        reason: String?,
        expiresAt: String?,
    ): String = withContext(Dispatchers.IO) {
        val trimmedReason = reason?.trim()?.takeIf { it.isNotEmpty() }
        val params = buildJsonObject {
            put("p_owner_user_id", ownerUserId)
            if (vineyardId != null) put("p_vineyard_id", vineyardId) else put("p_vineyard_id", JsonNull)
            if (trimmedReason != null) put("p_reason", trimmedReason) else put("p_reason", JsonNull)
            if (expiresAt != null) put("p_expires_at", expiresAt) else put("p_expires_at", JsonNull)
        }
        ensureSuccess(rpc("admin_grant_unlimited_access", params)).trim().trim('"')
    }

    /** Revoke an existing grant by subscription id. */
    suspend fun revokeUnlimited(
        subscriptionId: String,
        revokeLicences: Boolean = true,
    ): String = withContext(Dispatchers.IO) {
        val params = buildJsonObject {
            put("p_subscription_id", subscriptionId)
            put("p_revoke_licences", revokeLicences)
        }
        ensureSuccess(rpc("admin_revoke_unlimited_access", params)).trim().trim('"')
    }

    // MARK: - Plumbing

    private suspend fun rpc(name: String, params: JsonObject): HttpResponse {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        return SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(params)
        }
    }

    private inline fun <reified T> decodeList(text: String): List<T> {
        if (text.isBlank()) return emptyList()
        return json.decodeFromString(text)
    }

    private suspend fun ensureSuccess(response: HttpResponse): String = when {
        response.status.isSuccess() -> response.bodyAsText()
        response.status.value == 401 -> throw BackendError.Unauthorized
        response.status.value == 403 -> throw AdminAccessError
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
