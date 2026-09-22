package com.rork.vinetrack.data.material

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
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
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

/**
 * Supabase transport for Work Task Material Costs (sql/247) — the Android twin
 * of the iOS `SupabaseWorkTaskMaterialRepositories.swift`. Both platforms write
 * the SAME tables with the SAME payload shape, so costing never diverges.
 *
 * Three tables:
 *
 *  * `material_catalogue`   — READ ONLY. No write method exists here, and
 *    sql/247 refuses every client write regardless.
 *  * `vineyard_materials`   — read + merge-duplicates upsert + soft-delete RPC.
 *  * `work_task_materials`  — read + merge-duplicates upsert + soft-delete RPC.
 *
 * `work_task_materials.total_cost` is a GENERATED column and is deliberately
 * never sent: the server computes it from the quantity and unit cost in the
 * payload, so a client can never disagree with the stored total.
 *
 * No System Admin check appears in this file. Access is the ordinary
 * vineyard/work-task RLS contract; the temporary System-Admin-only exposure
 * lives solely in [WorkTaskMaterialCostsAccess].
 */
/**
 * The narrow write surface the offline replay coordinators depend on.
 *
 * Exists so [WorkTaskMaterialSync] and [VineyardMaterialSync] can be unit
 * tested on the JVM without an Android `Context` or a live Supabase client.
 * Production always uses [WorkTaskMaterialRepository].
 */
interface WorkTaskMaterialWriting {
    suspend fun upsertVineyardMaterial(
        id: String,
        vineyardId: String,
        baseMaterialId: String?,
        name: String,
        category: String,
        unit: String,
        defaultUnitCost: BigDecimal?,
        isCustom: Boolean,
        isActive: Boolean,
        clientUpdatedAt: String?,
    ): VineyardMaterial

    suspend fun softDeleteVineyardMaterial(id: String)

    suspend fun upsertTaskMaterial(
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String?,
    ): WorkTaskMaterial

    suspend fun softDeleteTaskMaterial(id: String)
}

class WorkTaskMaterialRepository(private val session: SessionStore) : WorkTaskMaterialWriting {

    // -----------------------------------------------------------------
    // Payloads
    // -----------------------------------------------------------------

    @Serializable
    private data class VineyardMaterialUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("base_material_id") val baseMaterialId: String? = null,
        val name: String,
        val category: String,
        val unit: String,
        @SerialName("default_unit_cost") val defaultUnitCost: String? = null,
        @SerialName("is_custom") val isCustom: Boolean,
        @SerialName("is_active") val isActive: Boolean,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_by") val updatedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class TaskMaterialUpsert(
        val id: String,
        @SerialName("work_task_id") val workTaskId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("base_material_id") val baseMaterialId: String? = null,
        @SerialName("vineyard_material_id") val vineyardMaterialId: String? = null,
        @SerialName("material_name") val materialName: String,
        val category: String,
        val unit: String,
        val quantity: String,
        @SerialName("unit_cost") val unitCost: String,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("updated_by") val updatedBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /** Stable client-generated id, minted BEFORE the network call. */
    fun newId(): String = UUID.randomUUID().toString()

    // -----------------------------------------------------------------
    // A. Base catalogue (read only)
    // -----------------------------------------------------------------

    /**
     * The global base catalogue. Readable by any authenticated user; it holds
     * no vineyard data and no prices.
     */
    suspend fun listCatalogue(): List<MaterialCatalogueItem> = withContext(Dispatchers.IO) {
        requireConfig()
        get("material_catalogue?select=*&order=sort_order.asc")
    }

    // -----------------------------------------------------------------
    // B. Vineyard material library
    // -----------------------------------------------------------------

