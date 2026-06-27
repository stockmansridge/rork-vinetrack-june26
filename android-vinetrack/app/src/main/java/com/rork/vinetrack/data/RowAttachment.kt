package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure, backend-neutral row-attachment helper for Repairs/Growth launcher pins.
 *
 * Mirrors the iOS `RowGuidance` / `PinAttachmentResolver` geometry: given a raw
 * GPS fix inside a block, it finds the nearest mapped vine row, projects the fix
 * onto that row's centreline, and reports the along-row distance. The operator's
 * selected Left/Right side is carried through verbatim.
 *
 * Launcher pins are dropped without an active trip lock or device heading, so —
 * exactly like iOS `PinAttachmentResolver.manual` — we never speculate a
 * `driving_row_number` (which path the tractor was on). We only persist what
 * geometry can confidently resolve: the attached vine row, the side, and the
 * along-row distance.
 *
 * Returns `null` when the block has no usable row geometry, in which case the
 * caller falls back to creating the pin with raw coordinates and side/row only.
 */
object RowAttachment {

    private const val METRES_PER_DEG_LAT = 111_320.0

    data class Attachment(
        /** Actual vine row the pin attaches to (e.g. 15). */
        val pinRowNumber: Double,
        /** Side the operator tagged the pin on, verbatim. */
        val pinSide: String?,
        /** Distance (m) along the attached row from its start point. */
        val alongRowDistanceM: Double,
        /** Snapped point on the row centreline. */
        val snappedLatitude: Double,
        val snappedLongitude: Double,
    )

    /**
     * Resolve the row attachment for a pin dropped at [latitude]/[longitude]
     * inside [paddock]. Prefers explicit mapped rows; falls back to a synthetic
     * row grid derived from `rowDirection`/`rowWidth` when no rows are mapped.
     */
    fun resolve(
        paddock: Paddock?,
        latitude: Double?,
        longitude: Double?,
        side: String?,
    ): Attachment? {
        if (paddock == null || latitude == null || longitude == null) return null
        explicitRowAttachment(paddock, latitude, longitude, side)?.let { return it }
        return syntheticRowAttachment(paddock, latitude, longitude, side)
    }

    /**
     * Nearest mapped (or synthetic) vine row to a fix, with the perpendicular
     * distance to its centreline and the effective row spacing. Used by the
     * active-trip row-lock to derive the live driving path and corridor check.
     * Unlike [resolve] this does not snap or carry a side — it is read-only
     * geometry for live movement context.
     */
    data class RowHit(
        /** Nearest vine row number. */
        val rowNumber: Int,
        /** Perpendicular distance (m) from the fix to that row's centreline. */
        val perpendicularDistanceM: Double,
        /** Effective row spacing (m) used for the corridor tolerance. */
        val rowWidthM: Double,
    )

    fun nearestRow(paddock: Paddock?, latitude: Double?, longitude: Double?): RowHit? {
        if (paddock == null || latitude == null || longitude == null) return null
        nearestExplicitRow(paddock, latitude, longitude)?.let { return it }
        return nearestSyntheticRow(paddock, latitude, longitude)
    }

    /** True when (lat,lng) falls inside the block polygon. */
    fun containsPoint(paddock: Paddock?, latitude: Double?, longitude: Double?): Boolean {
        if (paddock == null || latitude == null || longitude == null) return false
        val polygon = paddock.polygonPoints ?: return false
        if (polygon.size < 3) return false
        var inside = false
        var j = polygon.size - 1
        for (i in polygon.indices) {
            val xi = polygon[i].longitude
            val yi = polygon[i].latitude
            val xj = polygon[j].longitude
            val yj = polygon[j].latitude
            val denom = if (yj - yi == 0.0) 1e-12 else (yj - yi)
            val intersect = ((yi > latitude) != (yj > latitude)) &&
                (longitude < (xj - xi) * (latitude - yi) / denom + xi)
            if (intersect) inside = !inside
            j = i
        }
        return inside
    }

    private const val DEFAULT_ROW_WIDTH_M = 3.0

    private fun nearestExplicitRow(paddock: Paddock, lat: Double, lng: Double): RowHit? {
        val rows = paddock.rows?.filter { it.startPoint != null && it.endPoint != null }
        if (rows.isNullOrEmpty()) return null
        var bestRow: Int? = null
        var bestDistance = Double.MAX_VALUE
        for (row in rows) {
            val s = row.startPoint ?: continue
            val e = row.endPoint ?: continue
            val d = perpendicularDistanceMetres(lat, lng, s.latitude, s.longitude, e.latitude, e.longitude)
            if (d < bestDistance) {
                bestDistance = d
                bestRow = row.number
            }
        }
        val rowNumber = bestRow ?: return null
        val width = paddock.rowWidth?.takeIf { it > 0 } ?: DEFAULT_ROW_WIDTH_M
        return RowHit(rowNumber, bestDistance, width)
    }

