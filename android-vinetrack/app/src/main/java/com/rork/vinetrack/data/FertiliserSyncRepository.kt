package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.FertiliserAllocation
import com.rork.vinetrack.data.model.FertiliserRecord
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
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
import java.time.OffsetDateTime

/**
 * Supabase data layer for the Fertiliser Calculator, mirroring the iOS
 * `SupabaseFertiliserSyncRepository` contract (sql/110 + sql/111):
 * merge-duplicates upserts keyed by the client-generated id for
 * `fertiliser_records` and the per-block `fertiliser_record_allocations`
 * child rows; soft deletes via security-definer RPCs. The product library is
 * the shared `saved_chemicals` table, handled by [SavedChemicalRepository].
 */
class FertiliserSyncRepository(private val session: SessionStore) {

    @Serializable
    data class RecordRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("product_id") val productId: String? = null,
        @SerialName("product_name") val productName: String? = null,
        val form: String? = null,
        @SerialName("calculation_mode") val calculationMode: String? = null,
        @SerialName("record_status") val recordStatus: String? = null,
        @SerialName("application_date") val applicationDate: String? = null,
        @SerialName("block_names") val blockNames: List<String> = emptyList(),
        @SerialName("total_area_ha") val totalAreaHa: Double? = null,
        @SerialName("total_vines") val totalVines: Int? = null,
        @SerialName("application_rate") val applicationRate: Double? = null,
        @SerialName("total_product_required") val totalProductRequired: Double? = null,
        @SerialName("pack_size") val packSize: Double? = null,
        @SerialName("estimated_product_cost") val estimatedProductCost: Double? = null,
        @SerialName("labour_cost") val labourCost: Double? = null,
        val notes: String? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    ) {
        fun toModel(allocations: List<FertiliserAllocation>): FertiliserRecord = FertiliserRecord(
            id = id,
            vineyardId = vineyardId,
            date = applicationDate?.take(10) ?: createdAt?.take(10) ?: LocalDate.now().toString(),
            status = recordStatus ?: "planned",
            mode = calculationMode ?: "perHectare",
            productId = productId,
            productName = productName.orEmpty(),
            form = form ?: "solid",
            paddockIds = allocations.map { it.paddockId },
            blockNames = blockNames,
            areaHectares = totalAreaHa ?: 0.0,
            vineCount = totalVines ?: 0,
            rate = applicationRate ?: 0.0,
            totalProduct = totalProductRequired ?: 0.0,
            packSize = packSize,
            productCost = estimatedProductCost,
            labourMachineryCost = labourCost,
            notes = notes.orEmpty(),
            allocations = allocations,
            createdAtMs = runCatching {
                OffsetDateTime.parse(createdAt).toInstant().toEpochMilli()
            }.getOrDefault(0L),
        )
    }

    @Serializable
    private data class RecordUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("product_id") val productId: String? = null,
        @SerialName("product_name") val productName: String,
        val form: String,
        @SerialName("calculation_mode") val calculationMode: String,
        @SerialName("record_status") val recordStatus: String,
        @SerialName("application_date") val applicationDate: String,
        @SerialName("block_names") val blockNames: List<String>,
        @SerialName("total_area_ha") val totalAreaHa: Double,
        @SerialName("total_vines") val totalVines: Int,
        @SerialName("application_rate") val applicationRate: Double,
        @SerialName("application_rate_unit") val applicationRateUnit: String,
        @SerialName("total_product_required") val totalProductRequired: Double,
        @SerialName("product_unit") val productUnit: String,
        @SerialName("pack_size") val packSize: Double? = null,
        @SerialName("pack_count") val packCount: Double? = null,
        @SerialName("estimated_product_cost") val estimatedProductCost: Double? = null,
        @SerialName("labour_cost") val labourCost: Double? = null,
        @SerialName("total_job_cost") val totalJobCost: Double? = null,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    data class AllocationRow(
        val id: String,
        @SerialName("fertiliser_record_id") val fertiliserRecordId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("area_ha") val areaHa: Double? = null,
        @SerialName("vine_count") val vineCount: Int? = null,
        @SerialName("application_rate") val applicationRate: Double? = null,
        @SerialName("product_required") val productRequired: Double? = null,
        @SerialName("allocated_cost") val allocatedCost: Double? = null,
    ) {
        fun toModel(): FertiliserAllocation = FertiliserAllocation(
            id = id,
            paddockId = paddockId,
            areaHectares = areaHa ?: 0.0,
            vineCount = vineCount ?: 0,
            rate = applicationRate ?: 0.0,
            productRequired = productRequired ?: 0.0,
            allocatedCost = allocatedCost,
        )
    }

    @Serializable
    private data class IdArgs(@SerialName("p_id") val id: String)

    // MARK: Reads

    suspend fun fetchRecords(vineyardId: String): List<RecordRow> =
        getList("fertiliser_records?vineyard_id=eq.$vineyardId&order=updated_at.asc")

    suspend fun fetchAllocations(vineyardId: String): List<AllocationRow> =
        getList("fertiliser_record_allocations?vineyard_id=eq.$vineyardId")

    // MARK: Writes

    /** Upserts the record, then its per-block allocation rows. */
    suspend fun upsertRecord(record: FertiliserRecord) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val packCount = record.packSize?.takeIf { it > 0 }?.let { record.totalProduct / it }
        val body = RecordUpsert(
            id = record.id,
            vineyardId = record.vineyardId,
            productId = record.productId,
            productName = record.productName,
            form = record.form,
            calculationMode = record.mode,
            recordStatus = record.status,
            applicationDate = record.date,
            blockNames = record.blockNames,
            totalAreaHa = record.areaHectares,
            totalVines = record.vineCount,
            applicationRate = record.rate,
            applicationRateUnit = record.rateUnit,
            totalProductRequired = record.totalProduct,
            productUnit = record.unit,
            packSize = record.packSize,
            packCount = packCount,
            estimatedProductCost = record.productCost,
            labourCost = record.labourMachineryCost,
            totalJobCost = record.totalCost,
            notes = record.notes,
            createdBy = session.userId,
            clientUpdatedAt = Instant.now().toString(),
        )
        val recordResponse = SupabaseClient.http.post(SupabaseClient.restUrl("fertiliser_records?on_conflict=id")) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        requireSuccess(recordResponse)

        if (record.allocations.isNotEmpty()) {
            val allocations = record.allocations.map {
                AllocationRow(
                    id = it.id,
                    fertiliserRecordId = record.id,
                    vineyardId = record.vineyardId,
                    paddockId = it.paddockId,
                    areaHa = it.areaHectares,
                    vineCount = it.vineCount,
                    applicationRate = it.rate,
                    productRequired = it.productRequired,
                    allocatedCost = it.allocatedCost,
                )
            }
            val allocationResponse = SupabaseClient.http.post(
                SupabaseClient.restUrl("fertiliser_record_allocations?on_conflict=id"),
            ) {
                authHeaders(token)
                headers { append("Prefer", "resolution=merge-duplicates") }
                contentType(ContentType.Application.Json)
                setBody(allocations)
            }
            requireSuccess(allocationResponse)
        }
    }

    suspend fun softDeleteRecord(recordId: String) = softDelete("soft_delete_fertiliser_record", recordId)

    // MARK: Plumbing

    private suspend fun softDelete(rpc: String, id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(IdArgs(id))
        }
        requireSuccess(response)
    }

    private suspend inline fun <reified T> getList(pathAndQuery: String): List<T> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(SupabaseClient.restUrl(pathAndQuery)) {
                authHeaders(token)
            }
            when {
                response.status.isSuccess() -> response.body<List<T>>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private suspend fun requireSuccess(response: HttpResponse) {
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
