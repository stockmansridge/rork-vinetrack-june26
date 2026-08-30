package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalDataSource
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalVerificationConflict
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.patch
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
import java.time.Instant
import java.util.UUID

/**
 * Write path for the shared saved-chemicals library, mirroring the iOS
 * `saved_chemicals` sync contract (sql/011, sql/086, sql/087). RLS scopes
 * selects to vineyard members; inserts/updates require owner/manager; hard
 * deletes are blocked client-side, so deletion goes through the
 * `soft_delete_saved_chemicals` RPC.
 *
 * Edits use a **partial PATCH** of the Android-surfaced columns, mirroring the
 * iOS `EditSavedChemicalSheet.save()` write set: agronomic metadata, the dual
 * per-ha / per-100L `rates` JSONB (base-unit values), and the `purchase` JSONB
 * costing. All payloads use the iOS-compatible shapes so values round-trip
 * across platforms.
 */
class SavedChemicalRepository(private val session: SessionStore) {

    /**
     * Editable fields surfaced by the Android management form. The form builds
     * the [rates] list (base-unit values, preserving existing rate IDs) and the
     * already-resolved [purchase] snapshot, mirroring the iOS editor's `save()`.
     */
    data class ChemicalInput(
        val name: String,
        val unit: String,
        /** Legacy per-ha column in display units (kept in sync with [rates]). */
        val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        val activeIngredient: String?,
        val chemicalGroup: String?,
        val use: String?,
        val problem: String?,
        val manufacturer: String?,
        val notes: String?,
        val modeOfAction: String?,
        val labelUrl: String?,
        val productUrl: String?,
        /** Fully-resolved costing snapshot; null clears purchase tracking. */
        val purchase: ChemicalPurchase?,
        // Unified product-library fields (sql/111) — blank/null for ordinary
        // spray chemicals; populated for fertiliser/nutrient categories.
        val productCategory: String = "",
        val productForm: String = "",
        val packSize: Double? = null,
        val packUnit: String = "",
        val pricePerPack: Double? = null,
        val density: Double? = null,
        val nitrogenPercent: Double? = null,
        val phosphorusPercent: Double? = null,
        val potassiumPercent: Double? = null,
        val analysisBasis: String = "elemental",
        val organicCertified: Boolean = false,
        val inventoryQuantity: Double? = null,
        val inventoryUnit: String = "",
        val applicationNotes: String = "",
        /**
         * Structured Chemical Intelligence (sql/194). Null when the write came
         * from a path that carries no structured data — the columns are then
         * omitted entirely rather than blanked, so a legacy edit can never
         * destroy a previously verified record.
         */
        val intelligence: ChemicalIntelligence? = null,
        /**
         * Master Chemical Catalogue provenance (sql/199). Null means “leave
         * the stored link untouched” — `explicitNulls = false` omits the
         * columns from the write — so ordinary edits and AI-sourced re-matches
         * never clear or invent provenance. Only a master-served match sets
         * these, always together.
         */
        val masterChemicalId: String? = null,
        val masterSourceRevision: Int? = null,
    )

    /**
     * The sql/194 Chemical Intelligence columns, flattened for the REST body.
     *
     * Built once and read by both the insert and the patch shapes so the two
     * write paths cannot drift apart. Every field is nullable and the client's
     * `explicitNulls = false` means a null is OMITTED from the JSON — which is
     * what lets an intelligence-free edit leave the structured columns alone.
     *
     * `verificationStatus` deliberately persists [ChemicalIntelligence.resolvedVerificationStatus]
     * rather than the stored claim, so what lands in the database is the status
     * the evidence actually supports. Confidence can be lowered on write, never
     * raised.
     */
    private class IntelFields(intel: ChemicalIntelligence?) {
        val activeIngredients = intel?.activeIngredients
        val activityGroups = intel?.activityGroupCodes
        val activityGroupScheme = intel?.activityGroups?.firstOrNull()?.scheme?.raw
        val registrationCountry = intel?.registration?.countryCode?.takeIf { it.isNotBlank() }
        val registrationScheme = intel?.registration?.scheme?.raw
        val registrationNumber = intel?.registration?.registrationNumber
        val registrant = intel?.registration?.registrant
        val registeredProductName = intel?.registration?.registeredProductName
        // The REGULATOR's approved label. `regulatorLabelUrl` is the same fact
        // under the wire's newer name, so either may supply it — but a
        // MANUFACTURER document can never land here.
        val labelReference = intel?.registration?.let {
            it.labelReference ?: it.regulatorLabelUrl
        }
        // Persisted separately (sql/215) so opening and saving a chemical stops
        // discarding a manufacturer label the resolver had already validated.
        val manufacturerLabelUrl = intel?.registration?.manufacturerLabelUrl
        val manufacturerProductUrl = intel?.registration?.manufacturerProductUrl
        val labelVersion = intel?.registration?.labelVersion
        val verificationStatus = intel?.resolvedVerificationStatus?.raw
        val verificationSources = intel?.verification?.sources
        val verificationConflicts = intel?.verification?.conflicts
        val verificationUnresolvedFields = intel?.verification?.unresolvedFields
        val verifiedAt = intel?.verification?.verifiedAt
        val registeredUses = intel?.registeredUses
        val labelRateBases = intel?.labelRateBases?.map { it.raw }
        val activityGroupTableVersion = intel?.activityGroupTableVersion
        val intelligenceSchemaVersion = intel?.schemaVersion
    }

