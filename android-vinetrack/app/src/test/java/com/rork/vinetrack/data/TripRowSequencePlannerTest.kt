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
            startPath = 6.5,
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
        // path upward (matching iOS: diff % 2 == 0 from startPath), then wraps
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

        // Sequence is expressed in real row numbers, not local 1..n.
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = blocks,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = TripRowSequencePlanner.defaultStartPath(blocks),
            directionHigherFirst = true,
        )
        assertEquals(9.5, seq.first(), 0.0001)
        // One path per gap between/around rows, drawn from availablePaths.
        assertEquals(paths.size, seq.size)
    }

    @Test
    fun fromRaw_unknownDefaultsToSequential() {
        assertEquals(TrackingPattern.SEQUENTIAL, TrackingPattern.fromRaw(null))
        assertEquals(TrackingPattern.SEQUENTIAL, TrackingPattern.fromRaw("nonsense"))
        assertEquals(TrackingPattern.EVERY_SECOND_ROW, TrackingPattern.fromRaw("everySecondRow"))
    }

    // -----------------------------------------------------------------------
    // Path-generation defect regression.
    //
    // Patterns used to invent `totalRows + 1` numeric paths from the selected
    // local start row, so a block of rows 69-108 started at path 108.5 produced
    // 147.5 -> 146.5 -> ... The contract now: availablePaths is the
    // authoritative universe and every emitted value is a member of it.
    // Vectors are identical to the iOS TripRowSequencePlannerTests.
    // -----------------------------------------------------------------------

    /** Valid path universe for a set of ACTUAL configured row numbers. */
    private fun pathsForRows(rows: List<Int>): List<Double> {
        val set = mutableSetOf<Double>()
        for (n in rows) {
            set.add(n.toDouble() - 0.5)
            set.add(n.toDouble() + 0.5)
        }
        return set.sorted()
    }

    /** The Pinot Noir block: 40 actual rows, 41 valid paths (68.5 .. 108.5). */
    private val pinotNoirPaths: List<Double> get() = pathsForRows((69..108).toList())

    private val plannedPatterns = listOf(
        TrackingPattern.SEQUENTIAL,
        TrackingPattern.EVERY_SECOND_ROW,
        TrackingPattern.FIVE_THREE,
        TrackingPattern.UP_AND_BACK,
        TrackingPattern.TWO_ROW_UP_BACK,
        TrackingPattern.CUSTOM,
    )

    @Test
    fun production_sequential_start108_5_higherToLower() {
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pinotNoirPaths,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 108.5,
            higherFirst = false,
        )
        assertEquals(108.5, seq.first(), 0.0001)
        assertEquals(68.5, seq.last(), 0.0001)
        assertEquals(41, seq.size)
        assertEquals(listOf(108.5, 107.5, 106.5), seq.take(3))
        assertTrue("the defect's signature path must not appear", !seq.contains(147.5))
        assertTrue(seq.all { it in 68.5..108.5 })
    }

    @Test
    fun production_sequential_start68_5_lowerToHigher() {
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pinotNoirPaths,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 68.5,
            higherFirst = true,
        )
        assertEquals(68.5, seq.first(), 0.0001)
        assertEquals(108.5, seq.last(), 0.0001)
        assertEquals(41, seq.size)
    }

    @Test
    fun production_sequential_start90_5_lowerToHigher_wraps() {
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pinotNoirPaths,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 90.5,
            higherFirst = true,
        )
        assertEquals(90.5, seq.first(), 0.0001)
        assertEquals(41, seq.size)
        assertEquals(41, seq.toSet().size)
        assertEquals(108.5, seq[18], 0.0001)
        assertEquals(68.5, seq[19], 0.0001)
        assertEquals(89.5, seq.last(), 0.0001)
    }

    @Test
    fun production_sequential_start90_5_higherToLower_wraps() {
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pinotNoirPaths,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 90.5,
            higherFirst = false,
        )
        assertEquals(90.5, seq.first(), 0.0001)
        assertEquals(41, seq.size)
        assertEquals(41, seq.toSet().size)
        assertEquals(89.5, seq[1], 0.0001)
        assertEquals(68.5, seq[22], 0.0001)
        assertEquals(108.5, seq[23], 0.0001)
        assertEquals(91.5, seq.last(), 0.0001)
    }

    @Test
    fun everyPlannedPattern_onlyEmitsAvailablePaths() {
        val universe = pinotNoirPaths.toSet()
        for (pattern in plannedPatterns) {
            for (higherFirst in listOf(true, false)) {
                for (start in listOf(68.5, 90.5, 108.5)) {
                    val seq = TripRowSequencePlanner.plannedSequence(
                        paths = pinotNoirPaths,
                        pattern = pattern,
                        startPath = start,
                        higherFirst = higherFirst,
                    )
                    assertTrue("${pattern.rawValue} produced nothing", seq.isNotEmpty())
                    for (path in seq) {
                        assertTrue(
                            "${pattern.rawValue} invented path $path",
                            universe.contains(path),
                        )
                    }
                }
            }
        }
    }

    @Test
    fun startPathIsHonoured_forStartMeaningfulPatterns() {
        val startMeaningful = listOf(
            TrackingPattern.SEQUENTIAL,
            TrackingPattern.EVERY_SECOND_ROW,
            TrackingPattern.FIVE_THREE,
            TrackingPattern.UP_AND_BACK,
            TrackingPattern.CUSTOM,
        )
        for (pattern in startMeaningful) {
            for (higherFirst in listOf(true, false)) {
                val seq = TripRowSequencePlanner.plannedSequence(
                    paths = pinotNoirPaths,
                    pattern = pattern,
                    startPath = 90.5,
                    higherFirst = higherFirst,
                )
                assertEquals(
                    "${pattern.rawValue} did not start on the start path",
                    90.5,
                    seq.first(),
                    0.0001,
                )
            }
        }
    }

    @Test
    fun coveragePatterns_visitEveryPathOnce() {
        val onceThrough = listOf(
            TrackingPattern.SEQUENTIAL,
            TrackingPattern.FIVE_THREE,
            TrackingPattern.TWO_ROW_UP_BACK,
            TrackingPattern.CUSTOM,
        )
        for (pattern in onceThrough) {
            val seq = TripRowSequencePlanner.plannedSequence(
                paths = pinotNoirPaths,
                pattern = pattern,
                startPath = 108.5,
                higherFirst = false,
            )
            assertEquals("${pattern.rawValue} missed paths", 41, seq.toSet().size)
            assertEquals("${pattern.rawValue} repeated paths", 41, seq.size)
        }
    }

    @Test
    fun upAndBack_repeatsEachValidPath() {
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pinotNoirPaths,
            pattern = TrackingPattern.UP_AND_BACK,
            startPath = 108.5,
            higherFirst = false,
        )
        assertEquals(82, seq.size)
        assertEquals(41, seq.toSet().size)
        assertEquals(listOf(108.5, 108.5, 107.5, 107.5), seq.take(4))
    }

    @Test
    fun nonContiguousSelection_producesNoPhantomPathsInTheGap() {
        val rows = (1..14).toList() + (69..108).toList()
        val universe = pathsForRows(rows)
        assertEquals(56, universe.size)
        val valid = universe.toSet()

        for (pattern in plannedPatterns) {
            for (higherFirst in listOf(true, false)) {
                val seq = TripRowSequencePlanner.plannedSequence(
                    paths = universe,
                    pattern = pattern,
                    startPath = 108.5,
                    higherFirst = higherFirst,
                )
                for (path in seq) {
                    assertTrue("${pattern.rawValue} invented $path", valid.contains(path))
                    assertTrue(
                        "${pattern.rawValue} walked the gap at $path",
                        !(path > 14.5 && path < 68.5),
                    )
                }
            }
        }
    }

    @Test
    fun nonContiguousSelection_sequentialJumpsTheGap() {
        val rows = (1..14).toList() + (69..108).toList()
        val seq = TripRowSequencePlanner.plannedSequence(
            paths = pathsForRows(rows),
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = 0.5,
            higherFirst = true,
        )
        assertEquals(0.5, seq.first(), 0.0001)
        assertEquals(108.5, seq.last(), 0.0001)
        assertEquals(56, seq.size)
        val gapIndex = seq.indexOf(14.5)
        assertTrue("14.5 must be present", gapIndex >= 0)
        assertEquals(68.5, seq[gapIndex + 1], 0.0001)
    }

    /**
     * The production case driven through the paddock entry point TripsScreen
     * actually calls, so preview and trip creation are both covered.
     */
    @Test
    fun production_viaPaddockEntryPoint_matchesPurePlanner() {
        val blocks = listOf(block("Pinot Noir", 69..108))
        assertEquals(40, TripRowSequencePlanner.combinedTotalRows(blocks))
        assertEquals(41, TripRowSequencePlanner.availablePaths(blocks).size)

        val startPath = TripRowSequencePlanner.clampedStartPath(108.5, blocks)
        assertEquals(108.5, startPath, 0.0001)

        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = blocks,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = startPath,
            directionHigherFirst = false,
        )
        assertEquals(108.5, seq.first(), 0.0001)
        assertEquals(68.5, seq.last(), 0.0001)
        assertEquals(41, seq.size)
    }

    @Test
    fun nonContiguousPaddockSelection_hasNoPhantomPaths() {
        val blocks = listOf(block("Low", 1..14), block("High", 69..108))
        assertEquals(54, TripRowSequencePlanner.combinedTotalRows(blocks))
        val seq = TripRowSequencePlanner.generateSequence(
            paddocks = blocks,
            pattern = TrackingPattern.SEQUENTIAL,
            startPath = TripRowSequencePlanner.defaultStartPath(blocks),
            directionHigherFirst = true,
        )
        assertEquals(56, seq.size)
        assertTrue(seq.none { it > 14.5 && it < 68.5 })
    }
}
