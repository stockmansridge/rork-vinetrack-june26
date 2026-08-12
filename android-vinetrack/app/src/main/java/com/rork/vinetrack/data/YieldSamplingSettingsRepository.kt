package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
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
 * Shared Bunch Count Trip sampling default (`vineyards.yield_samples_per_hectare`,
 * sql/187) via the `get/set_vineyard_yield_sampling_settings` RPC pair. Members
 * read; every trip-capable role may write — a changed sample density becomes
 * the default for the NEXT trip on every device.
 */
class YieldSamplingSettingsRepository(private val session: SessionStore) {

    @Serializable
    private data class GetArgs(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class SetArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_samples_per_hectare") val samplesPerHectare: Int,
    )

    @Serializable
    private data class Row(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("samples_per_hectare") val samplesPerHectare: Int,
    )

    suspend fun getSamplingDefault(vineyardId: String): Int = withContext(Dispatchers.IO) {
        rpc("get_vineyard_yield_sampling_settings", GetArgs(vineyardId))
    }

    suspend fun setSamplingDefault(vineyardId: String, samplesPerHectare: Int): Int =
        withContext(Dispatchers.IO) {
            rpc(
                "set_vineyard_yield_sampling_settings",
                SetArgs(vineyardId, samplesPerHectare.coerceIn(1, 100)),
            )
        }

    private suspend inline fun <reified T> rpc(name: String, args: T): Int {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(args)
        }
        return when {
            response.status.isSuccess() ->
                response.body<List<Row>>().firstOrNull()?.samplesPerHectare ?: 20
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }
}
