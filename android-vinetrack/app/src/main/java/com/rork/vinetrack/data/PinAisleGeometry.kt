package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * Pure geometry for the core pin-location contract (Android mirror of the iOS
 * `PinAisleGeometry`): which aisle (inter-row driving path) an operator
 * occupies, and which of that aisle's two physically adjacent vine rows lies on
 * their Left vs Right.
 *
 * Everything is derived from mapped row geometry and a validated heading. Row
 * numbering order is never assumed — Left is not "the lower number", it is
 * whichever adjacent row actually sits to the operator's left.
 *
 * See docs/core-pin-location-contract.md.
 */
object PinAisleGeometry {

    private const val METRES_PER_DEG_LAT = 111_320.0

    /**
     * Minimum offset from a row centreline before an aisle can be claimed. A fix
     * sitting essentially on the vine row itself does not establish which of the
     * two neighbouring aisles the operator occupied.
     */
    const val MIN_AISLE_OFFSET_M: Double = 0.15

    /** Aisle-width ceiling used when the block records no row spacing. */
    const val FALLBACK_MAX_AISLE_WIDTH_M: Double = 12.0

    /** The two physically adjacent rows bounding the operator's aisle. */
    data class Aisle(
        /** Driving path identifier: mean of the two adjacent row numbers (32 + 33 -> 32.5). */
        val aisleNumber: Double,
        /** Row whose centreline is nearest the fix. */
        val nearRowNumber: Int,
        /** Row on the far side of the fix bounding the same aisle. */
        val farRowNumber: Int,
    )

    /** A row selected for an operator side, snapped onto that row's own centreline. */
    data class RowSelection(
        val rowNumber: Int,
        val snappedLatitude: Double,
        val snappedLongitude: Double,
        val alongRowDistanceM: Double,
    )

    /**
     * A usable recorded facing, or null. A genuine 0.0 (North) is valid; missing,
     * non-finite and out-of-range values are never turned into North.
     */
    fun validHeading(headingDegrees: Double?): Double? {
        val h = headingDegrees ?: return null
        if (!h.isFinite() || h < -0.0001 || h > 360.0001) return null
        return normalizedDegrees(h)
    }

    /**
     * Resolve the aisle physically containing the fix: the nearest mapped row
     * plus the nearest row lying beyond the fix on the same axis, provided the
     * pair is close enough to be a real aisle.
     *
     * Returns null when the block has no mapped row geometry, the fix sits on a
     * row centreline, the fix is outside the mapped rows (headland), or no
     * plausible neighbour exists — a missing neighbour is never invented.
     */
    fun aisleContaining(paddock: Paddock?, latitude: Double, longitude: Double): Aisle? {
        val rows = paddock?.rows
            ?.filter { it.startPoint != null && it.endPoint != null }
            ?.takeIf { it.size >= 2 }
            ?: return null

        val frame = MetricFrame(latitude, longitude)
        val point = frame.project(latitude, longitude)

        var nearRow: Int? = null
        var nearClosest: Point? = null
        var nearDistance = Double.MAX_VALUE
        for (row in rows) {
            val closest = closestPointOnRow(frame, row, point) ?: continue
            val distance = closest.distanceTo(point)
            if (distance < nearDistance) {
                nearDistance = distance
                nearRow = row.number
                nearClosest = closest
            }
        }
        val nearNumber = nearRow ?: return null
        val nearPoint = nearClosest ?: return null
        if (nearDistance < MIN_AISLE_OFFSET_M) return null

        // Axis: outward direction from the nearest row towards the fix.
        val axis = Point(point.x - nearPoint.x, point.y - nearPoint.y).normalized() ?: return null

        var farRow: Int? = null
        var farOffset = Double.MAX_VALUE
        for (row in rows) {
            if (row.number == nearNumber) continue
            val closest = closestPointOnRow(frame, row, point) ?: continue
            val offset = (closest.x - nearPoint.x) * axis.x + (closest.y - nearPoint.y) * axis.y
            // Must lie beyond the fix, i.e. on the opposite side of the aisle.
            if (offset <= nearDistance) continue
            if (offset < farOffset) {
                farOffset = offset
                farRow = row.number
            }
        }
        val farNumber = farRow ?: return null

        val rowWidth = paddock.rowWidth?.takeIf { it > 0 }
        val maxWidth = if (rowWidth != null) rowWidth * 2.5 else FALLBACK_MAX_AISLE_WIDTH_M
        if (farOffset > maxWidth) return null

        return Aisle(
            aisleNumber = (nearNumber.toDouble() + farNumber.toDouble()) / 2.0,
            nearRowNumber = nearNumber,
            farRowNumber = farNumber,
        )
    }

