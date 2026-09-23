package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TripRowPlanSyncTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun latestRouteWinsWithOneDurableMarkerForStableTripId() {
        val store = InMemoryPendingWriteStore()
        val first = PendingWriteRepository(store)
        val baseline = TripRowPlanSync.Plan("sequential", listOf(68.5, 69.5), 1, 69.5, null)
        val initial = TripRowPlanSync.Payload("trip-1", baseline,
            TripRowPlanSync.Plan("sequential", listOf(90.5, 91.5), 0, 90.5, 91.5))
        first.upsertCoalesced(PendingEntityType.TRIP_ROW_PLAN, "trip-1",
            json.encodeToString(TripRowPlanSync.Payload.serializer(), initial))
        val revised = initial.copy(target = TripRowPlanSync.Plan("everySecondRow", listOf(90.5, 92.5), 0, 90.5, 92.5),
            earlierLocalTargets = listOf(initial.target))
        first.upsertCoalesced(PendingEntityType.TRIP_ROW_PLAN, "trip-1",
            json.encodeToString(TripRowPlanSync.Payload.serializer(), revised))
        val restored = PendingWriteRepository(store).list().single()
        assertEquals("trip-1", restored.clientId)
        assertEquals(PendingEntityType.TRIP_ROW_PLAN, restored.entityType)
        val saved = json.decodeFromString(TripRowPlanSync.Payload.serializer(), restored.payloadJson)
        assertEquals(baseline, saved.baseline)
        assertEquals(revised.target, saved.target)
    }

    @Test fun changedServerRouteBlocksButCoverageIndexDoesNotCountAsRouteChange() {
        val baseline = TripRowPlanSync.Plan("sequential", listOf(68.5, 69.5), 0, 68.5, 69.5)
        val target = TripRowPlanSync.Plan("everySecondRow", listOf(90.5, 92.5), 0, 90.5, 92.5)
        val payload = TripRowPlanSync.Payload("trip-1", baseline, target)
        assertTrue(TripRowPlanSync.isCompatible(baseline.copy(index = 1, current = 69.5), payload))
        assertFalse(TripRowPlanSync.isCompatible(baseline.copy(sequence = listOf(70.5, 71.5)), payload))
        assertTrue(TripRowPlanSync.isCompatible(target, payload))
    }

    @Test fun plannerVectorsMatchIosAndReplanLeavesHistoricalTripFieldsUntouched() {
        val paths = (69..108).map { it - 0.5 } + 108.5
        val descending = TripRowSequencePlanner.plannedSequence(paths, TrackingPattern.SEQUENTIAL, 108.5, false)
        assertEquals(listOf(108.5, 107.5, 106.5), descending.take(3))
        val proposed = TripRowSequencePlanner.plannedSequence(paths, TrackingPattern.EVERY_SECOND_ROW, 90.5, true)
        assertEquals(90.5, proposed.first(), 0.0)
        assertEquals(emptyList<Double>(), TripRowSequencePlanner.plannedSequence(paths, TrackingPattern.FREE_DRIVE, 90.5, true))
        val trip = Trip(id = "trip-1", vineyardId = "v", isActive = true,
            trackingPattern = "sequential", rowSequence = descending, completedPaths = listOf(108.5), skippedPaths = listOf(107.5),
            totalDistance = 1234.0, startTime = "2026-09-23T00:00:00Z", manualCorrectionEvents = listOf("prior"))
        val remaining = proposed.filterNot { it in trip.completedPaths.orEmpty() || it in trip.skippedPaths.orEmpty() }
        val updated = trip.copy(trackingPattern = "everySecondRow", rowSequence = remaining, sequenceIndex = 0,
            currentRowNumber = remaining.first(), nextRowNumber = remaining.getOrNull(1), manualCorrectionEvents = trip.manualCorrectionEvents.orEmpty() + "new")
        assertEquals(trip.id, updated.id)
        assertEquals(trip.startTime, updated.startTime)
        assertEquals(trip.totalDistance, updated.totalDistance)
        assertEquals(trip.completedPaths, updated.completedPaths)
        assertEquals(trip.skippedPaths, updated.skippedPaths)
        assertEquals(listOf("prior", "new"), updated.manualCorrectionEvents)
    }
}
