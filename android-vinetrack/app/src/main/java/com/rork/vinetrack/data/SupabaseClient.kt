package com.rork.vinetrack.data

import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

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

    val http: HttpClient by lazy {
        HttpClient(Android) {
            expectSuccess = false
            install(ContentNegotiation) {
                json(json)
            }
        }
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
