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

/** Isolated authentication transport; ordinary field access is restored only by original-user admission. */
class AuthRecoveryRepository(
    private val clientFactory: () -> HttpClient = {
        HttpClient(Android) {
            expectSuccess = false
            followRedirects = false
            install(ContentNegotiation) { json(SupabaseClient.json) }
        }
    },
) {
    @Serializable private data class Credentials(val email: String, val password: String)
    @Serializable private data class Token(
        @SerialName("access_token") val accessToken: String? = null,
        @SerialName("refresh_token") val refreshToken: String? = null,
    )
    @Serializable private data class LiveVineyard(val id: String)
    @Serializable private data class Membership(
        @SerialName("vineyard_id") val vineyardId: String,
        val role: String,
    )

    /** Uses /user identity and current membership, never typed email or cached vineyard membership. */
    suspend fun recover(session: SessionStore, email: String, password: String): Boolean = withContext(Dispatchers.IO) {
        val (original, epoch) = session.retentionGuard.serialized {
            (session.recoveryPrincipal ?: throw AuthRecoveryFailure(AuthRecoveryFailure.Stage.ORIGINAL_IDENTITY)) to session.retentionGuard.identityEpoch.value
        }
        var stage = AuthRecoveryFailure.Stage.SIGN_IN
        try {
        check(SupabaseClient.isConfigured)
        withTimeout(30_000) {
            clientFactory().use { client ->
                val response = client.post(SupabaseClient.authUrl("token?grant_type=password")) {
                    headers { append("apikey", SupabaseClient.anonKey) }
                    contentType(ContentType.Application.Json)
                    setBody(Credentials(email.trim(), password))
                }
                check(response.status.isSuccess()) { "Account verification failed." }
                val token = response.body<Token>()
                val access = token.accessToken ?: error("Additional authentication is required.")
                var restored = false
                try {
                    stage = AuthRecoveryFailure.Stage.IDENTITY
                    val identity = client.get(SupabaseClient.authUrl("user")) {
                        headers {
                            append("apikey", SupabaseClient.anonKey)
                            append("Authorization", "Bearer $access")
                        }
                    }
                    check(identity.status.isSuccess()) { "Account verification failed." }
                    val user = identity.body<AppUser>()
                    check(user.id == original) { "The verified original account is required." }
                    stage = AuthRecoveryFailure.Stage.VINEYARD_ACCESS
                    val membership = client.get(SupabaseClient.restUrl("vineyard_members?select=vineyard_id,role&user_id=eq.${user.id}")) {
                        headers {
                            append("apikey", SupabaseClient.anonKey)
                            append("Authorization", "Bearer $access")
                        }
                    }
                    check(membership.status.isSuccess()) { "Current vineyard access could not be verified." }
                    val memberVineyards = membership.body<List<Membership>>()
                        .filter { it.role in setOf("owner", "operator", "supervisor", "manager") }
                        .mapTo(mutableSetOf()) { it.vineyardId }
                    val vineyards = client.get(SupabaseClient.restUrl("vineyards?select=id&deleted_at=is.null")) {
                        headers {
                            append("apikey", SupabaseClient.anonKey)
                            append("Authorization", "Bearer $access")
                        }
                    }
                    check(vineyards.status.isSuccess()) { "Current vineyard access could not be verified." }
                    val permitted = vineyards.body<List<LiveVineyard>>().map { it.id }.toSet() intersect memberVineyards
                    val refresh = token.refreshToken ?: error("Additional authentication is required.")
                    stage = AuthRecoveryFailure.Stage.IN_FLIGHT
                    restored = session.restoreOriginal(access, refresh, user, permitted, expectedEpoch = epoch)
                    if (!restored) throw AuthRecoveryFailure(stage)
                    true
                } finally {
                    if (!restored) runCatching {
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
        } catch (failure: AuthRecoveryFailure) {
            throw failure
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            throw AuthRecoveryFailure(stage)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw AuthRecoveryFailure(stage)
        }
    }

    suspend fun verify(email: String, password: String): Unit = withContext(Dispatchers.IO) {
        check(SupabaseClient.isConfigured) { "Account verification is unavailable." }
        withTimeout(30_000) {
            clientFactory().use { client ->
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
