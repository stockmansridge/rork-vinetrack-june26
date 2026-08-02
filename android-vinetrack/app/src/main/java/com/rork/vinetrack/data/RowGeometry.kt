package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A single laid-out row line between two boundary-clipped endpoints. */
data class RowLine(val start: CoordinatePoint, val end: CoordinatePoint)

/**
 * One generated row: its position in the laid-out set, the number the grower
 * sees, and the clipped centre-line.
 *
 * [index] is the geometric position across the block (0 = the first line the
 * generator produced). [number] is the label, which the numbering side can
 * reverse WITHOUT moving any geometry.
 */
data class BlockRow(
    val index: Int,
    val number: Int,
    val line: RowLine,
) {
    /**
     * Where a "Row N" label belongs for this row. Every row is clipped in the
     * same direction, so `start` is consistently the same end of the block and
     * the first/last labels line up along one headland.
     */
    val labelAnchor: CoordinatePoint get() = line.start
}

/**
 * The complete, canonical row layout for a block.
 *
 * Produced by [blockRowLayout] and used by EVERY surface — the full-screen
 * editor, the read-only block preview and the save path — so no two screens can
 * disagree about where a row is or what it is called.
 */
data class BlockRowLayout(
    val rows: List<BlockRow>,
    /** Direction actually used, always normalised to `0 ≤ d < 180`. */
    val direction: Double,
    /** Rows requested. May exceed `rows.size` when some fall outside the block. */
    val requestedCount: Int,
    val width: Double,
    val offset: Double,
    val numbering: RowNumbering,
) {
    val isEmpty: Boolean get() = rows.isEmpty()

    /** The first row across the block (geometry order), not the lowest number. */
    val firstRow: BlockRow? get() = rows.firstOrNull()

    /** The last row across the block (geometry order), not the highest number. */
    val lastRow: BlockRow? get() = rows.lastOrNull()

    /** Every endpoint, for camera framing. */
    val framePoints: List<CoordinatePoint>
        get() = rows.flatMap { listOf(it.line.start, it.line.end) }

    /** Total laid-out row length in metres. */
    val totalLengthMetres: Double
        get() {
            if (rows.isEmpty()) return 0.0
            val centroidLat = rows.sumOf { (it.line.start.latitude + it.line.end.latitude) / 2.0 } / rows.size
            val mPerDegLat = METRES_PER_DEGREE_LAT
            val mPerDegLon = METRES_PER_DEGREE_LAT * cos(centroidLat * Math.PI / 180.0)
            return rows.sumOf { row ->
                val dLat = (row.line.end.latitude - row.line.start.latitude) * mPerDegLat
                val dLon = (row.line.end.longitude - row.line.start.longitude) * mPerDegLon
                sqrt(dLat * dLat + dLon * dLon)
            }
        }

    companion object {
        val EMPTY = BlockRowLayout(
            rows = emptyList(),
            direction = 0.0,
            requestedCount = 0,
            width = 0.0,
            offset = 0.0,
            numbering = RowNumbering(1, true),
        )
    }
}

/**
 * How generated rows are labelled.
 *
 * [ascending] flips the labels only — swapping the side row 1 sits on must
 * never rotate, shift or regenerate the physical geometry.
 */
data class RowNumbering(
    val startNumber: Int,
    val ascending: Boolean,
) {
    /** Label for the row at geometric [index] within a set of [count] rows. */
    fun numberAt(index: Int, count: Int): Int =
        if (ascending) startNumber + index else startNumber + (maxOf(count, 1) - 1 - index)

    /** Number shown at the first (index 0) row. */
    fun firstNumber(count: Int): Int = numberAt(0, count)

    /** Number shown at the last row. */
    fun lastNumber(count: Int): Int = numberAt(maxOf(count, 1) - 1, count)

    companion object {
        val DEFAULT = RowNumbering(startNumber = 1, ascending = true)

        /**
         * Recovers the numbering a saved block was created with, so reopening
         * it reproduces the same labels instead of silently resetting to 1.
         *
         * Rows are stored in geometric order with their labels, so the first
         * row's number tells us which end row 1 sits on.
         */
        fun fromSavedRows(numbers: List<Int>): RowNumbering {
            val valid = numbers.filter { it > 0 }
            if (valid.isEmpty()) return DEFAULT
            val lowest = valid.min()
            val ascending = valid.first() <= valid.last()
            return RowNumbering(startNumber = lowest, ascending = ascending)
        }
    }
}

private const val METRES_PER_DEGREE_LAT = 111_320.0

/** Row layout limits, shared by the sliders, the numeric fields and validation. */
object RowLimits {
    const val DIRECTION_MIN: Double = 0.0

    /**
     * Exclusive upper bound. A row is an axis, not a heading: 24.8° and 204.8°
     * describe the same set of parallel lines, so the editor only ever offers
     * the 0–180 half-turn.
     */
    const val DIRECTION_MAX: Double = 180.0

    const val COUNT_MIN: Int = 0
    const val COUNT_MAX: Int = 500

