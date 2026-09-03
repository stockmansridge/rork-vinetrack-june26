package com.rork.vinetrack.data.ripeness

import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One row of `v_growth_stage_observations`.
 *
 * Every field is optional and **every timestamp is a String**. That is
 * deliberate: the contract slices the first ten characters of the stored ISO
 * text with no timezone conversion, so parsing into a date type and
 * re-formatting would silently shift observations across the day boundary for
 * any vineyard that is not in UTC.
 */
@Serializable
data class RipenessObservationRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String? = null,
    @SerialName("paddock_id") val paddockId: String? = null,
    @SerialName("pin_id") val pinId: String? = null,
    @SerialName("stage_code") val stageCode: String? = null,
    @SerialName("stage_label") val stageLabel: String? = null,
    val variety: String? = null,
    @SerialName("variety_id") val varietyId: String? = null,
    @SerialName("observed_at") val observedAt: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("row_number") val rowNumber: Int? = null,
    val side: String? = null,
    val notes: String? = null,
    @SerialName("photo_paths") val photoPaths: List<String>? = null,
    @SerialName("recorded_by_name") val recordedByName: String? = null,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("updated_by") val updatedBy: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    val source: String? = null,
) {
    /** Tagged as a remote source record for the adapter's merge. */
    fun sourceRecord(): ElRipenessObservationAdapter.SourceRecord =
        ElRipenessObservationAdapter.SourceRecord(
            record = ElRipenessHeatmap.RawRecord(
                id = id.lowercase(),
                vineyardId = vineyardId?.lowercase(),
                paddockId = paddockId?.lowercase(),
                stageCode = stageCode,
                latitude = latitude,
                longitude = longitude,
                observedAt = observedAt,
                createdAt = createdAt,
            ),
            origin = ElRipenessObservationAdapter.Origin.REMOTE,
            placementAssigned = null,
            pinId = pinId?.lowercase(),
        )
}

/** Seam so the view model and tests can swap the network out. */
sealed class RipenessObservationRepositoryException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class Permission : RipenessObservationRepositoryException("You do not have permission to read growth-stage observations.")
    class Query(status: Int) : RipenessObservationRepositoryException("Growth-stage observation query failed ($status).")
    class Decoding(cause: Throwable) : RipenessObservationRepositoryException("Growth-stage observations could not be decoded.", cause)
}

interface RipenessObservationRepositoryProtocol {
    suspend fun fetchObservations(vineyardId: String): List<RipenessObservationRow>
}

/**
 * Read-only PostgREST reader for the heatmap.
 *
 * Scoped to one vineyard by query filter as well as by RLS — the contract
 * treats a record from another vineyard as `wrong_vineyard`, and the cheapest
 * way to honour that is to never fetch it. Deleted rows are filtered
 * server-side; the contract still re-checks `deleted_at` client-side because
 * the cache can hold a row that was deleted after it was written.
 */
class RipenessObservationRepository(
    private val session: SessionStore,
) : RipenessObservationRepositoryProtocol {

    override suspend fun fetchObservations(vineyardId: String): List<RipenessObservationRow> =
        withContext(Dispatchers.IO) {
            val token = session.accessToken ?: throw IllegalStateException("Not signed in")
            val url = "${SupabaseClient.baseUrl}/rest/v1/v_growth_stage_observations" +
                "?select=$SELECT" +
                "&vineyard_id=eq.$vineyardId"

            val response = SupabaseClient.http.get(url) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                    append("Accept", "application/json")
                }
            }
            if (!response.status.isSuccess()) {
                // Consume but never log the body: it may contain server detail.
                response.bodyAsText()
                if (response.status.value == 401 || response.status.value == 403) {
                    throw RipenessObservationRepositoryException.Permission()
                }
                throw RipenessObservationRepositoryException.Query(response.status.value)
            }
            try {
                response.body()
            } catch (error: Exception) {
                throw RipenessObservationRepositoryException.Decoding(error)
            }
        }

    private companion object {
        const val SELECT =
            "id,vineyard_id,paddock_id,pin_id,stage_code,stage_label,variety,variety_id," +
                "observed_at,latitude,longitude,row_number,side,notes,photo_paths," +
                "recorded_by_name,created_by,updated_by,created_at,updated_at,source"
    }
}
