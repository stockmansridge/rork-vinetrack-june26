package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import com.rork.vinetrack.ui.screens.LiveTripGuidance
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class LiveTripGuidanceTest {
    private val vineyard = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val block = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private fun trip() = Trip("cccccccc-cccc-4ccc-8ccc-cccccccccccc", vineyard, paddockName = "Sauv Blanc", isActive = true)

    @Test fun genuineFreeDriveHasNoInventedPathProgressOrEtaInputs() {
        val result = LiveTripGuidance.from(trip().copy(trackingPattern = "freeDrive", currentRowNumber = 108.5))
        assertEquals("Free Drive", result.mode); assertNull(result.current); assertNull(result.next); assertFalse(result.hasPlan)
    }
    @Test fun missingPlannedRecoveryIsNotMislabelledFreeDrive() {
        val result = LiveTripGuidance.from(trip().copy(trackingPattern = "sequential"))
        assertEquals("Waiting for plan", result.mode); assertFalse(result.hasPlan)
    }
    @Test fun legacySavedCursorNotGpsDetectionDefinesAction() {
        val original = trip().copy(rowSequence = listOf(0.5, 2.5, 4.5, 6.5), sequenceIndex = 1,
            currentRowNumber = 108.5, completedPaths = listOf(0.5), skippedPaths = listOf(4.5))
        val result = LiveTripGuidance.from(original)
        assertEquals(2.5, result.current!!, 0.0); assertEquals(6.5, result.next!!, 0.0)
        assertEquals(1, result.done); assertEquals(1, result.skipped); assertEquals(2, result.position)
        assertEquals(listOf(0.5, 2.5, 4.5, 6.5), original.rowSequence)
    }
    @Test fun completedPlanDoesNotFabricateCurrentOrNext() {
        val result = LiveTripGuidance.from(trip().copy(rowSequence = listOf(0.5), sequenceIndex = 1, completedPaths = listOf(0.5)))
        assertEquals("Plan complete", result.mode); assertNull(result.current); assertNull(result.next); assertEquals(1, result.done)
    }
    @Test fun occurrenceSelectedPassAndNextIncompleteRetainIndependentIdentity() {
        val coverage = TripOccurrencePlanner.commit(List(3) { TripOccurrencePlanner.Candidate(vineyard, block, "Sauv Blanc", 38.5, emptyList()) }, vineyard)
        val d = TripOccurrenceCoverage.requireDocument(coverage)
        val selected = d.order[1]
        val changed = JsonObject(coverage + mapOf("selectedOccurrenceId" to JsonPrimitive(selected),
            "states" to JsonObject(d.raw.getValue("states").jsonObject.toMutableMap().apply {
                put(d.order[0], buildJsonObject { put("status", "done"); put("source", "manual"); put("lastOperationId", "dddddddd-dddd-4ddd-8ddd-dddddddddddd"); put("tankSessionIds", JsonArray(emptyList())) })
            })))
        val result = LiveTripGuidance.from(trip().copy(occurrenceCoverage = changed))
        assertEquals(38.5, result.current!!, 0.0); assertEquals(38.5, result.next!!, 0.0)
        assertEquals(2, result.pass); assertEquals(2, result.position); assertEquals(1, result.done); assertEquals(3, result.total)
        assertEquals(selected, TripOccurrenceCoverage.requireDocument(changed).targetId)
    }
    @Test fun unsupportedOccurrenceNeverFallsBackToLegacyNumbers() {
        val result = LiveTripGuidance.from(trip().copy(rowSequence = listOf(38.5), occurrenceCoverage = buildJsonObject { put("schemaVersion", 999) }))
        assertEquals("Recovery required", result.mode); assertNull(result.current); assertNull(result.next)
    }
    @Test fun pausedAndRecoveredSnapshotsDoNotChangeGuidanceOrEvidence() {
        val source = trip().copy(rowSequence = listOf(0.5, 2.5), completedPaths = listOf(0.5), sequenceIndex = 1)
        val encoded = Json.encodeToString(Trip.serializer(), source)
        val restored = Json.decodeFromString(Trip.serializer(), encoded)
        assertEquals(LiveTripGuidance.from(source), LiveTripGuidance.from(restored.copy(isPaused = true)))
        assertEquals(encoded, Json.encodeToString(Trip.serializer(), restored))
    }
}
