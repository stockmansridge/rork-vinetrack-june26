package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationBlock
import com.rork.vinetrack.data.model.GrapeAllocationFinancialRow
import com.rork.vinetrack.data.model.GrapePurchaser
import io.ktor.client.call.body
import io.ktor.client.request.delete
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
 * Grape allocations (sql/217), mirroring the iOS
 * `SupabaseGrapeAllocationRepository` contract: RLS-guarded REST upsert +
 * list, block splits replaced wholesale, deletes through the
 * `soft_delete_grape_allocation` RPC, and owner/manager money through the
 * `get_grape_allocation_financials` RPC (42501 for lower roles).
 *
 * The upsert body includes `price_per_tonne`: the sql/217 BEFORE trigger
 * routes it into the financial companion for owner/manager writers and
 * ALWAYS nulls the base column — a lower-role write can neither set nor wipe
 * a price.
 */
class GrapeAllocationRepository(private val session: SessionStore) {

    @Serializable
    private data class AllocationUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val vintage: Int,
        @SerialName("allocation_type") val allocationType: String,
        @SerialName("variety_id") val varietyId: String?,
        @SerialName("variety_key") val varietyKey: String?,
        @SerialName("variety_name") val varietyName: String,
        @SerialName("destination_name") val destinationName: String?,
        @SerialName("quantity_tonnes") val quantityTonnes: Double,
        val notes: String?,
        @SerialName("purchaser_id") val purchaserId: String?,
        @SerialName("purchaser_name") val purchaserName: String?,
        @SerialName("contact_name") val contactName: String?,
        @SerialName("contact_email") val contactEmail: String?,
        @SerialName("contact_phone") val contactPhone: String?,
        @SerialName("contact_address") val contactAddress: String?,
        @SerialName("price_per_tonne") val pricePerTonne: Double?,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class BlockInsert(
        val id: String,
        @SerialName("allocation_id") val allocationId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("paddock_name") val paddockName: String,
        @SerialName("quantity_tonnes") val quantityTonnes: Double?,
    )

    @Serializable
    private data class PurchaserUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("winery_name") val wineryName: String,
        @SerialName("contact_name") val contactName: String?,
        @SerialName("contact_email") val contactEmail: String?,
        @SerialName("contact_phone") val contactPhone: String?,
        @SerialName("contact_address") val contactAddress: String?,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class FinancialsArgs(@SerialName("p_vineyard_id") val vineyardId: String)

    suspend fun listAllocations(vineyardId: String): List<GrapeAllocation> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "grape_allocations?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=created_at.desc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    suspend fun listBlocks(vineyardId: String): List<GrapeAllocationBlock> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl("grape_allocation_blocks?select=*&vineyard_id=eq.$vineyardId"),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Owner/manager money via the sql/217 RPC — the ONLY way price values
     * reach a client. Throws for lower roles; callers treat that as
     * "no financial access".
     */
    suspend fun listFinancials(vineyardId: String): List<GrapeAllocationFinancialRow> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_grape_allocation_financials")) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(FinancialsArgs(vineyardId))
            }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /** Create-or-update by id, then replace the block split wholesale. */
    suspend fun upsertAllocation(
        allocation: GrapeAllocation,
        clientUpdatedAt: String,
    ): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = AllocationUpsert(
            id = allocation.id,
            vineyardId = allocation.vineyardId,
            vintage = allocation.vintage,
            allocationType = allocation.allocationType,
            varietyId = allocation.varietyId,
            varietyKey = allocation.varietyKey,
            varietyName = allocation.varietyName,
            destinationName = allocation.destinationName,
            quantityTonnes = allocation.quantityTonnes,
            notes = allocation.notes,
            purchaserId = if (allocation.isExternal) allocation.purchaserId else null,
            purchaserName = if (allocation.isExternal) allocation.purchaserName else null,
            contactName = if (allocation.isExternal) allocation.contactName else null,
            contactEmail = if (allocation.isExternal) allocation.contactEmail else null,
            contactPhone = if (allocation.isExternal) allocation.contactPhone else null,
            contactAddress = if (allocation.isExternal) allocation.contactAddress else null,
            pricePerTonne = if (allocation.isExternal) allocation.pricePerTonne else null,
            createdBy = session.userId,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("grape_allocations?on_conflict=id"),
        ) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=minimal") }
            contentType(ContentType.Application.Json)
            setBody(listOf(body))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }

        // Detail rows are replaced wholesale (sql/217 header).
        val deleteResponse = SupabaseClient.http.delete(
            SupabaseClient.restUrl("grape_allocation_blocks?allocation_id=eq.${allocation.id}"),
        ) { authHeaders(token) }
        if (!deleteResponse.status.isSuccess()) {
            throw BackendError.Server(deleteResponse.status.value, deleteResponse.bodyAsText())
        }
        if (allocation.blocks.isNotEmpty()) {
            val blocksBody = allocation.blocks.map {
                BlockInsert(
                    id = it.id,
                    allocationId = allocation.id,
                    vineyardId = allocation.vineyardId,
                    paddockId = it.paddockId,
                    paddockName = it.paddockName,
                    quantityTonnes = it.quantityTonnes,
                )
            }
            val insertResponse = SupabaseClient.http.post(
                SupabaseClient.restUrl("grape_allocation_blocks"),
            ) {
                authHeaders(token)
                headers { append("Prefer", "return=minimal") }
                contentType(ContentType.Application.Json)
                setBody(blocksBody)
            }
            if (!insertResponse.status.isSuccess()) {
                throw BackendError.Server(insertResponse.status.value, insertResponse.bodyAsText())
            }
        }
    }

    /** Saved purchaser book for the vineyard (sql/219), live rows only. */
    suspend fun listPurchasers(vineyardId: String): List<GrapePurchaser> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "grape_purchasers?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=winery_name.asc",
                ),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Create-or-update one saved purchaser. Editing a purchaser never
     * rewrites existing allocation snapshots — they keep their own copy.
     */
    suspend fun upsertPurchaser(purchaser: GrapePurchaser, clientUpdatedAt: String): Unit =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = PurchaserUpsert(
                id = purchaser.id,
                vineyardId = purchaser.vineyardId,
                wineryName = purchaser.wineryName,
                contactName = purchaser.contactName,
                contactEmail = purchaser.contactEmail,
                contactPhone = purchaser.contactPhone,
                contactAddress = purchaser.contactAddress,
                createdBy = session.userId,
                clientUpdatedAt = clientUpdatedAt,
            )
            val response = SupabaseClient.http.post(
                SupabaseClient.restUrl("grape_purchasers?on_conflict=id"),
            ) {
                authHeaders(token)
                headers { append("Prefer", "resolution=merge-duplicates,return=minimal") }
                contentType(ContentType.Application.Json)
                setBody(listOf(body))
            }
            when {
                response.status.isSuccess() -> Unit
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    suspend fun softDeleteAllocation(id: String): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_grape_allocation")) {
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
