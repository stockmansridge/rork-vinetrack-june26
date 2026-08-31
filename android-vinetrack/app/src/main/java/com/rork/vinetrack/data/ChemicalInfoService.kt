package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.AuthoritativeActivityGroups
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalDataSourceKind
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalProvenanceMapSerializer
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalServerDefaultRateOptions
import com.rork.vinetrack.data.chemical.ChemicalVerification
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

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
        /**
         * Registration number carried by official-register CANDIDATE rows
         * (additive; DISCOVERY only — a listing grants nothing). Selecting
         * the candidate passes this back as the identity hint so the strict
         * server-side resolver verifies that exact identity against the
         * register before anything binds. Mirrors iOS `ChemicalSearchResult`.
         */
        @SerialName("registration_number") val registrationNumber: String? = null,
        /** "master" | "official_register" | null (AI suggestion / older server). */
        val source: String? = null,
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
        /**
         * The server's own canonical default-rate options, carrying the
         * `option_key` and `rate_ids` a confirmed default must be persisted
         * with.
         *
         * Absent on a pre-`default_rate_options` server. Absent is NOT an
         * invitation to rebuild them here: without this block there is no
         * canonical option, the review screen fails closed, and the operator
         * is offered the corrective actions instead. Re-deriving them on
         * device is what produced identities no other client could match.
         */
        @SerialName("default_rate_options")
        val defaultRateOptions: ChemicalServerDefaultRateOptions? = null,
        /**
         * Per-field evidence tiers recorded by the resolver (`field_provenance`
         * at top level; each registered use additionally carries its own
         * `provenance` map). Decoded tolerantly and carried VERBATIM into
         * [ChemicalIntelligence] — absent on pre-provenance servers, never
         * invented on device. Mirrors iOS `ChemicalStructuredLookup`.
         */
        @Serializable(with = ChemicalProvenanceMapSerializer::class)
        @SerialName("field_provenance")
        val fieldProvenance: Map<String, String>? = null,
        val verification: ChemicalVerification = ChemicalVerification(),
        @SerialName("activity_group_table_version") val activityGroupTableVersion: Int = 0,
        @SerialName("schema_version") val schemaVersion: Int = 0,
        // ---- Additive sql/199 envelope (absent on pre-catalogue servers) ----
        /**
         * "master" | "authoritative_candidate" | "ai_candidate" |
         * "unresolved" | null (old server). Stage 3 adds
         * "authoritative_candidate": register-backed but NOT approved —
         * handled exactly like an AI candidate everywhere except provenance
         * display.
         */
        @SerialName("match_source") val matchSource: String? = null,
        /** Present only on master-served responses. */
        val master: ChemicalMasterMatch? = null,
    ) {
        /**
         * True when this lookup was served from an APPROVED master catalogue
         * row and carries the reference the saved record should retain.
         *
         * Stage 3 hardening: an automatically generated CANDIDATE must never
         * read as a master match — a master block carrying a non-approved
         * `catalogue_status` is rejected outright. A missing status reads as
         * approved (pre-Stage-3 servers only ever served approved rows here).
         */
        val isMasterMatch: Boolean
            get() = matchSource == "master" &&
                master?.masterChemicalId?.isNotBlank() == true &&
                (master?.catalogueStatus ?: "approved") == "approved"

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
                // Stored verbatim: the resolver's own record of which evidence
                // tier populated each field. Never derived or upgraded here.
                fieldProvenance = fieldProvenance,
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
            // A slow search is normal (the advisory says so); a HUNG one is
            // not. The bound matches the iOS `searchTimeout`, and hitting it
            // surfaces the ordinary retry/manual options — never an automatic
            // downgrade to manual entry.
            val data = try {
                withTimeout(SEARCH_TIMEOUT_MS) { postEdge(payload) }
            } catch (e: TimeoutCancellationException) {
                throw LookupException(
                    "The register search is taking longer than expected. Try again — " +
                        "repeat lookups are usually faster.",
                )
            }
            try {
                SupabaseClient.json.decodeFromString<ChemicalSearchResponse>(data).results
            } catch (e: Exception) {
                throw LookupException("AI returned an unexpected response. Please try again.")
            }
        }

    /**
     * LEGACY AI info path — quarantined (P3C).
     *
     * This transport remains only to mirror the iOS `ChemicalInfoService`,
     * where it likewise has no app call site. Its output (`ratesPerHectare`,
     * `ratesPer100L`, `labelURL`) is AI interpretation with no label evidence
     * behind it, so NO UI path may write it into a chemical's working rate
     * fields, label URL, or any other authoritative field. Rates, label
     * documents and registered uses arrive through the structured lookup with
     * verification evidence — or the operator types them. Fail closed.
     */
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
    suspend fun lookupStructured(
        productName: String,
        country: String,
        registrationNumber: String? = null,
    ): ChemicalStructuredLookup =
        withContext(Dispatchers.IO) {
            val payload = buildMap {
                put("action", "structured")
                put("productName", productName)
                if (country.isNotBlank()) put("country", country)
                // Identity hint from a selected register candidate. Only ever
                // a POINTER: the server re-verifies name↔number against the
                // official register before anything binds.
                if (!registrationNumber.isNullOrBlank()) {
                    put("registrationNumber", registrationNumber)
                }
            }
            // First-time structured lookups legitimately take minutes (label
            // PDF + Directions For Use extraction). The generous bound mirrors
            // the iOS `structuredLookupTimeout` raised after the Dithane
            // timeout audit — a slow lookup is never treated as failed before
            // this, and timing out offers Try Again rather than silently
            // degrading to manual.
            val data = try {
                withTimeout(STRUCTURED_TIMEOUT_MS) { postEdge(payload) }
            } catch (e: TimeoutCancellationException) {
                throw LookupException(
                    "Loading this product's registered details timed out. Try again — " +
                        "repeat lookups are usually faster.",
                )
            }
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
        } catch (e: CancellationException) {
            // Includes the withTimeout bound above — cancellation must
            // propagate for the caller to translate, never be swallowed into
            // a generic failure message.
            throw e
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
        /** Search action bound, matching the iOS `ChemicalInfoService.searchTimeout`. */
        const val SEARCH_TIMEOUT_MS: Long = 30_000L

        /**
         * Structured lookup bound, matching the iOS
         * `ChemicalInfoService.structuredLookupTimeout` (raised after the
         * Dithane timeout audit — first-time label extraction is minutes).
         */
        const val STRUCTURED_TIMEOUT_MS: Long = 180_000L

        /**
         * Resolves the jurisdiction country for chemical lookups.
         *
         * The vineyard profile is the ONLY source. Product registration is
         * country-scoped law, and the device locale says where the PHONE is
         * set up, not where the vines grow — an AU-region phone managing an
         * NZ vineyard must never silently check the APVMA register. When the
         * vineyard has no country this returns empty and the lookup flows
         * fail closed (search disabled, re-verify refused, nothing
         * verifiable) instead of guessing. Mirrors the iOS
         * `ChemicalInfoService.resolveCountry`.
         */
        fun resolveCountry(vineyardCountry: String?): String = vineyardCountry?.trim().orEmpty()
    }
}
