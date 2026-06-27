package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.FuelPurchase
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
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
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Write path for `public.fuel_purchases` (sql/011), mirroring the iOS
 * management sync upsert. Inserts/updates feed the weighted average fuel cost
 * per litre used by trip costing. Hard deletes are blocked, so archiving goes
 * through the `soft_delete_fuel_purchase` RPC.
 */
class FuelPurchaseRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android fuel-purchase form. */
    data class PurchaseInput(
        val volumeLitres: Double,
        val totalCost: Double,
        /** ISO-8601 purchase date. */
        val dateIso: String,
    )

    @Serializable
    private data class PurchaseInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("volume_litres") val volumeLitres: Double,
        @SerialName("total_cost") val totalCost: Double,
        val date: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class PurchasePatch(
        @SerialName("volume_litres") val volumeLitres: Double,
        @SerialName("total_cost") val totalCost: Double,
        val date: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: PurchaseInput): FuelPurchase =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = PurchaseInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                volumeLitres = input.volumeLitres,
                totalCost = input.totalCost,
                date = input.dateIso,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("fuel_purchases")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: PurchaseInput): FuelPurchase =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = PurchasePatch(
                volumeLitres = input.volumeLitres,
                totalCost = input.totalCost,
                date = input.dateIso,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("fuel_purchases?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_fuel_purchase")) {
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

    private suspend fun firstRow(response: HttpResponse): FuelPurchase = when {
        response.status.isSuccess() -> response.body<List<FuelPurchase>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
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