    @Serializable
    private data class ChemicalInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        val unit: String,
        @SerialName("rate_per_ha") val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        @SerialName("active_ingredient") val activeIngredient: String,
        @SerialName("chemical_group") val chemicalGroup: String,
        val use: String,
        val problem: String,
        val manufacturer: String,
        val notes: String,
        @SerialName("mode_of_action") val modeOfAction: String,
        @SerialName("label_url") val labelUrl: String,
        @SerialName("product_url") val productUrl: String,
        val purchase: ChemicalPurchase? = null,
        @SerialName("product_category") val productCategory: String = "",
        @SerialName("product_form") val productForm: String = "",
        @SerialName("pack_size") val packSize: Double? = null,
        @SerialName("pack_unit") val packUnit: String = "",
        @SerialName("price_per_pack") val pricePerPack: Double? = null,
        val density: Double? = null,
        @SerialName("nitrogen_percent") val nitrogenPercent: Double? = null,
        @SerialName("phosphorus_percent") val phosphorusPercent: Double? = null,
        @SerialName("potassium_percent") val potassiumPercent: Double? = null,
        @SerialName("analysis_basis") val analysisBasis: String = "elemental",
        @SerialName("organic_certified") val organicCertified: Boolean = false,
        @SerialName("inventory_quantity") val inventoryQuantity: Double? = null,
        @SerialName("inventory_unit") val inventoryUnit: String = "",
        @SerialName("application_notes") val applicationNotes: String = "",
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        // --- Chemical Intelligence (sql/194) ---
        @SerialName("active_ingredients") val activeIngredients: List<ChemicalActiveIngredient>? = null,
        @SerialName("activity_groups") val activityGroups: List<String>? = null,
        @SerialName("activity_group_scheme") val activityGroupScheme: String? = null,
        @SerialName("registration_country") val registrationCountry: String? = null,
        @SerialName("registration_scheme") val registrationScheme: String? = null,
        @SerialName("registration_number") val registrationNumber: String? = null,
        val registrant: String? = null,
        @SerialName("registered_product_name") val registeredProductName: String? = null,
        @SerialName("label_reference") val labelReference: String? = null,
        @SerialName("manufacturer_label_url") val manufacturerLabelUrl: String? = null,
        @SerialName("manufacturer_product_url") val manufacturerProductUrl: String? = null,
        @SerialName("label_version") val labelVersion: String? = null,
        @SerialName("verification_status") val verificationStatus: String? = null,
        @SerialName("verification_sources") val verificationSources: List<ChemicalDataSource>? = null,
        @SerialName("verification_conflicts")
        val verificationConflicts: List<ChemicalVerificationConflict>? = null,
        @SerialName("verification_unresolved_fields")
        val verificationUnresolvedFields: List<String>? = null,
        @SerialName("verified_at") val verifiedAt: String? = null,
        @SerialName("registered_uses") val registeredUses: List<ChemicalRegisteredUse>? = null,
        @SerialName("label_rate_bases") val labelRateBases: List<String>? = null,
        @SerialName("activity_group_table_version") val activityGroupTableVersion: Int? = null,
        @SerialName("intelligence_schema_version") val intelligenceSchemaVersion: Int? = null,
        // --- Master Chemical Catalogue (sql/199) ---
        @SerialName("master_chemical_id") val masterChemicalId: String? = null,
        @SerialName("master_source_revision") val masterSourceRevision: Int? = null,
    )

    @Serializable
    private data class ChemicalPatch(
        val name: String,
        val unit: String,
        @SerialName("rate_per_ha") val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        @SerialName("active_ingredient") val activeIngredient: String,
        @SerialName("chemical_group") val chemicalGroup: String,
        val use: String,
        val problem: String,
        val manufacturer: String,
        val notes: String,
        @SerialName("mode_of_action") val modeOfAction: String,
        @SerialName("label_url") val labelUrl: String,
        @SerialName("product_url") val productUrl: String,
        val purchase: ChemicalPurchase? = null,
        @SerialName("product_category") val productCategory: String = "",
        @SerialName("product_form") val productForm: String = "",
        @SerialName("pack_size") val packSize: Double? = null,
        @SerialName("pack_unit") val packUnit: String = "",
        @SerialName("price_per_pack") val pricePerPack: Double? = null,
        val density: Double? = null,
        @SerialName("nitrogen_percent") val nitrogenPercent: Double? = null,
        @SerialName("phosphorus_percent") val phosphorusPercent: Double? = null,
        @SerialName("potassium_percent") val potassiumPercent: Double? = null,
        @SerialName("analysis_basis") val analysisBasis: String = "elemental",
        @SerialName("organic_certified") val organicCertified: Boolean = false,
        @SerialName("inventory_quantity") val inventoryQuantity: Double? = null,
        @SerialName("inventory_unit") val inventoryUnit: String = "",
        @SerialName("application_notes") val applicationNotes: String = "",
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        // --- Chemical Intelligence (sql/194) ---
        @SerialName("active_ingredients") val activeIngredients: List<ChemicalActiveIngredient>? = null,
        @SerialName("activity_groups") val activityGroups: List<String>? = null,
        @SerialName("activity_group_scheme") val activityGroupScheme: String? = null,
        @SerialName("registration_country") val registrationCountry: String? = null,
        @SerialName("registration_scheme") val registrationScheme: String? = null,
        @SerialName("registration_number") val registrationNumber: String? = null,
        val registrant: String? = null,
        @SerialName("registered_product_name") val registeredProductName: String? = null,
        @SerialName("label_reference") val labelReference: String? = null,
        @SerialName("manufacturer_label_url") val manufacturerLabelUrl: String? = null,
        @SerialName("manufacturer_product_url") val manufacturerProductUrl: String? = null,
        @SerialName("label_version") val labelVersion: String? = null,
        @SerialName("verification_status") val verificationStatus: String? = null,
        @SerialName("verification_sources") val verificationSources: List<ChemicalDataSource>? = null,
        @SerialName("verification_conflicts")
        val verificationConflicts: List<ChemicalVerificationConflict>? = null,
        @SerialName("verification_unresolved_fields")
        val verificationUnresolvedFields: List<String>? = null,
        @SerialName("verified_at") val verifiedAt: String? = null,
        @SerialName("registered_uses") val registeredUses: List<ChemicalRegisteredUse>? = null,
        @SerialName("label_rate_bases") val labelRateBases: List<String>? = null,
        @SerialName("activity_group_table_version") val activityGroupTableVersion: Int? = null,
        @SerialName("intelligence_schema_version") val intelligenceSchemaVersion: Int? = null,
        // --- Master Chemical Catalogue (sql/199) ---
        @SerialName("master_chemical_id") val masterChemicalId: String? = null,
        @SerialName("master_source_revision") val masterSourceRevision: Int? = null,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class HardDeleteResult(
        val ok: Boolean = false,
        val reason: String? = null,
        val message: String? = null,
    )

    /** Outcome of a permanent-delete attempt, mirroring the iOS deletion service. */
    sealed interface HardDeleteOutcome {
        object Deleted : HardDeleteOutcome
        object NotFound : HardDeleteOutcome
        data class InUse(val message: String) : HardDeleteOutcome
    }

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: ChemicalInput): SavedChemical =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val intel = IntelFields(input.intelligence)
            val body = ChemicalInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                unit = input.unit,
                ratePerHa = input.ratePerHa,
                rates = input.rates,
                activeIngredient = input.activeIngredient.orEmpty(),
                chemicalGroup = input.chemicalGroup.orEmpty(),
                use = input.use.orEmpty(),
                problem = input.problem.orEmpty(),
                manufacturer = input.manufacturer.orEmpty(),
                notes = input.notes.orEmpty(),
                modeOfAction = input.modeOfAction.orEmpty(),
                labelUrl = input.labelUrl.orEmpty(),
                productUrl = input.productUrl.orEmpty(),
                purchase = input.purchase,
                productCategory = input.productCategory,
                productForm = input.productForm,
                packSize = input.packSize,
                packUnit = input.packUnit,
                pricePerPack = input.pricePerPack,
                density = input.density,
                nitrogenPercent = input.nitrogenPercent,
                phosphorusPercent = input.phosphorusPercent,
                potassiumPercent = input.potassiumPercent,
                analysisBasis = input.analysisBasis,
                organicCertified = input.organicCertified,
                inventoryQuantity = input.inventoryQuantity,
                inventoryUnit = input.inventoryUnit,
                applicationNotes = input.applicationNotes,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
                activeIngredients = intel.activeIngredients,
                activityGroups = intel.activityGroups,
                activityGroupScheme = intel.activityGroupScheme,
                registrationCountry = intel.registrationCountry,
                registrationScheme = intel.registrationScheme,
                registrationNumber = intel.registrationNumber,
                registrant = intel.registrant,
                registeredProductName = intel.registeredProductName,
                labelReference = intel.labelReference,
                manufacturerLabelUrl = intel.manufacturerLabelUrl,
                manufacturerProductUrl = intel.manufacturerProductUrl,
                labelVersion = intel.labelVersion,
                verificationStatus = intel.verificationStatus,
                verificationSources = intel.verificationSources,
                verificationConflicts = intel.verificationConflicts,
                verificationUnresolvedFields = intel.verificationUnresolvedFields,
                verifiedAt = intel.verifiedAt,
                registeredUses = intel.registeredUses,
                labelRateBases = intel.labelRateBases,
                activityGroupTableVersion = intel.activityGroupTableVersion,
                intelligenceSchemaVersion = intel.intelligenceSchemaVersion,
                masterChemicalId = input.masterChemicalId,
                masterSourceRevision = input.masterSourceRevision,
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("saved_chemicals")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: ChemicalInput): SavedChemical =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val intel = IntelFields(input.intelligence)
            val patch = ChemicalPatch(
                name = input.name,
                unit = input.unit,
                ratePerHa = input.ratePerHa,
                rates = input.rates,
                activeIngredient = input.activeIngredient.orEmpty(),
                chemicalGroup = input.chemicalGroup.orEmpty(),
                use = input.use.orEmpty(),
                problem = input.problem.orEmpty(),
                manufacturer = input.manufacturer.orEmpty(),
                notes = input.notes.orEmpty(),
                modeOfAction = input.modeOfAction.orEmpty(),
                labelUrl = input.labelUrl.orEmpty(),
                productUrl = input.productUrl.orEmpty(),
                purchase = input.purchase,
                productCategory = input.productCategory,
                productForm = input.productForm,
                packSize = input.packSize,
                packUnit = input.packUnit,
                pricePerPack = input.pricePerPack,
                density = input.density,
                nitrogenPercent = input.nitrogenPercent,
                phosphorusPercent = input.phosphorusPercent,
                potassiumPercent = input.potassiumPercent,
                analysisBasis = input.analysisBasis,
                organicCertified = input.organicCertified,
                inventoryQuantity = input.inventoryQuantity,
                inventoryUnit = input.inventoryUnit,
                applicationNotes = input.applicationNotes,
                clientUpdatedAt = nowIso(),
                activeIngredients = intel.activeIngredients,
                activityGroups = intel.activityGroups,
                activityGroupScheme = intel.activityGroupScheme,
                registrationCountry = intel.registrationCountry,
                registrationScheme = intel.registrationScheme,
                registrationNumber = intel.registrationNumber,
                registrant = intel.registrant,
                registeredProductName = intel.registeredProductName,
                labelReference = intel.labelReference,
                manufacturerLabelUrl = intel.manufacturerLabelUrl,
                manufacturerProductUrl = intel.manufacturerProductUrl,
                labelVersion = intel.labelVersion,
                verificationStatus = intel.verificationStatus,
                verificationSources = intel.verificationSources,
                verificationConflicts = intel.verificationConflicts,
                verificationUnresolvedFields = intel.verificationUnresolvedFields,
                verifiedAt = intel.verifiedAt,
                registeredUses = intel.registeredUses,
                labelRateBases = intel.labelRateBases,
                activityGroupTableVersion = intel.activityGroupTableVersion,
                intelligenceSchemaVersion = intel.intelligenceSchemaVersion,
                masterChemicalId = input.masterChemicalId,
                masterSourceRevision = input.masterSourceRevision,
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("saved_chemicals?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    /** Archive (soft-delete) via the owner/manager-gated server RPC. */
    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_saved_chemicals")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Permanently delete a saved chemical via the `hard_delete_unused_saved_chemical`
     * RPC. The backend is the final authority: it refuses (returning
     * [HardDeleteOutcome.InUse]) when the chemical is referenced by any spray
     * record, job, trip, or FK. Owner/manager only. Mirrors the iOS
     * `SavedChemicalDeletionService.hardDelete`.
     */
    suspend fun hardDeleteUnused(id: String): HardDeleteOutcome = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("hard_delete_unused_saved_chemical")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> {
                val result = response.body<HardDeleteResult>()
                when {
                    result.ok -> HardDeleteOutcome.Deleted
                    result.reason == "not_found" -> HardDeleteOutcome.NotFound
                    result.reason == "chemical_in_use" -> HardDeleteOutcome.InUse(
                        result.message
                            ?: "This chemical has been used and cannot be permanently deleted. You can archive it instead.",
                    )
                    else -> throw BackendError.Server(response.status.value, result.reason ?: "delete_failed")
                }
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend fun firstRow(response: HttpResponse): SavedChemical = when {
        response.status.isSuccess() -> response.body<List<SavedChemical>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
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
