package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SystemAdminUserRow
import com.rork.vinetrack.data.model.SystemFeatureFlagRow
import com.rork.vinetrack.data.model.UserLoginActivityRow
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
 * Platform System Admin status, shared feature flags, admin-registry management
 * and user login activity — mirroring the iOS `SupabaseSystemAdminRepository`.
 *
 * Source of truth lives in Supabase (`system_admins`, `system_feature_flags`).
 * Owner/manager vineyard roles do NOT grant access; only active `system_admins`
 * rows may edit flags or manage the registry. Anyone authenticated may *read*
 * the flags so diagnostic surfaces can be toggled remotely.
 */
class SystemAdminRepository(private val session: SessionStore) {

    private val json = SupabaseClient.json

    /** `is_system_admin()` — true when the signed-in user is an active platform admin. */
    suspend fun isSystemAdmin(): Boolean = withContext(Dispatchers.IO) {
        val text = ensureSuccess(rpc("is_system_admin", buildJsonObject {}))
        text.trim().equals("true", ignoreCase = true)
    }

    suspend fun fetchFlags(): List<SystemFeatureFlagRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("get_system_feature_flags", buildJsonObject {})))
    }

    suspend fun setFlag(key: String, isEnabled: Boolean) = withContext(Dispatchers.IO) {
        ensureSuccess(rpc("set_system_feature_flag", buildJsonObject {
            put("p_key", key)
            put("p_is_enabled", isEnabled)
        }))
        Unit
    }

    // MARK: - System admin registry

    suspend fun listSystemAdmins(): List<SystemAdminUserRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("list_system_admins", buildJsonObject {})))
    }

    suspend fun addSystemAdmin(email: String): SystemAdminUserRow? = withContext(Dispatchers.IO) {
        val response = rpc("add_system_admin", buildJsonObject { put("p_email", email) })
        decodeList<SystemAdminUserRow>(ensureSuccess(response)).firstOrNull()
    }

    suspend fun setSystemAdminActive(userId: String, isActive: Boolean): SystemAdminUserRow? =
        withContext(Dispatchers.IO) {
            val response = rpc("set_system_admin_active", buildJsonObject {
                put("p_user_id", userId)
                put("p_is_active", isActive)
            })
            decodeList<SystemAdminUserRow>(ensureSuccess(response)).firstOrNull()
        }

    // MARK: - User login / activity

    suspend fun listUserLoginActivity(): List<UserLoginActivityRow> = withContext(Dispatchers.IO) {
        decodeList(ensureSuccess(rpc("admin_list_user_login_activity", buildJsonObject {})))
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
