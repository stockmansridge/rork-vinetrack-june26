package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.GrowthStageRecord
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.patch
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
import java.util.UUID

/**
 * Write path for growth-stage observations, mirroring the iOS
 * `growth_stage_records` sync contract (table + `soft_delete_growth_stage_record`
 * RPC). RLS scopes everything to the signed-in user's vineyard role:
 * owner/manager/supervisor/operator may insert and update; only
 * owner/manager/supervisor may soft-delete.
 *
 * Online-first — there is no local queue yet. Android authors records directly
 * (no source pin), so `pin_id` is left null and the growth form is the sole
 * editor of these columns. `created_by` and the server-managed sync columns are
 * left untouched on edit. Records mirrored from iOS pins (with a `pin_id`) are
 * still readable and editable through the same path.
 */
class GrowthStageRecordRepository(private val session: SessionStore) {

    @Serializable
    private data class GrowthInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("stage_code") val stageCode: String,
        @SerialName("stage_label") val stageLabel: String? = null,
        val variety: String? = null,
        @SerialName("observed_at") val observedAt: String,
        val latitude: Double? = null,
        val longitude: Double? = null,
        @SerialName("row_number") val rowNumber: Int? = null,
        val notes: String? = null,
        @SerialName("recorded_by_name") val recordedByName: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Edit of the form-owned columns (no pin/created_by/photo/sync changes). */
    @Serializable
    private data class GrowthPatch(
        @SerialName("paddock_id") val paddockId: String? = null,
        @SerialName("stage_code") val stageCode: String,
        @SerialName("stage_label") val stageLabel: String? = null,
        val variety: String? = null,
        @SerialName("observed_at") val observedAt: String,
        @SerialName("row_number") val rowNumber: Int? = null,
        val notes: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Partial edit of only the photo array, leaving stage/block/date/notes/sync intact. */
    @Serializable
    private data class PhotoPathsPatch(
        @SerialName("photo_paths") val photoPaths: List<String>?,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /** Fields the growth-stage form edits, passed through both create and edit paths. */
    data class GrowthInput(
        val paddockId: String?,
        val stageCode: String,
        val stageLabel: String?,
        val variety: String?,
        val observedAt: String,
        val rowNumber: Int?,
        val notes: String?,
        /** GPS drop point captured like a map pin (auto-placement), or null. */
        val latitude: Double? = null,
        val longitude: Double? = null,
    )

    private fun nowIso(): String = Instant.now().toString()

    /**
     * Build the optimistic [GrowthStageRecord] for a new Android-authored
     * observation purely (no network). The same snapshot is used for the
     * optimistic UI row, the queued GROWTH_RECORD / CREATE marker payload, and
     * matches the row the server insert/replay produces — so the visible record
     * never changes shape once it syncs. Android authors direct records (no
     * source pin), so pin/geo/side/photo columns are null and `created_by` is
     * resolved from the live session at insert time, never carried here.
     */
    fun buildGrowthRecord(vineyardId: String, input: GrowthInput, id: String, clientUpdatedAt: String): GrowthStageRecord =
        GrowthStageRecord(
            id = id,
            vineyardId = vineyardId,
            paddockId = input.paddockId,
            pinId = null,
            stageCode = input.stageCode,
            stageLabel = input.stageLabel,
            variety = input.variety,
            varietyId = null,
            observedAt = input.observedAt,
            latitude = input.latitude,
            longitude = input.longitude,
            rowNumber = input.rowNumber,
            side = null,
            notes = input.notes,
            photoPaths = null,
            recordedByName = null,
            createdAt = clientUpdatedAt,
            deletedAt = null,
        )

    /**
     * Insert a new growth-stage observation. Default online behaviour is
     * unchanged: [id] mints a fresh UUID and [clientUpdatedAt] defaults to the
     * current instant. Offline replay ([GrowthRecordCreateSync]) passes the
     * original client-generated id + timestamp so a retried insert is idempotent
     * and faithful. `created_by` always resolves from the live session; pin/geo/
     * photo and server-managed audit/sync columns are never sent.
     */
    suspend fun createGrowthStageRecord(
        vineyardId: String,
        input: GrowthInput,
        id: String? = null,
        clientUpdatedAt: String? = null,
    ): GrowthStageRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = GrowthInsert(
                id = id ?: UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                paddockId = input.paddockId,
                stageCode = input.stageCode,
                stageLabel = input.stageLabel,
                variety = input.variety,
                observedAt = input.observedAt,
                latitude = input.latitude,
                longitude = input.longitude,
                rowNumber = input.rowNumber,
                notes = input.notes,
                recordedByName = null,
                createdBy = session.userId,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("growth_stage_records")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /**
     * Edit the form-owned columns of an existing observation. Default online
     * behaviour is unchanged: [clientUpdatedAt] defaults to the current instant.
     * Offline replay ([GrowthRecordUpdateSync]) passes the original
     * client-generated timestamp so the edit lands last-writer-wins faithfully.
     * Only stage/paddock/variety/observed-at/row/notes + `client_updated_at` are
     * sent; `created_by`, `updated_by`, pin/geo/side, photo paths and
     * server-managed audit/sync columns are never touched.
     */
    suspend fun updateGrowthStageRecord(
        id: String,
        input: GrowthInput,
        clientUpdatedAt: String? = null,
    ): GrowthStageRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = GrowthPatch(
                paddockId = input.paddockId,
                stageCode = input.stageCode,
                stageLabel = input.stageLabel,
                variety = input.variety,
                observedAt = input.observedAt,
                rowNumber = input.rowNumber,
                notes = input.notes,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("growth_stage_records?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    /**
     * Set or clear a record's `photo_paths` after a storage upload/removal.
     * Mirrors iOS's single-photo contract (the array holds at most one path) and
     * touches no other column. `null`/empty clears the photo reference.
     */
    suspend fun updatePhotoPaths(id: String, paths: List<String>?): GrowthStageRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = PhotoPathsPatch(
                photoPaths = paths?.takeIf { it.isNotEmpty() },
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("growth_stage_records?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    suspend fun softDeleteGrowthStageRecord(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_growth_stage_record")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): GrowthStageRecord = when {
        response.status.isSuccess() -> response.body<List<GrowthStageRecord>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
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
