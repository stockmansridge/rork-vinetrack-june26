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
interface YieldSessionWriting {
    suspend fun upsertSession(session: YieldEstimationSession, clientUpdatedAt: String? = null): YieldEstimationSession
}

class YieldEstimationSessionRepository(private val session: SessionStore) : YieldSessionWriting {

    @Serializable
    internal data class SessionUpsert(
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
    internal data class SessionRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val payload: YieldEstimationSession? = null,
        @SerialName("is_completed") val isCompleted: Boolean? = null,
        @SerialName("completed_at") val completedAt: String? = null,
        @SerialName("session_created_at") val sessionCreatedAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    ) {
        fun toSession(): YieldEstimationSession? {
            if (deletedAt != null) return null
            return payload?.copy(
                id = id, vineyardId = vineyardId,
                isCompleted = isCompleted ?: payload.isCompleted,
                completedAt = completedAt ?: payload.completedAt,
                createdAt = sessionCreatedAt ?: payload.createdAt,
            )
        }
    }

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class HardDeleteArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_expected_completed") val expectedCompleted: Boolean,
    )

    @Serializable
    private data class HardDeleteReceipt(
        @SerialName("session_id") val sessionId: String,
        @SerialName("vineyard_id") val vineyardId: String,
    )

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
                    response.body<List<SessionRow>>().mapNotNull { it.toSession() }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Insert or update (upsert by id) a yield session. Idempotent / last-write-wins. */
    override suspend fun upsertSession(
        session: YieldEstimationSession,
        clientUpdatedAt: String?,
    ): YieldEstimationSession = withContext(Dispatchers.IO) {
        require(!session.isCompleted || !session.completedAt.isNullOrBlank()) { "Completed trip requires its actual completion time." }
        if (session.isCompleted) Instant.parse(session.completedAt)
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
            response.status.isSuccess() -> {
                val saved = response.body<List<SessionRow>>().firstOrNull()?.toSession()
                    ?: throw IllegalStateException("Trip acknowledgement is missing; saved intent retained for retry.")
                check(saved.id.equals(session.id, true) && saved.vineyardId.equals(session.vineyardId, true) &&
                    saved.isCompleted == session.isCompleted && (!session.isCompleted || saved.completedAt?.let { Instant.parse(it) } == Instant.parse(session.completedAt))) {
                    "Trip acknowledgement did not confirm the saved completion."
                }
                saved
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Server-first hard deletion: never hide the local observation until
     * the role/state check succeeds and its deletion receipt can be read back.
     */
    suspend fun hardDeleteSession(source: YieldEstimationSession) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("hard_delete_yield_estimation_session"),
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(HardDeleteArgs(source.id, source.vineyardId, source.isCompleted))
        }
        when {
            response.status.isSuccess() -> {
                if (!response.body<Boolean>()) {
                    // A locally created draft can be deleted before its
                    // first upload. Verify no server row exists, then let
                    // the local delete coordinator cancel its pending save.
                    if (source.isCompleted) {
                        error("Completed yield observation does not exist or cannot be deleted.")
                    }
                    val check = SupabaseClient.http.get(SupabaseClient.restUrl(
                        "yield_estimation_sessions?select=id" +
                            "&id=eq.${source.id}&vineyard_id=eq.${source.vineyardId}"
                    )) { authHeaders(token) }
                    if (!check.status.isSuccess()) {
                        throw BackendError.Server(check.status.value, check.bodyAsText())
                    }
                    check(check.body<List<kotlinx.serialization.json.JsonObject>>().isEmpty()) {
                        "The draft exists on the server but hard deletion was rejected."
                    }
                    return@withContext
                }
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
        val receipt = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_estimation_session_deletion_receipts?select=session_id,vineyard_id" +
                "&session_id=eq.${source.id}&vineyard_id=eq.${source.vineyardId}"
        )) { authHeaders(token) }
        if (!receipt.status.isSuccess()) throw BackendError.Server(receipt.status.value, receipt.bodyAsText())
        check(receipt.body<List<HardDeleteReceipt>>().singleOrNull()?.sessionId.equals(source.id, true)) {
            "Hard delete receipt is unavailable; reload the server before retrying."
        }
    }

    /** Existing offline DELETE intents contain only an ID. Resolve exact
     * vineyard and completion status on the server under RLS at replay time.
     */
    suspend fun hardDeleteSessionById(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("hard_delete_yield_estimation_session_by_id")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> {
                if (!response.body<Boolean>()) {
                    throw BackendError.Server(404, "Session missing or not accessible for hard deletion.")
                }
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun deletedIds(vineyardId: String): Set<String> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_estimation_session_deletion_receipts?select=session_id,vineyard_id" +
                "&vineyard_id=eq.$vineyardId"
        )) { authHeaders(token) }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        response.body<List<HardDeleteReceipt>>().filter {
            it.vineyardId.equals(vineyardId, true)
        }.map { it.sessionId.lowercase() }.toSet()
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
