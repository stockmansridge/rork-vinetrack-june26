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
    private val loadTrip: (String, String, String) -> Trip?,
    private val saveTrip: (String, String, Trip) -> Boolean,
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
        val sourceTrip: Trip? = null,
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
        loadTrip = { ownerUserId, vineyardId, tripId ->
            activeTripStore.load()?.takeIf {
                it.ownerUserId == ownerUserId && it.vineyardId == vineyardId && it.trip.id == tripId
            }?.trip
        },
        saveTrip = activeTripStore::saveDurably,
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
    fun commit(ownerUserId: String, vineyardId: String, sourceTrip: Trip, trip: Trip, actual: SprayTankActual): Boolean {
        require(sourceTrip.id == trip.id && actual.tripId == trip.id && actual.tankSessionId.isNotBlank())
        if (journalStorage.read() != null) return false
        val journal = Journal(
            actualRecordId = actual.id,
            tankSessionId = actual.tankSessionId,
            tankNumber = actual.tankNumber,
            confirmationTimestamp = actual.confirmedAt,
            ownerUserId = ownerUserId,
            vineyardId = vineyardId,
            updatedTrip = trip,
            actual = actual,
            sourceTrip = sourceTrip,
        )
        if (!journalStorage.write(journal)) return false
        return finish(journal, currentOverride = sourceTrip) != null
    }

    /** Completes the exact saved operation; every step is stable-ID idempotent. */
    @Synchronized
    fun recover(): Journal? {
        val journal = journalStorage.read() ?: return null
        return if (finish(journal) != null) journal else null
    }

    /** Retries only the already-journaled confirmation and returns its durable merged trip. */
    @Synchronized
    fun resume(
        ownerUserId: String,
        vineyardId: String,
        sourceTrip: Trip,
        currentTrip: Trip,
        tankNumber: Int,
    ): Trip? {
        val journal = journalStorage.read() ?: return null
        if (journal.ownerUserId != ownerUserId || journal.vineyardId != vineyardId ||
            journal.updatedTrip.id != sourceTrip.id || journal.tankNumber != tankNumber ||
            journal.sourceTrip?.tankSessions != sourceTrip.tankSessions ||
            journal.sourceTrip?.activeTankNumber != sourceTrip.activeTankNumber ||
            journal.sourceTrip?.isFillingTank != sourceTrip.isFillingTank ||
            journal.sourceTrip?.fillingTankNumber != sourceTrip.fillingTankNumber
        ) return null
        return finish(journal, currentOverride = currentTrip)
    }

    private fun finish(initial: Journal, currentOverride: Trip? = null): Trip? {
        var journal = initial
        val current = currentOverride?.takeIf {
            it.id == journal.updatedTrip.id && it.vineyardId == journal.vineyardId
        } ?: loadTrip(journal.ownerUserId, journal.vineyardId, journal.updatedTrip.id)
            ?: return null
        val mergedTrip = StartTankOperationMerge.apply(
            current = current,
            source = journal.sourceTrip,
            intended = journal.updatedTrip,
            tankSessionId = journal.tankSessionId,
            tankNumber = journal.tankNumber,
        ) ?: return null
        if (!hasActual(journal.actual)) {
            if (!saveActual(journal.actual)) return null
        }
        journal = journal.copy(state = State.ACTUAL_DURABLE)
        if (!journalStorage.write(journal)) return null

        if (!StartTankOperationMerge.isEstablished(mergedTrip, journal.updatedTrip, journal.tankSessionId, journal.tankNumber)) return null
        if (mergedTrip != current && !saveTrip(journal.ownerUserId, journal.vineyardId, mergedTrip)) return null
        val persistedTrip = loadTrip(journal.ownerUserId, journal.vineyardId, journal.updatedTrip.id) ?: return null
        if (!StartTankOperationMerge.isEstablished(persistedTrip, journal.updatedTrip, journal.tankSessionId, journal.tankNumber)) return null
        journal = journal.copy(state = State.TRIP_DURABLE)
        if (!journalStorage.write(journal)) return null

        if (!hasTankMarker(journal.updatedTrip.id)) {
            if (!ensureTankMarker(persistedTrip)) return null
        }
        journal = journal.copy(state = State.REPLAY_DURABLE)
        if (!journalStorage.write(journal)) return null

        val durableTrip = loadTrip(journal.ownerUserId, journal.vineyardId, journal.updatedTrip.id) ?: return null
        if (!hasActual(journal.actual) ||
            !StartTankOperationMerge.isEstablished(durableTrip, journal.updatedTrip, journal.tankSessionId, journal.tankNumber) ||
            !hasTankMarker(journal.updatedTrip.id)
        ) return null
        return if (journalStorage.clear()) durableTrip else null
    }
}

/** Applies only a frozen Start Tank operation while retaining every unrelated field from the latest trip. */
object StartTankOperationMerge {
    fun apply(current: Trip, source: Trip?, intended: Trip, tankSessionId: String, tankNumber: Int): Trip? {
        if (current.id != intended.id || current.vineyardId != intended.vineyardId ||
            !current.isActive || current.endTime != null || current.deletedAt != null
        ) return null
        val intendedSession = intended.tankSessions.firstOrNull { it.id == tankSessionId && it.tankNumber == tankNumber }
            ?: return null
        if (isEstablished(current, intended, tankSessionId, tankNumber)) return current
        if (source == null || current.id != source.id || current.vineyardId != source.vineyardId ||
            current.tankSessions != source.tankSessions ||
            current.activeTankNumber != source.activeTankNumber ||
            current.isFillingTank != source.isFillingTank ||
            current.fillingTankNumber != source.fillingTankNumber
        ) return null
        return current.copy(
            tankSessions = intended.tankSessions,
            activeTankNumber = intended.activeTankNumber,
            isFillingTank = intended.isFillingTank,
            fillingTankNumber = intended.fillingTankNumber,
        )
    }

    fun isEstablished(trip: Trip, intended: Trip, tankSessionId: String, tankNumber: Int): Boolean {
        val expected = intended.tankSessions.firstOrNull { it.id == tankSessionId && it.tankNumber == tankNumber }
            ?: return false
        val actual = trip.tankSessions.firstOrNull { it.id == tankSessionId && it.tankNumber == tankNumber }
            ?: return false
        val startWasApplied = actual.startTime == expected.startTime &&
            actual.startRow == expected.startRow &&
            actual.fillStartTime == expected.fillStartTime &&
            actual.fillEndTime == expected.fillEndTime
        if (!startWasApplied) return false
        val completedLater = actual.endTime != null
        return completedLater || (actual.endTime == expected.endTime && actual.endRow == expected.endRow &&
            trip.activeTankNumber == intended.activeTankNumber &&
            trip.isFillingTank == intended.isFillingTank &&
            trip.fillingTankNumber == intended.fillingTankNumber)
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
