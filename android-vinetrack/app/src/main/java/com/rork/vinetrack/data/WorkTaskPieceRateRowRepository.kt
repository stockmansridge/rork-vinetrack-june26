package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTaskPieceRateRow
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Read/write path for `public.work_task_piece_rate_rows` (sql/188) — the
 * HISTORICAL per-row vine-count snapshot behind a piece-rate work task.
 *
 * This is NOT a row-selection system. Row selection for pruning stays in
 * `pruning_row_segments` (sql/112). These rows record the quantity the agreed
 * job value was calculated from, so a completed job keeps its commercial
 * figures even after the vineyard's rows are later edited.
 *
 * Mirrors the iOS `SupabaseWorkTaskPieceRateRowSyncRepository` contract:
 * client-generated ids, `upsert ... on conflict (id)`, soft delete through
 * `soft_delete_work_task_piece_rate_row`. RLS scopes everything to the
 * signed-in user's vineyard role.
 */
class WorkTaskPieceRateRowRepository(private val session: SessionStore) {

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /** Upsert payload — the exact column set iOS writes. */
    @Serializable
    private data class PieceRateRowUpsert(
        val id: String,
        @SerialName("work_task_id") val workTaskId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("paddock_row_id") val paddockRowId: String? = null,
        @SerialName("row_number") val rowNumber: Int? = null,
        @SerialName("vine_count") val vineCount: Int,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    fun newId(): String = UUID.randomUUID().toString()

    private fun nowIso(): String = Instant.now().toString()

    /** Every live snapshot row of one job, in row order. */
    suspend fun listForWorkTask(workTaskId: String): List<WorkTaskPieceRateRow> =
        withContext(Dispatchers.IO) {
            get(
                "work_task_piece_rate_rows?select=*&work_task_id=eq.$workTaskId" +
                    "&deleted_at=is.null&order=row_number.asc"
            )
        }

    /** Every live snapshot row of a vineyard — used to cost a task list in one pull. */
    suspend fun listForVineyard(vineyardId: String): List<WorkTaskPieceRateRow> =
        withContext(Dispatchers.IO) {
            get(
                "work_task_piece_rate_rows?select=*&vineyard_id=eq.$vineyardId" +
                    "&deleted_at=is.null&order=row_number.asc"
            )
        }

    /**
     * Replaces a job's ENTIRE row snapshot.
     *
     * Rows no longer part of the job are soft-deleted; the rest are upserted by
     * their stable client-generated id, so a retry can never duplicate history.
     */
    suspend fun replaceForWorkTask(
        workTaskId: String,
        rows: List<WorkTaskPieceRateRow>,
    ): List<WorkTaskPieceRateRow> = withContext(Dispatchers.IO) {
        requireConfig()
        val existing = listForWorkTask(workTaskId)
        val keptIds = rows.map { it.id }.toSet()
        existing.filter { it.id !in keptIds }.forEach { softDelete(it.id) }
        if (rows.isEmpty()) return@withContext emptyList()

        val token = session.accessToken ?: throw BackendError.Unauthorized
        val stamp = nowIso()
        val payload = rows.map { row ->
            PieceRateRowUpsert(
                id = row.id,
                workTaskId = workTaskId,
                vineyardId = row.vineyardId,
                paddockId = row.paddockId,
                paddockRowId = row.paddockRowId,
                rowNumber = row.rowNumber,
                vineCount = row.vineCount.coerceAtLeast(0),
                createdBy = session.userId,
                clientUpdatedAt = stamp,
            )
        }
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("work_task_piece_rate_rows")
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        rowsOrThrow(response)
    }

    /** Soft-delete one snapshot row (owner/manager/supervisor only). */
    suspend fun softDelete(id: String): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("soft_delete_work_task_piece_rate_row")
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

    private suspend fun get(path: String): List<WorkTaskPieceRateRow> {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
            authHeaders(token)
        }
        return rowsOrThrow(response)
    }

    private suspend fun rowsOrThrow(response: HttpResponse): List<WorkTaskPieceRateRow> = when {
        response.status.isSuccess() -> response.body()
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
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
