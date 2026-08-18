package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalVerification
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

    /**
     * Reference to an approved Master Chemical Catalogue row (sql/199) that a
     * structured lookup was served from. Mirrors iOS `ChemicalMasterMatch`.
     *
     * Carried through Match & Verify so the saved record can retain
     * `master_chemical_id` plus the catalogue revision its chemistry was
     * copied at (`master_source_revision`) — the provenance Re-verify later
     * compares to surface “Updated verified information available”.
     */
    @Serializable
    data class ChemicalMasterMatch(
        @SerialName("master_chemical_id") val masterChemicalId: String = "",
        @SerialName("master_revision") val masterRevision: Int = 1,
        @SerialName("catalogue_status") val catalogueStatus: String? = null,
        @SerialName("registration_identity_key") val registrationIdentityKey: String? = null,
    )

    /**
     * The structured payload returned by the `structured` lookup action.
     *
     * Deliberately a transport type: converted into [ChemicalIntelligence] via
     * [intelligence] so everything downstream reads one model.
     */
    @Serializable
    data class ChemicalStructuredLookup(
        @SerialName("product_name") val productName: String? = null,
        @SerialName("product_category") val productCategory: String? = null,
        @SerialName("form_type") val formType: String? = null,
        val registration: ChemicalRegistration? = null,
        @SerialName("active_ingredients")
        val activeIngredients: List<ChemicalActiveIngredient> = emptyList(),
        @SerialName("activity_groups") val activityGroups: List<String> = emptyList(),
        @SerialName("registered_uses") val registeredUses: List<ChemicalRegisteredUse> = emptyList(),
        @SerialName("label_rate_bases") val labelRateBases: List<String> = emptyList(),
        val verification: ChemicalVerification = ChemicalVerification(),
        @SerialName("activity_group_table_version") val activityGroupTableVersion: Int = 0,
        @SerialName("schema_version") val schemaVersion: Int = 0,
        // ---- Additive sql/199 envelope (absent on pre-catalogue servers) ----
        /** "master" | "ai_candidate" | "unresolved" | null (old server). */
        @SerialName("match_source") val matchSource: String? = null,
        /** Present only on master-served responses. */
        val master: ChemicalMasterMatch? = null,
    ) {
        /**
         * True when this lookup was served from an APPROVED master catalogue
         * row and carries the reference the saved record should retain.
         */
        val isMasterMatch: Boolean
            get() = matchSource == "master" && master?.masterChemicalId?.isNotBlank() == true

        /**
         * Converts the lookup into the single structured model.
         *
         * Every active's group is re-reconciled against the ON-DEVICE
         * authoritative table as well as the server's. That is not redundant: a
         * device running a newer classification table than the deployed edge
         * function still catches a disagreement, and a stale server response can
         * never quietly install a group the app itself would reject.
         */
        fun intelligence(): ChemicalIntelligence {
            var verification = this.verification
            val actives = activeIngredients.map { active ->
                val outcome = AuthoritativeActivityGroups.reconcile(
                    activeName = active.name,
                    extracted = active.activityGroup,
                    extractedSource = active.groupSource
                        ?: ChemicalDataSourceKind.AI_INTERPRETATION,
                )
                outcome.conflict?.let { verification = verification.addingConflict(it) }
                active.copy(activityGroup = outcome.group, groupSource = outcome.source)
            }

            if (verification.sources.none {
                    it.kind == ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION
                } && actives.any { it.hasAuthoritativeGroup }
            ) {
                verification = verification.copy(
                    sources = verification.sources + AuthoritativeActivityGroups.source(),
                )
            }

            return ChemicalIntelligence(
                activeIngredients = actives,
                registration = registration,
                verification = verification,
                registeredUses = registeredUses,
                productCategory = productCategory.orEmpty(),
                activityGroupTableVersion = maxOf(
                    activityGroupTableVersion,
                    AuthoritativeActivityGroups.TABLE_VERSION,
                ),
                schemaVersion = maxOf(
                    schemaVersion,
                    ChemicalIntelligence.CURRENT_SCHEMA_VERSION,
                ),
            )
        }
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

    /**
     * Structured Chemical Intelligence lookup.
     *
     * Returns actives, groups, registration, registered uses and label rate
     * bases as MACHINE-READABLE fields, plus the verification evidence behind
     * them. The server cross-checks every extracted activity group against the
     * authoritative FRAC/HRAC/IRAC table before replying, so a disagreement
     * arrives as a conflict rather than a silently overwritten value.
     *
     * The result is never verified: the lookup can identify a candidate and
     * classify its chemistry, but confirming product identity is a human step.
     */
    suspend fun lookupStructured(productName: String, country: String): ChemicalStructuredLookup =
        withContext(Dispatchers.IO) {
            val payload = buildMap {
                put("action", "structured")
                put("productName", productName)
                if (country.isNotBlank()) put("country", country)
            }
            val data = postEdge(payload)
            try {
                SupabaseClient.json.decodeFromString<ChemicalStructuredLookup>(data)
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
