package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Local durable persistence for the single in-progress trip (Tier-A Stage A —
 * local active-trip persistence only, NO replay).
 *
 * Backs the active trip with a JSON blob in a dedicated SharedPreferences file,
 * following the same lightweight local-only pattern as [DomainCacheStore] /
 * [PendingWriteStore]. Room/KSP was deliberately avoided: we persist exactly one
 * snapshot (the active trip) and whole-snapshot replace is sufficient.
 *
 * The snapshot is scoped to the owning user + vineyard so a snapshot can never
 * be restored into the wrong account/vineyard context. The persisted [Trip] is
 * the same `@Serializable` model already used everywhere else, so every
 * in-progress field (path points, distance, row coverage, row sequence, tank
 * sessions, fill state, engine hours, metadata) is captured automatically.
 *
 * IMPORTANT (this slice): this is durable local restore ONLY. Nothing here
 * queues, replays, or writes to the server. Server write contracts are
 * unchanged — replay lands in later Tier-A stages.
 */
class ActiveTripStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_active_trip", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * A persisted active-trip snapshot, scoped to the user + vineyard it belongs
     * to so restore can refuse a snapshot from a different context.
     */
    @Serializable
    data class Snapshot(
        @SerialName("owner_user_id") val ownerUserId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("trip") val trip: Trip,
        @SerialName("saved_at") val savedAt: Long,
    )

    /** Persist (replace) the active-trip snapshot for the given owner/vineyard. */
    fun save(ownerUserId: String, vineyardId: String, trip: Trip) {
        val snapshot = Snapshot(ownerUserId, vineyardId, trip, System.currentTimeMillis())
        val encoded = runCatching { json.encodeToString(Snapshot.serializer(), snapshot) }.getOrNull() ?: return
        prefs.edit { putString(KEY_SNAPSHOT, encoded) }
    }

    /** Read the persisted snapshot, or null when none is stored / it can't decode. */
    fun load(): Snapshot? {
        val raw = prefs.getString(KEY_SNAPSHOT, null) ?: return null
        return runCatching { json.decodeFromString(Snapshot.serializer(), raw) }.getOrNull()
    }

    /** Remove the persisted snapshot (trip ended/deleted, sign-out, or invalid). */
    fun clear() = prefs.edit { remove(KEY_SNAPSHOT) }

    private companion object {
        const val KEY_SNAPSHOT = "active_trip_snapshot_json"
    }
}
