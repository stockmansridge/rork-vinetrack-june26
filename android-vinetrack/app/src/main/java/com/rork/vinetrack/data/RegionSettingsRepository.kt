package com.rork.vinetrack.data

import android.util.Log
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
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Read/write path for vineyard-level Region & Units settings, mirroring the iOS
 * `SupabaseVineyardRepository.getVineyardRegionSettings` /
 * `setVineyardRegionSettings`. Backed by the `get_vineyard_region_settings` /
 * `set_vineyard_region_settings` RPCs (sql/099 + the 12-parameter sugar-unit
 * overload from sql/180). Any member may read; the set RPC enforces
 * owner/manager server-side.
 *
 * The settings themselves live on the shared `public.vineyards` row, so iOS,
 * Android and the web portal all read and write the same record — there is no
 * Android-specific storage. [RegionSettingsStore] only caches a copy locally
 * for instant first paint.
 *
 * ## PostgREST overload resolution (why payloads are built by hand)
 *
 * PostgREST picks a function overload by the exact SET OF ARGUMENT NAMES in the
 * JSON body. The shared [SupabaseClient.json] is configured with
 * `explicitNulls = false`, which DROPS null properties when serialising a
 * `@Serializable` class — so a settings payload with a null timezone and no
 * explicit sugar preference arrived as only 10 keys, matching neither the
 * 12-parameter nor the legacy 11-parameter overload, and PostgREST answered
 * `404 PGRST202` ("Could not find the function ... in the schema cache").
 *
 * Payloads are therefore built as explicit [JsonObject]s (see
 * [RegionSettingsPayload]) where a null value is a literal JSON `null`, which
 * is exactly what the iOS client sends via its custom `encode(to:)`.
 */
