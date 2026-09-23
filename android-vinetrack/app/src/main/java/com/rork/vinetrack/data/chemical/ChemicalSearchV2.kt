package com.rork.vinetrack.data.chemical

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@Serializable
data class ViticultureRates(
    @SerialName("per_hectare") val perHectare: List<ChemicalLabelRate> = emptyList(),
    @SerialName("per_100_litres") val per100Litres: List<ChemicalLabelRate> = emptyList(),
) {
    val all: List<ChemicalLabelRate> get() = perHectare + per100Litres
    val hasEvidence: Boolean get() = all.isNotEmpty()

    companion object {
        fun fromRegisteredUses(uses: List<ChemicalRegisteredUse>): ViticultureRates {
            val vineyard = uses.filter { it.isViticultural }.flatMap { it.rates }
            return ViticultureRates(
                perHectare = vineyard.filter { it.basis == ChemicalLabelRateBasis.PER_HECTARE || it.basis == ChemicalLabelRateBasis.RANGE_PER_HECTARE }.distinct(),
                per100Litres = vineyard.filter { it.basis == ChemicalLabelRateBasis.PER_100_LITRES || it.basis == ChemicalLabelRateBasis.RANGE_PER_100_LITRES }.distinct(),
            )
        }
    }
}

object ChemicalSearchV2OperationalDefaults {
    fun unambiguousRates(rates: ViticultureRates): Map<ChemicalDefaultRateBasis, ChemicalLabelRate> = buildMap {
        val groups = listOf(
            ChemicalDefaultRateBasis.PER_HECTARE to rates.perHectare,
            ChemicalDefaultRateBasis.PER_100_LITRES to rates.per100Litres,
        )
        groups.forEach { (basis, candidates) ->
            val usable = candidates
                .filter(ChemicalSaveContract::isAutoApplicable)
                .distinctBy(ChemicalDefaultRate::distinctnessKey)
            if (usable.size == 1) put(basis, usable.single())
        }
    }

    fun effectiveRates(
        automatic: Map<ChemicalDefaultRateBasis, ChemicalLabelRate>,
        edited: ChemicalLabelRate?,
    ): List<ChemicalLabelRate> {
        val result = automatic.toMutableMap()
        edited?.let { rate -> ChemicalDefaultRateBasis.of(rate.basis)?.let { result[it] = rate } }
        return ChemicalDefaultRateBasis.entries.mapNotNull(result::get)
    }

    fun storedDefaults(rates: List<ChemicalLabelRate>, selectedAt: String): StoredChemicalDefaultRates? {
        var defaults = StoredChemicalDefaultRates()
        rates.forEach { rate ->
            val basis = ChemicalDefaultRateBasis.of(rate.basis) ?: return@forEach
            val slot = when {
                rate.minValue != null && rate.maxValue != null -> StoredChemicalDefaultRate.manual(
                    basis = basis, unit = rate.unit, minValue = rate.minValue,
                    maxValue = rate.maxValue, selectedAt = selectedAt,
                )
                rate.value != null -> StoredChemicalDefaultRate.manual(
                    basis = basis, unit = rate.unit, value = rate.value, selectedAt = selectedAt,
                )
                else -> null
            }
            if (slot != null) defaults = defaults.withSlot(basis, slot)
        }
        return defaults.takeIf { !it.isEmpty }
    }
}

@Serializable
data class MasterChemicalV2(
    val id: String,
    @SerialName("registration_country") val registrationCountry: String,
    @SerialName("registration_scheme") val registrationScheme: String,
    @SerialName("registration_number") val registrationNumber: String,
    val registrant: String? = null,
    @SerialName("registered_product_name") val registeredProductName: String,
    @SerialName("common_names") val commonNames: List<String> = emptyList(),
    @SerialName("product_category") val productCategory: String? = null,
    @SerialName("form_type") val formType: String? = null,
    @SerialName("active_ingredients") val activeIngredients: List<ChemicalActiveIngredient> = emptyList(),
    @SerialName("activity_groups") val activityGroups: List<String> = emptyList(),
    @SerialName("activity_group_scheme") val activityGroupScheme: String? = null,
    @SerialName("registered_uses") val registeredUses: List<ChemicalRegisteredUse> = emptyList(),
    @SerialName("viticulture_rates") val viticultureRates: ViticultureRates = ViticultureRates(),
    @SerialName("has_viticulture_evidence") val hasViticultureEvidence: Boolean = false,
    @SerialName("label_rate_bases") val labelRateBases: List<String> = emptyList(),
    @SerialName("label_reference") val labelReference: String? = null,
    @SerialName("label_version") val labelVersion: String? = null,
    @SerialName("verification_status") val verificationStatus: String = "unverified",
    @SerialName("verification_sources") val verificationSources: List<ChemicalDataSource> = emptyList(),
    @SerialName("verification_conflicts") val verificationConflicts: List<ChemicalVerificationConflict> = emptyList(),
    @SerialName("verification_unresolved_fields") val verificationUnresolvedFields: List<String> = emptyList(),
    @SerialName("verified_at") val verifiedAt: String? = null,
    @SerialName("source_kind") val sourceKind: String,
    @SerialName("review_status") val reviewStatus: String,
    @SerialName("catalogue_version") val catalogueVersion: Int,
    @SerialName("manufacturer_label_url") val manufacturerLabelUrl: String? = null,
    @SerialName("manufacturer_product_url") val manufacturerProductUrl: String? = null,
    @SerialName("regulator_label_url") val regulatorLabelUrl: String? = null,
    @SerialName("search_rank") val searchRank: Int = 99,
) {
    val intelligence: ChemicalIntelligence
        get() = ChemicalIntelligence(
            activeIngredients = activeIngredients,
            registration = ChemicalRegistration.of(
                countryCode = registrationCountry,
                scheme = ChemicalRegistrationScheme.from(registrationScheme),
                registrationNumber = registrationNumber,
                registrant = registrant,
                registeredProductName = registeredProductName,
                labelReference = labelReference,
                manufacturerLabelUrl = manufacturerLabelUrl,
                regulatorLabelUrl = regulatorLabelUrl,
                manufacturerProductUrl = manufacturerProductUrl,
                labelVersion = labelVersion,
            ),
            verification = ChemicalVerification(
                status = ChemicalVerificationStatus.from(verificationStatus),
                sources = verificationSources,
                verifiedAt = verifiedAt,
                conflicts = verificationConflicts,
                unresolvedFields = verificationUnresolvedFields,
            ),
            registeredUses = registeredUses,
            productCategory = productCategory.orEmpty(),
            activityGroupTableVersion = 0,
        )

    val grapevineRates: List<ChemicalLabelRate>
        get() = viticultureRates.all
}

