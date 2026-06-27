package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Row/path traversal pattern, mirroring the iOS `TrackingPattern` enum. The
 * raw value matches the iOS string stored in `trips.tracking_pattern` so the
 * two platforms stay interchangeable.
 */
enum class TrackingPattern(val rawValue: String) {
    SEQUENTIAL("sequential"),
    EVERY_SECOND_ROW("everySecondRow"),
    FIVE_THREE("fiveThree"),
    UP_AND_BACK("upAndBack"),
    TWO_ROW_UP_BACK("twoRowUpBack"),
    CUSTOM("custom"),

    /**
     * Free Drive — operator is not following a planned row sequence. No
     * sequence is generated; rows are detected live from GPS position.
     */
    FREE_DRIVE("freeDrive");

    val title: String
        get() = when (this) {
            SEQUENTIAL -> "One After Another"
            EVERY_SECOND_ROW -> "Every Second Row"
            FIVE_THREE -> "3/5 Pattern"
            UP_AND_BACK -> "Up and Back"
            TWO_ROW_UP_BACK -> "2 Row Up & Back"
            CUSTOM -> "Custom"
            FREE_DRIVE -> "Free Drive"
        }

    val subtitle: String
        get() = when (this) {
            SEQUENTIAL -> "0.5, 1.5, 2.5 ... lastRow+0.5"
            EVERY_SECOND_ROW -> "0.5, 2.5, 4.5 ... then 3.5, 1.5"
            FIVE_THREE -> "0.5, 3.5, 1.5, 5.5, 2.5 ... +5, -3"
            UP_AND_BACK -> "0.5, 0.5, 1.5, 1.5 ... each path twice"
            TWO_ROW_UP_BACK -> "Spray 2, Skip 2 up then back"
            CUSTOM -> "Save & reuse your own sequences"
            FREE_DRIVE -> "No planned path — detect rows live"
        }

    /**
     * Generate the local (1-based) path sequence for this pattern. Mirrors the
     * iOS `TrackingPattern.generateSequence`. Free Drive returns an empty list.
     */
    fun generateSequence(startRow: Int, totalRows: Int, reversed: Boolean = false): List<Double> {
        if (this == FREE_DRIVE) return emptyList()
        if (totalRows <= 0) return emptyList()

        val firstPath = startRow.toDouble() - 0.5
        val totalPaths = totalRows + 1

        var result: List<Double> = when (this) {
            SEQUENTIAL, CUSTOM -> (0 until totalPaths).map { firstPath + it.toDouble() }

            EVERY_SECOND_ROW -> {
                val sequence = mutableListOf<Double>()
                var i = 0
                while (i < totalPaths) {
                    sequence.add(firstPath + i.toDouble())
                    i += 2
                }
                i = totalPaths - 1
                while (i >= 0) {
                    val path = firstPath + i.toDouble()
                    if (!sequence.contains(path)) sequence.add(path)
                    i -= 2
                }
                for (j in 0 until totalPaths) {
                    val path = firstPath + j.toDouble()
                    if (!sequence.contains(path)) sequence.add(path)
                }
                sequence
            }

            UP_AND_BACK -> {
                val sequence = mutableListOf<Double>()
                for (j in 0 until totalPaths) {
                    val path = firstPath + j.toDouble()
                    sequence.add(path)
                    sequence.add(path)
                }
                sequence
            }

            FIVE_THREE -> generateFiveThreeSequence(firstPath, totalPaths)

            TWO_ROW_UP_BACK -> generateTwoRowUpBackSequence(firstPath, totalPaths)

            FREE_DRIVE -> emptyList()
        }

        if (reversed) result = result.reversed()
        return result
    }

    companion object {
        /** Decode a raw column value, defaulting to [SEQUENTIAL] like iOS. */
        fun fromRaw(raw: String?): TrackingPattern =
            entries.firstOrNull { it.rawValue == raw } ?: SEQUENTIAL

        private fun generateTwoRowUpBackSequence(firstPath: Double, totalPaths: Int): List<Double> {
            val lastPath = firstPath + (totalPaths - 1).toDouble()

            val upPaths = mutableListOf<Double>()
            var path = firstPath + 1.0
            while (path <= lastPath) {
                upPaths.add(path)
                path += 4.0
            }

            val backPaths = mutableListOf<Double>()
            path = firstPath + 3.0
            while (path <= lastPath) {
                backPaths.add(path)
                path += 4.0
            }
            backPaths.reverse()

            val result = (upPaths + backPaths).toMutableList()

            val visited = result.toSet()
            var r = firstPath
            while (r <= lastPath) {
                if (!visited.contains(r)) result.add(r)
                r += 1.0
            }
            return result
        }

        private fun generateFiveThreeSequence(firstPath: Double, totalPaths: Int): List<Double> {
            val startRow = firstPath
            val endRow = firstPath + (totalPaths - 1).toDouble()
            val startupPattern = listOf(0.0, 3.0, 1.0, 5.0, 2.0).map { startRow + it }

            val result = mutableListOf<Double>()
            val visited = mutableSetOf<Double>()

            for (row in startupPattern) {
                if (row in startRow..endRow && !visited.contains(row)) {
                    result.add(row)
                    visited.add(row)
                }
            }

            var current = result.lastOrNull()
                ?: return (0 until totalPaths).map { firstPath + it.toDouble() }

            var usePlusFive = true
            while (true) {
                val next = if (usePlusFive) current + 5.0 else current - 3.0
                if (next < startRow || next > endRow || visited.contains(next)) break
                result.add(next)
                visited.add(next)
                current = next
                usePlusFive = !usePlusFive
            }

            val allRows = mutableListOf<Double>()
            var row = startRow
            while (row <= endRow) {
                allRows.add(row)
                row += 1.0
            }
            val remaining = allRows.filter { !visited.contains(it) }
            if (remaining.isNotEmpty()) result.addAll(remaining)

            return result
        }
    }
}

