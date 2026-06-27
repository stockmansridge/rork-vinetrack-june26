package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/** A single laid-out row line between two boundary-clipped endpoints. */
data class RowLine(val start: CoordinatePoint, val end: CoordinatePoint)

/**
 * Generate evenly-spaced row lines across a boundary polygon, clipped to the
 * polygon edges. Direct port of the iOS `calculateRowLines` (RowGeometry.swift)
 * so Android-authored row layouts match iOS/portal byte-for-byte: same
 * equirectangular projection, centroid origin, perpendicular spacing, and
 * segment-intersection clipping.
 *
 * @param polygon boundary points (>= 3 required)
 * @param direction row bearing in degrees (0–360)
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
): List<RowLine> {
    if (polygon.size < 3 || count <= 0 || width <= 0) return emptyList()

    val centroidLat = polygon.sumOf { it.latitude } / polygon.size
    val centroidLon = polygon.sumOf { it.longitude } / polygon.size

    val bearingRad = direction * Math.PI / 180.0
    val perpRad = bearingRad + Math.PI / 2.0

    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)

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

    val result = mutableListOf<RowLine>()
    for (i in 0 until count) {
        val off = startOff + i * width + offset
        val cLat = centroidLat + off * cos(perpRad) / mPerDegLat
        val cLon = centroidLon + off * Math.sin(perpRad) / mPerDegLon

        val dLat = halfLen * cos(bearingRad) / mPerDegLat
        val dLon = halfLen * Math.sin(bearingRad) / mPerDegLon

        val s = CoordinatePoint(latitude = cLat - dLat, longitude = cLon - dLon)
        val e = CoordinatePoint(latitude = cLat + dLat, longitude = cLon + dLon)

        clipLineToPolygon(s, e, polygon)?.let { result.add(it) }
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
