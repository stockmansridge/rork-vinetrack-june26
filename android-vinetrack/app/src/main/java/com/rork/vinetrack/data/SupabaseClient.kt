package com.rork.vinetrack.data

import android.util.Log
import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.HttpSend
import io.ktor.client.plugins.plugin
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.http.HttpHeaders
import io.ktor.http.encodedPath
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json
import java.io.IOException

/** Outcome of a refresh-token exchange, used by the HTTP retry layer. */
enum class RefreshOutcome {
    /** A valid (fresh or concurrently refreshed) access token is available. */
    REFRESHED,

    /** The refresh token was actively rejected — the session is truly invalid. */
    REJECTED,

    /** Network/transient server failure — the session may still be valid. */
    TRANSIENT,
}

/**
 * Hook the auth layer installs on [SupabaseClient] so the shared HTTP client
 * can transparently refresh an expired Supabase access token and retry the
 * original request once, instead of surfacing a 401 that logs the user out.
 */
interface SessionTokenRefresher {
    /** Current persisted access token, or null when signed out. */
    val sessionAccessToken: String?

    /** True when the access token is expired or expiring within the skew window. */
    fun accessTokenExpiresSoon(): Boolean

    /** Single-flight refresh-token exchange. Must never throw. */
    suspend fun refreshAccessToken(): RefreshOutcome
}

/**
 * Thin wrapper around a Ktor client configured for the VineTrack Supabase
 * project. We talk to the GoTrue auth endpoints and the PostgREST data API
 * directly, matching the iOS Supabase repositories.
 */
object SupabaseClient {

    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
        // Tolerate JSON `null` for non-nullable columns that carry a default
        // (e.g. trips.tank_sessions, row_sequence, is_active). Without this, a
        // single legacy row with a null in such a column throws during decode
        // and fails the whole list read ("Couldn't load trips").
        coerceInputValues = true
    }

    val baseUrl: String get() = AppConfig.supabaseUrl
    val anonKey: String get() = AppConfig.supabaseAnonKey
    val isConfigured: Boolean get() = AppConfig.isSupabaseConfigured

    /**
     * Installed by the auth layer at startup. When present, session-bearing
     * requests get a proactive pre-send token freshen and a single
     * refresh-and-retry on 401, mirroring the iOS Supabase SDK's automatic
     * session refresh.
     */
    @Volatile
    var sessionRefresher: SessionTokenRefresher? = null

    private const val AUTH_TAG = "VineTrackAuth"

    val http: HttpClient by lazy {
        HttpClient(Android) {
            expectSuccess = false
            install(ContentNegotiation) {
                json(json)
            }
        }.apply {
            plugin(HttpSend).intercept { request ->
                val refresher = sessionRefresher
                val bearer = request.headers[HttpHeaders.Authorization]
                    ?.removePrefix("Bearer")?.trim()
                // GoTrue endpoints (incl. the refresh call itself) and anon-only
                // requests are never intercepted — no recursion, and recovery
                // flows keep their short-lived tokens untouched.
                val isAuthEndpoint = request.url.encodedPath.contains("/auth/v1/")
                val isSessionRequest = refresher != null &&
                    !isAuthEndpoint &&
                    !bearer.isNullOrBlank() &&
                    bearer != anonKey

                if (isSessionRequest && refresher != null) {
                    // Proactive: refresh a token that is about to expire so the
                    // request succeeds first time after long idle periods.
                    if (refresher.accessTokenExpiresSoon()) {
                        Log.d(AUTH_TAG, "Access token expiring soon — refreshing before request")
                        refresher.refreshAccessToken()
                    }
                    // Swap in the latest persisted token in case the captured
                    // one is stale (another request refreshed meanwhile).
                    val latest = refresher.sessionAccessToken
                    if (!latest.isNullOrBlank() && latest != bearer) request.replaceBearerToken(latest)
                }

                val call = execute(request)
                if (!isSessionRequest || refresher == null) return@intercept call
                if (call.response.status.value != 401) return@intercept call

                Log.d(AUTH_TAG, "401 from ${request.url.encodedPath} — attempting session refresh")
                when (refresher.refreshAccessToken()) {
                    RefreshOutcome.REFRESHED -> {
                        val fresh = refresher.sessionAccessToken ?: return@intercept call
                        request.replaceBearerToken(fresh)
                        Log.d(AUTH_TAG, "Refresh succeeded — retrying ${request.url.encodedPath} once")
                        execute(request)
                    }
                    RefreshOutcome.REJECTED -> {
                        // Session is definitively invalid; the 401 propagates as
                        // Unauthorized so existing routing sends the user to login.
                        Log.w(AUTH_TAG, "Refresh token rejected — session invalid, routing to login")
                        call
                    }
                    RefreshOutcome.TRANSIENT -> {
                        // Couldn't reach the auth server — do NOT let this look
                        // like a credential rejection (which would log the user
                        // out). Surface a recoverable network error instead.
                        Log.w(AUTH_TAG, "Session refresh failed transiently — keeping user signed in")
                        throw BackendError.Network(
                            IOException("Could not refresh session. Check your connection and try again."),
                        )
                    }
                }
            }
        }
    }

    private fun HttpRequestBuilder.replaceBearerToken(token: String) {
        headers.remove(HttpHeaders.Authorization)
        headers.append(HttpHeaders.Authorization, "Bearer $token")
    }

    fun authUrl(path: String): String = "$baseUrl/auth/v1/$path"
    fun restUrl(path: String): String = "$baseUrl/rest/v1/$path"
    fun rpcUrl(name: String): String = "$baseUrl/rest/v1/rpc/$name"
    fun storageUrl(path: String): String = "$baseUrl/storage/v1/$path"
    fun functionUrl(name: String): String = "$baseUrl/functions/v1/$name"
}

/** Domain error surfaced to the UI layer. */
sealed class BackendError(message: String) : Exception(message) {
    object NotConfigured : BackendError("Supabase is not configured.")
    object Unauthorized : BackendError("Your session has expired. Please sign in again.")
    class Network(cause: Throwable) : BackendError(cause.message ?: "Network error.")
    class Server(val code: Int, val body: String) : BackendError("Request failed ($code).")
}
