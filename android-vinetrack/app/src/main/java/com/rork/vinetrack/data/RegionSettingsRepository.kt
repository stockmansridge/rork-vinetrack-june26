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

/**
 * Read/write path for vineyard-level Region & Units settings, mirroring the iOS
 * `SupabaseVineyardRepository.getVineyardRegionSettings` /
 * `setVineyardRegionSettings`. Backed by the `get_vineyard_region_settings` /
 * `set_vineyard_region_settings` RPCs (sql/099). Any member may read; the set
 * RPC enforces owner/manager server-side.
 */
class RegionSettingsRepository(private val session: SessionStore) {

    @Serializable
    private data class GetArgs(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class SetArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_country_code") val countryCode: String?,
        @SerialName("p_currency_code") val currencyCode: String?,
        @SerialName("p_timezone") val timezone: String?,
        @SerialName("p_area_unit") val areaUnit: String?,
        @SerialName("p_volume_unit") val volumeUnit: String?,
        @SerialName("p_distance_unit") val distanceUnit: String?,
        @SerialName("p_fuel_unit") val fuelUnit: String?,
        @SerialName("p_spray_rate_area_unit") val sprayRateAreaUnit: String?,
        @SerialName("p_date_format") val dateFormat: String?,
        @SerialName("p_terminology_region") val terminologyRegion: String?,
    )

    @Serializable
    private data class RegionRow(
        @SerialName("country_code") val countryCode: String? = null,
        @SerialName("currency_code") val currencyCode: String? = null,
        val timezone: String? = null,
        @SerialName("area_unit") val areaUnit: String? = null,
        @SerialName("volume_unit") val volumeUnit: String? = null,
        @SerialName("distance_unit") val distanceUnit: String? = null,
        @SerialName("fuel_unit") val fuelUnit: String? = null,
        @SerialName("spray_rate_area_unit") val sprayRateAreaUnit: String? = null,
        @SerialName("date_format") val dateFormat: String? = null,
        @SerialName("terminology_region") val terminologyRegion: String? = null,
    )

    /** Merge a server row onto the AU defaults, keeping defaults for null/blank. */
    private fun RegionRow.toSettings(): RegionSettings {
        val d = RegionSettings.defaults
        fun s(v: String?, fallback: String) = v?.takeIf { it.isNotBlank() } ?: fallback
        return RegionSettings(
            countryCode = s(countryCode, d.countryCode),
            currencyCode = s(currencyCode, d.currencyCode),
            timezone = timezone?.takeIf { it.isNotBlank() },
            areaUnit = s(areaUnit, d.areaUnit),
            volumeUnit = s(volumeUnit, d.volumeUnit),
            distanceUnit = s(distanceUnit, d.distanceUnit),
            fuelUnit = s(fuelUnit, d.fuelUnit),
            sprayRateAreaUnit = s(sprayRateAreaUnit, d.sprayRateAreaUnit),
            dateFormat = s(dateFormat, d.dateFormat),
            terminologyRegion = s(terminologyRegion, d.terminologyRegion),
        )
    }

    suspend fun get(vineyardId: String): RegionSettings? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_vineyard_region_settings")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(GetArgs(vineyardId))
        }
        rows(response).firstOrNull()?.toSettings()
    }

    suspend fun set(vineyardId: String, s: RegionSettings): RegionSettings = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("set_vineyard_region_settings")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(
                SetArgs(
                    vineyardId = vineyardId,
                    countryCode = s.countryCode,
                    currencyCode = s.currencyCode,
                    timezone = s.timezone,
                    areaUnit = s.areaUnit,
                    volumeUnit = s.volumeUnit,
                    distanceUnit = s.distanceUnit,
                    fuelUnit = s.fuelUnit,
                    sprayRateAreaUnit = s.sprayRateAreaUnit,
                    dateFormat = s.dateFormat,
                    terminologyRegion = s.terminologyRegion,
                )
            )
        }
        rows(response).firstOrNull()?.toSettings()
            ?: throw BackendError.Server(response.status.value, "Empty response")
    }

    private suspend fun rows(response: HttpResponse): List<RegionRow> = when {
        response.status.isSuccess() -> response.body()
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