    private fun nearestSyntheticRow(paddock: Paddock, lat: Double, lng: Double): RowHit? {
        val polygon = paddock.polygonPoints ?: return null
        if (polygon.size < 3) return null
        val width = paddock.rowWidth?.takeIf { it > 0 } ?: return null
        val direction = paddock.rowDirection ?: return null
        val lines = rowLines(paddock, polygon, direction, width) ?: return null
        if (lines.isEmpty()) return null
        var bestIndex = -1
        var bestDistance = Double.MAX_VALUE
        for ((index, line) in lines.withIndex()) {
            val d = perpendicularDistanceMetres(lat, lng, line.startLat, line.startLng, line.endLat, line.endLng)
            if (d < bestDistance) {
                bestDistance = d
                bestIndex = index
            }
        }
        if (bestIndex < 0) return null
        return RowHit(bestIndex + 1, bestDistance, width)
    }

    // MARK: - Explicit mapped rows

    private fun explicitRowAttachment(
        paddock: Paddock,
        lat: Double,
        lng: Double,
        side: String?,
    ): Attachment? {
        val rows = paddock.rows?.filter { it.startPoint != null && it.endPoint != null }
        if (rows.isNullOrEmpty()) return null

        var bestRow: Int? = null
        var bestDistance = Double.MAX_VALUE
        for (row in rows) {
            val s = row.startPoint ?: continue
            val e = row.endPoint ?: continue
            val d = perpendicularDistanceMetres(lat, lng, s.latitude, s.longitude, e.latitude, e.longitude)
            if (d < bestDistance) {
                bestDistance = d
                bestRow = row.number
            }
        }
        val rowNumber = bestRow ?: return null
        val row = rows.first { it.number == rowNumber }
        val s = row.startPoint!!
        val e = row.endPoint!!
        val snap = snap(lat, lng, s.latitude, s.longitude, e.latitude, e.longitude) ?: return null
        return Attachment(
            pinRowNumber = rowNumber.toDouble(),
            pinSide = side,
            alongRowDistanceM = snap.distanceAlong,
            snappedLatitude = snap.lat,
            snappedLongitude = snap.lng,
        )
    }

    // MARK: - Synthetic row grid (no mapped rows)

    private fun syntheticRowAttachment(
        paddock: Paddock,
        lat: Double,
        lng: Double,
        side: String?,
    ): Attachment? {
        val polygon = paddock.polygonPoints ?: return null
        if (polygon.size < 3) return null
        val width = paddock.rowWidth ?: return null
        if (width <= 0) return null
        val direction = paddock.rowDirection ?: return null

        val lines = rowLines(paddock, polygon, direction, width) ?: return null
        if (lines.isEmpty()) return null

        var bestIndex = -1
        var bestDistance = Double.MAX_VALUE
        for ((index, line) in lines.withIndex()) {
            val d = perpendicularDistanceMetres(lat, lng, line.startLat, line.startLng, line.endLat, line.endLng)
            if (d < bestDistance) {
                bestDistance = d
                bestIndex = index
            }
        }
        if (bestIndex < 0) return null
        val line = lines[bestIndex]
        val snap = snap(lat, lng, line.startLat, line.startLng, line.endLat, line.endLng) ?: return null
        return Attachment(
            pinRowNumber = (bestIndex + 1).toDouble(),
            pinSide = side,
            alongRowDistanceM = snap.distanceAlong,
            snappedLatitude = snap.lat,
            snappedLongitude = snap.lng,
        )
    }

    private data class RowLine(
        val startLat: Double,
        val startLng: Double,
        val endLat: Double,
        val endLng: Double,
    )

