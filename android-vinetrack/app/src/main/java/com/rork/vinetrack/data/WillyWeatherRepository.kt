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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/** A WillyWeather forecast location returned by the proxy search. */
@Serializable
data class WillyWeatherLocation(
    val id: String,
    val name: String = "",
    val region: String? = null,
    val state: String? = null,
    val postcode: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val distanceKm: Double? = null,
)

/**
 * One day of normalised WillyWeather forecast data returned by the
 * `willyweather-proxy` edge function (`fetch_forecast` action). Mirrors the
 * iOS `WillyWeatherForecastDay` and the JSON contract in
 * `supabase/functions/willyweather-proxy/index.ts`.
 */
@Serializable
data class WillyWeatherForecastDay(
    /** Local calendar day, "yyyy-MM-dd". */
    val date: String,
    @SerialName("rain_mm") val rainMm: Double? = null,
    @SerialName("rain_probability") val rainProbability: Double? = null,
    @SerialName("temp_min_c") val tempMinC: Double? = null,
    @SerialName("temp_max_c") val tempMaxC: Double? = null,
    @SerialName("wind_kmh_max") val windKmhMax: Double? = null,
    @SerialName("et0_mm") val et0Mm: Double? = null,
)

/** Result of the `fetch_forecast` proxy action. Mirrors iOS `WillyWeatherForecastResult`. */
@Serializable
data class WillyWeatherForecastResult(
    val source: String = "WillyWeather",
    @SerialName("location_id") val locationId: String? = null,
    @SerialName("location_name") val locationName: String? = null,
    val days: List<WillyWeatherForecastDay> = emptyList(),
)

/**
 * Client for the `willyweather-proxy` edge function. The WillyWeather API key
 * is global (server-side) — the device only manages the per-vineyard forecast
 * provider preference (stored on `vineyards.forecast_provider`) and the
 * selected location (stored in `vineyard_weather_integrations`).
 *
 * Mirrors the iOS `VineyardWillyWeatherProxyService`. Owner/manager role is
 * required for `set_location`, `delete` and `set_provider_preference`; the
 * edge function enforces this server-side.
 */
class WillyWeatherRepository(private val session: SessionStore) {

    @Serializable
    private data class ProviderResponse(val success: Boolean = false, val provider: String? = null)

    @Serializable
    private data class SearchResponse(
        val success: Boolean = false,
        val mode: String? = null,
        val locations: List<WillyWeatherLocation> = emptyList(),
        val error: String? = null,
    )

    @Serializable
    private data class GenericResponse(
        val success: Boolean = false,
        val error: String? = null,
    )

    /** Read the vineyard's forecast provider preference (auto/open_meteo/willyweather). */
    suspend fun getProviderPreference(vineyardId: String): String =
        withContext(Dispatchers.IO) {
            val body = invoke(buildJsonObject {
                put("vineyardId", JsonPrimitive(vineyardId))
                put("action", JsonPrimitive("get_provider_preference"))
            })
            val parsed = SupabaseClient.json.decodeFromString(ProviderResponse.serializer(), body)
            parsed.provider ?: "auto"
        }

    /** Write the vineyard's forecast provider preference. Owner/manager only. */
    suspend fun setProviderPreference(vineyardId: String, provider: String): Unit =
        withContext(Dispatchers.IO) {
            invoke(buildJsonObject {
                put("vineyardId", JsonPrimitive(vineyardId))
                put("action", JsonPrimitive("set_provider_preference"))
                put("provider", JsonPrimitive(provider))
            })
        }

    /** Search WillyWeather locations by free text and/or coordinates. */
    suspend fun searchLocations(
        vineyardId: String,
        query: String,
        lat: Double? = null,
        lon: Double? = null,
    ): List<WillyWeatherLocation> = withContext(Dispatchers.IO) {
        val body = invoke(buildJsonObject {
            put("vineyardId", JsonPrimitive(vineyardId))
            put("action", JsonPrimitive("search_locations"))
            if (query.isNotBlank()) put("query", JsonPrimitive(query))
            if (lat != null) put("lat", JsonPrimitive(lat))
            if (lon != null) put("lon", JsonPrimitive(lon))
        })
        SupabaseClient.json.decodeFromString(SearchResponse.serializer(), body).locations
    }

    /** Save the selected WillyWeather location for the vineyard. Owner/manager only. */
    suspend fun setLocation(vineyardId: String, location: WillyWeatherLocation): Unit =
        withContext(Dispatchers.IO) {
            invoke(buildJsonObject {
                put("vineyardId", JsonPrimitive(vineyardId))
                put("action", JsonPrimitive("set_location"))
                put("locationId", JsonPrimitive(location.id))
                put("locationName", JsonPrimitive(location.name))
                location.latitude?.let { put("latitude", JsonPrimitive(it)) }
                location.longitude?.let { put("longitude", JsonPrimitive(it)) }
            })
        }

    /**
     * Fetch the normalised WillyWeather daily forecast for the vineyard's
     * configured location. Throws when WillyWeather is not configured, the
     * location is missing, or the upstream API fails — callers fall back to
     * Open-Meteo, mirroring the iOS `IrrigationForecastService`.
     */
    suspend fun fetchForecast(vineyardId: String, days: Int = 7): WillyWeatherForecastResult =
        withContext(Dispatchers.IO) {
            val body = invoke(buildJsonObject {
                put("vineyardId", JsonPrimitive(vineyardId))
                put("action", JsonPrimitive("fetch_forecast"))
                put("days", JsonPrimitive(days.coerceIn(1, 7)))
            })
            SupabaseClient.json.decodeFromString(WillyWeatherForecastResult.serializer(), body)
        }

    /** Remove the vineyard's WillyWeather location. Owner/manager only. */
    suspend fun deleteLocation(vineyardId: String): Unit = withContext(Dispatchers.IO) {
        invoke(buildJsonObject {
            put("vineyardId", JsonPrimitive(vineyardId))
            put("action", JsonPrimitive("delete"))
        })
    }

    private suspend fun invoke(payload: JsonObject): String {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl("willyweather-proxy")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        return readBody(response)
    }

    private suspend fun readBody(response: HttpResponse): String = when {
        response.status.isSuccess() -> response.bodyAsText()
        response.status.value == 401 -> throw BackendError.Unauthorized
        else -> {
            val text = response.bodyAsText()
            val message = runCatching {
                SupabaseClient.json.decodeFromString(GenericResponse.serializer(), text).error
            }.getOrNull()
            throw BackendError.Server(response.status.value, message ?: text)
        }
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
