package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.screens.LiveRowSideGuidance
import org.junit.Assert.*
import org.junit.Test

class LiveRowSideGuidanceTest {
    private val now = 20_000L
    private fun point(x: Double, y: Double) = CoordinatePoint(y / 111_320.0, x / 111_320.0)
    private fun block(id: String = "block", offset: Double = 0.0, numbers: List<Int> = listOf(12, 13)) = Paddock(id, "vineyard", id, rowWidth = 4.0,
        polygonPoints = listOf(point(offset - 2, -10.0), point(offset + 6, -10.0), point(offset + 6, 110.0), point(offset - 2, 110.0)),
        rows = numbers.mapIndexed { index, number -> PaddockRow(number = number, startPoint = point(offset + index * 4.0, 0.0), endPoint = point(offset + index * 4.0, 100.0)) })
    private val trip = Trip("trip", "vineyard", isActive = true, trackingPattern = "freeDrive")
    private fun fix(x: Double = 2.0, y: Double = 50.0, bearing: Double? = 0.0, speed: Double? = 1.5, accuracy: Double? = 1.0, time: Long = now) =
        LocationTracker.MovementSample(y / 111_320.0, x / 111_320.0, bearing, speed, accuracy, time)
    private fun resolve(sample: LocationTracker.MovementSample? = fix(), blocks: List<Paddock> = listOf(block()), source: Trip = trip) = LiveRowSideGuidance.resolve(source, blocks, sample, now)
    @Test fun freeDriveUsesPhysicalBoundingRowsNotAnyPlannedPath() {
        val result = resolve(); assertEquals(12.0, result.left!!, 0.0); assertEquals(13.0, result.right!!, 0.0); assertEquals("block", result.blockId)
        assertTrue(trip.rowSequence.orEmpty().isEmpty()); assertNull(trip.occurrenceCoverage)
    }
    @Test fun oppositeCourseReversesSidesEvenWithNorthUpMap() {
        val result = resolve(fix(bearing = 180.0)); assertEquals(13.0, result.left!!, 0.0); assertEquals(12.0, result.right!!, 0.0)
    }
    @Test fun reversedNonconsecutiveNumberingAndRowEndpointOrientationAreGeometric() {
        val b = block(numbers = listOf(91, 7)); val reversed = b.copy(rows = b.rows!!.map { it.copy(startPoint = it.endPoint, endPoint = it.startPoint) })
        val result = resolve(blocks = listOf(reversed)); assertEquals(91.0, result.left!!, 0.0); assertEquals(7.0, result.right!!, 0.0)
    }
    @Test fun decimalSavedRowNumbersRemainExact() {
        val b = block(); val r = resolve(blocks = listOf(b.copy(rows = b.rows!!.map { it.copy(decimalNumber = it.number + 0.25) })))
        assertEquals(12.25, r.left!!, 0.0); assertEquals(13.25, r.right!!, 0.0)
    }
    @Test fun legacySavedActionTargetDoesNotControlSidesOrMutate() {
        val planned = trip.copy(rowSequence = listOf(108.5, 103.5), sequenceIndex = 1, currentRowNumber = 108.5)
        val before = SupabaseClient.json.encodeToString(Trip.serializer(), planned)
        val r = resolve(source = planned); assertEquals(12.0, r.left!!, 0.0)
        assertEquals(before, SupabaseClient.json.encodeToString(Trip.serializer(), planned))
    }
    @Test fun occurrenceTargetAndIdentitiesStayIndependent() {
        val candidate = TripOccurrencePlanner.Candidate("vineyard", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "block", 108.5, emptyList())
        val planned = trip.copy(occurrenceCoverage = TripOccurrencePlanner.commit(listOf(candidate, candidate), "vineyard"))
        val before = planned.occurrenceDocument!!; val r = resolve(source = planned)
        assertEquals(12.0, r.left!!, 0.0); assertEquals(before.raw, planned.occurrenceDocument!!.raw)
        assertEquals(before.targetId, planned.occurrenceDocument!!.targetId); assertEquals(0, before.count("done"))
    }
    @Test fun stationaryLowSpeedMissingAndInvalidHeadingNeverGuess() {
        listOf(fix(speed = 0.0), fix(speed = 0.9), fix(bearing = null), fix(bearing = Double.NaN), fix(speed = null)).forEach {
            val r = resolve(it); assertNull(r.left); assertNull(r.right); assertTrue(r.message!!.contains("direction"))
        }
    }
    @Test fun staleFutureAndMissingFixNeverReusePriorSides() {
        listOf(null, fix(time = now - 5_001), fix(time = now + 1)).forEach { assertNull(resolve(it).left); assertTrue(resolve(it).message!!.contains("reliable fix")) }
    }
    @Test fun inaccurateAndMissingAccuracyWaitForReliableFix() {
        listOf(null, 4.0, 15.0, Double.NaN, -1.0).forEach { val r = resolve(fix(accuracy = it)); assertNull(r.left); assertEquals(LiveRowSideGuidance.ACCURACY_WAITING, r.message) }
    }
    @Test fun headlandsOutsideAndCrossRowTravelNeverInventSides() {
        listOf(fix(y = 105.0), fix(y = 130.0), fix(x = 5.0), fix(bearing = 90.0)).forEach { assertNull(resolve(it).left); assertNull(resolve(it).right) }
    }
    @Test fun movesAcrossBlocksWithoutStaleOrForeignRows() {
        val blocks = listOf(block(), block("next", 20.0, listOf(40, 9)), block("foreign", 20.0).copy(vineyardId = "foreign"))
        assertEquals("block", resolve(blocks = blocks).blockId)
        val r = resolve(fix(x = 22.0), blocks); assertEquals("next", r.blockId); assertEquals(40.0, r.left!!, 0.0)
        assertNull(resolve(fix(x = 22.0), blocks, trip.copy(paddockId = "block")).left)
    }
    @Test fun overlappingBlocksMissingRowsAndDuplicateIdentitiesAreUnavailable() {
        assertNull(resolve(blocks = listOf(block(), block("overlap"))).left)
        assertNull(resolve(blocks = listOf(block().copy(rows = emptyList(), rowDirection = 0.0))).left)
        assertNull(resolve(blocks = listOf(block(numbers = listOf(12, 12)))).left)
    }
    @Test fun oneKnownMappedSideDoesNotInventTheOtherOrAnAisle() {
        val one = block().copy(rows = block().rows!!.take(1))
        val r = resolve(blocks = listOf(one)); assertEquals(12.0, r.left!!, 0.0); assertNull(r.right)
        val reverse = resolve(fix(bearing = 180.0), listOf(one)); assertNull(reverse.left); assertEquals(12.0, reverse.right!!, 0.0)
        assertNull(resolve(fix(y = 105.0), listOf(one)).left)
        assertNull(resolve(fix(accuracy = 3.0), listOf(one)).left)
    }
    @Test fun outerMappedRowInMultiRowBlockShowsOnlyPhysicallyKnownSide() {
        val r = resolve(fix(x = 5.5, accuracy = 0.5)); assertEquals(13.0, r.left!!, 0.0); assertNull(r.right)
        val reverse = resolve(fix(x = 5.5, accuracy = 0.5, bearing = 180.0)); assertNull(reverse.left); assertEquals(13.0, reverse.right!!, 0.0)
        assertNull(resolve(fix(x = 5.5, y = 105.0, accuracy = 0.5)).left)
    }
    @Test fun courseCannotDistinguishBackingFromTurnaroundAndNeverClaimsFacing() {
        val north = resolve(fix(bearing = 0.0))
        // A southbound forward vehicle and a north-facing vehicle backing south
        // have exactly the same available MovementSample. No gear/facing is present.
        val backing = fix(bearing = 180.0)
        val turnedAround = backing.copy()
        val south = resolve(backing)
        assertEquals(south, resolve(turnedAround))
        assertEquals(north.left, south.right); assertEquals(north.right, south.left)
        assertEquals(LiveRowSideGuidance.TRAVEL_REFERENCE, south.message)
        assertNull(resolve(fix(bearing = 90.0)).left)
        assertNull(resolve(fix(speed = 0.0)).left)
        assertEquals(north, resolve(fix(bearing = 0.0)))
    }
    private fun narrowBlock(spacing: Double): Paddock = block().copy(rowWidth = spacing,
        rows = (12..15).mapIndexed { index, number -> PaddockRow(number = number,
            startPoint = point(index * spacing, 0.0), endPoint = point(index * spacing, 100.0)) },
        polygonPoints = listOf(point(-2.0, -10.0), point(spacing * 3 + 2, -10.0), point(spacing * 3 + 2, 110.0), point(-2.0, 110.0)))
    @Test fun realisticSpacingAccuracyMatrixNeverTreatsGpsGoodAsRowProof() {
        listOf(2.8, 2.9, 3.0).forEach { spacing ->
            listOf(1.0, 3.0, 5.0, 8.0).forEach { accuracy ->
                val result = resolve(fix(x = spacing * 1.5, accuracy = accuracy), listOf(narrowBlock(spacing)))
                if (accuracy == 1.0) {
                    assertEquals(13.0, result.left!!, 0.0); assertEquals(14.0, result.right!!, 0.0)
                } else {
                    assertNull(result.left); assertNull(result.right)
                    assertEquals(LiveRowSideGuidance.ACCURACY_WAITING, result.message)
                }
            }
        }
    }
    @Test fun evenOneMetreFixMustClearBothRowsAndTheirEnds() {
        val b = narrowBlock(2.8)
        listOf(fix(x = 0.8), fix(x = 2.0), fix(x = 1.4, y = 0.8), fix(x = 1.4, y = 99.2)).forEach {
            val result = resolve(it, listOf(b)); assertNull(result.left); assertNull(result.right)
            assertEquals(LiveRowSideGuidance.ACCURACY_WAITING, result.message)
        }
    }
    @Test fun accuracyLossRecoveryAndBlockTransitionNeverChangeOriginalEvidence() {
        val original = trip.copy(pathPoints = listOf(point(1.4, 40.0), point(1.4, 45.0)))
        val bytes = SupabaseClient.json.encodeToString(Trip.serializer(), original)
        val first = narrowBlock(2.8)
        val next = first.copy(id = "next", rows = first.rows!!.map { row -> row.copy(
            startPoint = row.startPoint!!.copy(longitude = row.startPoint!!.longitude + 20.0 / 111_320.0),
            endPoint = row.endPoint!!.copy(longitude = row.endPoint!!.longitude + 20.0 / 111_320.0)) },
            polygonPoints = first.polygonPoints!!.map { it.copy(longitude = it.longitude + 20.0 / 111_320.0) })
        listOf(1.0, 3.0, 5.0, 8.0, 1.0).forEach { accuracy ->
            val result = resolve(fix(x = 1.4, accuracy = accuracy), listOf(first, next), original)
            assertEquals(accuracy == 1.0, result.left != null)
        }
        assertEquals("next", resolve(fix(x = 21.4), listOf(first, next), original).blockId)
        assertEquals(bytes, SupabaseClient.json.encodeToString(Trip.serializer(), original))
    }
    @Test fun pauseAndReturnUseFreshEvidenceWithoutChangingTrip() {
        assertNull(resolve(source = trip.copy(isPaused = true)).left)
        val evidence = trip.copy(pathPoints = listOf(point(2.0, 40.0), point(2.0, 45.0)))
        assertNull(LiveRowSideGuidance.resolve(evidence, listOf(block()), fix(), now + 6_000).left)
        assertEquals(12.0, LiveRowSideGuidance.resolve(evidence, listOf(block()), fix(time = now + 6_000), now + 6_000).left!!, 0.0)
        assertEquals(2, evidence.pathPoints!!.size); assertEquals(trip.id, evidence.id)
    }
}
