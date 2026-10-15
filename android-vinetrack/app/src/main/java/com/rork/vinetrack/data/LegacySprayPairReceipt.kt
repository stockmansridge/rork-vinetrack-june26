package com.rork.vinetrack.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.auth.AuthRetentionGuard

/** Only the authenticated recovery RPC can verify PostgreSQL JSONB fingerprints for an exact frozen body. */
object LegacySprayPairReceipt {
    private val strict = Json { ignoreUnknownKeys = true }
    @Serializable data class Request(val operation: String, val trip: JsonObject, val record: JsonObject) {
        fun body(): JsonObject = buildJsonObject {
            put("p_operation_id", operation); put("p_trip", trip); put("p_record", record)
        }
    }
    @Serializable data class Receipt(
        val version: Int, val status: String, val operation_id: String? = null,
        val vineyard_id: String? = null, val trip_id: String? = null, val spray_record_id: String? = null,
        val request_sha256: String? = null, val committed_at: String? = null, val code: String? = null,
    ) {
        fun validate(item: LegacySpraySaveStore.Attempt) {
            check(version == 1 && status in listOf("accepted", "rejected") &&
                operation_id == item.rpc?.operation && vineyard_id == item.trip.vineyardId &&
                trip_id == item.trip.id && spray_record_id == item.recordId &&
                request_sha256?.matches(Regex("[0-9a-f]{64}")) == true &&
                runCatching { java.time.Instant.parse(committed_at) }.isSuccess &&
                (if (status == "accepted") code == null else code in listOf("identity_conflict", "validation_or_reference_conflict"))) { LegacySpraySaveStore.MESSAGE }
        }
    }
    fun decode(raw: String): Receipt = strict.decodeFromString(Receipt.serializer(), raw)
    val tripKeys = "id vineyard_id paddock_id paddock_ids paddock_name tracking_pattern start_time is_active is_paused person_name trip_function trip_title machine_id tractor_id work_task_id operator_user_id worker_type_id total_distance path_points start_engine_hours seeding_details row_sequence sequence_index current_row_number next_row_number total_tanks created_by client_updated_at".split(" ").toSet()
    val recordKeys = "id vineyard_id date start_time temperature wind_speed wind_direction humidity spray_reference notes number_of_fans_jets average_speed equipment_type tractor tractor_gear machine_id tractor_id spray_equipment_id operation_type trip_id spray_job_id is_template tanks gross_area_ha treated_area_ha application_mode treated_area_method band_width_total_metres band_width_left_metres band_width_right_metres canonical_row_length_metres row_spacing_metres geometry_source geometry_quality carrier_volume_basis total_carrier_litres carrier_litres_per_hectare dilute_litres_per_100m applied_litres_per_100m concentration_factor targets spray_head_target ground_application_target carrier_area_basis application_blocks entry_source created_by client_updated_at".split(" ").toSet()
    fun prepare(trip: JsonObject, record: JsonObject): Request {
        check(trip.keys.all { it in tripKeys } && record.keys.all { it in recordKeys }) {
            "Legacy receipt v1 does not admit this mix's fields. Original evidence retained; no fields were discarded or sent."
        }
        return Request(java.util.UUID.randomUUID().toString(), trip, record)
    }
    suspend fun transport(session: SessionStore, access: AuthRetentionGuard.AccountAccess, rpc: String, request: Request): Receipt {
        check(session.isAccountAccessCurrent(access))
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("rpc/$rpc")) {
            attributes.put(SupabaseClient.accountRequestScope, access)
            header("Authorization", "Bearer $token"); header("apikey", SupabaseClient.anonKey)
            contentType(ContentType.Application.Json); setBody(request.body())
        }
        check(session.isAccountAccessCurrent(access))
        if (response.status.value == 401) throw BackendError.Unauthorized
        check(response.status.isSuccess()) { LegacySpraySaveStore.MESSAGE }
        return decode(response.bodyAsText())
    }
}
