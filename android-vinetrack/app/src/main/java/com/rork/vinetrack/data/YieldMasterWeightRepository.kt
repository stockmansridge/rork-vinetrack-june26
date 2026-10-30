package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Complete shared-table read + last-server-confirmed cache, isolated by account, vineyard, block and variety. */
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
    private val rowsRepository = YieldBunchWeightsRepository(context.applicationContext)
    private val _changes = kotlinx.coroutines.flow.MutableStateFlow(0L)
    val changes: kotlinx.coroutines.flow.StateFlow<Long> = _changes
    private val failures = java.util.concurrent.ConcurrentHashMap<String, String>()
    fun syncError(vineyardId: String): String? = scope(vineyardId)?.let { failures[it] }

    suspend fun refresh(vineyardId: String, paddocks: List<Paddock>): Map<String, YieldMasterWeight> {
        val account = session.retentionGuard.captureAccount(session.userId) ?: return emptyMap()
        val scope = scope(vineyardId) ?: return emptyMap()
        return mutex.withLock {
            try {
                check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
                val rows = rowsRepository.fetch(vineyardId)
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                check(session.retentionGuard.withAccount(account, { session.userId }) {
                    val weights = resolvedRows(vineyardId, paddocks, rows)
                    check(prefs.edit().putString(scope, json.encodeToString(serializer, weights)).commit())
                    failures.remove(scope)
                    _changes.value += 1
                }) { "Account changed" }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                session.retentionGuard.withAccount(account, { session.userId }) {
                    failures[scope] = "Shared bunch weights could not refresh; saved values may be out of date."
                    _changes.value += 1
                }
            }
            if (session.retentionGuard.isAccountCurrent(account, session.userId)) cached(vineyardId) else emptyMap()
        }
    }
    private fun resolvedRows(vineyardId: String, paddocks: List<Paddock>, rows: List<YieldBunchWeightRow>): Map<String, YieldMasterWeight> =
        paddocks.filter { it.vineyardId.equals(vineyardId, true) }.flatMap { block ->
            CurrentYieldEstimate.plantings(block).map { planting ->
                CurrentYieldEstimate.key(block.id, planting.key) to YieldBunchWeightRow.resolved(rows, vineyardId, block.id, planting.key)
            }
        }.toMap()

    suspend fun installConfirmedRows(vineyardId: String, paddocks: List<Paddock>, rows: List<YieldBunchWeightRow>, account: com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess) {
        check(session.retentionGuard.isAccountCurrent(account, session.userId)) { "Account changed" }
        val scope = scope(vineyardId) ?: return
        mutex.withLock {
            val weights = resolvedRows(vineyardId, paddocks, rows)
            check(session.retentionGuard.withAccount(account, { session.userId }) {
                check(prefs.edit().putString(scope, json.encodeToString(serializer, weights)).commit())
                failures.remove(scope)
                _changes.value += 1
            }) { "Account changed" }
        }
    }
    companion object {
        @Volatile private var instance: YieldMasterWeightRepository? = null
        fun get(context: Context): YieldMasterWeightRepository = instance ?: synchronized(this) {
            instance ?: YieldMasterWeightRepository(context.applicationContext).also { instance = it }
        }
    }
}