    suspend fun listVineyardMaterials(vineyardId: String): List<VineyardMaterial> =
        withContext(Dispatchers.IO) {
            requireConfig()
            get("vineyard_materials?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
        }

    /**
     * Insert or update a library row (merge-duplicates on id, so a retried
     * write is idempotent). [clientUpdatedAt] defaults to now for the online
     * path; offline replay passes the original save moment so last-writer-wins
     * is preserved.
     */
    override suspend fun upsertVineyardMaterial(
        id: String,
        vineyardId: String,
        baseMaterialId: String?,
        name: String,
        category: String,
        unit: String,
        defaultUnitCost: BigDecimal?,
        isCustom: Boolean,
        isActive: Boolean,
        clientUpdatedAt: String?,
    ): VineyardMaterial = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = VineyardMaterialUpsert(
            id = id,
            vineyardId = vineyardId,
            // The database's `vineyard_materials_custom_shape` check requires a
            // custom row to carry NO base id and an override to carry one.
            baseMaterialId = if (isCustom) null else baseMaterialId,
            name = name.trim(),
            category = category,
            unit = MaterialUnitCatalog.normalised(unit),
            defaultUnitCost = defaultUnitCost?.let { MaterialMoney.wire(it.max(BigDecimal.ZERO)) },
            isCustom = isCustom,
            isActive = isActive,
            createdBy = session.userId,
            updatedBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("vineyard_materials?on_conflict=id"),
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() ->
                response.body<List<VineyardMaterial>>().firstOrNull()
                    ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Soft-delete a library row (owner/manager/supervisor via RLS).
     *
     * Deliberately does NOT touch `work_task_materials`: historical Work Task
     * usage survives, reading from its own snapshot.
     */
    override suspend fun softDeleteVineyardMaterial(id: String) {
        withContext(Dispatchers.IO) {
            requireConfig()
            rpcSoftDelete("soft_delete_vineyard_material", id)
        }
    }

    // -----------------------------------------------------------------
    // C. Work Task material lines
    // -----------------------------------------------------------------

    /** All active material lines of ONE task. */
    suspend fun listTaskMaterials(workTaskId: String): List<WorkTaskMaterial> =
        withContext(Dispatchers.IO) {
            requireConfig()
            get("work_task_materials?select=*&work_task_id=eq.$workTaskId&deleted_at=is.null&order=created_at.asc")
        }

    /** All active material lines for a vineyard — backs later roll-ups. */
    suspend fun listTaskMaterialsForVineyard(vineyardId: String): List<WorkTaskMaterial> =
        withContext(Dispatchers.IO) {
            requireConfig()
            get("work_task_materials?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=created_at.asc")
        }

    /**
     * Insert or update a material line (merge-duplicates on id).
     *
     * The snapshot fields are sent verbatim — this is what freezes the material
     * name, unit, quantity and unit cost onto the task. `total_cost` is NOT
     * sent: it is generated server-side from the quantity and unit cost here.
     */
    override suspend fun upsertTaskMaterial(
        id: String,
        workTaskId: String,
        vineyardId: String,
        baseMaterialId: String?,
        vineyardMaterialId: String?,
        materialName: String,
        category: String,
        unit: String,
        quantity: BigDecimal,
        unitCost: BigDecimal,
        notes: String?,
        clientUpdatedAt: String?,
    ): WorkTaskMaterial = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = TaskMaterialUpsert(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            baseMaterialId = baseMaterialId,
            vineyardMaterialId = vineyardMaterialId,
            materialName = materialName.trim(),
            category = category,
            unit = MaterialUnitCatalog.normalised(unit),
            quantity = MaterialMoney.wire(quantity.max(BigDecimal.ZERO)),
            unitCost = MaterialMoney.wire(unitCost.max(BigDecimal.ZERO)),
            notes = notes ?: "",
            createdBy = session.userId,
            updatedBy = session.userId,
            clientUpdatedAt = clientUpdatedAt ?: nowIso(),
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("work_task_materials?on_conflict=id"),
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() ->
                response.body<List<WorkTaskMaterial>>().firstOrNull()
                    ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Soft-delete a material line (owner/manager/supervisor via the RPC). */
    override suspend fun softDeleteTaskMaterial(id: String) {
        withContext(Dispatchers.IO) {
            requireConfig()
            rpcSoftDelete("soft_delete_work_task_material", id)
        }
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

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

    private suspend inline fun <reified T> get(path: String): T {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) { authHeaders(token) }
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

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
