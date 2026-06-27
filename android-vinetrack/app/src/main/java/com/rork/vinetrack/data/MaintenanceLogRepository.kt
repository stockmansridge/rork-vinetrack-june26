package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.MaintenanceLog
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
 * Write path for maintenance logs, mirroring the iOS maintenance sync contract
 * (`maintenance_logs` table + `soft_delete_maintenance_log` RPC). RLS scopes
 * everything to the signed-in user's vineyard role.
 *
 * Online-first — there is no local queue yet. The maintenance form is the sole
 * editor of these columns, so create/edit send the editable column set.
 * `item_name` is the authoritative display snapshot; `equipment_source` +
 * `equipment_ref_id` carry the optional stable link. Photo upload is deferred,
 * so `photo_path` is left untouched. `created_by` and server-managed sync
 * columns are left untouched on edit.
 */
class MaintenanceLogRepository(private val session: SessionStore) {

    @Serializable
    private data class MaintenanceInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("item_name") val itemName: String,
        @SerialName("equipment_source") val equipmentSource: String? = null,
        @SerialName("equipment_ref_id") val equipmentRefId: String? = null,
        val hours: Double = 0.0,
        @SerialName("machine_hours") val machineHours: Double? = null,
        @SerialName("work_completed") val workCompleted: String = "",
        @SerialName("parts_used") val partsUsed: String = "",
        @SerialName("parts_cost") val partsCost: Double = 0.0,
        @SerialName("labour_cost") val labourCost: Double = 0.0,
        val date: String,
        @SerialName("is_archived") val isArchived: Boolean = false,
        @SerialName("is_finalized") val isFinalized: Boolean = false,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class MaintenancePatch(
        @SerialName("item_name") val itemName: String,
        @SerialName("equipment_source") val equipmentSource: String? = null,
        @SerialName("equipment_ref_id") val equipmentRefId: String? = null,
        val hours: Double = 0.0,
        @SerialName("machine_hours") val machineHours: Double? = null,
        @SerialName("work_completed") val workCompleted: String = "",
        @SerialName("parts_used") val partsUsed: String = "",
        @SerialName("parts_cost") val partsCost: Double = 0.0,
        @SerialName("labour_cost") val labourCost: Double = 0.0,
        val date: String,
        @SerialName("is_archived") val isArchived: Boolean = false,
        @SerialName("is_finalized") val isFinalized: Boolean = false,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class PhotoPatch(@SerialName("photo_path") val photoPath: String?)

    /** Fields the maintenance form edits, shared by create and edit paths. */
    data class MaintenanceInput(
        val itemName: String,
        val equipmentSource: String?,
        val equipmentRefId: String?,
        val hours: Double,
        val machineHours: Double?,
        val workCompleted: String,
        val partsUsed: String,
        val partsCost: Double,
        val labourCost: Double,
        val date: String,
        val isArchived: Boolean = false,
        val isFinalized: Boolean = false,
    )

    private fun nowIso(): String = Instant.now().toString()

    /** Mint a stable maintenance-log id up front so the optimistic row, the
     *  queued create marker, and the eventual server insert all share one id. */
    fun newId(): String = UUID.randomUUID().toString()

    /**
     * Insert a maintenance log. Default online behaviour is unchanged: when [id]
     * is null a fresh UUID is minted, and when [clientUpdatedAt] is null the
     * current instant is used. Offline replay ([MaintenanceLogCreateSync]) passes
     * the original client-generated [id] and [clientUpdatedAt] so a retried
     * insert is idempotent and preserves the moment the operator saved it.
     * `created_by` always resolves from the live session, never from a payload;
     * `photo_path` is never sent or mutated here.
     */
    suspend fun createMaintenanceLog(
        vineyardId: String,
        input: MaintenanceInput,
        id: String? = null,
        clientUpdatedAt: String? = null,
    ): MaintenanceLog =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = MaintenanceInsert(
                id = id ?: UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                itemName = input.itemName,
                equipmentSource = input.equipmentSource,
                equipmentRefId = input.equipmentRefId,
                hours = input.hours,
                machineHours = input.machineHours,
                workCompleted = input.workCompleted,
                partsUsed = input.partsUsed,
                partsCost = input.partsCost,
                labourCost = input.labourCost,
                date = input.date,
                isArchived = input.isArchived,
                isFinalized = input.isFinalized,
                createdBy = session.userId,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("maintenance_logs")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /**
     * Patch a maintenance log. Default online behaviour is unchanged: when
     * [clientUpdatedAt] is null the current instant is used. Offline replay
     * ([MaintenanceLogUpdateSync]) passes the original client_updated_at the
     * operator saved the edit at (last-writer-wins stamp). `created_by`,
     * `photo_path` and server-managed audit/sync columns are never sent or
     * mutated here.
     */
    suspend fun updateMaintenanceLog(
        id: String,
        input: MaintenanceInput,
        clientUpdatedAt: String? = null,
    ): MaintenanceLog =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = MaintenancePatch(
                itemName = input.itemName,
                equipmentSource = input.equipmentSource,
                equipmentRefId = input.equipmentRefId,
                hours = input.hours,
                machineHours = input.machineHours,
                workCompleted = input.workCompleted,
                partsUsed = input.partsUsed,
                partsCost = input.partsCost,
                labourCost = input.labourCost,
                date = input.date,
                isArchived = input.isArchived,
                isFinalized = input.isFinalized,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("maintenance_logs?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    /**
     * Set or clear a maintenance log's `photo_path` after an invoice-photo
     * upload/removal. Only the storage reference changes — the editable form
     * columns and server-managed audit/sync columns are untouched. Returns the
     * refreshed row.
     */
    suspend fun updatePhotoPath(id: String, photoPath: String?): MaintenanceLog = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("maintenance_logs?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(PhotoPatch(photoPath))
        }
        firstRow(response)
    }

    suspend fun softDeleteMaintenanceLog(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_maintenance_log")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): MaintenanceLog = when {
        response.status.isSuccess() -> response.body<List<MaintenanceLog>>().firstOrNull()
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
