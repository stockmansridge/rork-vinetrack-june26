package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure unit tests for the [TripRowSequencePlanner] Kotlin port, exercising the
 * same vectors as the iOS planner: every-second-row parity, sequential
 * higher/lower direction, start-path clamping, free-drive empty sequence, and
 * multi-block available-path handling.
 */
class TripRowSequencePlannerTest {

    private fun block(name: String, rows: IntRange): Paddock =
        Paddock(
            id = name,
            vineyardId = "v",
            name = name,
            rows = rows.map { PaddockRow(number = it) },
        )

    private val singleBlock = listOf(block("A", 1..6))

    @Test
    fun availablePaths_singleBlock_spansHalfStepsAroundRows() {
        val paths = TripRowSequencePlanner.availablePaths(singleBlock)
        assertEquals(listOf(0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5), paths)
    }

    @Test
    fun sequential_higherFirst_walksEveryPathAscending() {
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = singleBlock,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 0.5,
            directionHigherFirst = true,
        )
        assertEquals(listOf(0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5), seq)
    }

    @Test
    fun sequential_lowerFirst_reversesTraversal() {
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = singleBlock,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 0.5,
            directionHigherFirst = false,
        )
        assertEquals(listOf(6.5, 5.5, 4.5, 3.5, 2.5, 1.5, 0.5), seq)
    }

    @Test
    fun everySecondRow_higherFirst_coversSameParityPaths() {
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = singleBlock,
            pattern = TrackingPattern.EVERY_SECOND_ROW,
            startPath = 0.5,
            directionHigherFirst = true,
        )
        // Planner's every-second-row walks the same-parity paths from the start
        // path upward (matching iOS: diff %% 2 == 0 from startPath), then wraps
        // to same-parity paths below the start (none here).
        assertEquals(listOf(0.5, 2.5, 4.5, 6.5), seq)
    }

    @Test
    fun everySecondRow_startMidRange_wrapsToLowerSameParity() {
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = singleBlock,
            pattern = TrackingPattern.EVERY_SECOND_ROW,
            startPath = 4.5,
            directionHigherFirst = true,
        )
        // From 4.5 upward (4.5, 6.5), then wrap to lower same-parity (0.5, 2.5).
        assertEquals(listOf(4.5, 6.5, 0.5, 2.5), seq)
    }

    @Test
    fun startPath_clampsAndSnapsToValidPath() {
        // Below range snaps to first available path.
        assertEquals(0.5, TripRowSequencePlanner.clampedStartPath(-5.0, singleBlock), 0.0001)
        // Above range snaps to last available path.
        assertEquals(6.5, TripRowSequencePlanner.clampedStartPath(99.0, singleBlock), 0.0001)
        // An off-grid value snaps onto a half-step.
        assertEquals(3.5, TripRowSequencePlanner.clampedStartPath(3.4, singleBlock), 0.0001)
    }

    @Test
    fun freeDrive_returnsEmptySequence() {
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = singleBlock,
            pattern = TrackingPattern.FREE_DRIVE,
            startPath = 0.5,
            directionHigherFirst = true,
        )
        assertTrue(seq.isEmpty())
    }

    @Test
    fun multiBlock_preservesRealRowNumbersAndOrdering() {
        val blocks = listOf(block("B", 69..72), block("A", 10..12))
        val numbers = TripRowSequencePlanner.selectedRowNumbers(blocks)
        assertEquals(listOf(10, 11, 12, 69, 70, 71, 72), numbers)

        val paths = TripRowSequencePlanner.availablePaths(blocks)
        // Half-steps around each real row number across both blocks.
        assertTrue(paths.contains(9.5))
        assertTrue(paths.contains(68.5))
        assertTrue(paths.contains(72.5))

        // Sequence is offset to real row numbers, not local 1..n.
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = blocks,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = TripRowSequencePlanner.defaultStartPath(blocks),
            directionHigherFirst = true,
        )
        assertEquals(9.5, seq.first(), 0.0001)
        assertEquals(TripRowSequencePlanner.combinedTotalRows(blocks) + 1, seq.size)
    }

    @Test
    fun fromRaw_unknownDefaultsToSequential() {
        assertEquals(TrackingPattern.SEQUENTIAL, TrackingPattern.fromRaw(null))
        assertEquals(TrackingPattern.SEQUENTIAL, TrackingPattern.fromRaw("nonsense"))
        assertEquals(TrackingPattern.EVERY_SECOND_ROW, TrackingPattern.fromRaw("everySecondRow"))
    }
}