/**
 * Shared row/path sequence planning, ported from the iOS
 * `TripRowSequencePlanner`. Encapsulates the multi-block aware path math so the
 * Start Path picker, Sequence Direction handling, and Proposed Row Sequence all
 * match iOS for a given selection. Real vineyard row numbers are preserved
 * (e.g. a block with rows 69–108 yields paths 68.5–108.5).
 *
 * Pure helper — no I/O, no Android dependencies — so it is unit-testable.
 */
object TripRowSequencePlanner {

    private fun rowsOf(paddock: Paddock): List<Int> =
        paddock.rows.orEmpty().map { it.number }

    /**
     * Comparator equivalent of the iOS `rowOrderSort`: lowest row number first,
     * then name; blocks without rows sort to the end (by name).
     */
    val rowOrderComparator: Comparator<Paddock> = Comparator { a, b ->
        val aMin = rowsOf(a).minOrNull()
        val bMin = rowsOf(b).minOrNull()
        when {
            aMin != null && bMin != null ->
                if (aMin != bMin) aMin.compareTo(bMin)
                else a.name.lowercase().compareTo(b.name.lowercase())
            aMin != null && bMin == null -> -1
            aMin == null && bMin != null -> 1
            else -> a.name.lowercase().compareTo(b.name.lowercase())
        }
    }

    /** Sorted, de-duplicated list of every actual row number across the blocks. */
    fun selectedRowNumbers(paddocks: List<Paddock>): List<Int> {
        val set = mutableSetOf<Int>()
        for (paddock in paddocks) {
            for (n in rowsOf(paddock)) set.add(n)
        }
        return set.sorted()
    }

    /** Combined total row count across every selected block. */
    fun combinedTotalRows(paddocks: List<Paddock>): Int =
        paddocks.sumOf { rowsOf(it).size }

    /** Whether any selected block has row geometry. */
    fun hasAnyRowGeometry(paddocks: List<Paddock>): Boolean =
        paddocks.any { rowsOf(it).isNotEmpty() }

    /**
     * Available start paths across the full selection. For each actual row
     * number N we contribute paths N-0.5 and N+0.5.
     */
    fun availablePaths(paddocks: List<Paddock>): List<Double> {
        val numbers = selectedRowNumbers(paddocks)
        if (numbers.isEmpty()) return listOf(0.5)
        val set = mutableSetOf<Double>()
        for (n in numbers) {
            set.add(n.toDouble() - 0.5)
            set.add(n.toDouble() + 0.5)
        }
        return set.sorted()
    }

    /** Clamp + snap a start path to a valid value within [availablePaths]. */
    fun clampedStartPath(value: Double, paddocks: List<Paddock>): Double {
        val paths = availablePaths(paddocks)
        val first = paths.firstOrNull() ?: return value
        val last = paths.lastOrNull() ?: return value
        var p = value
        if (p < first) p = first
        if (p > last) p = last
        val rounded = (p - 0.5).roundToInt().toDouble() + 0.5
        if (abs(rounded - p) > 0.01) {
            p = minOf(maxOf(rounded, first), last)
        }
        return p
    }

    /** Default start path — the very first path of the selection. */
    fun defaultStartPath(paddocks: List<Paddock>): Double =
        availablePaths(paddocks).firstOrNull() ?: 0.5

    /** Format a path with a single decimal where required ("1", "1.5"). */
    fun formatPath(value: Double): String =
        if (value % 1.0 == 0.0) value.toInt().toString()
        else String.format("%.1f", value)

    /** Friendly label for a path in a picker menu. */
    fun pathMenuLabel(path: Double, paddocks: List<Paddock>): String {
        val pathStr = formatPath(path)
        val numbers = selectedRowNumbers(paddocks)
        val lo = numbers.firstOrNull() ?: 1
        val hi = numbers.lastOrNull() ?: 0
        if (numbers.isNotEmpty() && path < lo.toDouble()) {
            return "Path before row $lo — $pathStr"
        }
        if (numbers.isNotEmpty() && path > hi.toDouble()) {
            return "Path after row $hi — $pathStr"
        }
        val lower = floor(path).toInt()
        val upper = lower + 1
        return "Between rows $lower\u2013$upper — $pathStr"
    }

