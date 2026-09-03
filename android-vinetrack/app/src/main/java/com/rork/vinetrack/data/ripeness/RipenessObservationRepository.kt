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
    @SerialName("growth_stage_code") val growthStageCode: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val date: String? = null,
    @SerialName("completed_at") val completedAt: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("is_location_assigned") val isLocationAssigned: Boolean? = null,
) {
    /** Tagged as a remote source record for the adapter's merge. */
    fun sourceRecord(): ElRipenessObservationAdapter.SourceRecord =
        ElRipenessObservationAdapter.SourceRecord(
            record = ElRipenessHeatmap.RawRecord(
                id = id.lowercase(),
                vineyardId = vineyardId?.lowercase(),
                paddockId = paddockId?.lowercase(),
                stageCode = growthStageCode,
                latitude = latitude,
                longitude = longitude,
                date = date,
                completedAt = completedAt,
                createdAt = createdAt,
                deletedAt = deletedAt,
            ),
            origin = ElRipenessObservationAdapter.Origin.REMOTE,
            placementAssigned = isLocationAssigned,
        )
}

/** Seam so the view model and tests can swap the network out. */
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
                "&vineyard_id=eq.$vineyardId" +
                "&deleted_at=is.null"

            val response = SupabaseClient.http.get(url) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                    append("Accept", "application/json")
                }
            }
            if (!response.status.isSuccess()) {
                // Body is read for the status line only; never logged verbatim.
                response.bodyAsText()
                throw IllegalStateException("Observation fetch failed (${response.status.value})")
            }
            response.body()
        }

    private companion object {
        const val SELECT =
            "id,vineyard_id,paddock_id,growth_stage_code,latitude,longitude,date," +
                "completed_at,created_at,deleted_at,is_location_assigned"
    }
}
