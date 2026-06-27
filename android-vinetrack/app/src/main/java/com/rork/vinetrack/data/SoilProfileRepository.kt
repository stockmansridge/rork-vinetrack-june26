package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.BackendSoilProfile
import com.rork.vinetrack.data.model.NSWSeedSoilLookupResult
import com.rork.vinetrack.data.model.NSWSeedSoilSuggestion
import com.rork.vinetrack.data.model.SoilClassDefault
import com.rork.vinetrack.data.model.SoilProfileUpsert
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Read/write path for soil-aware irrigation, mirroring the iOS
 * `SupabaseSoilProfileRepository` and `NSWSeedSoilLookupService`. Backed by the
 * shared `get_soil_class_defaults` / `get_paddock_soil_profile` /
 * `get_vineyard_default_soil_profile` / `list_vineyard_soil_profiles` /
 * `upsert_paddock_soil_profile` / `upsert_vineyard_default_soil_profile` /
 * `delete_*` RPCs and the `nsw-seed-soil-lookup` edge function. RPC params and
 * column names match the iOS payloads exactly (sql/064-066).
 */
class SoilProfileRepository(private val session: SessionStore) {

    private val json = SupabaseClient.json

    suspend fun fetchSoilClassDefaults(): List<SoilClassDefault> = withContext(Dispatchers.IO) {
        val response = rpc("get_soil_class_defaults", buildJsonObject {})
        decodeRows(response)
    }

    suspend fun fetchPaddockSoilProfile(paddockId: String): BackendSoilProfile? =
        withContext(Dispatchers.IO) {
            val response = rpc("get_paddock_soil_profile", buildJsonObject {
                put("p_paddock_id", paddockId)
            })
            decodeProfiles(response).firstOrNull()
        }

    suspend fun fetchVineyardDefaultSoilProfile(vineyardId: String): BackendSoilProfile? =
        withContext(Dispatchers.IO) {
            val response = rpc("get_vineyard_default_soil_profile", buildJsonObject {
                put("p_vineyard_id", vineyardId)
            })
            decodeProfiles(response).firstOrNull()
        }

    suspend fun listVineyardSoilProfiles(vineyardId: String): List<BackendSoilProfile> =
        withContext(Dispatchers.IO) {
            val response = rpc("list_vineyard_soil_profiles", buildJsonObject {
                put("p_vineyard_id", vineyardId)
            })
            decodeProfiles(response)
        }

    suspend fun upsertSoilProfile(profile: SoilProfileUpsert): BackendSoilProfile? =
        withContext(Dispatchers.IO) {
            val paddockId = profile.paddockId
            val vineyardId = profile.vineyardId
            val (rpcName, params) = if (paddockId == null && vineyardId != null) {
                "upsert_vineyard_default_soil_profile" to upsertParams(profile, vineyardKey = vineyardId)
            } else {
                require(paddockId != null) { "Soil upsert requires a paddockId or vineyardId" }
                "upsert_paddock_soil_profile" to upsertParams(profile, paddockKey = paddockId)
            }
            val response = rpc(rpcName, params)
            decodeProfiles(response).firstOrNull()
        }

    suspend fun deleteSoilProfile(paddockId: String) = withContext(Dispatchers.IO) {
        val response = rpc("delete_paddock_soil_profile", buildJsonObject {
            put("p_paddock_id", paddockId)
        })
        ensureSuccess(response)
    }

    suspend fun deleteVineyardDefaultSoilProfile(vineyardId: String) = withContext(Dispatchers.IO) {
        val response = rpc("delete_vineyard_default_soil_profile", buildJsonObject {
            put("p_vineyard_id", vineyardId)
        })
        ensureSuccess(response)
    }

