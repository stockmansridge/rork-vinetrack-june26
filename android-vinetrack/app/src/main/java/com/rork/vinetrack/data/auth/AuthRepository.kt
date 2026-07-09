package com.rork.vinetrack.data.auth

import android.util.Base64
import android.util.Log
import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.RefreshOutcome
import com.rork.vinetrack.data.SessionTokenRefresher
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

class AuthRepository(private val session: SessionStore) : SessionTokenRefresher {

    init {
        // Install the refresh hook so the shared HTTP client can transparently
        // refresh an expired access token and retry the original request once.
        SupabaseClient.sessionRefresher = this
    }

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
    private data class IdTokenBody(
        val provider: String,
        @SerialName("id_token") val idToken: String,
        val nonce: String? = null,
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

    /** ISO auth `created_at` for the signed-in user (drives the free-access window). */
    val currentUserCreatedAt: String? get() = session.userCreatedAt

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
        if (session.refreshToken == null) {
            Log.d(TAG, "restoreSession: no persisted session")
            return@withContext null
        }
        when (val result = performRefresh(session.accessToken)) {
            is RefreshResult.Success -> result.user ?: cachedUser()
            RefreshResult.Rejected -> null // session already cleared by performRefresh
            RefreshResult.Transient -> cachedUser() // offline: stay signed in
        }
    }

    /**
     * Foreground/resume session check (parity with the iOS SDK's automatic
     * revalidation). Refreshes the access token when it is missing, expired,
     * or expiring within [FOREGROUND_SKEW_SECONDS]. Returns false only when
     * the session is definitively invalid (refresh token rejected); network
     * failures keep the user signed in for offline field work.
     */
    suspend fun ensureFreshSession(): Boolean = withContext(Dispatchers.IO) {
        if (session.refreshToken == null) return@withContext false
        val token = session.accessToken
        val exp = token?.let { jwtExpiryEpochSeconds(it) }
        val now = System.currentTimeMillis() / 1000
        val needsRefresh = token == null || exp == null || exp - now < FOREGROUND_SKEW_SECONDS
        if (!needsRefresh) {
            Log.d(TAG, "Session healthy on resume (expires in ${(exp ?: 0) - now}s)")
            return@withContext true
        }
        Log.d(TAG, "Stale session on resume (expires in ${exp?.minus(now)}s) — refreshing")
        performRefresh(token) !is RefreshResult.Rejected
    }

    // --- SessionTokenRefresher (central HTTP refresh-and-retry hook) ---

    override val sessionAccessToken: String? get() = session.accessToken

    override fun accessTokenExpiresSoon(): Boolean {
        val token = session.accessToken ?: return false
        val exp = jwtExpiryEpochSeconds(token) ?: return false
        return exp - System.currentTimeMillis() / 1000 < EXPIRY_SKEW_SECONDS
    }

    override suspend fun refreshAccessToken(): RefreshOutcome = withContext(Dispatchers.IO) {
        when (performRefresh(session.accessToken)) {
            is RefreshResult.Success -> RefreshOutcome.REFRESHED
            RefreshResult.Rejected -> RefreshOutcome.REJECTED
            RefreshResult.Transient -> RefreshOutcome.TRANSIENT
        }
    }

    private sealed interface RefreshResult {
        data class Success(val user: AppUser?) : RefreshResult
        data object Rejected : RefreshResult
        data object Transient : RefreshResult
    }

    /**
     * Single-flight refresh-token exchange. [tokenBefore] is the access token
     * the caller observed failing/expiring: if another caller already refreshed
     * while we waited on the lock, the exchange is skipped and the fresh token
     * is reused. Clears the session ONLY when the server actively rejects the
     * refresh token — never on network/transient failures.
     */
    private suspend fun performRefresh(tokenBefore: String?): RefreshResult = refreshMutex.withLock {
        if (tokenBefore != null && session.accessToken != tokenBefore) {
            Log.d(TAG, "Session already refreshed by a concurrent request")
            return@withLock RefreshResult.Success(cachedUser())
        }
        val refresh = session.refreshToken ?: return@withLock RefreshResult.Rejected
        try {
            val response = SupabaseClient.http.post(SupabaseClient.authUrl("token?grant_type=refresh_token")) {
                anonHeaders()
                contentType(ContentType.Application.Json)
                setBody(RefreshBody(refresh))
            }
            when {
                response.status.isSuccess() -> {
                    val user = persist(response.body())
                    if (user != null) {
                        Log.d(TAG, "Session refresh succeeded")
                        RefreshResult.Success(user)
                    } else {
                        // Success status but no tokens in the body — treat as
                        // transient rather than destroying a possibly valid session.
                        Log.w(TAG, "Session refresh returned no tokens — treating as transient")
                        RefreshResult.Transient
                    }
                }
                response.status.value in listOf(400, 401, 403) -> {
                    // Refresh token rejected — the session is truly invalid.
                    Log.w(TAG, "Refresh token rejected (${response.status.value}) — clearing session")
                    session.clear()
                    RefreshResult.Rejected
                }
                else -> {
                    Log.w(TAG, "Session refresh failed transiently (${response.status.value})")
                    RefreshResult.Transient
                }
            }
        } catch (e: Exception) {
            // Network failure — keep the user signed in using the cached session.
            Log.w(TAG, "Session refresh network failure: ${e.message}")
            RefreshResult.Transient
        }
    }

    /** Decode the `exp` claim from a JWT without verifying the signature. */
    private fun jwtExpiryEpochSeconds(token: String): Long? {
        return try {
            val payload = token.split(".").getOrNull(1) ?: return null
            val decoded = Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
            val obj = SupabaseClient.json.parseToJsonElement(decoded.toString(Charsets.UTF_8)).jsonObject
            obj["exp"]?.jsonPrimitive?.longOrNull
        } catch (_: Exception) {
            null
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

    /**
     * Exchange a Google ID token for a Supabase session (GoTrue
     * `POST /auth/v1/token?grant_type=id_token`), mirroring the iOS
     * `signInWithApple` id_token flow. [nonce] is the RAW nonce whose SHA-256
     * was sent to Google — GoTrue hashes it and compares against the token's
     * nonce claim. Supabase links the Google identity to an existing account
     * with the same verified email, so no duplicate user is created.
     */
    suspend fun signInWithGoogleIdToken(idToken: String, nonce: String?): AppUser = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val response = SupabaseClient.http.post(SupabaseClient.authUrl("token?grant_type=id_token")) {
            anonHeaders()
            contentType(ContentType.Application.Json)
            setBody(IdTokenBody(provider = "google", idToken = idToken, nonce = nonce))
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

    private val refreshMutex = Mutex()

    private fun persist(token: TokenResponse): AppUser? {
        val access = token.accessToken ?: return null
        val refresh = token.refreshToken ?: return null
        session.save(
            access,
            refresh,
            token.user?.id,
            token.user?.email,
            token.user?.displayName,
            token.user?.createdAt,
        )
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

    private companion object {
        const val TAG = "VineTrackAuth"

        /** Pre-send refresh margin for the HTTP interceptor. */
        const val EXPIRY_SKEW_SECONDS = 60L

        /** Foreground/resume refresh margin — refresh well before expiry. */
        const val FOREGROUND_SKEW_SECONDS = 300L
    }
}
