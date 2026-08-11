package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PickingRecord
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

/**
 * Write/read path for the Detailed picking log (`public.picking_records`,
 * sql/180), mirroring the iOS `SupabasePickingRecordSyncRepository` contract:
 * REST insert + list plus the `soft_delete_picking_record` RPC. RLS scopes
 * everything to vineyard membership (operator+ insert/update;
 * owner/manager/supervisor delete).
 *
 * The insert body deliberately OMITS `vintage` (server-derived from
 * `picked_at` via the sql/119 resolver — a client value is never trusted) and
 * `grape_value` (a generated column; sending it would fail the insert).
 */
class PickingRecordRepository(private val session: SessionStore) {

    @Serializable
    private data class PickingInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("picked_at") val pickedAt: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("paddock_name") val paddockName: String,
        @SerialName("variety_id") val varietyId: String?,
        @SerialName("variety_key") val varietyKey: String?,
        @SerialName("variety_name") val varietyName: String,
        val clone: String?,
        @SerialName("weight_kg") val weightKg: Double,
        @SerialName("sugar_value") val sugarValue: Double?,
        @SerialName("sugar_unit") val sugarUnit: String?,
        val ph: Double?,
        @SerialName("ta_g_l") val taGPerL: Double?,
        val purpose: String,
        val sold: Boolean,
        @SerialName("sold_to") val soldTo: String?,
        @SerialName("price_per_tonne") val pricePerTonne: Double?,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /**
     * Insert a fully-formed picking record. Shared by the online create flow
     * and offline replay ([PickingRecordCreateSync]) so the record is preserved
     * byte-for-byte. `created_by` always resolves from the live session.
     * Returns the server row (with the authoritative vintage + grape value).
     */
    suspend fun insertPickingRecord(
        record: PickingRecord,
        clientUpdatedAt: String,
    ): PickingRecord = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = PickingInsert(
            id = record.id,
            vineyardId = record.vineyardId,
            pickedAt = record.pickedAt,
            paddockId = record.paddockId,
            paddockName = record.paddockName,
            varietyId = record.varietyId,
            varietyKey = record.varietyKey,
            varietyName = record.varietyName,
            clone = record.clone,
            weightKg = record.weightKg,
            sugarValue = record.sugarValue,
            sugarUnit = record.sugarUnit,
            ph = record.ph,
            taGPerL = record.taGPerL,
            purpose = record.purpose,
            sold = record.sold,
            soldTo = record.soldTo,
            pricePerTonne = record.pricePerTonne,
            notes = record.notes,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("picking_records")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    suspend fun listPickingRecords(vineyardId: String): List<PickingRecord> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "picking_records?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=picked_at.desc,created_at.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    suspend fun softDeletePickingRecord(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_picking_record")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): PickingRecord = when {
        response.status.isSuccess() -> response.body<List<PickingRecord>>().firstOrNull()
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
