package com.rork.vinetrack.data

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
import java.util.Locale

/**
 * AI-assisted chemical lookup, mirroring the iOS `ChemicalInfoService`. Talks to
 * the shared `chemical-info-lookup` Supabase edge function (action `search` for
 * a result list, `info` for a single product's details). Results are advisory
 * and must be checked against the official label before use.
 */
class ChemicalInfoService {

    /** One product candidate returned by the `search` action. */
    @Serializable
    data class ChemicalSearchResult(
        val name: String = "",
        val activeIngredient: String = "",
        val chemicalGroup: String = "",
        val brand: String = "",
        val primaryUse: String = "",
        val modeOfAction: String = "",
    )

    @Serializable
    private data class ChemicalSearchResponse(val results: List<ChemicalSearchResult> = emptyList())

    @Serializable
    data class ChemicalRateInfo(val label: String = "", val value: Double = 0.0)

    /** Full detail payload returned by the `info` action. */
    @Serializable
    data class ChemicalInfoResponse(
        val activeIngredient: String = "",
        val brand: String = "",
        val chemicalGroup: String = "",
        val labelURL: String = "",
        val productURL: String? = null,
        val sdsURL: String? = null,
        val primaryUse: String = "",
        val ratesPerHectare: List<ChemicalRateInfo>? = null,
        val ratesPer100L: List<ChemicalRateInfo>? = null,
        val formType: String? = null,
        val modeOfAction: String? = null,
    ) {
        /** Liquid unless the form type clearly reads as a solid/dry formulation. */
        val isLiquid: Boolean
            get() {
                val form = formType?.lowercase() ?: return true
                return !listOf("solid", "granul", "powder", "wettable", "dry", "wdg", "wg", "wp", "df")
                    .any { form.contains(it) }
            }

        /** Default display unit implied by the form type. */
        val defaultUnit: String get() = if (isLiquid) "Litres" else "Kg"
    }

    @Serializable
    private data class EdgeError(val error: String? = null)

    /** A failed lookup with a user-facing message. */
    class LookupException(message: String) : Exception(message)

    suspend fun searchChemicals(query: String, country: String): List<ChemicalSearchResult> =
        withContext(Dispatchers.IO) {
            val payload = buildMap {
                put("action", "search")
                put("query", query)
                if (country.isNotBlank()) put("country", country)
            }
            val data = postEdge(payload)
            try {
                SupabaseClient.json.decodeFromString<ChemicalSearchResponse>(data).results
            } catch (e: Exception) {
                throw LookupException("AI returned an unexpected response. Please try again.")
            }
        }

    suspend fun lookupChemicalInfo(productName: String, country: String): ChemicalInfoResponse =
        withContext(Dispatchers.IO) {
            val payload = buildMap {
                put("action", "info")
                put("productName", productName)
                if (country.isNotBlank()) put("country", country)
            }
            val data = postEdge(payload)
            try {
                SupabaseClient.json.decodeFromString<ChemicalInfoResponse>(data)
            } catch (e: Exception) {
                throw LookupException("AI returned an unexpected response. Please try again.")
            }
        }

    private suspend fun postEdge(payload: Map<String, String>): String {
        if (!SupabaseClient.isConfigured) {
            throw LookupException("AI lookup is not configured. Please try again later.")
        }
        val anonKey = SupabaseClient.anonKey
        if (anonKey.isBlank()) {
            throw LookupException("AI lookup is not configured. Please try again later.")
        }
        val response = try {
            SupabaseClient.http.post(SupabaseClient.functionUrl("chemical-info-lookup")) {
                headers {
                    append("apikey", anonKey)
                    append("Authorization", "Bearer $anonKey")
                }
                contentType(ContentType.Application.Json)
                setBody(payload)
            }
        } catch (e: Exception) {
            throw LookupException("AI lookup failed: ${e.message ?: "network error"}")
        }
        val text = response.bodyAsText()
        if (response.status.isSuccess()) return text
        val message = try {
            SupabaseClient.json.decodeFromString<EdgeError>(text).error
        } catch (e: Exception) {
            null
        }
        if (message != null && message.contains("OPENAI_API_KEY")) {
            throw LookupException("AI provider key is not set on the server. Ask an admin to configure it.")
        }
        throw LookupException(message?.let { "AI lookup failed: $it" } ?: "AI lookup failed: HTTP ${response.status.value}")
    }

    companion object {
        /**
         * Resolve the localization country: prefer the explicit vineyard country,
         * else the device region's display name (e.g. "Australia"). Mirrors the
         * iOS `ChemicalInfoService.resolveCountry`.
         */
        fun resolveCountry(vineyardCountry: String?): String {
            val trimmed = vineyardCountry?.trim().orEmpty()
            if (trimmed.isNotEmpty()) return trimmed
            val region = Locale.getDefault().country
            if (region.isBlank()) return ""
            val display = Locale("", region).getDisplayCountry(Locale.ENGLISH)
            return display.ifBlank { region }
        }
    }
}