class RegionSettingsRepository(private val session: SessionStore) {

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
        @SerialName("sugar_measurement_unit") val sugarMeasurementUnit: String? = null,
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
            sugarMeasurementUnit = sugarMeasurementUnit?.takeIf { it.isNotBlank() } ?: "",
        )
    }

    /** Read the shared settings for [vineyardId]. Null when the row is missing. */
    suspend fun get(vineyardId: String): RegionSettings? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = post(GET_RPC, RegionSettingsPayload.getArgs(vineyardId), token)
        rows(response, operation = "load", rpc = GET_RPC).firstOrNull()?.toSettings()
    }

    /**
     * Write the shared settings for [vineyardId] and return the authoritative
     * server row. Owner/manager only (enforced by the RPC).
     *
     * If the deployed backend only has the legacy 11-parameter overload (no
     * sugar preference), the 12-parameter call answers `404 PGRST202`; we then
     * retry once against the legacy shape so saving still succeeds rather than
     * dead-ending the user.
     */
    suspend fun set(vineyardId: String, s: RegionSettings): RegionSettings = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized

        var response = post(SET_RPC, RegionSettingsPayload.setArgs(vineyardId, s), token)
        if (response.status.value == 404) {
            val detail = response.bodyAsText()
            Log.w(
                TAG,
                "save: $SET_RPC 12-param overload returned 404 " +
                    "(${detail.take(MAX_LOGGED_DETAIL)}) — retrying legacy 11-param overload",
            )
            response = post(
                SET_RPC,
                RegionSettingsPayload.setArgs(vineyardId, s, includeSugarUnit = false),
                token,
            )
        }

        val saved = rows(response, operation = "save", rpc = SET_RPC).firstOrNull()?.toSettings()
            ?: throw RegionSettingsException(
                operation = "save",
                rpc = SET_RPC,
                statusCode = response.status.value,
                serverDetail = "empty response body",
                message = "Region & Units were not saved — the server returned no settings. Please try again.",
            )
        // The legacy overload never writes the sugar preference; keep the value
        // the user chose so the UI and cache stay truthful for this session.
        if (saved.sugarMeasurementUnit.isBlank() && s.sugarMeasurementUnit.isNotBlank()) {
            saved.copy(sugarMeasurementUnit = s.sugarMeasurementUnit)
        } else {
            saved
        }
    }

    private suspend fun post(rpc: String, body: JsonObject, token: String): HttpResponse =
        SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(body)
        }

    private suspend fun rows(
        response: HttpResponse,
        operation: String,
        rpc: String,
    ): List<RegionRow> {
        if (response.status.isSuccess()) {
            return SupabaseClient.json.decodeFromString(response.bodyAsText())
        }
        val status = response.status.value
        val detail = runCatching { response.bodyAsText() }.getOrElse { "" }
        // Developer diagnostics: operation, backend resource, status and the
        // server's own error body (PostgREST hint/code lives here).
        Log.e(
            TAG,
            "$operation failed: POST /rest/v1/rpc/$rpc -> HTTP $status; body=${detail.take(MAX_LOGGED_DETAIL)}",
        )
        if (status == 401 || status == 403) throw BackendError.Unauthorized
        throw RegionSettingsException(
            operation = operation,
            rpc = rpc,
            statusCode = status,
            serverDetail = detail,
            message = friendlyMessage(operation, status),
        )
    }

    private fun friendlyMessage(operation: String, status: Int): String {
        val what = if (operation == "save") "save" else "load"
        return when (status) {
            404 -> "Couldn't $what Region & Units — the settings service didn't accept this request. " +
                "Please try again, and contact support if it keeps happening."
            409 -> "Couldn't $what Region & Units — these settings were changed elsewhere. " +
                "Reopen the screen and try again."
            in 500..599 -> "Couldn't $what Region & Units — the server is temporarily unavailable. Please try again."
            else -> "Couldn't $what Region & Units (error $status). Please try again."
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

    companion object {
        private const val TAG = "RegionSettings"
        private const val MAX_LOGGED_DETAIL = 400
        const val GET_RPC = "get_vineyard_region_settings"
        const val SET_RPC = "set_vineyard_region_settings"
    }
}

/**
 * Region & Units backend failure carrying developer diagnostics ([operation],
 * [rpc], [statusCode], [serverDetail]) while [message] stays customer-facing.
 */
class RegionSettingsException(
    val operation: String,
    val rpc: String,
    val statusCode: Int?,
    val serverDetail: String?,
    override val message: String,
) : Exception(message)

/**
 * Builds the RPC argument objects for the shared region-settings contract.
 *
 * Pure and side-effect free so the exact wire shape can be unit tested: every
 * named parameter of the chosen overload is ALWAYS present (null values are
 * literal JSON `null`), which is what PostgREST needs to resolve between the
 * 11-parameter (sql/099) and 12-parameter (sql/180) overloads.
 */
object RegionSettingsPayload {

    /** Named parameters of the legacy 11-parameter overload (sql/099). */
    val LEGACY_SET_KEYS: List<String> = listOf(
        "p_vineyard_id",
        "p_country_code",
        "p_currency_code",
        "p_timezone",
        "p_area_unit",
        "p_volume_unit",
        "p_distance_unit",
        "p_fuel_unit",
        "p_spray_rate_area_unit",
        "p_date_format",
        "p_terminology_region",
    )

    /** Named parameters of the current 12-parameter overload (sql/180). */
    val SET_KEYS: List<String> = LEGACY_SET_KEYS + "p_sugar_measurement_unit"

    fun getArgs(vineyardId: String): JsonObject = buildJsonObject {
        put("p_vineyard_id", vineyardId)
    }

    fun setArgs(
        vineyardId: String,
        s: RegionSettings,
        includeSugarUnit: Boolean = true,
    ): JsonObject = buildJsonObject {
        put("p_vineyard_id", vineyardId)
        putNullable("p_country_code", s.countryCode)
        putNullable("p_currency_code", s.currencyCode)
        putNullable("p_timezone", s.timezone)
        putNullable("p_area_unit", s.areaUnit)
        putNullable("p_volume_unit", s.volumeUnit)
        putNullable("p_distance_unit", s.distanceUnit)
        putNullable("p_fuel_unit", s.fuelUnit)
        putNullable("p_spray_rate_area_unit", s.sprayRateAreaUnit)
        putNullable("p_date_format", s.dateFormat)
        putNullable("p_terminology_region", s.terminologyRegion)
        if (includeSugarUnit) {
            putNullable("p_sugar_measurement_unit", s.sugarMeasurementUnit)
        }
    }

    /** Blank means "no explicit value" — sent as JSON null, never omitted. */
    private fun kotlinx.serialization.json.JsonObjectBuilder.putNullable(key: String, value: String?) {
        val trimmed = value?.trim()
        if (trimmed.isNullOrEmpty()) put(key, JsonNull) else put(key, trimmed)
    }
}
