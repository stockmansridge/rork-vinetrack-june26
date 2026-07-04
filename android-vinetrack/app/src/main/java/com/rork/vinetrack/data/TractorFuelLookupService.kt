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
import kotlinx.serialization.Serializable

/**
 * AI-assisted tractor fuel-rate lookup, mirroring the iOS
 * `TractorFuelLookupService`. Talks to the shared `tractor-fuel-lookup`
 * Supabase edge function which estimates fuel consumption (L/hr) under working
 * load from a brand/model/year. The AI value is a starting estimate only —
 * real fuel-log and trip data should refine the machine's rate over time.
 */
class TractorFuelLookupService {

    /** Successful edge-function payload, including the AI's matched-tractor echo. */
    @Serializable
    data class FuelLookupResult(
        val fuelUsageLPerHour: Double = 0.0,
        val confidence: String? = null,
        val notes: String? = null,
        val matchedBrand: String? = null,
        val matchedModel: String? = null,
        val matchedYearRange: String? = null,
    ) {
        /**
         * True when the AI returned a usable identification — a non-empty
         * matched-model echo and a confidence other than "low". Mirrors the
         * iOS `FuelLookupResult.isReliableMatch`.
         */
        val isReliableMatch: Boolean
            get() = !matchedModel.isNullOrBlank() && !confidence.equals("low", ignoreCase = true)

        /** Friendly "Brand Model · YearRange" label of what the AI referenced. */
        fun matchedLabel(fallback: String): String {
            val head = listOfNotNull(
                matchedBrand?.trim()?.takeIf { it.isNotEmpty() },
                matchedModel?.trim()?.takeIf { it.isNotEmpty() },
            ).joinToString(" ")
            val primary = head.ifEmpty { fallback }
            val years = matchedYearRange?.trim().orEmpty()
            return if (years.isNotEmpty()) "$primary · $years" else primary
        }
    }

    /**
     * One of four mutually-exclusive lookup outcomes, mirroring the iOS
     * `LookupOutcome`. The AI never silently overwrites the user's entered
     * value — callers must let the user explicitly apply a match.
     */
    sealed interface LookupOutcome {
        /** Reliable AI match — confirm with the user before applying. */
        data class Match(val result: FuelLookupResult) : LookupOutcome

        /** AI returned a low-confidence guess / no model echo. */
        data class Uncertain(val result: FuelLookupResult) : LookupOutcome

        /** AI ran but couldn't identify the tractor at all. */
        data class NoMatch(val message: String) : LookupOutcome

        /** Network/API failure — manual entry only; retain user input. */
        data class Unavailable(val message: String) : LookupOutcome
    }

    @Serializable
    private data class LookupRequest(val brand: String, val model: String, val year: Int? = null)

    @Serializable
    private data class EdgeError(val error: String? = null)

    /**
     * Estimate fuel use for a tractor. Never throws — all failure modes are
     * folded into the returned [LookupOutcome] so the UI can show the right
     * message without losing the user's entered data.
     */
    suspend fun lookupFuelUsage(brand: String, model: String, year: Int?): LookupOutcome =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured || SupabaseClient.anonKey.isBlank()) {
                return@withContext LookupOutcome.Unavailable(
                    "Tractor lookup is not configured. Please try again later.",
                )
            }
            val response = try {
                SupabaseClient.http.post(SupabaseClient.functionUrl("tractor-fuel-lookup")) {
                    headers {
                        append("apikey", SupabaseClient.anonKey)
                        append("Authorization", "Bearer ${SupabaseClient.anonKey}")
                    }
                    contentType(ContentType.Application.Json)
                    setBody(LookupRequest(brand = brand.trim(), model = model.trim(), year = year))
                }
            } catch (e: Exception) {
                // Transport failures — lookup unavailable, user input retained.
                return@withContext LookupOutcome.Unavailable(
                    "Tractor lookup is unavailable right now. You can still enter the fuel rate manually. (${e.message ?: "network error"})",
                )
            }
            val text = response.bodyAsText()
            if (!response.status.isSuccess()) {
                val message = try {
                    SupabaseClient.json.decodeFromString<EdgeError>(text).error
                } catch (e: Exception) {
                    null
                }
                return@withContext when {
                    message != null && message.contains("OPENAI_API_KEY") ->
                        LookupOutcome.Unavailable("AI provider key is not set on the server. Ask an admin to configure it.")
                    // 502 with "Could not determine fuel usage" → AI ran but
                    // couldn't identify; everything else is service failure.
                    response.status.value == 502 && message?.contains("determine", ignoreCase = true) == true ->
                        LookupOutcome.NoMatch("We couldn't find a reliable tractor match.")
                    else -> LookupOutcome.Unavailable(
                        "Tractor lookup is unavailable right now. You can still enter the fuel rate manually. (${message ?: "HTTP ${response.status.value}"})",
                    )
                }
            }
            val result = try {
                SupabaseClient.json.decodeFromString<FuelLookupResult>(text)
            } catch (e: Exception) {
                return@withContext LookupOutcome.NoMatch("We couldn't find a reliable tractor match.")
            }
            when {
                result.fuelUsageLPerHour <= 0.0 -> LookupOutcome.NoMatch("We couldn't find a reliable tractor match.")
                result.isReliableMatch -> LookupOutcome.Match(result)
                else -> LookupOutcome.Uncertain(result)
            }
        }
}
