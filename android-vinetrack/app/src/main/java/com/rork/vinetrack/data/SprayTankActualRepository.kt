package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayTankActual
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Dedicated idempotent RPC boundary for confirmed actual tank contents. */
class SprayTankActualRepository(private val session: SessionStore) {
    @Serializable private data class Request(
        @SerialName("p_id") val id: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_spray_record_id") val sprayRecordId: String,
        @SerialName("p_trip_id") val tripId: String,
        @SerialName("p_tank_session_id") val tankSessionId: String,
        @SerialName("p_tank_number") val tankNumber: Int,
        @SerialName("p_water_volume_l") val waterVolumeL: Double,
        @SerialName("p_chemicals") val chemicals: List<com.rork.vinetrack.data.model.SprayTankActualChemical>,
        @SerialName("p_confirmed_at") val confirmedAt: String,
        @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    )

    suspend fun fetch(vineyardId: String): List<SprayTankActual> {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl("spray_tank_actuals")) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $token")
                append("apikey", SupabaseClient.anonKey)
            }
            parameter("select", "id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,water_volume_l,chemicals,confirmed_at,confirmed_by,client_updated_at")
            parameter("vineyard_id", "eq.$vineyardId")
            parameter("deleted_at", "is.null")
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return SupabaseClient.json.decodeFromString(response.bodyAsText())
    }

    suspend fun upsert(actual: SprayTankActual) {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_spray_tank_actual")) {
            headers {
                append(HttpHeaders.Authorization, "Bearer $token")
                append("apikey", SupabaseClient.anonKey)
            }
            contentType(ContentType.Application.Json)
            setBody(Request(actual.id, actual.vineyardId, actual.sprayRecordId, actual.tripId,
                actual.tankSessionId, actual.tankNumber, actual.waterVolumeL, actual.chemicals,
                actual.confirmedAt, actual.clientUpdatedAt))
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
    }
}
