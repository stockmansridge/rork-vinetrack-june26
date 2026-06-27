package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
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

/** Provider keys used by the shared `vineyard_weather_integrations` table. */
object WeatherIntegrationProvider {
    const val WILLY_WEATHER = "willyweather"
    const val WUNDERGROUND = "wunderground"
    const val DAVIS = "davis_weatherlink"
}

/**
 * Non-secret view of a vineyard weather integration, returned by the
 * `get_vineyard_weather_integration` RPC. Mirrors the iOS
 * `VineyardWeatherIntegration`. API key/secret values are never exposed —
 * only `hasApiKey`/`hasApiSecret` flags plus a `callerRole` hint so the UI
 * can gate owner/manager-only controls.
 */
@Serializable
data class VineyardWeatherIntegration(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val provider: String,
    @SerialName("has_api_key") val hasApiKey: Boolean = false,
    @SerialName("has_api_secret") val hasApiSecret: Boolean = false,
    @SerialName("station_id") val stationId: String? = null,
    @SerialName("station_name") val stationName: String? = null,
    @SerialName("station_latitude") val stationLatitude: Double? = null,
    @SerialName("station_longitude") val stationLongitude: Double? = null,
    @SerialName("has_leaf_wetness") val hasLeafWetness: Boolean = false,
    @SerialName("has_rain") val hasRain: Boolean = false,
    @SerialName("has_wind") val hasWind: Boolean = false,
    @SerialName("has_temperature_humidity") val hasTemperatureHumidity: Boolean = false,
    @SerialName("detected_sensors") val detectedSensors: List<String> = emptyList(),
    @SerialName("configured_by") val configuredBy: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("last_tested_at") val lastTestedAt: String? = null,
    @SerialName("last_test_status") val lastTestStatus: String? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("caller_role") val callerRole: String? = null,
)

/**
 * Read/write path for the shared per-vineyard weather integration rows
 * (WillyWeather location, Weather Underground PWS, Davis WeatherLink). Backed
 * by the `get_/save_/delete_vineyard_weather_integration` RPCs (sql/021).
 * Any member may read; save/delete enforce owner/manager server-side.
 */
class VineyardWeatherIntegrationRepository(private val session: SessionStore) {

    @Serializable
    private data class Lookup(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_provider") val provider: String,
    )

    @Serializable
    private data class SaveArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_provider") val provider: String,
        @SerialName("p_station_id") val stationId: String? = null,
        @SerialName("p_station_name") val stationName: String? = null,
        @SerialName("p_station_latitude") val stationLatitude: Double? = null,
        @SerialName("p_station_longitude") val stationLongitude: Double? = null,
        @SerialName("p_has_rain") val hasRain: Boolean? = null,
        @SerialName("p_has_wind") val hasWind: Boolean? = null,
        @SerialName("p_has_temperature_humidity") val hasTemperatureHumidity: Boolean? = null,
        @SerialName("p_last_test_status") val lastTestStatus: String? = null,
        @SerialName("p_is_active") val isActive: Boolean? = null,
    )

    suspend fun fetch(vineyardId: String, provider: String): VineyardWeatherIntegration? =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("get_vineyard_weather_integration")
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(Lookup(vineyardId, provider))
            }
            rows(response).firstOrNull()
        }

    /** Save (insert/update) a station selection. Owner/manager only. */
    suspend fun saveStation(
        vineyardId: String,
        provider: String,
        stationId: String,
        stationName: String?,
        latitude: Double? = null,
        longitude: Double? = null,
        hasRain: Boolean? = null,
        hasWind: Boolean? = null,
        hasTemperatureHumidity: Boolean? = null,
    ): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("save_vineyard_weather_integration")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(
                SaveArgs(
                    vineyardId = vineyardId,
                    provider = provider,
                    stationId = stationId,
                    stationName = stationName,
                    stationLatitude = latitude,
                    stationLongitude = longitude,
                    hasRain = hasRain,
                    hasWind = hasWind,
                    hasTemperatureHumidity = hasTemperatureHumidity,
                    lastTestStatus = "ok",
                    isActive = true,
                )
            )
        }
        checkStatus(response)
    }

    /** Remove the integration for this provider. Owner/manager only. */
    suspend fun delete(vineyardId: String, provider: String): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("delete_vineyard_weather_integration")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(Lookup(vineyardId, provider))
        }
        checkStatus(response)
    }

    private suspend fun rows(response: HttpResponse): List<VineyardWeatherIntegration> = when {
        response.status.isSuccess() -> response.body()
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private suspend fun checkStatus(response: HttpResponse) {
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
