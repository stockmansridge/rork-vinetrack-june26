package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.statement.HttpResponse
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
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID

/**
 * Write path for work-task costing lines, mirroring the iOS canonical contract:
 * `work_task_labour_lines` (sql/050) and `work_task_machine_lines` (sql/103).
 *
 * These are the authoritative line tables iOS writes — Android writes the same
 * tables (NOT the legacy `resources` JSONB) so costing stays consistent across
 * platforms. `total_hours`/`total_cost` on labour lines are DB-generated, so we
 * only send the inputs and read computed values back. Soft-delete goes through
 * the `soft_delete_work_task_*_line` RPCs (owner/manager/supervisor only);
 * inserts/updates follow the standard vineyard-membership RLS. Online-first —
 * no local queue yet.
 */
class WorkTaskLineRepository(private val session: SessionStore) {

    // MARK: - Labour lines

    @Serializable
    private data class LabourLineUpsert(
        val id: String,
        @SerialName("work_task_id") val workTaskId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("work_date") val workDate: String,
        @SerialName("operator_category_id") val operatorCategoryId: String? = null,
        @SerialName("worker_type") val workerType: String,
        @SerialName("worker_count") val workerCount: Int,
        @SerialName("hours_per_worker") val hoursPerWorker: Double,
        @SerialName("hourly_rate") val hourlyRate: Double? = null,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_by") val updatedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    suspend fun listLabourLines(workTaskId: String): List<WorkTaskLabourLine> = withContext(Dispatchers.IO) {
        requireConfig()
        get("work_task_labour_lines?select=*&work_task_id=eq.$workTaskId&deleted_at=is.null&order=work_date.asc")
    }

    /** Stable client-generated id for a new labour line, minted before the network call. */
    fun newLineId(): String = UUID.randomUUID().toString()

    /**
     * Insert or update a labour line (id present = update). Returns the row with
     * DB-computed totals. [clientUpdatedAt] defaults to now for the online path;
     * offline replay passes the original moment the operator saved the line so
     * last-writer-wins is preserved.
     */
    suspend fun upsertLabourLine(
        id: String?,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        operatorCategoryId: String?,
        workerType: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        notes: String?,
        clientUpdatedAt: String? = null,
    ): WorkTaskLabourLine = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = LabourLineUpsert(
            id = id ?: UUID.randomUUID().toString(),
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            workDate = dateOnly(workDate),
            operatorCategoryId = operatorCategoryId,
            workerType = workerType.trim(),
            workerCount = workerCount.coerceAtLeast(0),
            hoursPerWorker = hoursPerWorker.coerceAtLeast(0.0),
            hourlyRate = hourlyRate,
            notes = notes ?: "",
            createdBy = session.userId,
            updatedBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("work_task_labour_lines")) {
            authHeaders(token)
            headers {
                append("Prefer", "resolution=merge-duplicates,return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        firstLabour(response)
    }

    suspend fun deleteLabourLine(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        rpcSoftDelete("soft_delete_work_task_labour_line", id)
    }

    // MARK: - Machine lines

    @Serializable
    private data class MachineLineUpsert(
        val id: String,
        @SerialName("work_task_id") val workTaskId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("work_date") val workDate: String,
        @SerialName("equipment_source") val equipmentSource: String? = null,
        @SerialName("equipment_ref_id") val equipmentRefId: String? = null,
        @SerialName("equipment_name_snapshot") val equipmentNameSnapshot: String,
        @SerialName("operator_user_id") val operatorUserId: String? = null,
        @SerialName("operator_category_id") val operatorCategoryId: String? = null,
        @SerialName("duration_hours") val durationHours: Double? = null,
        @SerialName("fuel_litres") val fuelLitres: Double? = null,
        @SerialName("fuel_cost") val fuelCost: Double? = null,
        @SerialName("hourly_machine_rate") val hourlyMachineRate: Double? = null,
        @SerialName("total_machine_cost") val totalMachineCost: Double? = null,
        @SerialName("entry_source") val entrySource: String = "manual",
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_by") val updatedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    suspend fun listMachineLines(workTaskId: String): List<WorkTaskMachineLine> = withContext(Dispatchers.IO) {
        requireConfig()
        get("work_task_machine_lines?select=*&work_task_id=eq.$workTaskId&deleted_at=is.null&order=work_date.asc")
    }

    /**
     * Insert or update a machine line (id present = update). Returns the saved
     * row. [clientUpdatedAt] defaults to now for the online path; offline replay
     * passes the original moment the operator saved the line so last-writer-wins
     * is preserved.
     */
    suspend fun upsertMachineLine(
        id: String?,
        workTaskId: String,
        vineyardId: String,
        workDate: String,
        equipmentRefId: String?,
        equipmentNameSnapshot: String,
        operatorCategoryId: String?,
        durationHours: Double?,
        fuelLitres: Double?,
        fuelCost: Double?,
        hourlyMachineRate: Double?,
        totalMachineCost: Double?,
        notes: String?,
        clientUpdatedAt: String? = null,
    ): WorkTaskMachineLine = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        // `vineyard_machine` is the canonical source for linked equipment;
        // unlinked entries use the free-text snapshot (matches iOS).
        val source = if (equipmentRefId != null) "vineyard_machine" else "free_text"
        val body = MachineLineUpsert(
            id = id ?: UUID.randomUUID().toString(),
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            workDate = dateOnly(workDate),
            equipmentSource = source,
            equipmentRefId = equipmentRefId,
            equipmentNameSnapshot = equipmentNameSnapshot.trim(),
            operatorCategoryId = operatorCategoryId,
            durationHours = durationHours,
            fuelLitres = fuelLitres,
            fuelCost = fuelCost,
            hourlyMachineRate = hourlyMachineRate,
            totalMachineCost = totalMachineCost,
            entrySource = "manual",
            notes = notes ?: "",
            createdBy = session.userId,
            updatedBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("work_task_machine_lines")) {
            authHeaders(token)
            headers {
                append("Prefer", "resolution=merge-duplicates,return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        firstMachine(response)
    }

    suspend fun deleteMachineLine(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        rpcSoftDelete("soft_delete_work_task_machine_line", id)
    }

    // MARK: - Helpers

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private suspend fun rpcSoftDelete(rpc: String, id: String) {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
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

    private suspend fun firstLabour(response: HttpResponse): WorkTaskLabourLine = when {
        response.status.isSuccess() -> response.body<List<WorkTaskLabourLine>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private suspend fun firstMachine(response: HttpResponse): WorkTaskMachineLine = when {
        response.status.isSuccess() -> response.body<List<WorkTaskMachineLine>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private suspend inline fun <reified T> get(path: String): T {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
            authHeaders(token)
        }
        return when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun nowIso(): String = Instant.now().toString()

    /** Reduce an ISO timestamp (or date) to the `yyyy-MM-dd` form the SQL `date` column expects. */
    private fun dateOnly(value: String): String = try {
        if (value.length >= 10 && value[4] == '-' && value[7] == '-') {
            value.substring(0, 10)
        } else {
            LocalDate.ofInstant(Instant.parse(value), ZoneOffset.UTC).toString()
        }
    } catch (_: Exception) {
        LocalDate.now().toString()
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
