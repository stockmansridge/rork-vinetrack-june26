package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.Serializable

/** Crash-safe local transaction for one confirmed tank start. */
class StartTankCommitCoordinator internal constructor(
    private val journalStorage: StartTankJournalStorage,
    private val saveActual: (SprayTankActual) -> Boolean,
    private val hasActual: (SprayTankActual) -> Boolean,
    private val saveTrip: (String, String, Trip) -> Boolean,
    private val hasTrip: (Trip) -> Boolean,
    private val ensureTankMarker: (Trip) -> Boolean,
    private val hasTankMarker: (String) -> Boolean,
) {
    @Serializable
    data class Journal(
        val actualRecordId: String,
        val tankSessionId: String,
        val tankNumber: Int,
        val confirmationTimestamp: String,
        val ownerUserId: String,
        val vineyardId: String,
        val updatedTrip: Trip,
        val actual: SprayTankActual,
        val state: String = State.PREPARED,
    )

    object State {
        const val PREPARED = "prepared"
        const val ACTUAL_DURABLE = "actual_durable"
        const val TRIP_DURABLE = "trip_durable"
        const val REPLAY_DURABLE = "replay_durable"
    }

    constructor(
        context: Context,
        activeTripStore: ActiveTripStore,
        actualStore: SprayTankActualStore,
        pendingWrites: PendingWriteRepository,
        tripTankSync: TripTankSync,
    ) : this(
        journalStorage = SharedPreferencesStartTankJournalStorage(context),
        saveActual = actualStore::save,
        hasActual = { expected -> actualStore.load().any { it.id == expected.id && it.tripId == expected.tripId && it.tankSessionId == expected.tankSessionId } },
        saveTrip = activeTripStore::saveDurably,
        hasTrip = { expected -> activeTripStore.load()?.trip == expected },
        ensureTankMarker = { trip ->
            try {
                tripTankSync.enqueue(trip)
                true
            } catch (_: Exception) {
                false
            }
        },
        hasTankMarker = { tripId -> pendingWrites.list().any { it.clientId == tripId && it.entityType == com.rork.vinetrack.data.model.PendingEntityType.TRIP_TANK && it.status in com.rork.vinetrack.data.model.PendingWriteStatus.unresolved } },
    )

    @Synchronized
    fun commit(ownerUserId: String, vineyardId: String, trip: Trip, actual: SprayTankActual): Boolean {
        require(actual.tripId == trip.id && actual.tankSessionId.isNotBlank())
        val journal = Journal(
            actualRecordId = actual.id,
            tankSessionId = actual.tankSessionId,
            tankNumber = actual.tankNumber,
            confirmationTimestamp = actual.confirmedAt,
            ownerUserId = ownerUserId,
            vineyardId = vineyardId,
            updatedTrip = trip,
            actual = actual,
        )
        if (!journalStorage.write(journal)) return false
        return finish(journal)
    }

    /** Completes the exact saved operation; every step is stable-ID idempotent. */
    @Synchronized
    fun recover(): Journal? {
        val journal = journalStorage.read() ?: return null
        return if (finish(journal)) journal else null
    }

    private fun finish(initial: Journal): Boolean {
        var journal = initial
        if (!hasActual(journal.actual)) {
            if (!saveActual(journal.actual)) return false
        }
        journal = journal.copy(state = State.ACTUAL_DURABLE)
        if (!journalStorage.write(journal)) return false

        if (!hasTrip(journal.updatedTrip)) {
            if (!saveTrip(journal.ownerUserId, journal.vineyardId, journal.updatedTrip)) return false
        }
        journal = journal.copy(state = State.TRIP_DURABLE)
        if (!journalStorage.write(journal)) return false

        if (!hasTankMarker(journal.updatedTrip.id)) {
            if (!ensureTankMarker(journal.updatedTrip)) return false
        }
        journal = journal.copy(state = State.REPLAY_DURABLE)
        if (!journalStorage.write(journal)) return false

        if (!hasActual(journal.actual) || !hasTrip(journal.updatedTrip) || !hasTankMarker(journal.updatedTrip.id)) return false
        return journalStorage.clear()
    }
}

internal interface StartTankJournalStorage {
    fun read(): StartTankCommitCoordinator.Journal?
    fun write(journal: StartTankCommitCoordinator.Journal): Boolean
    fun clear(): Boolean
}

private class SharedPreferencesStartTankJournalStorage(context: Context) : StartTankJournalStorage {
    private val prefs = context.applicationContext.getSharedPreferences("vinetrack_start_tank_journal", Context.MODE_PRIVATE)

    override fun read(): StartTankCommitCoordinator.Journal? = prefs.getString(KEY, null)?.let { raw ->
        runCatching { SupabaseClient.json.decodeFromString(StartTankCommitCoordinator.Journal.serializer(), raw) }.getOrNull()
    }

    override fun write(journal: StartTankCommitCoordinator.Journal): Boolean = prefs.edit()
        .putString(KEY, SupabaseClient.json.encodeToString(StartTankCommitCoordinator.Journal.serializer(), journal))
        .commit()

    override fun clear(): Boolean = prefs.edit().remove(KEY).commit()

    private companion object { const val KEY = "pending_commit" }
}
