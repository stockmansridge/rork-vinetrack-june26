package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AdminEngagementSummary
import com.rork.vinetrack.data.model.AdminInvitationRow
import com.rork.vinetrack.data.model.AdminPinRow
import com.rork.vinetrack.data.model.AdminPlatformScale
import com.rork.vinetrack.data.model.AdminSprayRow
import com.rork.vinetrack.data.model.AdminUserRow
import com.rork.vinetrack.data.model.AdminUserVineyardRow
import com.rork.vinetrack.data.model.AdminVineyardRow
import com.rork.vinetrack.data.model.AdminWorkTaskRow
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
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Read-only platform-level Admin dashboard data, mirroring the iOS
 * `SupabaseAdminRepository`. Every method is backed by a server-enforced
 * `admin_*` RPC — non-admins receive an error from the database, so there is no
 * client-side gating here beyond an authenticated session.
 */
class AdminRepository(private val session: SessionStore) {

    private val json = SupabaseClient.json

    suspend fun fetchEngagementSummary(): AdminEngagementSummary = withContext(Dispatchers.IO) {
        val text = ensureSuccess(rpc("admin_engagement_summary", buildJsonObject {}))
        decodeList<AdminEngagementSummary>(text).firstOrNull() ?: AdminEngagementSummary()
    }

    suspend fun fetchBlocksCount(): Int = withContext(Dispatchers.IO) {
        val text = ensureSuccess(rpc("admin_blocks_count", buildJsonObject {}))
        text.trim().toIntOrNull() ?: 0
    }

    suspend fun fetchPlatformScale(): AdminPlatformScale = withContext(Dispatchers.IO) {
        val text = ensureSuccess(rpc("admin_platform_scale", buildJsonObject {}))
        decodeList<AdminPlatformScale>(text).firstOrNull() ?: AdminPlatformScale()
    }

    suspend fun fetchAllUsers(): List<AdminUserRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("admin_list_users", buildJsonObject {})))
    }

    suspend fun fetchAllVineyards(): List<AdminVineyardRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("admin_list_vineyards", buildJsonObject {})))
    }

    suspend fun fetchUserVineyards(userId: String): List<AdminUserVineyardRow> =
        withContext(Dispatchers.IO) {
            val response = rpc("admin_list_user_vineyards", buildJsonObject {
                put("p_user_id", userId)
            })
            decodeList(ensureSuccess(response))
        }

    suspend fun fetchInvitations(): List<AdminInvitationRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("admin_list_invitations", buildJsonObject {})))
    }

    suspend fun fetchPins(limit: Int = 500): List<AdminPinRow> = withContext(Dispatchers.IO) {
        val response = rpc("admin_list_pins", buildJsonObject { put("p_limit", limit) })
        decodeList(ensureSuccess(response))
    }

    suspend fun fetchSprayRecords(limit: Int = 500): List<AdminSprayRow> =
        withContext(Dispatchers.IO) {
            val response = rpc("admin_list_spray_records", buildJsonObject { put("p_limit", limit) })
            decodeList(ensureSuccess(response))
        }

    suspend fun fetchWorkTasks(limit: Int = 500): List<AdminWorkTaskRow> =
        withContext(Dispatchers.IO) {
            val response = rpc("admin_list_work_tasks", buildJsonObject { put("p_limit", limit) })
            decodeList(ensureSuccess(response))
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

/** Raised when the server rejects an admin RPC because the caller is not a system admin. */
object AdminAccessError : Exception("System admin access required.")
