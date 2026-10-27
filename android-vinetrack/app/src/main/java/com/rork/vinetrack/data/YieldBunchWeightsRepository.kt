package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

@Serializable
data class YieldBunchWeightRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String? = null,
    @SerialName("variety_key") val varietyKey: String,
    @SerialName("variety_name") val varietyName: String,
    @SerialName("bunch_weight_grams") val grams: Double,
    @SerialName("updated_at") val updatedAt: String? = null,
) {
    val isValid: Boolean get() = grams.isFinite() && grams > 0 && grams <= 5000 && varietyKey.isNotBlank()
    companion object {
        fun resolved(rows: List<YieldBunchWeightRow>, vineyard: String, block: String, key: String): YieldMasterWeight {
            val scoped = rows.filter { it.vineyardId.equals(vineyard, true) && it.varietyKey == key && it.isValid }
            val row = scoped.firstOrNull { it.paddockId.equals(block, true) } ?: scoped.firstOrNull { it.paddockId == null }
            return YieldMasterWeight(row?.grams, when { row == null -> "not_configured"; row.paddockId == null -> "variety_default"; else -> "block_override" }, row?.id, key)
        }
    }
}

/** Online, server-confirmed management. No local defaults, speculative success or background write queue. */
class YieldBunchWeightsRepository(context: Context) {
    val session = SessionStore(context)
    private val prefs = context.applicationContext.getSharedPreferences("yield_management_confirmed_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private fun key(vineyard: String) = "${session.userId?.lowercase()}/${vineyard.lowercase()}"
    suspend fun cached(vineyard: String): List<YieldBunchWeightRow>? = withContext(Dispatchers.IO) {
        val account = session.retentionGuard.captureAccount(session.userId) ?: return@withContext null
        var rows: List<YieldBunchWeightRow>? = null
        session.retentionGuard.withAccount(account, { session.userId }) {
            rows = prefs.getString(key(vineyard), null)?.let { runCatching { json.decodeFromString<List<YieldBunchWeightRow>>(it) }.getOrNull() }
                ?.takeIf { list -> list.all { it.vineyardId.equals(vineyard, true) && it.isValid } }
        }
        rows
    }
    suspend fun fetch(vineyard: String): List<YieldBunchWeightRow> {
        val account = session.retentionGuard.captureAccount(session.userId) ?: throw BackendError.Unauthorized
        return withContext(Dispatchers.IO) {
        check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val rows = mutableListOf<YieldBunchWeightRow>()
        var total: Int? = null
        do {
            check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
            val response = SupabaseClient.http.get(SupabaseClient.restUrl("yield_bunch_weights")) {
                attributes.put(SupabaseClient.accountRequestScope, account)
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token"); append("Prefer", "count=exact") }
                url {
                    parameters.append("select", "id,vineyard_id,paddock_id,variety_key,variety_name,bunch_weight_grams,updated_at")
                    parameters.append("vineyard_id", "eq.$vineyard")
                    parameters.append("deleted_at", "is.null")
                    parameters.append("order", "updated_at.desc,id.asc")
                    parameters.append("offset", rows.size.toString())
                    parameters.append("limit", "200")
                }
            }
            if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
            val page = response.body<List<YieldBunchWeightRow>>()
            val count = response.headers["Content-Range"]?.substringAfterLast('/')?.toIntOrNull()
            check(count != null && count in 0..100_000 && (total == null || total == count) && (page.isNotEmpty() || rows.size == count)) { "Incomplete shared bunch weights; refresh again" }
            total = count
            rows.addAll(page)
            check(rows.size <= count && rows.map { it.id.lowercase() }.distinct().size == rows.size && page.all { it.vineyardId.equals(vineyard, true) && it.isValid }) { "Invalid shared bunch weights" }
        } while (rows.size < (total ?: 0))
        check(session.retentionGuard.withAccount(account, { session.userId }) {
            check(prefs.edit().putString(key(vineyard), json.encodeToString(rows)).commit())
        }) { "Account changed" }
        rows
        }
    }
    suspend fun save(vineyard: String, block: String?, key: String, name: String, grams: Double) {
        require(grams.isFinite() && grams > 0 && grams <= 5000 && key.isNotBlank() && name.isNotBlank())
        mutate(vineyard, "upsert_yield_bunch_weight", buildJsonObject {
            put("p_vineyard_id", vineyard)
            put("p_paddock_id", block?.let(::JsonPrimitive) ?: JsonNull)
            put("p_variety_key", key)
            put("p_variety_name", name)
            put("p_bunch_weight_grams", grams)
        })
    }
    suspend fun remove(row: YieldBunchWeightRow) {
        val account = session.retentionGuard.captureAccount(session.userId) ?: throw BackendError.Unauthorized
        withContext(Dispatchers.IO) {
        check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        val token = session.accessToken ?: throw BackendError.Unauthorized
        OperationalWrites.requireWrite(row.vineyardId)
        // ID-only RPC: prove the owning vineyard with an authenticated read, not the selected vineyard or supplied row.
        val response = SupabaseClient.http.get(SupabaseClient.restUrl("yield_bunch_weights")) {
            attributes.put(SupabaseClient.accountRequestScope, account)
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            url {
                parameters.append("select", "id,vineyard_id,paddock_id,variety_key,variety_name,bunch_weight_grams,updated_at")
                parameters.append("id", "eq.${row.id}")
                parameters.append("deleted_at", "is.null")
            }
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        val owners = response.body<List<YieldBunchWeightRow>>()
        check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        val owner = owners.singleOrNull()
        check(owner != null && owner.id.equals(row.id, true) && owner.vineyardId.equals(row.vineyardId, true)) { "Record ownership not confirmed" }
        mutate(owner.vineyardId, "soft_delete_yield_bunch_weight", buildJsonObject { put("p_id", row.id) })
        }
    }
    private suspend fun mutate(vineyard: String, rpc: String, body: kotlinx.serialization.json.JsonObject) {
        val account = session.retentionGuard.captureAccount(session.userId) ?: throw BackendError.Unauthorized
        withContext(Dispatchers.IO) {
        check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        val token = session.accessToken ?: throw BackendError.Unauthorized
        OperationalWrites.requireWrite(vineyard)
        try {
            check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
                attributes.put(SupabaseClient.accountRequestScope, account)
                attributes.put(SupabaseClient.operationalWriteVineyard, vineyard)
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
            check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        } catch (error: Exception) {
            if (session.retentionGuard.isAccountCurrent(account, session.userId)) OperationalWrites.handleServerError(error, vineyard)
            throw error
        }
        }
    }
}
