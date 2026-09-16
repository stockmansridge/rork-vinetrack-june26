package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Supabase reads and writes for Scout and Vintage Notes (SQL 236).
 *
 * ## Payload shapes are deliberately explicit
 *
 * Every DTO spells out its `snake_case` column name. `scout_date` and
 * `note_date` are `date` columns and are sent as `yyyy-MM-dd`; everything else
 * is ISO 8601. A `date` column silently receiving a full timestamp is exactly
 * how a note lands on the wrong day across a timezone boundary — and the
 * vintage is derived from that date, so the error would propagate into the
 * season the record belongs to.
 *
 * ## What is NOT sent
 *
 * `vintage_year` is never written by the client. SQL 236 resolves it with a
 * trigger via `resolve_vineyard_vintage_year`, and the client's value is
 * display-only. Sending it would invite exactly the disagreement the
 * server-authoritative rule exists to prevent.
 */
class VineyardInsightsSyncRepository(private val session: SessionStore) {

    // ------------------------------------------------------------ Scout DTOs

    @Serializable
    data class VisitUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("scout_date") val scoutDate: String,
        val status: String,
        @SerialName("visit_summary") val visitSummary: String? = null,
        @SerialName("weather_snapshot") val weatherSnapshot: WeatherPayload? = null,
        @SerialName("scout_user_id") val scoutUserId: String? = null,
        @SerialName("scout_name_snapshot") val scoutNameSnapshot: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class WeatherPayload(
        @SerialName("observed_at") val observedAt: String? = null,
        @SerialName("captured_at") val capturedAt: String,
        val source: String? = null,
        @SerialName("temperature_c") val temperatureC: Double? = null,
        @SerialName("humidity_pct") val humidityPct: Double? = null,
        @SerialName("wind_kph") val windKph: Double? = null,
        @SerialName("gust_kph") val gustKph: Double? = null,
        @SerialName("recent_rainfall_mm") val recentRainfallMm: Double? = null,
        @SerialName("is_stale") val isStale: Boolean = false,
        @SerialName("is_unavailable") val isUnavailable: Boolean = false,
    )

