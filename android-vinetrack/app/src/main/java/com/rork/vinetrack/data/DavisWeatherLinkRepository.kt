package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** A WeatherLink station returned by the davis-proxy `test`/`stations` action. */
data class DavisStation(
    val stationId: String,
    val name: String,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val timezone: String? = null,
    val active: Boolean? = null,
)

/** Sensors detected from a Davis `current` payload for a selected station. */
data class DavisSensorSummary(
    val hasTemperatureHumidity: Boolean = false,
    val hasRain: Boolean = false,
    val hasWind: Boolean = false,
    val hasLeafWetness: Boolean = false,
    val hasSoilMoisture: Boolean = false,
    val detectedSensors: List<String> = emptyList(),
)

/**
 * Result of `test_saved` — re-validating the credentials already stored for
 * the vineyard. Mirrors the iOS `test_saved` contract.
 */
data class DavisTestSavedResult(
    val success: Boolean,
    val status: String,
    val message: String,
    val stations: List<DavisStation>,
)

/**
 * Client for the shared `davis-proxy` edge function plus the credential-aware
 * `save_vineyard_weather_integration` RPC. Mirrors the iOS
 * `VineyardDavisProxyService` + `WeatherDataSettingsView` Davis flow:
 *
 *  - `testConnection` verifies an ad-hoc key/secret pair (owner/manager) and
 *    returns the available stations without persisting anything.
 *  - `saveCredentials` stores the key/secret on the shared vineyard integration
 *    so every member fetches through the proxy.
 *  - `detectSensors` runs a `current` read for the selected station to discover
 *    leaf-wetness / rain / wind sensors.
 *  - `saveStation` persists the chosen station plus its detected sensors.
 *  - `remove` clears the integration.
 *
 * All writes enforce owner/manager server-side.
 */
class DavisWeatherLinkRepository(private val session: SessionStore) {

    /** ISS-family sensor types that imply outdoor T/H, wind and rain. */
    private val issSensorTypes = setOf(23, 37, 43, 45, 46, 48, 55)
    private val internalSensorTypes = setOf(27)

