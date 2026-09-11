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

    /**
     * Oldest compass sample still accepted as the operator's facing at capture.
     * Heading freshness only — GPS acceptance thresholds are unchanged.
     */
    const val MAX_HEADING_AGE_MS: Long = 5_000L

    /**
     * Slowest travel that still proves a direction of travel. Below this the
     * GPS course is noise from a stationary or crawling machine and must never
     * be labelled as the operator's facing.
     */
    const val MIN_COURSE_SPEED_MPS: Double = 1.0

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
     * Validated facing with temporal evidence. A compass sample older than
     * [MAX_HEADING_AGE_MS] describes an earlier moment, not this capture, so it
     * is discarded instead of frozen into the pin. A null age means no age was
     * reported and is not treated as evidence of staleness.
     */
    fun validHeading(headingDegrees: Double?, ageMs: Long?): Double? {
        if (ageMs != null && (ageMs < -500L || ageMs > MAX_HEADING_AGE_MS)) return null
        return validHeading(headingDegrees)
    }

    /**
     * A GPS travel course qualified as the operator's facing. Numeric validity
     * alone is not enough: a stationary or reversing machine reports a course
     * that is not where the operator is looking, so a course is accepted only
     * with genuine forward travel evidence.
     */
    fun qualifiedCourseHeading(
        bearingDegrees: Double?,
        speedMetresPerSecond: Double?,
        hasForwardTravelEvidence: Boolean,
    ): Double? {
        if (!hasForwardTravelEvidence) return null
        val speed = speedMetresPerSecond ?: return null
        if (!speed.isFinite() || speed < MIN_COURSE_SPEED_MPS) return null
        return validHeading(bearingDegrees)
    }

    /**
     * Freeze one facing for both row selection and persistence. Compass evidence
     * must carry a current sensor timestamp. GPS course is accepted only when a
     * caller has independent evidence that travel is forward, not reversing.
     */
    fun frozenCaptureHeading(
        compassHeadingDegrees: Double?,
        compassObservedAtElapsedRealtimeNanos: Long?,
        captureElapsedRealtimeNanos: Long,
        courseDegrees: Double?,
        speedMetresPerSecond: Double?,
        hasForwardTravelEvidence: Boolean,
    ): Double? {
        val compassAgeMs = compassObservedAtElapsedRealtimeNanos?.let { observedAt ->
            (captureElapsedRealtimeNanos - observedAt) / 1_000_000L
        }
        val compass = if (compassObservedAtElapsedRealtimeNanos == null) {
            null
        } else {
            validHeading(compassHeadingDegrees, compassAgeMs)
        }
        return compass ?: qualifiedCourseHeading(
            courseDegrees,
            speedMetresPerSecond,
            hasForwardTravelEvidence,
        )
    }

    /**
     * True when an accepted fix is precise enough for mapped-aisle matching.
     * Requiring the whole accuracy circle to fit on both sides of a ~3 m aisle
     * rejected ordinary field GPS. Adjacent-row containment and headland checks
     * already constrain the corridor, so accuracy is compared with its full
     * mapped width. Missing accuracy or uncertainty spanning the aisle remains
     * ambiguous and requires confirmation.
     */
    fun uncertaintyFitsBetweenRows(
        accuracyMetres: Double?,
        distanceToNearRowMetres: Double,
        distanceToFarRowMetres: Double,
    ): Boolean {
        val accuracy = accuracyMetres ?: return false
        if (!accuracy.isFinite() || accuracy < 0.0) return false
        if (!distanceToNearRowMetres.isFinite() || distanceToNearRowMetres <= 0.0) return false
        if (!distanceToFarRowMetres.isFinite() || distanceToFarRowMetres <= 0.0) return false
        return accuracy < distanceToNearRowMetres + distanceToFarRowMetres
    }

    /**
     * Resolve the aisle physically containing the fix: the nearest mapped row
     * plus the nearest row lying beyond the fix on the same axis, provided the
     * pair is close enough to be a real aisle.
     *
     * Returns null when the block has no mapped row geometry, the fix sits on a
     * row centreline, the fix lies beyond the ends of the rows (a clamped
     * endpoint projection proves nothing about containment), no plausible
     * neighbour exists, or the reported uncertainty spans more than the aisle.
     *
     * [accuracyMetres] is required evidence — null or invalid resolves to no
     * aisle, and the caller keeps an honest unconfirmed attachment.
     */
    fun aisleContaining(
        paddock: Paddock?,
        latitude: Double,
        longitude: Double,
        accuracyMetres: Double?,
    ): Aisle? = resolveAisle(
        paddock = paddock,
        latitude = latitude,
        longitude = longitude,
        accuracyMetres = accuracyMetres,
        requiresQualifiedAccuracy = true,
    )

    /**
     * Browsing-only aisle estimate. It retains mapped-row containment, headland
     * and width checks but is never capture evidence and must never be persisted.
     */
    fun approximateAisle(
        paddock: Paddock?,
        latitude: Double,
        longitude: Double,
    ): Aisle? = resolveAisle(
        paddock = paddock,
        latitude = latitude,
        longitude = longitude,
        accuracyMetres = null,
        requiresQualifiedAccuracy = false,
    )

    private fun resolveAisle(
        paddock: Paddock?,
        latitude: Double,
        longitude: Double,
        accuracyMetres: Double?,
        requiresQualifiedAccuracy: Boolean,
    ): Aisle? {
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
            val projection = projectOntoRow(frame, row, point) ?: continue
            val distance = projection.point.distanceTo(point)
            if (distance < nearDistance) {
                nearDistance = distance
                nearRow = row.number
                nearClosest = if (projection.clampedToEnd) null else projection.point
            }
        }
        val nearNumber = nearRow ?: return null
        // Past the end of a row the nearest point is only its endpoint. That
        // clamped projection is a geometry artefact, never proof the operator
        // was between the rows, so a headland fix stays unconfirmed.
        val nearPoint = nearClosest ?: return null
        if (nearDistance < MIN_AISLE_OFFSET_M) return null

        // Axis: outward direction from the nearest row towards the fix.
        val axis = Point(point.x - nearPoint.x, point.y - nearPoint.y).normalized() ?: return null

        var farRow: Int? = null
        var farOffset = Double.MAX_VALUE
        var farDistance = Double.MAX_VALUE
        for (row in rows) {
            if (row.number == nearNumber) continue
            val projection = projectOntoRow(frame, row, point) ?: continue
            if (projection.clampedToEnd) continue
            val closest = projection.point
            val offset = (closest.x - nearPoint.x) * axis.x + (closest.y - nearPoint.y) * axis.y
            // Must lie beyond the fix, i.e. on the opposite side of the aisle.
            if (offset <= nearDistance) continue
            if (offset < farOffset) {
                farOffset = offset
                farDistance = closest.distanceTo(point)
                farRow = row.number
            }
        }
        val farNumber = farRow ?: return null

        val rowWidth = paddock.rowWidth?.takeIf { it > 0 }
        val maxWidth = if (rowWidth != null) rowWidth * 2.5 else FALLBACK_MAX_AISLE_WIDTH_M
        if (farOffset > maxWidth) return null

        // Map matching already established the containing adjacent-row corridor.
        // Reject only when uncertainty spans that full mapped aisle.
        if (requiresQualifiedAccuracy && !uncertaintyFitsBetweenRows(accuracyMetres, nearDistance, farDistance)) return null

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
        useAisleMidpointReference: Boolean = false,
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

        // A locked aisle survives a brief lateral GPS outlier. The mapped
        // midpoint determines only Left/Right; snapping still projects the
        // unchanged current fix onto the selected row.
        val sideReference = if (useAisleMidpointReference) {
            Point((firstClosest.x + secondClosest.x) / 2.0, (firstClosest.y + secondClosest.y) / 2.0)
        } else point
        val leftBearing = normalizedDegrees(heading - 90.0)
        val firstBearing = bearing(sideReference, firstClosest) ?: return null
        val secondBearing = bearing(sideReference, secondClosest) ?: return null
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

    private data class Snap(
        val point: Point,
        val distanceAlong: Double,
        /** True when the fix lies beyond an end of the segment. */
        val clampedToEnd: Boolean,
    )

    private fun closestPointOnRow(
        frame: MetricFrame,
        row: com.rork.vinetrack.data.model.PaddockRow,
        point: Point,
    ): Point? = projectOntoRow(frame, row, point)?.point

    private fun projectOntoRow(
        frame: MetricFrame,
        row: com.rork.vinetrack.data.model.PaddockRow,
        point: Point,
    ): Snap? {
        val s = row.startPoint ?: return null
        val e = row.endPoint ?: return null
        val a = frame.project(s.latitude, s.longitude)
        val b = frame.project(e.latitude, e.longitude)
        return snapOnto(a, b, point)
    }

    private fun snapOnto(a: Point, b: Point, p: Point): Snap? {
        val dx = b.x - a.x
        val dy = b.y - a.y
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared <= 1e-9) return null
        val length = sqrt(lengthSquared)
        val rawT = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        val t = rawT.coerceIn(0.0, 1.0)
        val tolerance = 1e-9
        return Snap(
            point = Point(a.x + t * dx, a.y + t * dy),
            distanceAlong = t * length,
            clampedToEnd = rawT < -tolerance || rawT > 1.0 + tolerance,
        )
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
