package com.rork.vinetrack.data

import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Anonymous read, deliberately independent of the restored Supabase session. */
class AppReleasePolicyRepository {
    suspend fun fetch(): AppReleasePolicy? = withTimeoutOrNull(8_000L) {
        if (!SupabaseClient.isConfigured) return@withTimeoutOrNull null
        try {
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_app_release_policy")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer ${SupabaseClient.anonKey}")
                }
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject { put("p_platform", "android") })
            }
            if (response.status.isSuccess()) {
                SupabaseClient.json.decodeFromString<AppReleasePolicy?>(response.bodyAsText())
            } else null
        } catch (_: Exception) {
            null
        }
    }
}