    const val WIDTH_MIN: Double = 0.1
    const val WIDTH_MAX: Double = 12.0

    const val SHIFT_MIN: Double = -200.0
    const val SHIFT_MAX: Double = 200.0

    const val START_NUMBER_MIN: Int = 1
    const val START_NUMBER_MAX: Int = 9999
}

/**
 * Normalise a row bearing into the canonical half-turn `0 ≤ d < 180`.
 *
 * ```
 * 180 → 0      204.8 → 24.8      -10 → 170      360 → 0
 * ```
 *
 * Row direction describes an axis, so a heading and that heading + 180° lay out
 * the identical set of parallel lines. Storing one canonical value stops the
 * same physical layout being written two different ways.
 */
fun normaliseRowDirection(direction: Double): Double {
    if (direction.isNaN() || direction.isInfinite()) return 0.0
    val wrapped = ((direction % 180.0) + 180.0) % 180.0
    // Guard the floating-point edge where a negative epsilon rounds up to 180.
    return if (wrapped >= 180.0 || wrapped < 0.0) 0.0 else wrapped
}

/** Steps a direction by [delta] degrees, wrapping inside the 0–180 half-turn. */
fun stepRowDirection(direction: Double, delta: Double): Double =
    normaliseRowDirection(direction + delta)

/**
 * THE canonical row layout used by the full-screen editor, the read-only block
 * preview and the save path.
 *
 * @param polygon boundary ring (3+ points required)
 * @param direction row bearing in degrees; normalised to 0–180 before use
 * @param count rows requested
 * @param width row spacing in metres (never degrees)
 * @param offset lateral shift of the whole set in metres
 * @param numbering label start + side
 */
fun blockRowLayout(
    polygon: List<CoordinatePoint>,
    direction: Double,
    count: Int,
    width: Double,
    offset: Double = 0.0,
    numbering: RowNumbering = RowNumbering.DEFAULT,
): BlockRowLayout {
    val normalised = normaliseRowDirection(direction)
    val safeCount = count.coerceIn(RowLimits.COUNT_MIN, RowLimits.COUNT_MAX)
    if (polygon.size < 3 || safeCount <= 0 || width <= 0 || width.isNaN() || offset.isNaN()) {
        return BlockRowLayout.EMPTY.copy(
            direction = normalised,
            requestedCount = safeCount,
            width = width,
            offset = offset,
            numbering = numbering,
        )
    }
    val rows = indexedRowLines(polygon, normalised, safeCount, width, offset).map { (index, line) ->
        BlockRow(index = index, number = numbering.numberAt(index, safeCount), line = line)
    }
    return BlockRowLayout(
        rows = rows,
        direction = normalised,
        requestedCount = safeCount,
        width = width,
        offset = offset,
        numbering = numbering,
    )
}

/**
 * Generate evenly-spaced row lines across a boundary polygon, clipped to the
 * polygon edges. Direct port of the iOS `calculateRowLines` (RowGeometry.swift)
 * so Android-authored row layouts match iOS/portal byte-for-byte: same
 * equirectangular projection, centroid origin, perpendicular spacing, and
 * segment-intersection clipping.
 *
 * Prefer [blockRowLayout] for anything that also needs numbering or labels.
 *
 * @param polygon boundary points (>= 3 required)
 * @param direction row bearing in degrees (normalised to the 0–180 half-turn)
 * @param count number of rows to generate
 * @param width row spacing in metres
 * @param offset lateral shift of the whole row set in metres
 */
fun calculateRowLines(
    polygon: List<CoordinatePoint>,
    direction: Double,
    count: Int,
    width: Double,
    offset: Double = 0.0,
): List<RowLine> = indexedRowLines(polygon, direction, count, width, offset).map { it.second }

/**
 * Row lines paired with the index of the slot they occupy. Rows that fall
 * outside the polygon are dropped, so the index is the only safe way to line
 * geometry up with numbering.
 */
private fun indexedRowLines(
    polygon: List<CoordinatePoint>,
    direction: Double,
    count: Int,
    width: Double,
    offset: Double,
): List<Pair<Int, RowLine>> {
    if (polygon.size < 3 || count <= 0 || width <= 0) return emptyList()

    val centroidLat = polygon.sumOf { it.latitude } / polygon.size
    val centroidLon = polygon.sumOf { it.longitude } / polygon.size

    val bearingRad = normaliseRowDirection(direction) * Math.PI / 180.0
    val perpRad = bearingRad + Math.PI / 2.0

    val mPerDegLat = METRES_PER_DEGREE_LAT
    val mPerDegLon = METRES_PER_DEGREE_LAT * cos(centroidLat * Math.PI / 180.0)

    var maxDist = 0.0
    for (i in polygon.indices) {
        for (j in (i + 1) until polygon.size) {
            val dLat = (polygon[i].latitude - polygon[j].latitude) * mPerDegLat
            val dLon = (polygon[i].longitude - polygon[j].longitude) * mPerDegLon
            maxDist = maxOf(maxDist, sqrt(dLat * dLat + dLon * dLon))
        }
    }
    val halfLen = maxDist * 1.5

    val totalW = (count - 1) * width
    val startOff = -totalW / 2.0

    val result = mutableListOf<Pair<Int, RowLine>>()
    for (i in 0 until count) {
        val off = startOff + i * width + offset
        val cLat = centroidLat + off * cos(perpRad) / mPerDegLat
        val cLon = centroidLon + off * Math.sin(perpRad) / mPerDegLon

        val dLat = halfLen * cos(bearingRad) / mPerDegLat
        val dLon = halfLen * Math.sin(bearingRad) / mPerDegLon

        val s = CoordinatePoint(latitude = cLat - dLat, longitude = cLon - dLon)
        val e = CoordinatePoint(latitude = cLat + dLat, longitude = cLon + dLon)

        clipLineToPolygon(s, e, polygon)?.let { result.add(i to it) }
    }
    return result
}