object ChemicalSearchV2RequestGate {
    fun accepts(completed: String, active: String?): Boolean = completed == active
}

object ChemicalSearchV2Rank {
    fun rank(query: String, productName: String, commonNames: List<String>, registrationNumber: String, activeNames: List<String>, registrant: String?): Int? {
        val normal = ChemicalStoreMatching.normalisedName(query).replace(" ", "")
        val product = ChemicalStoreMatching.normalisedName(productName)
        if (product.replace(" ", "") == normal) return 1
        if (product.startsWith(ChemicalStoreMatching.normalisedName(query))) return 2
        if (commonNames.any { ChemicalStoreMatching.normalisedName(it).replace(" ", "") == normal }) return 3
        if (product.contains(ChemicalStoreMatching.normalisedName(query))) return 4
        val digits = query.filter(Char::isDigit)
        if (digits.isNotEmpty() && registrationNumber.filter(Char::isDigit) == digits) return 5
        val secondary = (activeNames + registrant.orEmpty()).joinToString(" ")
        return if (secondary.contains(query, ignoreCase = true)) 6 else null
    }
}

object ChemicalSearchV2Duplicate {
    fun existing(master: MasterChemicalV2?, intelligence: ChemicalIntelligence, name: String, chemicals: List<SavedChemical>): SavedChemical? {
        master?.let { candidate ->
            chemicals.firstOrNull { it.isActive && it.masterChemicalId == candidate.id }?.let { return it }
        }
        ChemicalStoreMatching.findByRegistrationIdentity(chemicals, intelligence.registration)?.let { return it }
        return chemicals.firstOrNull { it.isActive && ChemicalStoreMatching.namesMatch(it.displayName, name) }
    }
}

class MasterChemicalV2Repository {
    companion object { const val INVOKES_AI: Boolean = false }
    suspend fun search(query: String): List<MasterChemicalV2> = withContext(Dispatchers.IO) {
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: throw BackendError.Unauthorized
        val started = System.nanoTime()
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("search_master_chemicals_v2")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject { put("p_query", query.trim()); put("p_limit", 25) })
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        val rows = SupabaseClient.json.decodeFromString<List<MasterChemicalV2>>(response.bodyAsText())
        val elapsed = (System.nanoTime() - started) / 1_000_000
        Log.d("ChemicalSearchV2", "query=${query.trim()} duration_ms=$elapsed results=${rows.size} master_hit=${rows.isNotEmpty()}")
        rows
    }
}

class ChemicalLabelAttachmentV2Repository {
    @Serializable
    private data class AttachmentInsert(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("saved_chemical_id") val savedChemicalId: String,
        @SerialName("storage_path") val storagePath: String,
    )

    suspend fun upload(jpeg: ByteArray, vineyardId: String, chemicalId: String) = withContext(Dispatchers.IO) {
        val token = SupabaseClient.sessionRefresher?.sessionAccessToken ?: throw BackendError.Unauthorized
        val path = "${vineyardId.lowercase()}/${chemicalId.lowercase()}/${UUID.randomUUID()}.jpg"
        val upload = SupabaseClient.http.post(SupabaseClient.storageUrl("object/chemical-label-photos/$path")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
        }
        if (!upload.status.isSuccess()) throw BackendError.Server(upload.status.value, upload.bodyAsText())
        val insert = SupabaseClient.http.post(SupabaseClient.restUrl("saved_chemical_attachments")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(AttachmentInsert(vineyardId, chemicalId, path))
        }
        if (!insert.status.isSuccess()) throw BackendError.Server(insert.status.value, insert.bodyAsText())
    }
}

data class ChemicalLabelIdentityEvidence(val text: String, val apvmaNumber: String?, val searchQuery: String?)

object ChemicalLabelIdentityOCR {
    fun proposedQuery(apvma: String?, identifiedName: String?): String? = apvma ?: identifiedName

    suspend fun recognise(context: Context, uri: Uri): ChemicalLabelIdentityEvidence {
        val image = InputImage.fromFilePath(context, uri)
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        val text = suspendCancellableCoroutine<String> { continuation ->
            recognizer.process(image)
                .addOnSuccessListener { result -> if (continuation.isActive) continuation.resume(result.text) }
                .addOnFailureListener { error -> if (continuation.isActive) continuation.resumeWithException(error) }
        }
        recognizer.close()
        val number = apvmaNumber(text)
        return ChemicalLabelIdentityEvidence(text, number, number)
    }

    fun apvmaNumber(text: String): String? =
        Regex("(?i)(?:APVMA|product\\s*(?:no\\.?|number)|registration\\s*(?:no\\.?|number))[^0-9]{0,16}([0-9]{3,8})")
            .find(text)?.groupValues?.getOrNull(1)
}