    /**
     * Choose which of two candidate rows lies on the operator's [side] for a
     * validated [headingDegrees], then snap the fix onto that row's own
     * centreline (never the aisle midline).
     *
     * Returns null when the heading is unusable, the rows are missing, or the two
     * candidates do not actually lie on opposite sides of the operator — an
     * unconfirmed side is never guessed.
     */
    fun rowOnSide(
        paddock: Paddock?,
        rowNumbers: Pair<Int, Int>,
        latitude: Double,
        longitude: Double,
        headingDegrees: Double?,
        side: String?,
    ): RowSelection? {
        val heading = validHeading(headingDegrees) ?: return null
        val cleanSide = side?.trim()?.lowercase()?.takeIf { it == "left" || it == "right" } ?: return null
        if (rowNumbers.first == rowNumbers.second) return null
        val rows = paddock?.rows?.filter { it.startPoint != null && it.endPoint != null } ?: return null
        val first = rows.firstOrNull { it.number == rowNumbers.first } ?: return null
        val second = rows.firstOrNull { it.number == rowNumbers.second } ?: return null

        val frame = MetricFrame(latitude, longitude)
        val point = frame.project(latitude, longitude)
        val firstClosest = closestPointOnRow(frame, first, point) ?: return null
        val secondClosest = closestPointOnRow(frame, second, point) ?: return null

        val leftBearing = normalizedDegrees(heading - 90.0)
        val firstBearing = bearing(point, firstClosest) ?: return null
        val secondBearing = bearing(point, secondClosest) ?: return null
        val firstIsLeft = abs(signedAngularDifference(firstBearing, leftBearing)) < 90.0
        val secondIsLeft = abs(signedAngularDifference(secondBearing, leftBearing)) < 90.0
        // The two rows must genuinely lie on opposite sides of the operator.
        if (firstIsLeft == secondIsLeft) return null

        val chosen = when (cleanSide) {
            "left" -> if (firstIsLeft) first else second
            else -> if (firstIsLeft) second else first
        }
        val chosenStart = chosen.startPoint ?: return null
        val chosenEnd = chosen.endPoint ?: return null
        val a = frame.project(chosenStart.latitude, chosenStart.longitude)
        val b = frame.project(chosenEnd.latitude, chosenEnd.longitude)
        val snap = snapOnto(a, b, point) ?: return null
        val snapped = frame.unproject(snap.point)
        return RowSelection(
            rowNumber = chosen.number,
            snappedLatitude = snapped.first,
            snappedLongitude = snapped.second,
            alongRowDistanceM = snap.distanceAlong,
        )
    }

    /**
     * The two vine rows bounding an explicit driving path (32.5 -> 32 and 33).
     * Null unless both rows exist in the block's mapped geometry.
     */
    fun rowsBoundingPath(paddock: Paddock?, path: Double): Pair<Int, Int>? {
        val lower = kotlin.math.floor(path).toInt()
        val upper = kotlin.math.ceil(path).toInt()
        if (lower == upper) return null
        val rows = paddock?.rows?.filter { it.startPoint != null && it.endPoint != null } ?: return null
        if (rows.none { it.number == lower } || rows.none { it.number == upper }) return null
        return lower to upper
    }

    // MARK: - Local metric frame

    private data class Point(val x: Double, val y: Double) {
        fun distanceTo(other: Point): Double {
            val dx = x - other.x
            val dy = y - other.y
            return sqrt(dx * dx + dy * dy)
        }

        fun normalized(): Point? {
            val length = sqrt(x * x + y * y)
            if (length <= 1e-9) return null
            return Point(x / length, y / length)
        }
    }

    private class MetricFrame(private val originLat: Double, private val originLon: Double) {
        private val metresPerDegLon = METRES_PER_DEG_LAT * cos(originLat * Math.PI / 180.0)

        fun project(lat: Double, lon: Double): Point = Point(
            x = (lon - originLon) * metresPerDegLon,
            y = (lat - originLat) * METRES_PER_DEG_LAT,
        )

        fun unproject(point: Point): Pair<Double, Double> = Pair(
            originLat + point.y / METRES_PER_DEG_LAT,
            originLon + point.x / metresPerDegLon,
        )
    }

    private data class Snap(val point: Point, val distanceAlong: Double)

    private fun closestPointOnRow(
        frame: MetricFrame,
        row: com.rork.vinetrack.data.model.PaddockRow,
        point: Point,
    ): Point? {
        val s = row.startPoint ?: return null
        val e = row.endPoint ?: return null
        val a = frame.project(s.latitude, s.longitude)
        val b = frame.project(e.latitude, e.longitude)
        return snapOnto(a, b, point)?.point
    }

    private fun snapOnto(a: Point, b: Point, p: Point): Snap? {
        val dx = b.x - a.x
        val dy = b.y - a.y
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared <= 1e-9) return null
        val length = sqrt(lengthSquared)
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = t.coerceIn(0.0, 1.0)
        return Snap(Point(a.x + t * dx, a.y + t * dy), t * length)
    }

    /** True bearing (0–360) of the vector from -> to in the local frame. */
    private fun bearing(from: Point, to: Point): Double? {
        val east = to.x - from.x
        val north = to.y - from.y
        if (sqrt(east * east + north * north) <= 1e-6) return null
        return normalizedDegrees(Math.toDegrees(atan2(east, north)))
    }

    /** Signed difference (a - b) wrapped to (-180, 180]. */
    fun signedAngularDifference(a: Double, b: Double): Double {
        var diff = (a - b) % 360.0
        if (diff > 180.0) diff -= 360.0
        if (diff <= -180.0) diff += 360.0
        return diff
    }

    fun normalizedDegrees(value: Double): Double {
        val v = value % 360.0
        return if (v < 0) v + 360.0 else v
    }
}