    /** Builds the shared upsert RPC param object. Exactly one key is set. */
    private fun upsertParams(
        p: SoilProfileUpsert,
        paddockKey: String? = null,
        vineyardKey: String? = null,
    ): JsonObject = buildJsonObject {
        if (paddockKey != null) put("p_paddock_id", paddockKey)
        if (vineyardKey != null) put("p_vineyard_id", vineyardKey)
        p.irrigationSoilClass?.let { put("p_irrigation_soil_class", it) }
        p.availableWaterCapacityMmPerM?.let { put("p_available_water_capacity_mm_per_m", it) }
        p.effectiveRootDepthM?.let { put("p_effective_root_depth_m", it) }
        p.managementAllowedDepletionPercent?.let { put("p_management_allowed_depletion_percent", it) }
        p.soilLandscape?.let { put("p_soil_landscape", it) }
        p.soilLandscapeCode?.let { put("p_soil_landscape_code", it) }
        p.australianSoilClassification?.let { put("p_australian_soil_classification", it) }
        p.australianSoilClassificationCode?.let { put("p_australian_soil_classification_code", it) }
        p.landSoilCapability?.let { put("p_land_soil_capability", it) }
        p.landSoilCapabilityClass?.let { put("p_land_soil_capability_class", it) }
        p.soilDescription?.let { put("p_soil_description", it) }
        p.soilTextureClass?.let { put("p_soil_texture_class", it) }
        p.confidence?.let { put("p_confidence", it) }
        put("p_is_manual_override", p.isManualOverride)
        p.manualNotes?.let { put("p_manual_notes", it) }
        put("p_source", p.source)
        p.sourceProvider?.let { put("p_source_provider", it) }
        p.sourceDataset?.let { put("p_source_dataset", it) }
        p.sourceFeatureId?.let { put("p_source_feature_id", it) }
        p.sourceName?.let { put("p_source_name", it) }
        p.countryCode?.let { put("p_country_code", it) }
        p.regionCode?.let { put("p_region_code", it) }
        put("p_model_version", p.modelVersion)
    }

    // MARK: - NSW SEED edge function