private fun clipLineToPolygon(
    start: CoordinatePoint,
    end: CoordinatePoint,
    polygon: List<CoordinatePoint>,
): RowLine? {
    val pts = mutableListOf<CoordinatePoint>()
    val n = polygon.size
    for (i in 0 until n) {
        val j = (i + 1) % n
        segmentIntersection(start, end, polygon[i], polygon[j])?.let { pts.add(it) }
    }
    if (pts.size < 2) return null
    val dx = end.latitude - start.latitude
    val dy = end.longitude - start.longitude
    val useDx = abs(dx) > 1e-14
    val sorted = pts.sortedBy { p ->
        if (useDx) (p.latitude - start.latitude) / dx else (p.longitude - start.longitude) / dy
    }
    return RowLine(start = sorted.first(), end = sorted.last())
}

private fun segmentIntersection(
    a1: CoordinatePoint,
    a2: CoordinatePoint,
    b1: CoordinatePoint,
    b2: CoordinatePoint,
): CoordinatePoint? {
    val d1x = a2.latitude - a1.latitude
    val d1y = a2.longitude - a1.longitude
    val d2x = b2.latitude - b1.latitude
    val d2y = b2.longitude - b1.longitude
    val cross = d1x * d2y - d1y * d2x
    if (abs(cross) < 1e-14) return null
    val dx = b1.latitude - a1.latitude
    val dy = b1.longitude - a1.longitude
    val t = (dx * d2y - dy * d2x) / cross
    val u = (dx * d1y - dy * d1x) / cross
    if (t < 0 || t > 1 || u < 0 || u > 1) return null
    return CoordinatePoint(latitude = a1.latitude + t * d1x, longitude = a1.longitude + t * d1y)
}

/**
 * Parsing + clamping for the editor's direct numeric fields.
 *
 * Kept free of Compose so the whole "what happens while the grower is midway
 * through typing" contract is unit-testable (`BlockRowLayoutTest`).
 */
object RowInput {

    /**
     * Parses a decimal the grower typed. Accepts the device locale's separator
     * (`24,8` and `24.8` both work), tolerates a leading `+`, and returns null
     * for anything not yet a number — including the partial states `""`, `"-"`
     * and `"24."`, so the caller can keep the last valid value on screen
     * instead of dropping the row overlay mid-keystroke.
     */
    fun parseDecimal(text: String): Double? {
        val cleaned = text.trim().replace(',', '.').removePrefix("+")
        if (cleaned.isEmpty() || cleaned == "-" || cleaned == "." || cleaned == "-.") return null
        if (cleaned.endsWith(".")) return null
        return cleaned.toDoubleOrNull()?.takeIf { it.isFinite() }
    }

    /** Parses an integer the grower typed; null while the field is incomplete. */
    fun parseInt(text: String): Int? {
        val cleaned = text.trim().removePrefix("+")
        if (cleaned.isEmpty() || cleaned == "-") return null
        return cleaned.toIntOrNull()
    }

    /** Any typed direction becomes a canonical 0–180 value. */
    fun direction(text: String): Double? = parseDecimal(text)?.let { normaliseRowDirection(it) }

    fun count(text: String): Int? =
        parseInt(text)?.coerceIn(RowLimits.COUNT_MIN, RowLimits.COUNT_MAX)

    fun width(text: String): Double? =
        parseDecimal(text)?.coerceIn(RowLimits.WIDTH_MIN, RowLimits.WIDTH_MAX)

    fun shift(text: String): Double? =
        parseDecimal(text)?.coerceIn(RowLimits.SHIFT_MIN, RowLimits.SHIFT_MAX)

    fun startNumber(text: String): Int? =
        parseInt(text)?.coerceIn(RowLimits.START_NUMBER_MIN, RowLimits.START_NUMBER_MAX)

    /** Display form for a decimal field: one decimal place, locale-independent. */
    fun formatDecimal(value: Double, decimals: Int = 1): String =
        String.format(java.util.Locale.US, "%.${decimals}f", value)

    /** Rounds a slider position to the field's displayed precision. */
    fun roundToDecimals(value: Double, decimals: Int = 1): Double {
        val factor = Math.pow(10.0, decimals.toDouble())
        return (value * factor).roundToInt() / factor
    }
}
