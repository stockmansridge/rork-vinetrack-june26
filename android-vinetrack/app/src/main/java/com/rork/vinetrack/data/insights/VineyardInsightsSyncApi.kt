package com.rork.vinetrack.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The server contract for Scout and Vintage Notes (SQL 236), stated without any
 * transport.
 *
 * ## Why this interface exists
 *
 * [VineyardInsightsSyncWorker] owns the rules that actually matter — parent
 * before child, bytes before metadata row, a queue entry discharged only when
 * both effects landed, a deleted photograph never resurrected by its own
 * in-flight callback. Those rules were previously only reachable through a Ktor
 * client, which cannot be driven in an ordinary JVM test, so they could only be
 * verified by reading the code.
 *
 * Depending on this interface instead lets a test supply a fake that fails
 * exactly one call — the storage upload succeeding while the metadata row
 * fails, say — and then assert what the queue did about it. The production
 * implementation, [VineyardInsightsSyncRepository], is the only Ktor-aware part
 * and is not needed off-device.
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
interface VineyardInsightsSyncApi {

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

    /**
     * One photograph's metadata row.
     *
     * `observation_id` is the OWNER. SQL 236 gives every assessment item its own
     * `scout_observations` row (unique on `assessment_id` + `item_kind`), and a
     * photograph hangs off that row rather than off the block assessment — so a
     * photograph is always attributable to one specific item, and several
     * photographs can belong to the same item without colliding.
     */
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
    data class HardDeleteArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_operation_id") val operationId: String,
        @SerialName("p_deleted_at") val deletedAt: String,
        @SerialName("p_visit_id") val visitId: String? = null,
        @SerialName("p_note_id") val noteId: String? = null,
    )

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

    /** Parent-first: visit, then assessments, then observations. */
    suspend fun pushVisit(
        visit: VisitUpsert,
        assessments: List<AssessmentUpsert>,
        observations: List<ObservationUpsert>,
    )

    /**
     * Write the photo METADATA row. The bytes must already be in the bucket: a
     * row pointing at an object that does not exist would render as a broken
     * image on another device, which is worse than a photograph still shown as
     * pending upload.
     */
    suspend fun pushPhotoRow(photo: PhotoUpsert)

    /** Upload photo bytes. Same path on every retry, so the object is never duplicated. */
    suspend fun uploadPhotoBytes(path: String, jpeg: ByteArray): String

    /** Remove a storage object that no metadata row references. */
    suspend fun removePhotoObject(path: String)

    suspend fun hardDeleteVisit(id: String, vineyardId: String, operationId: String, atIso: String)

    suspend fun softDeletePhoto(id: String, atIso: String)

    // ----------------------------------------------------------- Scout pull

    suspend fun fetchVisits(vineyardId: String, sinceIso: String?): List<VisitRow>

    suspend fun fetchAssessments(vineyardId: String, visitIds: List<String>): List<AssessmentRow>

    suspend fun fetchObservations(
        vineyardId: String,
        assessmentIds: List<String>,
    ): List<ObservationRow>

    suspend fun fetchPhotos(vineyardId: String, observationIds: List<String>): List<PhotoRow>

    suspend fun fetchNotes(vineyardId: String, sinceIso: String?): List<NoteRow>

    // ----------------------------------------------------------------- RPCs

    suspend fun upsertNote(args: UpsertNoteArgs): NoteRow?

    suspend fun hardDeleteNote(id: String, vineyardId: String, operationId: String, atIso: String)

    suspend fun upsertNoteType(args: UpsertNoteTypeArgs)
}