    /**
     * Calls the `nsw-seed-soil-lookup` edge function for a paddock centroid.
     * The NSW SEED API key stays server-side; we only pass the signed-in JWT.
     */
    suspend fun lookupNSWSeedSoil(
        vineyardId: String,
        paddockId: String,
        persist: Boolean = true,
    ): NSWSeedSoilLookupResult = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val payload = buildJsonObject {
            put("action", "lookup_paddock_soil")
            put("vineyardId", vineyardId.lowercase())
            put("paddockId", paddockId.lowercase())
            put("persist", persist)
        }
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl("nsw-seed-soil-lookup")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        val bodyText = response.bodyAsText()
        val body = runCatching { json.parseToJsonElement(bodyText).jsonObject }.getOrNull()
            ?: JsonObject(emptyMap())
        when {
            response.status.isSuccess() -> parsePaddockResult(body)
            response.status.value == 401 -> throw BackendError.Unauthorized
            response.status.value == 403 -> throw NSWSeedError(
                "You don't have access to fetch NSW SEED soil data for this vineyard."
            )
            response.status.value == 400 -> {
                val reason = body.stringOrNull("reason")
                when (reason) {
                    "unsupported_country" -> throw NSWSeedError(
                        "NSW SEED lookup is only available for Australian vineyards."
                    )
                    "paddock_missing_polygon" -> throw NSWSeedError(
                        "This block has no boundary polygon yet. Draw the block boundary before fetching NSW SEED soil data."
                    )
                    else -> throw NSWSeedError(
                        body.stringOrNull("error") ?: "NSW SEED service request failed."
                    )
                }
            }
            response.status.value == 404 -> throw NSWSeedError("Block not found.")
            response.status.value == 503 -> {
                if (body.stringOrNull("reason") == "missing_soil_landscape_endpoint") {
                    throw NSWSeedError("NSW SEED soil landscape endpoint is not configured on the server.")
                }
                throw NSWSeedError("NSW SEED service unavailable.")
            }
            else -> throw NSWSeedError(
                body.stringOrNull("error") ?: "NSW SEED service unavailable (HTTP ${response.status.value})."
            )
        }
    }

    private fun parsePaddockResult(body: JsonObject): NSWSeedSoilLookupResult {
        val suggestionObj = body["suggestion"]?.let { it as? JsonObject }
        val suggestion = suggestionObj?.let { parseSuggestion(it) }
        val found = (body["found"]?.jsonPrimitive?.booleanOrNull()) ?: (suggestion != null)
        val message = body.stringOrNull("message")
        val disclaimer = body.stringOrNull("disclaimer") ?: suggestion?.disclaimer
        return NSWSeedSoilLookupResult(
            found = found,
            suggestion = suggestion,
            message = message,
            disclaimer = disclaimer,
        )
    }

    private fun parseSuggestion(dict: JsonObject): NSWSeedSoilSuggestion {
        val keywords = (dict["matched_keywords"] as? kotlinx.serialization.json.JsonArray)
            ?.mapNotNull { it.jsonPrimitive.contentOrNull() } ?: emptyList()
        return NSWSeedSoilSuggestion(
            irrigationSoilClass = dict.stringOrNull("irrigation_soil_class"),
            confidence = dict.stringOrNull("confidence"),
            soilLandscape = dict.stringOrNull("soil_landscape"),
            soilLandscapeCode = dict.stringOrNull("soil_landscape_code"),
            australianSoilClassification = dict.stringOrNull("australian_soil_classification"),
            australianSoilClassificationCode = dict.stringOrNull("australian_soil_classification_code"),
            landSoilCapability = dict.stringOrNull("land_soil_capability"),
            landSoilCapabilityClass = dict.intOrNull("land_soil_capability_class"),
            sourceFeatureId = dict.stringOrNull("source_feature_id"),
            sourceName = dict.stringOrNull("source_name"),
            sourceDataset = dict.stringOrNull("source_dataset"),
            countryCode = dict.stringOrNull("country_code"),
            regionCode = dict.stringOrNull("region_code"),
            lookupLatitude = dict.doubleOrNull("lookup_latitude"),
            lookupLongitude = dict.doubleOrNull("lookup_longitude"),
            modelVersion = dict.stringOrNull("model_version"),
            matchedKeywords = keywords,
            disclaimer = dict.stringOrNull("disclaimer"),
        )
    }

    // MARK: - Plumbing

    private suspend fun rpc(name: String, params: JsonObject): HttpResponse {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        return SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(params)
        }
    }

    private suspend fun decodeProfiles(response: HttpResponse): List<BackendSoilProfile> {
        val text = ensureSuccess(response)
        if (text.isBlank()) return emptyList()
        return json.decodeFromString(text)
    }

    private suspend fun decodeRows(response: HttpResponse): List<SoilClassDefault> {
        val text = ensureSuccess(response)
        if (text.isBlank()) return emptyList()
        return json.decodeFromString(text)
    }

    private suspend fun ensureSuccess(response: HttpResponse): String = when {
        response.status.isSuccess() -> response.bodyAsText()
        response.status.value == 401 || response.status.value == 403 -> {
            val body = response.bodyAsText()
            if (body.contains("not_authorized")) {
                throw NSWSeedError("You don't have permission to edit the soil profile for this paddock.")
            }
            throw BackendError.Unauthorized
        }
        else -> {
            val body = response.bodyAsText()
            throw mapSoilError(response.status.value, body)
        }
    }

    private fun mapSoilError(code: Int, body: String): Exception {
        val lower = body.lowercase()
        val message = when {
            lower.contains("invalid_awc") -> "Available water capacity must be between 0 and 400 mm/m."
            lower.contains("invalid_root_depth") -> "Effective root depth must be between 0 and 5 m."
            lower.contains("invalid_allowed_depletion") -> "Allowed depletion must be between 0 and 100%."
            lower.contains("invalid_irrigation_soil_class") -> "Unknown irrigation soil class."
            lower.contains("paddock_not_found") -> "Block not found."
            lower.contains("not_authorized") -> "You don't have permission to edit the soil profile for this paddock."
            else -> null
        }
        return if (message != null) SoilValidationError(message) else BackendError.Server(code, body)
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

/** A friendly, already-localised soil validation message surfaced to the UI. */
class SoilValidationError(message: String) : Exception(message)

/** A friendly NSW SEED lookup error surfaced to the UI. */
class NSWSeedError(message: String) : Exception(message)

private fun kotlinx.serialization.json.JsonPrimitive.booleanOrNull(): Boolean? =
    content.toBooleanStrictOrNull()

private fun kotlinx.serialization.json.JsonPrimitive.contentOrNull(): String? =
    if (this is kotlinx.serialization.json.JsonNull) null else content

private fun JsonObject.stringOrNull(key: String): String? {
    val el = this[key] ?: return null
    val prim = el as? kotlinx.serialization.json.JsonPrimitive ?: return null
    if (prim is kotlinx.serialization.json.JsonNull) return null
    return prim.content.takeIf { it.isNotBlank() }
}

private fun JsonObject.doubleOrNull(key: String): Double? =
    (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull()

private fun JsonObject.intOrNull(key: String): Int? =
    (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull()?.toInt()
