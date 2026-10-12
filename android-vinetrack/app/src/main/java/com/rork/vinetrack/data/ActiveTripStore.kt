package com.rork.vinetrack.data

import android.content.Context
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
class ActiveTripStore internal constructor(
    private val storage: ActiveTripSnapshotStorage,
    private val fieldAccess: com.rork.vinetrack.data.auth.FieldStoreAccess? = null,
) {
    constructor(context: Context) : this(
        SharedPreferencesActiveTripSnapshotStorage(context),
        com.rork.vinetrack.data.auth.FieldStoreAccess(context),
    )

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

    /** A stored active claim blocks a new trip on this device, regardless of signed-in user. */
    fun hasActiveClaim(): Boolean {
        val read = runCatching { storage.read() }
        if (read.isFailure) return true
        val raw = read.getOrNull() ?: return false
        val snapshot = runCatching { json.decodeFromString(Snapshot.serializer(), raw) }.getOrNull()
            ?: return true
        return snapshot.trip.isActive
    }

    /** Claim only when no active trip is already stored; never replace another operator's claim. */
    fun claimIfAvailable(ownerUserId: String, vineyardId: String, trip: Trip): Boolean {
        val claim = {
            synchronized(this) {
                if (hasActiveClaim()) false else saveDurably(ownerUserId, vineyardId, trip)
            }
        }
        return if (fieldAccess == null) claim() else fieldAccess.admittedForOwner(ownerUserId, claim)
    }

    /** Persist (replace) the active-trip snapshot for the given owner/vineyard. */
    fun save(ownerUserId: String, vineyardId: String, trip: Trip) {
        val snapshot = Snapshot(ownerUserId, vineyardId, trip, System.currentTimeMillis())
        val encoded = runCatching { json.encodeToString(Snapshot.serializer(), snapshot) }.getOrNull() ?: return
        val write = {
            check(canReplace(ownerUserId)) { "The retained Trip needs ownership or storage review. It was not replaced." }
            storage.write(encoded)
        }
        if (fieldAccess == null) synchronized(this, write)
        else fieldAccess.admittedForOwner(ownerUserId) { synchronized(this, write) }
    }

    /** Synchronous result-returning commit used by the Start Tank transaction. */
    fun saveDurably(ownerUserId: String, vineyardId: String, trip: Trip): Boolean {
        val snapshot = Snapshot(ownerUserId, vineyardId, trip, System.currentTimeMillis())
        val encoded = runCatching { json.encodeToString(Snapshot.serializer(), snapshot) }.getOrNull() ?: return false
        val write = { if (canReplace(ownerUserId)) storage.writeDurably(encoded) else false }
        return if (fieldAccess == null) synchronized(this, write)
        else fieldAccess.admittedForOwner(ownerUserId) { synchronized(this, write) }
    }

    /** Read the persisted snapshot, or null when none is stored / it can't decode. */
    fun load(): Snapshot? {
        val raw = storage.read() ?: return null
        return runCatching { json.decodeFromString(Snapshot.serializer(), raw) }.getOrNull()
    }

    private fun canReplace(ownerUserId: String): Boolean = runCatching {
        val raw = storage.read() ?: return@runCatching true
        val existing = json.decodeFromString(Snapshot.serializer(), raw)
        existing.ownerUserId == ownerUserId && existing.ownerUserId.isNotBlank() &&
            existing.vineyardId == existing.trip.vineyardId
    }.getOrDefault(false)

    /** Unreadable/foreign snapshots are retained, never cleared as an empty or invalid claim. */
    fun clear() {
        val remove = {
            synchronized(this) {
                storage.read()?.let { raw ->
                    val existing = runCatching { json.decodeFromString(Snapshot.serializer(), raw) }
                        .getOrElse { error("Saved Trip evidence couldn't be read. Keep this installation and contact support.") }
                    check(existing.ownerUserId.isNotBlank() && existing.vineyardId == existing.trip.vineyardId)
                    if (fieldAccess == null) storage.remove()
                    else fieldAccess.commitForOwner(existing.ownerUserId) { storage.remove() }
                }
                Unit
            }
        }
        if (fieldAccess == null) remove() else fieldAccess.admitted(remove)
    }
}
