package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import java.time.Instant

/**
 * Focused write path for paddock/block phenology milestone dates, mirroring the
 * iOS `paddocks` contract (`budburst_date`, `flowering_date`, `veraison_date`,
 * `harvest_date` — nullable `timestamptz`). RLS `paddocks_update_members` allows
 * update for owner/manager/supervisor/operator.
 *
 * Unlike the iOS full-row upsert, Android sends a **partial PATCH** containing
 * only the four phenology columns, so geometry, rows, variety allocations, area,
 * and other paddock metadata are never touched. Cleared dates are sent as an
 * explicit JSON `null` (the shared client uses `explicitNulls = false`, so a
 * hand-built `JsonObject` is used to guarantee nulls are transmitted).
 */
class PaddockRepository(private val session: SessionStore) {

    /** The four editable phenology milestone dates as ISO-8601 strings (null = cleared). */
    data class PhenologyDates(
        val budburstDate: String?,
        val floweringDate: String?,
        val veraisonDate: String?,
        val harvestDate: String?,
    )

    /**
     * PATCH only the phenology date columns for [paddockId]. Returns the updated
     * paddock row so callers can reconcile state with the server-resolved values.
     */
    suspend fun updatePhenologyDates(paddockId: String, dates: PhenologyDates): Paddock =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body: JsonObject = buildJsonObject {
                put("budburst_date", dates.budburstDate?.let { JsonPrimitive(it) } ?: JsonNull)
                put("flowering_date", dates.floweringDate?.let { JsonPrimitive(it) } ?: JsonNull)
                put("veraison_date", dates.veraisonDate?.let { JsonPrimitive(it) } ?: JsonNull)
                put("harvest_date", dates.harvestDate?.let { JsonPrimitive(it) } ?: JsonNull)
                put("client_updated_at", JsonPrimitive(Instant.now().toString()))
            }
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("paddocks?id=eq.$paddockId")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                    append("Prefer", "return=representation")
                }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /**
     * PATCH only the `variety_allocations` JSONB column for [paddockId]. Used by
     * the Optimal Ripeness "Fix Block Varieties" sheet so correcting a block's
     * variety doesn't have to round-trip the whole row (and risk recomputing
     * rows). Returns the server-resolved row.
     */
    suspend fun updateVarietyAllocations(
        paddockId: String,
        allocations: List<PaddockVarietyAllocation>,
    ): Paddock = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body: JsonObject = buildJsonObject {
            put("variety_allocations", allocationArray(allocations))
            put("client_updated_at", JsonPrimitive(Instant.now().toString()))
        }
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("paddocks?id=eq.$paddockId")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
                append("Prefer", "return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    /**
     * Full-row upsert of a block, mirroring the iOS `BackendPaddockUpsert`
     * contract (`upsert(..., onConflict: "id")`). Sends every editable column
     * including the `polygon_points`, `rows`, and `variety_allocations` JSONB
     * payloads in the exact camelCase nested shape iOS/portal read back. Used
     * for both create (new id) and edit (existing id). Returns the
     * server-resolved row.
     *
     * Nested nulls are emitted explicitly via a hand-built [JsonObject] because
     * the shared client uses `explicitNulls = false`.
     */
    suspend fun upsertPaddock(paddock: Paddock, createdBy: String?): Paddock =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body: JsonObject = buildJsonObject {
                put("id", JsonPrimitive(paddock.id))
                put("vineyard_id", JsonPrimitive(paddock.vineyardId))
                put("name", JsonPrimitive(paddock.name))
                put("row_direction", paddock.rowDirection.toJson())
                put("row_width", paddock.rowWidth.toJson())
                put("row_offset", paddock.rowOffset.toJson())
                put("vine_spacing", paddock.vineSpacing.toJson())
                put("vine_count_override", paddock.vineCountOverride.toJson())
                put("row_length_override", paddock.rowLengthOverride.toJson())
                put("flow_per_emitter", paddock.flowPerEmitter.toJson())
                put("emitter_spacing", paddock.emitterSpacing.toJson())
                put("intermediate_post_spacing", paddock.intermediatePostSpacing.toJson())
                put("budburst_date", paddock.budburstDate.toJson())
                put("flowering_date", paddock.floweringDate.toJson())
                put("veraison_date", paddock.veraisonDate.toJson())
                put("harvest_date", paddock.harvestDate.toJson())
                put("planting_year", paddock.plantingYear.toJson())
                put("calculation_mode_override", paddock.calculationModeOverride.toJson())
                put("reset_mode_override", paddock.resetModeOverride.toJson())
                put("polygon_points", coordinateArray(paddock.polygonPoints))
                put("rows", rowArray(paddock.rows))
                put("variety_allocations", allocationArray(paddock.varietyAllocations))
                put("created_by", createdBy?.let { JsonPrimitive(it) } ?: JsonNull)
                put("client_updated_at", JsonPrimitive(Instant.now().toString()))
            }
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("paddocks")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                    append("Prefer", "resolution=merge-duplicates,return=representation")
                }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /** Soft-delete (archive) a block via the `soft_delete_paddock` RPC. */
    suspend fun softDeletePaddock(id: String) = withContext(Dispatchers.IO) {
        rpcDelete("soft_delete_paddock", id)
    }

    /**
     * Permanently delete a block via the `hard_delete_paddock` RPC. The server
     * enforces that no linked records remain (`total_references == 0`).
     */
    suspend fun hardDeletePaddock(id: String) = withContext(Dispatchers.IO) {
        rpcDelete("hard_delete_paddock", id)
    }

    /**
     * Active-row reference counts for a block across every linked table
     * (`paddock_reference_counts` RPC). Used to decide whether a permanent
     * delete is safe before offering it.
     */
    suspend fun paddockReferenceCounts(id: String): PaddockReferenceCounts =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("paddock_reference_counts")) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject { put("p_paddock_id", JsonPrimitive(id)) })
            }
            when {
                response.status.isSuccess() ->
                    response.body<List<PaddockReferenceCounts>>().firstOrNull()
                        ?: PaddockReferenceCounts()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private suspend fun rpcDelete(rpc: String, id: String) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject { put("p_paddock_id", JsonPrimitive(id)) })
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun Double?.toJson(): JsonElement = this?.let { JsonPrimitive(it) } ?: JsonNull
    private fun Int?.toJson(): JsonElement = this?.let { JsonPrimitive(it) } ?: JsonNull
    private fun String?.toJson(): JsonElement = this?.let { JsonPrimitive(it) } ?: JsonNull

    private fun coordinateArray(points: List<CoordinatePoint>?): JsonArray = buildJsonArray {
        points.orEmpty().forEach { p ->
            add(buildJsonObject {
                put("latitude", JsonPrimitive(p.latitude))
                put("longitude", JsonPrimitive(p.longitude))
            })
        }
    }

    private fun coordinateObject(point: CoordinatePoint?): JsonElement =
        if (point == null) JsonNull else buildJsonObject {
            put("latitude", JsonPrimitive(point.latitude))
            put("longitude", JsonPrimitive(point.longitude))
        }

    private fun rowArray(rows: List<PaddockRow>?): JsonArray = buildJsonArray {
        rows.orEmpty().forEach { row ->
            add(buildJsonObject {
                // Preserve the stable row id — pruning progress is keyed on it.
                // Legacy rows without one get the deterministic fallback id
                // (identical on iOS), so the identity persists from now on.
                put("id", JsonPrimitive(row.stableId))
                put("number", JsonPrimitive(row.number))
                put("startPoint", coordinateObject(row.startPoint))
                put("endPoint", coordinateObject(row.endPoint))
            })
        }
    }

    private fun allocationArray(allocations: List<PaddockVarietyAllocation>?): JsonArray = buildJsonArray {
        allocations.orEmpty().forEach { a ->
            add(buildJsonObject {
                a.varietyKey?.let { put("varietyKey", JsonPrimitive(it)) }
                a.varietyId?.let { put("varietyId", JsonPrimitive(it)) }
                a.name?.let { put("name", JsonPrimitive(it)) }
                a.percent?.let { put("percent", JsonPrimitive(it)) }
                a.clone?.let { put("clone", JsonPrimitive(it)) }
                a.rootstock?.let { put("rootstock", JsonPrimitive(it)) }
            })
        }
    }

    private suspend fun firstRow(response: HttpResponse): Paddock = when {
        response.status.isSuccess() -> response.body<List<Paddock>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }
}