    /** Combined row range label like "Rows 69–108" or "Rows not configured". */
    fun combinedRangeLabel(paddocks: List<Paddock>): String {
        val numbers = selectedRowNumbers(paddocks)
        val lo = numbers.firstOrNull()
        val hi = numbers.lastOrNull()
        if (lo == null || hi == null) return "Rows not configured"
        if (lo == hi) return "Row $lo"
        return "Rows $lo\u2013$hi"
    }

    /** Combined paths label like "Paths 0.5–108.5". */
    fun combinedPathsLabel(paddocks: List<Paddock>): String {
        val paths = availablePaths(paddocks)
        val lo = paths.firstOrNull() ?: return ""
        val hi = paths.lastOrNull() ?: return ""
        return "Paths ${formatPath(lo)}\u2013${formatPath(hi)}"
    }

    /** Compact row-range label from a sorted list of actual row numbers. */
    fun compactRowRangeLabel(numbers: List<Int>): String {
        val lo = numbers.firstOrNull() ?: return "Rows"
        val hi = numbers.lastOrNull() ?: return "Rows"
        val segments = mutableListOf<Pair<Int, Int>>()
        var segStart = lo
        var prev = lo
        for (n in numbers.drop(1)) {
            if (n == prev + 1) {
                prev = n
            } else {
                segments.add(segStart to prev)
                segStart = n
                prev = n
            }
        }
        segments.add(segStart to prev)
        if (segments.size == 1) {
            return if (lo == hi) "Row $lo" else "Rows $lo\u2013$hi"
        }
        if (segments.size <= 2) {
            val parts = segments.map { if (it.first == it.second) "${it.first}" else "${it.first}\u2013${it.second}" }
            return "Rows " + parts.joinToString(", ")
        }
        return "Rows $lo\u2013$hi"
    }

    /**
     * Generate the full traversal sequence for the given pattern, start path,
     * and direction across all selected paddocks. Returns paths expressed as
     * real row numbers (e.g. 68.5, 69.5, …), matching `Trip.rowSequence`.
     */
    fun generateSequence(
        paddocks: List<Paddock>,
        pattern: TrackingPattern,
        startPath: Double,
        directionHigherFirst: Boolean,
    ): List<Double> {
        val n = combinedTotalRows(paddocks)
        if (n <= 0) return emptyList()
        if (pattern == TrackingPattern.EVERY_SECOND_ROW) {
            return everySecondRowSequence(
                paths = availablePaths(paddocks),
                startPath = startPath,
                higherFirst = directionHigherFirst,
            )
        }
        val numbers = selectedRowNumbers(paddocks)
        val minRow = numbers.firstOrNull() ?: 1
        val offset = (minRow - 1).toDouble()
        val localStartRow = maxOf(1, minOf(((startPath - offset) + 0.5).toInt(), n))
        val raw = pattern.generateSequence(
            startRow = localStartRow,
            totalRows = n,
            reversed = !directionHigherFirst,
        )
        return raw.map { it + offset }
    }

    /** Every Second Row, parity-preserving sequence across the combined paths. */
    fun everySecondRowSequence(
        paths: List<Double>,
        startPath: Double,
        higherFirst: Boolean,
    ): List<Double> {
        if (paths.isEmpty()) return emptyList()
        val sorted = paths.sorted()
        val sameParity = sorted.filter { p ->
            val diff = (p - startPath).roundToInt()
            diff % 2 == 0
        }
        if (sameParity.isEmpty()) return emptyList()
        return if (higherFirst) {
            val firstRun = sameParity.filter { it >= startPath }.sorted()
            val wrap = sameParity.filter { it < startPath }.sorted()
            firstRun + wrap
        } else {
            val firstRun = sameParity.filter { it <= startPath }.sortedDescending()
            val wrap = sameParity.filter { it > startPath }.sortedDescending()
            firstRun + wrap
        }
    }

    /** Short preview text for the Proposed Row Sequence card. */
    fun sequencePreviewText(sequence: List<Double>, maxItems: Int = 10): String {
        val preview = sequence.take(maxItems).map { formatPath(it) }
        val joined = preview.joinToString(" \u2192 ")
        return if (sequence.size > maxItems) "$joined \u2192 \u2026" else joined
    }

    /** Human-readable explanation of how a pattern walks the paths; null for Free Drive. */
    fun patternPreviewNote(pattern: TrackingPattern): String? = when (pattern) {
        TrackingPattern.SEQUENTIAL ->
            "Sequential: walks every path one-by-one in the chosen direction."
        TrackingPattern.EVERY_SECOND_ROW ->
            "Every Second Row: advances by +2 in the chosen direction, then wraps to cover the remaining same-parity paths."
        TrackingPattern.FIVE_THREE ->
            "5/3 pattern: skips ahead 5, back 3, repeating from the chosen start."
        TrackingPattern.UP_AND_BACK ->
            "Up and Back: traverses then reverses, covering each path once."
        TrackingPattern.TWO_ROW_UP_BACK ->
            "Two Row Up & Back: pairs of rows, advancing then returning."
        TrackingPattern.CUSTOM ->
            "Custom pattern: generated from the chosen start and direction."
        TrackingPattern.FREE_DRIVE -> null
    }
}
