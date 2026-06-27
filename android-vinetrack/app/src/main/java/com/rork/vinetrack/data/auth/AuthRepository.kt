package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.model.AppUser
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

class AuthRepository(private val session: SessionStore) {

    @Serializable
    private data class Credentials(val email: String, val password: String)

    @Serializable
    private data class SignUpBody(val email: String, val password: String, val data: Map<String, String>? = null)

    @Serializable
    private data class RefreshBody(@SerialName("refresh_token") val refreshToken: String)

    @Serializable
    private data class TokenResponse(
        @SerialName("access_token") val accessToken: String? = null,
        @SerialName("refresh_token") val refreshToken: String? = null,
        val user: AppUser? = null,
    )

    @Serializable
    private data class RecoveryBody(val email: String)

    @Serializable
    private data class VerifyOtpBody(val email: String, val token: String, val type: String)

    @Serializable
    private data class PasswordBody(val password: String)

    @Serializable
    private data class UpdateUserBody(val data: Map<String, String>)

    val currentUserId: String? get() = session.userId
    val currentEmail: String? get() = session.userEmail
    val currentName: String? get() = session.userName

    /**
     * Update the signed-in user's display name in Supabase auth metadata
     * (GoTrue `PUT /auth/v1/user`). Mirrors iOS `updateDisplayName`. Returns the
     * saved name on success.
     */
    suspend fun updateDisplayName(name: String): String = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val trimmed = name.trim()
        val response = SupabaseClient.http.put(SupabaseClient.authUrl("user")) {
            anonHeaders()
            headers { append(HttpHeaders.Authorization, "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(UpdateUserBody(mapOf("display_name" to trimmed, "full_name" to trimmed)))
        }
        if (!response.status.isSuccess()) throw authError(response)
        val user: AppUser = response.body()
        val saved = user.displayName ?: trimmed
        session.userName = saved
        saved
    }

    /**
     * Restore a persisted session. Returns the user if a valid session exists,
     * null if genuinely signed out, and keeps offline users signed in.
     */
    suspend fun restoreSession(): AppUser? = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val refresh = session.refreshToken ?: return@withContext null
        try {
            val response = SupabaseClient.http.post(SupabaseClient.authUrl("token?grant_type=refresh_token")) {
                anonHeaders()
                contentType(ContentType.Application.Json)
                setBody(RefreshBody(refresh))
            }
            when {
                response.status.isSuccess() -> persist(response.body())
                response.status.value in listOf(400, 401, 403) -> {
                    // Refresh token rejected — sign out.
                    session.clear()
                    null
                }
                else -> cachedUser() // transient server error: stay signed in offline
            }
        } catch (e: Exception) {
            // Network failure — keep the user signed in using the cached session.
            cachedUser()
        }
    }

    suspend fun signIn(email: String, password: String): AppUser = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val response = SupabaseClient.http.post(SupabaseClient.authUrl("token?grant_type=password")) {
            anonHeaders()
            contentType(ContentType.Application.Json)
            setBody(Credentials(email.trim(), password))
        }
        if (!response.status.isSuccess()) throw authError(response)
        persist(response.body()) ?: throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    suspend fun signUp(name: String, email: String, password: String): AppUser = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val response = SupabaseClient.http.post(SupabaseClient.authUrl("signup")) {
            anonHeaders()
            contentType(ContentType.Application.Json)
            setBody(SignUpBody(email.trim(), password, mapOf("full_name" to name)))
        }
        if (!response.status.isSuccess()) throw authError(response)
        val token: TokenResponse = response.body()
        // Sign-up may require email confirmation (no session returned).
        persist(token) ?: (token.user ?: AppUser(id = "", email = email))
    }

    suspend fun sendPasswordReset(email: String): Boolean = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val response = SupabaseClient.http.post(SupabaseClient.authUrl("recover")) {
            anonHeaders()
            contentType(ContentType.Application.Json)
            setBody(RecoveryBody(email.trim()))
        }
        response.status.isSuccess()
    }

    /**
     * Complete a PIN-based password reset, mirroring iOS `resetPasswordWithPin`.
     * Verifies the 6-digit recovery code (GoTrue `/verify` type=recovery) to
     * obtain a short-lived session, then sets the new password via
     * `PUT /auth/v1/user`. Returns true on success.
     */
    suspend fun resetPasswordWithPin(email: String, pin: String, newPassword: String): Boolean =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val verifyResponse = SupabaseClient.http.post(SupabaseClient.authUrl("verify")) {
                anonHeaders()
                contentType(ContentType.Application.Json)
                setBody(VerifyOtpBody(email.trim(), pin.trim(), "recovery"))
            }
            if (!verifyResponse.status.isSuccess()) throw authError(verifyResponse)
            val token: TokenResponse = verifyResponse.body()
            val access = token.accessToken
                ?: throw BackendError.Server(verifyResponse.status.value, "No session returned.")

            val updateResponse = SupabaseClient.http.put(SupabaseClient.authUrl("user")) {
                anonHeaders()
                headers { append(HttpHeaders.Authorization, "Bearer $access") }
                contentType(ContentType.Application.Json)
                setBody(PasswordBody(newPassword))
            }
            if (!updateResponse.status.isSuccess()) throw authError(updateResponse)
            // Don't persist this recovery session — the user signs in fresh after.
            true
        }

    suspend fun signOut() = withContext(Dispatchers.IO) {
        val token = session.accessToken
        if (SupabaseClient.isConfigured && !token.isNullOrBlank()) {
            try {
                SupabaseClient.http.post(SupabaseClient.authUrl("logout")) {
                    anonHeaders()
                    headers { append(HttpHeaders.Authorization, "Bearer $token") }
                }
            } catch (_: Exception) { /* best effort */ }
        }
        session.clear()
    }

    private fun io.ktor.client.request.HttpRequestBuilder.anonHeaders() {
        headers { append("apikey", SupabaseClient.anonKey) }
    }

    private fun persist(token: TokenResponse): AppUser? {
        val access = token.accessToken ?: return null
        val refresh = token.refreshToken ?: return null
        session.save(access, refresh, token.user?.id, token.user?.email, token.user?.displayName)
        return token.user ?: AppUser(id = session.userId ?: "", email = session.userEmail)
    }

    private fun cachedUser(): AppUser? {
        val id = session.userId ?: return null
        return AppUser(id = id, email = session.userEmail)
    }

    private suspend fun authError(response: HttpResponse): BackendError {
        val body = response.bodyAsText()
        return if (response.status.value in listOf(400, 401, 403)) {
            BackendError.Server(response.status.value, parseMessage(body))
        } else {
            BackendError.Server(response.status.value, body)
        }
    }

    private fun parseMessage(body: String): String {
        return try {
            val obj = SupabaseClient.json.parseToJsonElement(body)
            val map = obj as? kotlinx.serialization.json.JsonObject
            val msg = (map?.get("error_description") ?: map?.get("msg") ?: map?.get("message"))
            msg?.toString()?.trim('"') ?: "Invalid email or password."
        } catch (_: Exception) {
            "Invalid email or password."
        }
    }
}
