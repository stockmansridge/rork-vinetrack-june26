package com.rork.vinetrack.data.chemical

import android.content.Context
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.request.*
import io.ktor.client.call.body
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.util.UUID

class CatalogueRepository(context: Context) {
    private val session = SessionStore(context)
    val userId: String get() = requireNotNull(session.userId)
    private fun HttpRequestBuilder.authenticate() { headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer ${requireNotNull(session.accessToken)}") } }
    suspend fun rpc(name: String, args: JsonObject): JsonElement = withContext(Dispatchers.IO) {
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) { authenticate(); contentType(ContentType.Application.Json); setBody(args) }
        check(response.status.isSuccess()) { "Unable to complete request. Check permissions and try again." }
        SupabaseClient.json.parseToJsonElement(response.bodyAsText())
    }
    private suspend fun get(path: String): JsonElement = withContext(Dispatchers.IO) {
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) { authenticate() }
        check(response.status.isSuccess()) { "Unable to retrieve result." }
        SupabaseClient.json.parseToJsonElement(response.bodyAsText())
    }
    fun rows(value: JsonElement): List<CatalogueRow> = (value as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(::CatalogueRow) }.orEmpty()
    /** One financial batch per vineyard/vintage; backend enforces Owner/Manager access. */
    suspend fun chemicalSeasonPrices(vineyardId: String, vintage: Int, asOf: String? = null): ChemicalSeasonPriceBatch {
        val value = rpc("chemical_season_purchase_prices", buildJsonObject {
            put("p_vineyard_id", vineyardId); put("p_vintage", vintage)
            put("p_as_of", asOf?.let(::JsonPrimitive) ?: JsonNull)
        })
        val prices = SupabaseClient.json.decodeFromJsonElement<List<ChemicalSeasonPrice>>(value)
        return ChemicalSeasonPriceBatch(vineyardId, vintage, prices)
    }
    suspend fun search(query: String, country: String): List<CatalogueRow> = rows(rpc("search_chemical_v3_catalogue", buildJsonObject {
        put("p_query", query); put("p_country_code", country.takeIf { it.isNotBlank() }?.let(::JsonPrimitive) ?: JsonNull); put("p_limit", 20)
    }))
    suspend fun revision(id: String): CatalogueRow = rows(get("chemical_v3_product_revisions?id=eq.$id&select=*")).single().also { check(it.id == id) }
    /** Image-only fallback; no saved-chemical writes or catalogue-field substitution. */
    suspend fun resolvedFrontLabelPath(exactRevision: CatalogueRow): String? =
        CatalogueFrontLabelResolver.resolve(exactRevision,
            product = { id -> rows(get("chemical_v3_products?id=eq.$id&select=id,approved_revision_id")).single() },
            revision = { id -> revision(id) })
    suspend fun job(id: String): CatalogueRow = rows(get("chemical_v3_discovery_jobs?id=eq.$id&select=id,status,stage,revision_id,product_id,progress_percent,user_message")).single()
    suspend fun invoke(id: String) = withContext(Dispatchers.IO) {
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl("chemical-lookup-v3")) {
            authenticate(); contentType(ContentType.Application.Json); setBody(buildJsonObject { put("action", "start"); put("job_id", id) })
        }
        check(response.status.isSuccess()) { "Discovery is saved. Resume to check progress." }
    }
    suspend fun upload(bytes: ByteArray): String = withContext(Dispatchers.IO) {
        val path = "search-inputs/$userId/${UUID.randomUUID()}.jpg"
        val response = SupabaseClient.http.post(SupabaseClient.storageUrl("object/chemical-v3-media/$path")) {
            authenticate(); contentType(ContentType.Image.JPEG); setBody(bytes)
        }
        check(response.status.isSuccess()) { "Photo could not be uploaded." }; path
    }
    suspend fun media(path: String): ByteArray = withContext(Dispatchers.IO) {
        val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/authenticated/chemical-v3-media/$path")) { authenticate() }
        check(response.status.isSuccess()); response.body<ByteArray>()
    }
    suspend fun add(revision: String, vineyard: String): SavedChemical {
        val row = rows(rpc("chemical_v3_add_to_vineyard", buildJsonObject {
            put("p_revision_id", revision); put("p_vineyard_id", vineyard); put("p_opening_quantity", JsonNull); put("p_opening_unit", JsonNull)
        })).single()
        val id = requireNotNull(row.text("saved_chemical_id"))
        val saved = (get("saved_chemicals?id=eq.$id&vineyard_id=eq.$vineyard&select=*") as JsonArray).single()
        return SupabaseClient.json.decodeFromJsonElement<SavedChemical>(saved).also { check(it.id == id) }
    }
}
