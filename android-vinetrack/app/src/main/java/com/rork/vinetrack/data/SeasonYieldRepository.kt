package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SeasonYieldOverview
import com.rork.vinetrack.data.model.SeasonYieldRefreshResult
import io.ktor.client.call.body
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
 * Canonical seasonal yield estimates (sql/221), mirroring the iOS
 * `SupabaseSeasonYieldRepository`.
 *
 * `season_yield_estimates` is client READ-ONLY — there is deliberately no
 * insert/update/delete here. The ONLY write path is
 * [refreshPruningEstimates], which re-derives the vintage's pruning rows
 * server-side and never downgrades a bunch_count or manual estimate.
 */
class SeasonYieldRepository(private val session: SessionStore) {

    @Serializable
    private data class OverviewArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_vintage") val vintage: Int,
    )

    /** The single authority for base (undamaged) seasonal estimates. */
    suspend fun fetchOverview(vineyardId: String, vintage: Int): SeasonYieldOverview =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("get_season_yield_base_overview"),
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(OverviewArgs(vineyardId, vintage))
            }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Re-derive the vintage's pruning-based estimates. Safe and idempotent: a
     * group already carrying a higher-priority estimate is skipped, not
     * overwritten.
     */
    suspend fun refreshPruningEstimates(vineyardId: String, vintage: Int): SeasonYieldRefreshResult =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("refresh_pruning_yield_estimates"),
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(OverviewArgs(vineyardId, vintage))
            }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
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
