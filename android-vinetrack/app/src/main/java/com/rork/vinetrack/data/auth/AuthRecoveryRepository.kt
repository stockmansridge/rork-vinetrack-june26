package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.model.AppUser
import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.headers
import io.ktor.client.request.setBody
import io.ktor.client.call.body
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Authentication only. No SessionStore, refresh hook, field client, persistence or unlock authority. */
class AuthRecoveryRepository {
    @Serializable private data class Credentials(val email: String, val password: String)
    @Serializable private data class Token(@SerialName("access_token") val accessToken: String? = null)

    suspend fun verify(email: String, password: String): Unit = withContext(Dispatchers.IO) {
        check(SupabaseClient.isConfigured) { "Account verification is unavailable." }
        withTimeout(30_000) {
            HttpClient(Android) {
                expectSuccess = false
                followRedirects = false
                install(ContentNegotiation) { json(SupabaseClient.json) }
            }.use { client ->
                val response = client.post(SupabaseClient.authUrl("token?grant_type=password")) {
                    headers { append("apikey", SupabaseClient.anonKey) }
                    contentType(ContentType.Application.Json)
                    setBody(Credentials(email.trim(), password))
                }
                check(response.status.isSuccess()) { "Account verification failed." }
                val access = response.body<Token>().accessToken
                    ?: error("Account verification requires additional authentication.")
                try {
                    val userResponse = client.get(SupabaseClient.authUrl("user")) {
                        headers {
                            append("apikey", SupabaseClient.anonKey)
                            append("Authorization", "Bearer $access")
                        }
                    }
                    check(userResponse.status.isSuccess()) { "Account verification failed." }
                    check(userResponse.body<AppUser>().id.isNotBlank()) { "Account verification failed." }
                } finally {
                    // Best effort local-session revocation; tokens are never returned or persisted.
                    runCatching {
                        client.post(SupabaseClient.authUrl("logout?scope=local")) {
                            headers {
                                append("apikey", SupabaseClient.anonKey)
                                append("Authorization", "Bearer $access")
                            }
                        }
                    }
                }
            }
        }
    }
}
