package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.YieldEstimationSession
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Write/read path for yield-estimation working sessions, mirroring the iOS
 * `YieldEstimationSessionSyncService` contract (the `yield_estimation_sessions`
 * table + `soft_delete_yield_estimation_session` RPC).
 *
 * The whole session is stored in the JSONB `payload` column (selected blocks,
 * generated sample sites with inline bunch counts, per-block bunch weights, path
 * waypoints, completion). Promoted scalar columns (`is_completed`,
 * `completed_at`, `session_created_at`) shadow the payload for server-side
 * filtering and round-trip with iOS / the web portal unchanged.
 *
 * RLS scopes everything to the signed-in user's vineyard role: owner / manager /
 * supervisor / operator may insert and update; only owner / manager / supervisor
 * may soft-delete. Upsert is keyed on `id` (merge-duplicates) so a retried save
 * is idempotent and last-write-wins via `client_updated_at`.
 */
class YieldEstimationSessionRepository(private val session: SessionStore) {

    @Serializable
    private data class SessionUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val payload: YieldEstimationSession,
        @SerialName("is_completed") val isCompleted: Boolean,
        @SerialName("completed_at") val completedAt: String? = null,
        @SerialName("session_created_at") val sessionCreatedAt: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SessionRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val payload: YieldEstimationSession? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    /** All non-deleted yield sessions for a vineyard, newest update first. */
    suspend fun listSessions(vineyardId: String): List<YieldEstimationSession> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "yield_estimation_sessions?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=updated_at.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() ->
                    response.body<List<SessionRow>>().mapNotNull { it.payload }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Insert or update (upsert by id) a yield session. Idempotent / last-write-wins. */
    suspend fun upsertSession(
        session: YieldEstimationSession,
        clientUpdatedAt: String? = null,
    ): YieldEstimationSession = withContext(Dispatchers.IO) {
        requireConfig()
        val token = this@YieldEstimationSessionRepository.session.accessToken
            ?: throw BackendError.Unauthorized
        val now = clientUpdatedAt ?: nowIso()
        val body = SessionUpsert(
            id = session.id,
            vineyardId = session.vineyardId,
            payload = session,
            isCompleted = session.isCompleted,
            completedAt = session.completedAt,
            sessionCreatedAt = session.createdAt,
            createdBy = this@YieldEstimationSessionRepository.session.userId,
            clientUpdatedAt = now,
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("yield_estimation_sessions?on_conflict=id"),
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() ->
                response.body<List<SessionRow>>().firstOrNull()?.payload ?: session
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun softDeleteSession(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("soft_delete_yield_estimation_session"),
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