    /** Verify ad-hoc credentials (owner/manager). Returns available stations. */
    suspend fun testConnection(
        vineyardId: String,
        apiKey: String,
        apiSecret: String,
    ): List<DavisStation> = withContext(Dispatchers.IO) {
        val json = invoke(buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "test")
            put("apiKey", apiKey.trim())
            put("apiSecret", apiSecret.trim())
        })
        parseStations(json)
    }

    /** Re-validate the credentials already stored for this vineyard. */
    suspend fun testSaved(vineyardId: String): DavisTestSavedResult = withContext(Dispatchers.IO) {
        val json = invoke(buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "test_saved")
        })
        DavisTestSavedResult(
            success = json["success"]?.jsonPrimitive?.content?.toBoolean() ?: false,
            status = json["status"]?.jsonPrimitive?.content ?: "",
            message = json["message"]?.jsonPrimitive?.content ?: "",
            stations = parseStations(json),
        )
    }

    /** List stations for the stored credentials (any member). */
    suspend fun fetchStations(vineyardId: String): List<DavisStation> = withContext(Dispatchers.IO) {
        val json = invoke(buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "stations")
        })
        parseStations(json)
    }

    /**
     * Run a `current` read for [stationId] and detect available sensors so the
     * UI can show leaf-wetness availability and the sensor list.
     */
    suspend fun detectSensors(vineyardId: String, stationId: String): DavisSensorSummary =
        withContext(Dispatchers.IO) {
            val json = invoke(buildJsonObject {
                put("vineyardId", vineyardId)
                put("action", "current")
                put("stationId", stationId)
            })
            parseSensors(json)
        }

    /**
     * Store the API key/secret on the shared vineyard integration. Owner/manager
     * only (enforced server-side). Marks the integration tested.
     */
    suspend fun saveCredentials(
        vineyardId: String,
        apiKey: String,
        apiSecret: String,
    ): Unit = withContext(Dispatchers.IO) {
        save(buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_provider", WeatherIntegrationProvider.DAVIS)
            put("p_api_key", apiKey.trim())
            put("p_api_secret", apiSecret.trim())
            put("p_last_test_status", "ok")
            put("p_is_active", true)
        })
    }

    /** Persist the selected station plus its detected sensors. */
    suspend fun saveStation(
        vineyardId: String,
        station: DavisStation,
        sensors: DavisSensorSummary,
    ): Unit = withContext(Dispatchers.IO) {
        save(buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_provider", WeatherIntegrationProvider.DAVIS)
            put("p_station_id", station.stationId)
            put("p_station_name", station.name)
            station.latitude?.let { put("p_station_latitude", it) }
            station.longitude?.let { put("p_station_longitude", it) }
            put("p_has_leaf_wetness", sensors.hasLeafWetness)
            put("p_has_rain", sensors.hasRain)
            put("p_has_wind", sensors.hasWind)
            put("p_has_temperature_humidity", sensors.hasTemperatureHumidity)
            put("p_last_test_status", "ok")
            put("p_is_active", true)
        })
    }

    /** Remove the Davis integration for this vineyard. Owner/manager only. */
    suspend fun remove(vineyardId: String): Unit = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("delete_vineyard_weather_integration")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("p_vineyard_id", vineyardId)
                put("p_provider", WeatherIntegrationProvider.DAVIS)
            })
        }
        checkStatus(response)
    }

    // MARK: - Parsing

    private fun parseStations(json: JsonObject): List<DavisStation> {
        val arr = json["stations"]?.jsonArray ?: return emptyList()
        return arr.mapNotNull { el ->
            val obj = el.jsonObject
            val idPrim = obj["station_id"]?.jsonPrimitive ?: return@mapNotNull null
            val stationId = idPrim.intOrNull?.toString() ?: idPrim.content
            if (stationId.isBlank()) return@mapNotNull null
            val name = obj["station_name"]?.jsonPrimitive?.content ?: "Davis Station $stationId"
            val active = obj["active"]?.jsonPrimitive?.let {
                it.content.toBooleanStrictOrNull() ?: (it.intOrNull?.let { i -> i != 0 })
            }
            DavisStation(
                stationId = stationId,
                name = name,
                latitude = obj["latitude"]?.jsonPrimitive?.doubleOrNull,
                longitude = obj["longitude"]?.jsonPrimitive?.doubleOrNull,
                timezone = obj["time_zone"]?.jsonPrimitive?.content,
                active = active,
            )
        }
    }

    private fun parseSensors(json: JsonObject): DavisSensorSummary {
        val sensors = json["sensors"]?.jsonArray ?: return DavisSensorSummary()
        var hasTH = false
        var hasRain = false
        var hasWind = false
        var hasLW = false
        var hasSoil = false

        for (el in sensors) {
            val obj = el.jsonObject
            val sensorType = obj["sensor_type"]?.jsonPrimitive?.intOrNull
            if (sensorType != null && sensorType in issSensorTypes) {
                hasTH = true; hasWind = true; hasRain = true
            }
            if (sensorType == 242) { hasLW = true; hasSoil = true }
            if (sensorType != null && sensorType in internalSensorTypes) continue

            val data = obj["data"]?.jsonArray ?: continue
            for (rec in data) {
                val recObj = rec.jsonObject
                for (rawKey in recObj.keys) {
                    val key = rawKey.lowercase()
                    if ((key.contains("temp") || key.contains("hum") || key.contains("dew")) &&
                        !key.contains("soil") && !key.contains("leaf") &&
                        !key.startsWith("temp_in") && !key.startsWith("hum_in") &&
                        !key.contains("_in_")
                    ) hasTH = true
                    if (key.contains("rain")) hasRain = true
                    if (key.contains("wind")) hasWind = true
                    if (isLeafWetnessKey(key)) hasLW = true
                    if (key.contains("soil_moisture") || key.contains("moist_soil")) hasSoil = true
                }
            }
        }

        val detected = buildList {
            if (hasTH) add("Temperature / Humidity")
            if (hasRain) add("Rainfall")
            if (hasWind) add("Wind")
            if (hasLW) add("Leaf wetness")
            if (hasSoil) add("Soil moisture")
        }
        return DavisSensorSummary(hasTH, hasRain, hasWind, hasLW, hasSoil, detected)
    }

    private fun isLeafWetnessKey(key: String): Boolean =
        key.contains("leaf_wetness") || key.contains("wet_leaf") || key.contains("leaf_wet")

    // MARK: - HTTP

    private suspend fun invoke(payload: JsonObject): JsonObject {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl("davis-proxy")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        val text = response.bodyAsText()
        if (response.status.isSuccess()) {
            return SupabaseClient.json.parseToJsonElement(text).jsonObject
        }
        if (response.status.value == 401) throw BackendError.Unauthorized
        val message = runCatching {
            SupabaseClient.json.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        throw BackendError.Server(response.status.value, message ?: text)
    }

    private suspend fun save(payload: JsonObject) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("save_vineyard_weather_integration")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        checkStatus(response)
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