/**
 * Active-row reference counts for a block across linked tables, mirroring the
 * iOS `PaddockReferenceCounts`. Returned by the `paddock_reference_counts` RPC;
 * a permanent delete is only offered when [totalReferences] is zero.
 */
@Serializable
data class PaddockReferenceCounts(
    val pins: Int = 0,
    val trips: Int = 0,
    @SerialName("trip_cost_allocations") val tripCostAllocations: Int = 0,
    @SerialName("work_tasks") val workTasks: Int = 0,
    @SerialName("work_task_paddocks") val workTaskPaddocks: Int = 0,
    @SerialName("damage_records") val damageRecords: Int = 0,
    @SerialName("growth_stage_records") val growthStageRecords: Int = 0,
    @SerialName("spray_job_paddocks") val sprayJobPaddocks: Int = 0,
    @SerialName("paddock_soil_profiles") val paddockSoilProfiles: Int = 0,
    @SerialName("total_references") val totalReferences: Int = 0,
) {
    val isEmpty: Boolean get() = totalReferences == 0

    /** Human-readable breakdown, omitting zero counts (mirrors iOS summaryLines). */
    val summaryLines: List<String>
        get() {
            val lines = mutableListOf<String>()
            fun add(n: Int, singular: String, plural: String) {
                if (n > 0) lines.add("$n ${if (n == 1) singular else plural}")
            }
            add(pins, "pin", "pins")
            add(trips, "trip", "trips")
            add(tripCostAllocations, "trip cost allocation", "trip cost allocations")
            add(workTasks, "work/task log", "work/task logs")
            add(workTaskPaddocks, "work-task link", "work-task links")
            add(damageRecords, "damage record", "damage records")
            add(growthStageRecords, "growth-stage record", "growth-stage records")
            add(sprayJobPaddocks, "spray job link", "spray job links")
            add(paddockSoilProfiles, "soil profile", "soil profiles")
            return lines
        }
}