    /**
     * Build synthetic row centrelines across the polygon, perpendicular to the
     * row direction and spaced by [width]. Mirrors iOS `RowGuidance`'s synthetic
     * grid: spans the polygon along the row-perpendicular axis and emits one
     * line per row width.
     */
    private fun rowLines(
        paddock: Paddock,
        polygon: List<com.rork.vinetrack.data.model.CoordinatePoint>,
        direction: Double,
        width: Double,
    ): List<RowLine>? {
        val centroidLat = polygon.sumOf { it.latitude } / polygon.size
        val mPerDegLat = METRES_PER_DEG_LAT
        val mPerDegLon = METRES_PER_DEG_LAT * cos(centroidLat * Math.PI / 180.0)
        if (mPerDegLon == 0.0) return null

        val bearingRad = direction * Math.PI / 180.0
        val perpRad = bearingRad + Math.PI / 2.0
        // Unit vectors in local metric space.
        val dirX = cos(bearingRad)
        val dirY = sin(bearingRad)
        val nx = cos(perpRad)
        val ny = sin(perpRad)

        // Project polygon onto direction + perpendicular axes (metres, relative
        // to the first vertex) to find the spans.
        val originLat = polygon[0].latitude
        val originLon = polygon[0].longitude
        var minPerp = Double.MAX_VALUE
        var maxPerp = -Double.MAX_VALUE
        var minDir = Double.MAX_VALUE
        var maxDir = -Double.MAX_VALUE
        for (p in polygon) {
            val dx = (p.longitude - originLon) * mPerDegLon
            val dy = (p.latitude - originLat) * mPerDegLat
            val projPerp = dx * nx + dy * ny
            val projDir = dx * dirX + dy * dirY
            minPerp = minOf(minPerp, projPerp)
            maxPerp = maxOf(maxPerp, projPerp)
            minDir = minOf(minDir, projDir)
            maxDir = maxOf(maxDir, projDir)
        }
        val span = maxPerp - minPerp
        if (span <= 0) return null
        val count = (span / width).toInt().coerceIn(0, 1000)
        if (count <= 0) return null

        val lines = ArrayList<RowLine>(count)
        for (i in 0 until count) {
            val perpOffset = minPerp + (i + 0.5) * width
            // Two endpoints along the row direction at this perpendicular offset.
            val sxMetres = nx * perpOffset + dirX * minDir
            val syMetres = ny * perpOffset + dirY * minDir
            val exMetres = nx * perpOffset + dirX * maxDir
            val eyMetres = ny * perpOffset + dirY * maxDir
            lines.add(
                RowLine(
                    startLat = originLat + syMetres / mPerDegLat,
                    startLng = originLon + sxMetres / mPerDegLon,
                    endLat = originLat + eyMetres / mPerDegLat,
                    endLng = originLon + exMetres / mPerDegLon,
                ),
            )
        }
        return lines
    }

    // MARK: - Geometry primitives

    private data class SnapResult(val lat: Double, val lng: Double, val distanceAlong: Double)

    /** Project (pLat,pLng) onto segment a→b; returns snapped point + distance from a. */
    private fun snap(
        pLat: Double,
        pLng: Double,
        aLat: Double,
        aLng: Double,
        bLat: Double,
        bLng: Double,
    ): SnapResult? {
        val centroidLat = (aLat + bLat + pLat) / 3.0
        val mPerDegLat = METRES_PER_DEG_LAT
        val mPerDegLon = METRES_PER_DEG_LAT * cos(centroidLat * Math.PI / 180.0)

        val ax = aLng * mPerDegLon
        val ay = aLat * mPerDegLat
        val bx = bLng * mPerDegLon
        val by = bLat * mPerDegLat
        val px = pLng * mPerDegLon
        val py = pLat * mPerDegLat

        val dx = bx - ax
        val dy = by - ay
        val lenSq = dx * dx + dy * dy
        if (lenSq <= 1e-6) return null
        val length = sqrt(lenSq)
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = t.coerceIn(0.0, 1.0)
        val cx = ax + t * dx
        val cy = ay + t * dy
        return SnapResult(
            lat = cy / mPerDegLat,
            lng = cx / mPerDegLon,
            distanceAlong = t * length,
        )
    }

    /** Perpendicular distance (m) from point to segment a→b. */
    private fun perpendicularDistanceMetres(
        pLat: Double,
        pLng: Double,
        aLat: Double,
        aLng: Double,
        bLat: Double,
        bLng: Double,
    ): Double {
        val centroidLat = (aLat + bLat + pLat) / 3.0
        val mPerDegLat = METRES_PER_DEG_LAT
        val mPerDegLon = METRES_PER_DEG_LAT * cos(centroidLat * Math.PI / 180.0)

        val ax = aLng * mPerDegLon
        val ay = aLat * mPerDegLat
        val bx = bLng * mPerDegLon
        val by = bLat * mPerDegLat
        val px = pLng * mPerDegLon
        val py = pLat * mPerDegLat

        val dx = bx - ax
        val dy = by - ay
        val lenSq = dx * dx + dy * dy
        if (lenSq <= 1e-9) {
            val ex = px - ax
            val ey = py - ay
            return sqrt(ex * ex + ey * ey)
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = t.coerceIn(0.0, 1.0)
        val cx = ax + t * dx
        val cy = ay + t * dy
        val ex = px - cx
        val ey = py - cy
        return sqrt(ex * ex + ey * ey)
    }
}
