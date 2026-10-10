package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

/** Durable, separate local authority for actual tank contents and their retry queue. */
class SprayTankActualStore internal constructor(
    private val readBytes: () -> String?,
    private val commitBytes: (String) -> Boolean,
) {
    constructor(context: Context) : this(
        { context.getSharedPreferences("vinetrack_spray_tank_actuals", Context.MODE_PRIVATE).getString("cache", null) },
        { bytes -> context.getSharedPreferences("vinetrack_spray_tank_actuals", Context.MODE_PRIVATE)
            .edit().putString("cache", bytes).commit() },
    )
    @Serializable private data class Cache(
        val records: List<SprayTankActual> = emptyList(),
        val pendingIds: Set<String> = emptySet(),
    )

    private var accountProvider: (() -> com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess?)? = null

    /** Refuses new confirmations after this process's auth admission is revoked. */
    @Synchronized fun configureAccountAccess(provider: () -> com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess?) {
        accountProvider = provider
    }

    /** Only an unchanged original confirmation carries explicit operation authorship.
     * confirmedBy does not authorise later corrections, edits or other related Trip work.
     */
    @Synchronized fun pendingOwned(access: com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess): List<SprayTankActual> =
        pending().filter { it.confirmedBy == access.userId && it.confirmedBy.isNotBlank() &&
            it.correctionVersion == 0L && it.lastCorrectedAt == null && it.clientUpdatedAt == it.confirmedAt }

    @Synchronized fun hasReadableSyncEvidence(): Boolean = runCatching {
        val decoded = readBytes()?.let { SupabaseClient.json.decodeFromString(Cache.serializer(), it) } ?: Cache()
        val identities = decoded.records.map { it.id }
        identities.distinct().size == identities.size && decoded.pendingIds.all { it in identities }
    }.getOrDefault(false)

    /** A server read cannot consume foreign, edited or unattributed pending confirmation evidence. */
    @Synchronized fun mergeRemoteForAccount(remote: List<SprayTankActual>, access: com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess): Boolean {
        if (!hasReadableSyncEvidence()) return false
        val current = cache()
        val eligible = pendingOwned(access).mapTo(mutableSetOf()) { it.id }
        val safe = remote.filter { incoming ->
            current.records.none { local -> local.tripId == incoming.tripId && local.tankSessionId == incoming.tankSessionId &&
                local.id in current.pendingIds && local.id !in eligible }
        }
        return safe.isEmpty() || mergeRemote(safe)
    }

    private val _records = MutableStateFlow(cache().records)
    /** Single observable authority consumed by UI, reports, and reconciliation. */
    val records: StateFlow<List<SprayTankActual>> = _records.asStateFlow()

    private val _syncEvidenceChanges = MutableStateFlow(0L)
    /** Signals pending-only acknowledgements as well as record changes; read-only UI trigger. */
    val syncEvidenceChanges: StateFlow<Long> = _syncEvidenceChanges.asStateFlow()

    /** Neutral notice only: never reveals foreign/uncertain identities, quantities or counts. */
    @Synchronized internal fun syncNotice(
        access: com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess,
        vineyardId: String?,
        hasDependency: (SprayTankActual) -> Boolean,
    ): String? {
        if (!hasReadableSyncEvidence()) return "Saved tank actual evidence couldn't be read consistently. Syncing is paused; keep this installation and contact support."
        val pending = pending()
        val owned = pendingOwned(access)
        if (pending.any { row -> owned.none { it == row } })
            return "Saved tank actual evidence needs ownership or correction review. It remains protected and is not replayed; contact support if this persists."
        val selected = owned.filter { it.vineyardId == vineyardId }
        if (selected.isEmpty()) return null
        return if (selected.any(hasDependency))
            "Saved tank actuals are waiting for earlier Trip or spray changes. Review Trip tanks in Pending Sync; held changes are not cleared by Retry all."
        else "Tank actuals are saved on this device but not yet acknowledged by the server. They remain pending; check your connection and contact support if syncing does not resolve this."
    }

    @Synchronized fun load(): List<SprayTankActual> = _records.value

    @Synchronized fun actual(tripId: String, tankNumber: Int): SprayTankActual? =
        cache().records.filter { it.tripId == tripId && it.tankNumber == tankNumber }
            .maxByOrNull { it.clientUpdatedAt }

    /** Commits record and pending marker in one synchronous SharedPreferences transaction. */
    fun save(actual: SprayTankActual): Boolean {
        // Capture before the storage monitor: callbacks acquire auth then storage, never invert them.
        val provider = synchronized(this) { accountProvider }
        val access = provider?.invoke()
        if (provider != null && access == null) return false
        if (access == null) return saveCurrent(actual)
        var committed = false
        val admitted = access.authority.withAccount(access, { provider?.invoke()?.userId }) {
            committed = saveCurrent(actual)
        }
        return admitted && committed
    }

    @Synchronized private fun saveCurrent(actual: SprayTankActual): Boolean {
        val current = cache()
        val records = current.records.toMutableList()
        val index = records.indexOfFirst { it.tripId == actual.tripId && it.tankSessionId == actual.tankSessionId }
        if (index >= 0) {
            if (records[index].clientUpdatedAt > actual.clientUpdatedAt) return true
            records[index] = actual
        } else records.add(actual)
        val validIds = records.mapTo(mutableSetOf()) { it.id }
        return write(Cache(records, (current.pendingIds intersect validIds) + actual.id))
    }

    /** Removes a just-created local row when a coordinated trip commit fails. */
    @Synchronized fun remove(id: String): Boolean {
        val current = cache()
        return write(current.copy(records = current.records.filterNot { it.id == id }, pendingIds = current.pendingIds - id))
    }

    @Synchronized fun pending(tripId: String? = null): List<SprayTankActual> {
        val current = cache()
        return current.records.filter { it.id in current.pendingIds && (tripId == null || it.tripId == tripId) }
    }

    /** Merges server rows without replacing a newer pending local confirmation. */
    @Synchronized fun mergeRemote(remote: List<SprayTankActual>): Boolean {
        val current = cache()
        val records = current.records.toMutableList()
        val pending = current.pendingIds.toMutableSet()
        remote.forEach { incoming ->
            val index = records.indexOfFirst { it.tripId == incoming.tripId && it.tankSessionId == incoming.tankSessionId }
            if (index < 0) records.add(incoming)
            else {
                val hasServerCorrection = incoming.correctionVersion > records[index].correctionVersion
                if (hasServerCorrection || (records[index].id !in pending && records[index].clientUpdatedAt < incoming.clientUpdatedAt)) {
                    pending.remove(records[index].id)
                    records[index] = incoming
                }
            }
        }
        return write(current.copy(records = records, pendingIds = pending))
    }

    @Synchronized fun markSynced(id: String): Boolean {
        val current = cache()
        return write(current.copy(pendingIds = current.pendingIds - id))
    }

    /** Old upload responses never acknowledge a replacement confirmation for the same actual ID. */
    @Synchronized fun markSyncedIfCurrent(expected: SprayTankActual): Boolean {
        val current = cache()
        if (expected.id !in current.pendingIds || current.records.none { it == expected }) return false
        return write(current.copy(pendingIds = current.pendingIds - expected.id))
    }

    private fun cache(): Cache = readBytes()?.let {
        runCatching { SupabaseClient.json.decodeFromString(Cache.serializer(), it) }.getOrNull()
    } ?: Cache()

    private fun write(cache: Cache): Boolean {
        val committed = commitBytes(SupabaseClient.json.encodeToString(Cache.serializer(), cache))
        if (committed) {
            _records.value = cache.records
            _syncEvidenceChanges.value += 1L
        }
        return committed
    }
}
