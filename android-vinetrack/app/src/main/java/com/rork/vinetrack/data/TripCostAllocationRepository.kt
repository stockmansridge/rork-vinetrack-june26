package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.TripCostAllocation
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Read-only transport for authoritative stored trip cost allocations. */
class TripCostAllocationRepository(private val session: SessionStore) {
    suspend fun listForVineyard(vineyardId: String): List<TripCostAllocation> = withContext(Dispatchers.IO) {
        val base = AppConfig.supabaseUrl?.trimEnd('/') ?: throw BackendError.NotConfigured
        val key = AppConfig.supabaseAnonKey ?: throw BackendError.NotConfigured
        val response = SupabaseClient.http.get("$base/rest/v1/trip_cost_allocations?select=id,vineyard_id,trip_id,total_cost,costing_status,deleted_at&vineyard_id=eq.$vineyardId&deleted_at=is.null") {
            headers {
                append("apikey", key)
                session.accessToken?.let { append("Authorization", "Bearer $it") }
            }
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, "Unable to load trip costs")
        response.body()
    }
}
