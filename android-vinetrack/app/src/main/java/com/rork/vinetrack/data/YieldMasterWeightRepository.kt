package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Read-only RPC + last-server-confirmed cache, isolated by account, vineyard, block and variety. */
class YieldMasterWeightRepository internal constructor(context: Context) {
    val session = SessionStore(context)
    private val prefs = context.applicationContext.getSharedPreferences("yield_master_confirmed_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = MapSerializer(String.serializer(), YieldMasterWeight.serializer())
    private val mutex = Mutex()
    private fun scope(vineyardId: String): String? = session.userId?.let { "${it.lowercase()}/${vineyardId.lowercase()}" }
    fun cached(vineyardId: String): Map<String, YieldMasterWeight> {
        val account = session.retentionGuard.captureAccount(session.userId) ?: return emptyMap()
        var result = emptyMap<String, YieldMasterWeight>()
        session.retentionGuard.withAccount(account, { session.userId }) {
            scope(vineyardId)?.let { key -> result = runCatching { json.decodeFromString(serializer, prefs.getString(key, "{}") ?: "{}") }.getOrDefault(emptyMap()) }
        }
        return result
    }
    @Serializable private data class Args(
        @SerialName("p_vineyard_id") val vineyard: String,
        @SerialName("p_paddock_id") val block: String,
        @SerialName("p_variety_key") val variety: String,
    )
    suspend fun refresh(vineyardId: String, paddocks: List<Paddock>): Map<String, YieldMasterWeight> {
        // Capture BEFORE waiting for a prior refresh, including same-user sign-out/return.
        val account = session.retentionGuard.captureAccount(session.userId) ?: return emptyMap()
        val scope = scope(vineyardId) ?: return emptyMap()
        return mutex.withLock {
            val weights = cached(vineyardId).toMutableMap()
            for (paddock in paddocks) for (planting in CurrentYieldEstimate.plantings(paddock)) {
                if (!session.retentionGuard.isAccountCurrent(account, session.userId)) return@withLock emptyMap()
                val token = session.accessToken ?: return@withLock emptyMap()
                try {
                    val response = SupabaseClient.http.post(SupabaseClient.restUrl("rpc/resolve_yield_bunch_weight")) {
                        attributes.put(SupabaseClient.accountRequestScope, account)
                        headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                        contentType(ContentType.Application.Json)
                        setBody(Args(vineyardId, paddock.id, planting.key))
                    }
                    if (!response.status.isSuccess()) continue
                    val result = response.body<YieldMasterWeight>()
                    if (result.varietyKey != planting.key || result.source !in listOf("block_override", "variety_default", "not_configured") || (result.source != "not_configured" && result.kg == null)) continue
                    if (!session.retentionGuard.withAccount(account, { session.userId }) {
                        val confirmed = weights + (CurrentYieldEstimate.key(paddock.id, planting.key) to result)
                        check(prefs.edit().putString(scope, json.encodeToString(serializer, confirmed)).commit())
                        weights.clear()
                        weights.putAll(confirmed)
                    }) return@withLock emptyMap()
                } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                  catch (_: Exception) { /* A failed read is never confirmation of absence. */ }
            }
            if (session.retentionGuard.isAccountCurrent(account, session.userId)) weights else emptyMap()
        }
    }
    companion object {
        @Volatile private var instance: YieldMasterWeightRepository? = null
        fun get(context: Context): YieldMasterWeightRepository = instance ?: synchronized(this) {
            instance ?: YieldMasterWeightRepository(context.applicationContext).also { instance = it }
        }
    }
}
