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
 * table + server-authorised hard-delete RPC and receipt readback).
 *
 * The whole session is stored in the JSONB `payload` column (selected blocks,
 * generated sample sites with inline bunch counts, per-block bunch weights, path
 * waypoints, completion). Promoted scalar columns (`is_completed`,
 * `completed_at`, `session_created_at`) shadow the payload for server-side
 * filtering and round-trip with iOS / the web portal unchanged.
 *
 * RLS scopes everything to the signed-in user's vineyard role: owner / manager /
 * supervisor / operator may insert, update and delete drafts; only owner / manager /
 * supervisor may delete completed observations. Upsert is keyed on `id` (merge-duplicates) so a retried save
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
        @SerialName("was_completed") val wasCompleted: Boolean,
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
                check(response.body<Boolean>()) {
                    "Hard deletion was not acknowledged. A durable server receipt is required, including for a local draft."
                }
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
        val receipt = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_estimation_session_deletion_receipts?select=session_id,vineyard_id,was_completed" +
                "&session_id=eq.${source.id}&vineyard_id=eq.${source.vineyardId}"
        )) { authHeaders(token) }
        if (!receipt.status.isSuccess()) throw BackendError.Server(receipt.status.value, receipt.bodyAsText())
        val deleted = receipt.body<List<HardDeleteReceipt>>().singleOrNull()
        val absence = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_estimation_sessions?select=id&id=eq.${source.id}&vineyard_id=eq.${source.vineyardId}"
        )) { authHeaders(token) }
        if (!absence.status.isSuccess()) throw BackendError.Server(absence.status.value, absence.bodyAsText())
        check(deleted != null && deleted.sessionId.equals(source.id, true)
            && deleted.vineyardId.equals(source.vineyardId, true) && deleted.wasCompleted == source.isCompleted
            && absence.body<List<kotlinx.serialization.json.JsonObject>>().isEmpty()) {
            "Hard delete receipt is unavailable; reload the server before retrying."
        }
    }

    /** Existing offline DELETE intents contain only an ID. Resolve exact
     * vineyard and completion status on the server under RLS at replay time.
     */
    suspend fun hardDeleteSessionById(id: String, vineyardId: String? = null) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        require(!vineyardId.isNullOrBlank()) { "A selected vineyard is required; unscoped deletion stays held." }
        run {
            val scope = SupabaseClient.http.get(SupabaseClient.restUrl(
                "yield_estimation_sessions?select=*&id=eq.$id&vineyard_id=eq.$vineyardId"
            )) { authHeaders(token) }
            if (!scope.status.isSuccess()) throw BackendError.Server(scope.status.value, scope.bodyAsText())
            val rows = scope.body<List<SessionRow>>()
            val row = rows.singleOrNull()?.toSession()
            if (row != null) { hardDeleteSession(row); return@withContext }
            check(rows.isEmpty()) { "Session absence was not verified; retained for review." }
            val deleted = deletedIds(vineyardId)
            check(id.lowercase() in deleted) { "No deletion receipt in the selected vineyard; retained for review." }
            return@withContext
        }
    }

    suspend fun deletedIds(vineyardId: String): Set<String> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_estimation_session_deletion_receipts?select=session_id,vineyard_id,was_completed" +
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
