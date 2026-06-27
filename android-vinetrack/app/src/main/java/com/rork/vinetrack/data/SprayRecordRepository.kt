package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
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
 * Write path for spray records, mirroring the iOS spray sync contract
 * (`spray_records` table + `soft_delete_spray_record` RPC). RLS scopes
 * everything to the signed-in user's vineyard role: owner/manager/supervisor/
 * operator may insert and update; only owner/manager/supervisor may
 * soft-delete.
 *
 * Online-first — there is no local queue yet. The spray form is the sole editor
 * of these columns (including the `tanks` JSONB), so create/edit send the full
 * editable column set. `trip_id` is the only link field the schema supports
 * (there is no `work_task_id` on spray_records — iOS derives the task via the
 * linked trip), and it is user-editable from the form. `created_by` and the
 * server-managed sync columns are left untouched on edit.
 */
class SprayRecordRepository(private val session: SessionStore) {

    @Serializable
    private data class SprayInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val date: String,
        @SerialName("start_time") val startTime: String,
        val temperature: Double? = null,
        @SerialName("wind_speed") val windSpeed: Double? = null,
        @SerialName("wind_direction") val windDirection: String? = null,
        val humidity: Double? = null,
        @SerialName("spray_reference") val sprayReference: String? = null,
        val notes: String? = null,
        @SerialName("number_of_fans_jets") val numberOfFansJets: String? = null,
        @SerialName("average_speed") val averageSpeed: Double? = null,
        @SerialName("equipment_type") val equipmentType: String? = null,
        val tractor: String? = null,
        @SerialName("tractor_gear") val tractorGear: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("spray_equipment_id") val sprayEquipmentId: String? = null,
        @SerialName("operation_type") val operationType: String? = null,
        @SerialName("trip_id") val tripId: String? = null,
        @SerialName("is_template") val isTemplate: Boolean = false,
        val tanks: List<SprayTank> = emptyList(),
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /** Full edit of the form-owned columns (no trip/created_by/sync changes). */
    @Serializable
    private data class SprayPatch(
        val date: String,
        @SerialName("start_time") val startTime: String,
        val temperature: Double? = null,
        @SerialName("wind_speed") val windSpeed: Double? = null,
        @SerialName("wind_direction") val windDirection: String? = null,
        val humidity: Double? = null,
        @SerialName("spray_reference") val sprayReference: String? = null,
        val notes: String? = null,
        @SerialName("number_of_fans_jets") val numberOfFansJets: String? = null,
        @SerialName("average_speed") val averageSpeed: Double? = null,
        @SerialName("equipment_type") val equipmentType: String? = null,
        val tractor: String? = null,
        @SerialName("tractor_gear") val tractorGear: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("spray_equipment_id") val sprayEquipmentId: String? = null,
        @SerialName("operation_type") val operationType: String? = null,
        @SerialName("trip_id") val tripId: String? = null,
        @SerialName("is_template") val isTemplate: Boolean = false,
        val tanks: List<SprayTank> = emptyList(),
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_spray_record_id") val id: String)

    /** Fields the spray form edits, passed through both create and edit paths. */
    data class SprayInput(
        val date: String,
        val startTime: String,
        val temperature: Double?,
        val windSpeed: Double?,
        val windDirection: String?,
        val humidity: Double?,
        val sprayReference: String?,
        val notes: String?,
        val numberOfFansJets: String?,
        val averageSpeed: Double?,
        val equipmentType: String?,
        val tractor: String?,
        val tractorGear: String?,
        val machineId: String?,
        val sprayEquipmentId: String?,
        val operationType: String?,
        val tripId: String?,
        val isTemplate: Boolean = false,
        val tanks: List<SprayTank>,
    )

    fun nowIso(): String = Instant.now().toString()

    /** Generate a fresh client-side spray-record id (UUID). */
    fun newId(): String = UUID.randomUUID().toString()

    /**
     * Insert a spray record. When [id] / [clientUpdatedAt] are supplied (Android
     * Stage I-1 offline replay) the same id is shared by the optimistic local
     * row, the queued SPRAY_RECORD / CREATE marker, and the eventual server
     * insert, and the original save moment is preserved; re-running with the same
     * id is idempotent server-side (a duplicate primary key surfaces as a 409 the
     * create coordinator treats as success). The live online path passes neither
     * and gets a fresh id + `now`. `created_by` is always resolved from the
     * signed-in session, never carried in a queued payload.
     */
    suspend fun createSprayRecord(
        vineyardId: String,
        input: SprayInput,
        id: String = newId(),
        clientUpdatedAt: String? = null,
    ): SprayRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val now = clientUpdatedAt ?: nowIso()
            val body = SprayInsert(
                id = id,
                vineyardId = vineyardId,
                date = input.date,
                startTime = input.startTime,
                temperature = input.temperature,
                windSpeed = input.windSpeed,
                windDirection = input.windDirection,
                humidity = input.humidity,
                sprayReference = input.sprayReference,
                notes = input.notes,
                numberOfFansJets = input.numberOfFansJets,
                averageSpeed = input.averageSpeed,
                equipmentType = input.equipmentType,
                tractor = input.tractor,
                tractorGear = input.tractorGear,
                machineId = input.machineId,
                sprayEquipmentId = input.sprayEquipmentId,
                operationType = input.operationType,
                tripId = input.tripId,
                isTemplate = input.isTemplate,
                tanks = input.tanks,
                createdBy = session.userId,
                clientUpdatedAt = now,
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("spray_records")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /**
     * Patch the form-owned columns of a spray record. The live online edit path
     * passes no [clientUpdatedAt] and gets `now`; the Android Stage I-2 offline
     * replay path passes the moment the operator actually saved the edit so the
     * last-writer-wins stamp reflects the save, not the later sync. `created_by`,
     * `trip` ownership and the server-managed sync columns are never touched here.
     */
    suspend fun updateSprayRecord(
        id: String,
        input: SprayInput,
        clientUpdatedAt: String? = null,
    ): SprayRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = SprayPatch(
                date = input.date,
                startTime = input.startTime,
                temperature = input.temperature,
                windSpeed = input.windSpeed,
                windDirection = input.windDirection,
                humidity = input.humidity,
                sprayReference = input.sprayReference,
                notes = input.notes,
                numberOfFansJets = input.numberOfFansJets,
                averageSpeed = input.averageSpeed,
                equipmentType = input.equipmentType,
                tractor = input.tractor,
                tractorGear = input.tractorGear,
                machineId = input.machineId,
                sprayEquipmentId = input.sprayEquipmentId,
                operationType = input.operationType,
                tripId = input.tripId,
                isTemplate = input.isTemplate,
                tanks = input.tanks,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("spray_records?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    suspend fun softDeleteSprayRecord(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_spray_record")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): SprayRecord = when {
        response.status.isSuccess() -> response.body<List<SprayRecord>>().firstOrNull()
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