    @Serializable
    data class VisitRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("vintage_year") val vintageYear: Int = 0,
        @SerialName("scout_date") val scoutDate: String = "",
        val status: String = "draft",
        @SerialName("visit_summary") val visitSummary: String? = null,
        @SerialName("weather_snapshot") val weatherSnapshot: WeatherPayload? = null,
        @SerialName("scout_user_id") val scoutUserId: String? = null,
        @SerialName("scout_name_snapshot") val scoutNameSnapshot: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String? = null,
        @SerialName("sync_version") val syncVersion: Long = 0,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    data class AssessmentUpsert(
        val id: String,
        @SerialName("scout_visit_id") val scoutVisitId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        val status: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class AssessmentRow(
        val id: String,
        @SerialName("scout_visit_id") val scoutVisitId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        val status: String = "in_progress",
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    data class ObservationUpsert(
        val id: String,
        @SerialName("assessment_id") val assessmentId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("item_kind") val itemKind: String,
        @SerialName("value_code") val valueCode: String? = null,
        @SerialName("value_label") val valueLabel: String? = null,
        val notes: String? = null,
        @SerialName("linked_pin_id") val linkedPinId: String? = null,
        @SerialName("linked_growth_stage_record_id") val linkedGrowthStageRecordId: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class ObservationRow(
        val id: String,
        @SerialName("assessment_id") val assessmentId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("item_kind") val itemKind: String = "",
        @SerialName("value_code") val valueCode: String? = null,
        @SerialName("value_label") val valueLabel: String? = null,
        val notes: String? = null,
        @SerialName("linked_pin_id") val linkedPinId: String? = null,
        @SerialName("linked_growth_stage_record_id") val linkedGrowthStageRecordId: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    data class PhotoUpsert(
        val id: String,
        @SerialName("observation_id") val observationId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("storage_path") val storagePath: String,
        @SerialName("captured_at") val capturedAt: String,
        val latitude: Double? = null,
        val longitude: Double? = null,
        @SerialName("horizontal_accuracy") val horizontalAccuracy: Double? = null,
        @SerialName("location_status") val locationStatus: String,
        @SerialName("captured_by") val capturedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class PhotoRow(
        val id: String,
        @SerialName("observation_id") val observationId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("storage_path") val storagePath: String = "",
        @SerialName("captured_at") val capturedAt: String = "",
        val latitude: Double? = null,
        val longitude: Double? = null,
        @SerialName("horizontal_accuracy") val horizontalAccuracy: Double? = null,
        @SerialName("location_status") val locationStatus: String = "location_unavailable",
        @SerialName("captured_by") val capturedBy: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    data class NoteRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("note_date") val noteDate: String = "",
        @SerialName("vintage_year") val vintageYear: Int = 0,
        @SerialName("note_type_id") val noteTypeId: String? = null,
        @SerialName("note_type_label") val noteTypeLabel: String? = null,
        val notes: String? = null,
        @SerialName("observed_by_user_id") val observedByUserId: String? = null,
        @SerialName("observer_name_snapshot") val observerNameSnapshot: String? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String? = null,
        @SerialName("sync_version") val syncVersion: Long = 0,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    private data class SoftDeletePatch(
        @SerialName("deleted_at") val deletedAt: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    // --------------------------------------------------------- Vintage Notes

    @Serializable
    data class UpsertNoteArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_note_date") val noteDate: String,
        @SerialName("p_note_type_id") val noteTypeId: String? = null,
        @SerialName("p_note_type_label") val noteTypeLabel: String? = null,
        @SerialName("p_notes") val notes: String? = null,
        @SerialName("p_observer_name") val observerName: String? = null,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String? = null,
    )

    @Serializable
    private data class SoftDeleteNoteArgs(@SerialName("p_id") val id: String)

    @Serializable
    data class UpsertNoteTypeArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_code") val code: String,
        @SerialName("p_group_code") val groupCode: String,
        @SerialName("p_label") val label: String,
        @SerialName("p_sort_order") val sortOrder: Int = 0,
        @SerialName("p_is_active") val isActive: Boolean = true,
    )

    // ----------------------------------------------------------- Scout push
    //
    // Parent-first, always: visit, then assessments, then observations, then
    // photo rows. The SQL 236 foreign keys are real, so replaying a child
    // before its parent would be rejected. Ordering it here means offline
    // replay never depends on the order the operator happened to tap.

    suspend fun pushVisit(
        visit: VisitUpsert,
        assessments: List<AssessmentUpsert>,
        observations: List<ObservationUpsert>,
    ) = withContext(Dispatchers.IO) {
        upsert("scout_visits", listOf(visit), VisitUpsert.serializer())
        if (assessments.isNotEmpty()) {
            upsert("scout_block_assessments", assessments, AssessmentUpsert.serializer())
        }
        if (observations.isNotEmpty()) {
            upsert("scout_observations", observations, ObservationUpsert.serializer())
        }
    }

    /**
     * Insert the photo METADATA row. The bytes must already be in the bucket: a
     * row pointing at an object that does not exist would render as a broken
     * image on another device, which is worse than a photograph still shown as
     * pending upload.
     */
    suspend fun pushPhotoRow(photo: PhotoUpsert) = withContext(Dispatchers.IO) {
        upsert("scout_observation_photos", listOf(photo), PhotoUpsert.serializer())
    }

    /**
     * Upload photo bytes into the private `scout-photos` bucket.
     *
     * The path's first folder is the vineyard id because the SQL 236 storage
     * policies authorise on `storage_first_folder_uuid(name)`.
     */
    suspend fun uploadPhotoBytes(path: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$PHOTO_BUCKET/$path"),
            ) {
                authHeaders(token)
                headers {
                    // Upsert so a retry after an ambiguous failure overwrites
                    // its own object rather than failing forever on a conflict.
                    append("x-upsert", "true")
                    append("cache-control", "3600")
                }
                setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
            }
            when {
                response.status.isSuccess() -> path
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Soft-delete a visit and its assessments.
     *
     * No client hard delete exists anywhere in SQL 236 (every table carries a
     * `for delete using (false)` policy), so this is the only shape a deletion
     * can take. Children are tombstoned explicitly rather than relying on the
     * cascade, which only fires on a real DELETE.
     */
    suspend fun softDeleteVisit(id: String, vineyardId: String, atIso: String) =
        withContext(Dispatchers.IO) {
            val patch = SoftDeletePatch(atIso, atIso)
            patchRows(
                "scout_visits?id=eq.$id&vineyard_id=eq.$vineyardId",
                patch,
            )
            patchRows("scout_block_assessments?scout_visit_id=eq.$id", patch)
        }

    suspend fun softDeletePhoto(id: String, atIso: String) = withContext(Dispatchers.IO) {
        patchRows("scout_observation_photos?id=eq.$id", SoftDeletePatch(atIso, atIso))
    }

    // ----------------------------------------------------------- Scout pull

    suspend fun fetchVisits(vineyardId: String, sinceIso: String?): List<VisitRow> =
        select(
            buildString {
                append("scout_visits?vineyard_id=eq.$vineyardId")
                if (sinceIso != null) append("&updated_at=gt.$sinceIso")
                append("&order=updated_at.asc")
            },
        )

    suspend fun fetchAssessments(vineyardId: String, visitIds: List<String>): List<AssessmentRow> =
        if (visitIds.isEmpty()) {
            emptyList()
        } else {
            select(
                "scout_block_assessments?vineyard_id=eq.$vineyardId" +
                    "&scout_visit_id=in.(${visitIds.joinToString(",")})",
            )
        }

    suspend fun fetchObservations(
        vineyardId: String,
        assessmentIds: List<String>,
    ): List<ObservationRow> =
        if (assessmentIds.isEmpty()) {
            emptyList()
        } else {
            select(
                "scout_observations?vineyard_id=eq.$vineyardId" +
                    "&assessment_id=in.(${assessmentIds.joinToString(",")})",
            )
        }

    suspend fun fetchPhotos(vineyardId: String, observationIds: List<String>): List<PhotoRow> =
        if (observationIds.isEmpty()) {
            emptyList()
        } else {
            select(
                "scout_observation_photos?vineyard_id=eq.$vineyardId" +
                    "&observation_id=in.(${observationIds.joinToString(",")})",
            )
        }

    suspend fun fetchNotes(vineyardId: String, sinceIso: String?): List<NoteRow> =
        select(
            buildString {
                append("vintage_notes?vineyard_id=eq.$vineyardId")
                if (sinceIso != null) append("&updated_at=gt.$sinceIso")
                append("&order=updated_at.asc")
            },
        )

    // ----------------------------------------------------------------- RPCs

    suspend fun upsertNote(args: UpsertNoteArgs): NoteRow? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_vintage_note")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(args)
        }
        when {
            response.status.isSuccess() -> response.body<List<NoteRow>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 ->
                throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun softDeleteNote(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("soft_delete_vintage_note"),
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteNoteArgs(id))
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    suspend fun upsertNoteType(args: UpsertNoteTypeArgs) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("upsert_vintage_note_type"),
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(args)
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    // ------------------------------------------------------------- Plumbing

    private suspend inline fun <reified T> select(path: String): List<T> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
                authHeaders(token)
            }
            when {
                response.status.isSuccess() -> response.body<List<T>>()
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private suspend fun <T> upsert(
        table: String,
        rows: List<T>,
        serializer: kotlinx.serialization.KSerializer<T>,
    ) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = SupabaseClient.json.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(serializer),
            rows,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl(table)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            headers { append("Prefer", "resolution=merge-duplicates,return=minimal") }
            setBody(body)
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    private suspend fun patchRows(path: String, patch: SoftDeletePatch) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl(path)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            headers { append("Prefer", "return=minimal") }
            setBody(patch)
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    private suspend fun checkWrite(status: Int, body: suspend () -> String) {
        when {
            status in 200..299 -> Unit
            status == 401 || status == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(status, body())
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

    companion object {
        const val PHOTO_BUCKET = "scout-photos"
    }
}
