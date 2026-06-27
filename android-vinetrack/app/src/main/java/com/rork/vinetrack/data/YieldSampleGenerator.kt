package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.BlockYieldEstimate
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import java.util.UUID
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * Pure geometry/maths for yield estimation, ported verbatim from the iOS
 * `YieldEstimationViewModel`. Generates row-clipped jittered sample sites per
 * selected block, a serpentine midline sampling path, and computes per-block
 * yield estimates from recorded bunch counts. No platform state — fully testable.
 *
 * All distance maths use the same equirectangular approximation as iOS
 * (111,320 m per degree latitude; longitude scaled by cos(centroid latitude)).
 */
object YieldSampleGenerator {

    private const val M_PER_DEG_LAT = 111_320.0

    private data class ClippedSegment(
        val row: PaddockRow,
        val startLat: Double,
        val startLon: Double,
        val endLat: Double,
        val endLon: Double,
        val length: Double,
    )

    private data class RowSegment(
        val startLat: Double,
        val startLon: Double,
        val endLat: Double,
        val endLon: Double,
    )

    private data class MidlineLane(val start: CoordinatePoint, val end: CoordinatePoint)

    /**
     * Generate sample sites across the selected blocks. The site count per block
     * is `round(samplesPerHectare * areaHectares)` (min 1); points are spread
     * along clipped vine-row segments in a serpentine order with jittered spacing.
     */
    fun generateSampleSites(
        paddocks: List<Paddock>,
        selectedPaddockIds: Collection<String>,
        samplesPerHectare: Int,
        random: Random = Random.Default,
    ): List<SampleSite> {
        val all = mutableListOf<SampleSite>()
        var globalIndex = 1
        val selected = paddocks.filter { p -> selectedPaddockIds.any { it.equals(p.id, ignoreCase = true) } }
        for (paddock in selected) {
            val area = paddock.areaHectares
            if (area <= 0) continue
            val totalSamples = maxOf(1, round(samplesPerHectare * area).toInt())
            val sites = generateSitesOnRows(paddock, totalSamples, globalIndex, random)
            all.addAll(sites)
            globalIndex += sites.size
        }
        return all
    }

    /** Serpentine midline path across the selected blocks (entry/exit per lane). */
    fun generatePath(
        paddocks: List<Paddock>,
        selectedPaddockIds: Collection<String>,
        sampleSites: List<SampleSite>,
    ): List<CoordinatePoint> {
        if (sampleSites.isEmpty()) return emptyList()
        val selected = paddocks.filter { p -> selectedPaddockIds.any { it.equals(p.id, ignoreCase = true) } }
        val waypoints = mutableListOf<CoordinatePoint>()
        for (paddock in selected) {
            val sitesInPaddock = sampleSites.filter { it.paddockId.equals(paddock.id, ignoreCase = true) }
            if (sitesInPaddock.isEmpty()) continue
            val lanes = computeMidlineLanes(paddock)
            if (lanes.isEmpty()) continue
            lanes.forEachIndexed { laneIdx, lane ->
                val reversed = laneIdx % 2 == 1
                waypoints.add(if (reversed) lane.end else lane.start)
                waypoints.add(if (reversed) lane.start else lane.end)
            }
        }
        return waypoints
    }

    /** Per-block yield estimate from recorded samples (matches iOS calculation). */
    fun calculateYieldEstimates(
        session: YieldEstimationSession,
        paddocks: List<Paddock>,
        damageFactorProvider: (String) -> Double = { 1.0 },
    ): List<BlockYieldEstimate> {
        val selected = paddocks.filter { session.isPaddockSelected(it.id) }
        return selected.map { paddock ->
            val sitesInPaddock = session.sitesIn(paddock.id)
            val recorded = sitesInPaddock.filter { it.isRecorded }
            val damageFactor = damageFactorProvider(paddock.id)
            val totalVines = paddock.effectiveVineCount
            val blockWeight = session.bunchWeightKg(paddock.id)
            if (recorded.isEmpty()) {
                BlockYieldEstimate(
                    paddockId = paddock.id,
                    paddockName = paddock.name,
                    areaHectares = paddock.areaHectares,
                    totalVines = totalVines,
                    averageBunchesPerVine = 0.0,
                    totalBunches = 0.0,
                    averageBunchWeightKg = blockWeight,
                    damageFactor = damageFactor,
                    estimatedYieldKg = 0.0,
                    estimatedYieldTonnes = 0.0,
                    samplesRecorded = 0,
                    samplesTotal = sitesInPaddock.size,
                )
            } else {
                val avgBunches = recorded.sumOf { it.bunchCountEntry?.bunchesPerVine ?: 0.0 } / recorded.size
                val avgRounded = round(avgBunches * 100) / 100
                val totalBunches = totalVines * avgRounded
                val yieldKg = totalBunches * blockWeight * damageFactor
                BlockYieldEstimate(
                    paddockId = paddock.id,
                    paddockName = paddock.name,
                    areaHectares = paddock.areaHectares,
                    totalVines = totalVines,
                    averageBunchesPerVine = avgRounded,
                    totalBunches = totalBunches,
                    averageBunchWeightKg = blockWeight,
                    damageFactor = damageFactor,
                    estimatedYieldKg = yieldKg,
                    estimatedYieldTonnes = yieldKg / 1000.0,
                    samplesRecorded = recorded.size,
                    samplesTotal = sitesInPaddock.size,
                )
            }
        }
    }

    /** Expected site count for the current selection, before generation. */
    fun expectedSampleCount(
        paddocks: List<Paddock>,
        selectedPaddockIds: Collection<String>,
        samplesPerHectare: Int,
    ): Int = paddocks
        .filter { p -> selectedPaddockIds.any { it.equals(p.id, ignoreCase = true) } }
        .sumOf { maxOf(1, round(samplesPerHectare * it.areaHectares).toInt()) }

    fun totalSelectedArea(paddocks: List<Paddock>, selectedPaddockIds: Collection<String>): Double =
        paddocks
            .filter { p -> selectedPaddockIds.any { it.equals(p.id, ignoreCase = true) } }
            .sumOf { it.areaHectares }

    private fun generateSitesOnRows(
        paddock: Paddock,
        totalSamples: Int,
        startIndex: Int,
        random: Random,
    ): List<SampleSite> {
        val rows = paddock.rows ?: return emptyList()
        val polygon = paddock.polygonPoints ?: return emptyList()
        if (rows.isEmpty() || polygon.size < 3) return emptyList()

        val centroidLat = polygon.sumOf { it.latitude } / polygon.size
        val centroidLon = polygon.sumOf { it.longitude } / polygon.size
        val mPerDegLon = M_PER_DEG_LAT * cos(centroidLat * Math.PI / 180.0)
        val rowAngleRad = (paddock.rowDirection ?: 0.0) * Math.PI / 180.0

        val segmentsByRow = LinkedHashMap<Int, MutableList<ClippedSegment>>()
        for (row in rows) {
            val s = row.startPoint ?: continue
            val e = row.endPoint ?: continue
            val segments = clipRowToPolygon(s, e, polygon)
            for (seg in segments) {
                val dLat = (seg.endLat - seg.startLat) * M_PER_DEG_LAT
                val dLon = (seg.endLon - seg.startLon) * mPerDegLon
                val length = sqrt(dLat * dLat + dLon * dLon)
                if (length <= 0.5) continue
                segmentsByRow.getOrPut(row.number) { mutableListOf() }.add(
                    ClippedSegment(row, seg.startLat, seg.startLon, seg.endLat, seg.endLon, length),
                )
            }
        }
        if (segmentsByRow.isEmpty()) return emptyList()

        fun rowProj(r: PaddockRow): Double {
            val s = r.startPoint ?: return 0.0
            val e = r.endPoint ?: return 0.0
            val cx = ((s.longitude + e.longitude) / 2 - centroidLon) * mPerDegLon
            val cy = ((s.latitude + e.latitude) / 2 - centroidLat) * M_PER_DEG_LAT
            return cx * cos(rowAngleRad) - cy * sin(rowAngleRad)
        }

        val sortedRowNumbers = segmentsByRow.keys.sortedWith(Comparator { a, b ->
            val rA = rows.firstOrNull { it.number == a }
            val rB = rows.firstOrNull { it.number == b }
            if (rA == null || rB == null) a.compareTo(b)
            else rowProj(rA).compareTo(rowProj(rB))
        })

        val rowPairs = mutableListOf<List<Int>>()
        var ri = 0
        while (ri < sortedRowNumbers.size) {
            if (ri + 1 < sortedRowNumbers.size) {
                rowPairs.add(listOf(sortedRowNumbers[ri], sortedRowNumbers[ri + 1]))
                ri += 2
            } else {
                rowPairs.add(listOf(sortedRowNumbers[ri]))
                ri += 1
            }
        }

        fun orientSegment(seg: ClippedSegment): ClippedSegment {
            val sx = (seg.startLon - centroidLon) * mPerDegLon
            val sy = (seg.startLat - centroidLat) * M_PER_DEG_LAT
            val ex = (seg.endLon - centroidLon) * mPerDegLon
            val ey = (seg.endLat - centroidLat) * M_PER_DEG_LAT
            val projS = sx * sin(rowAngleRad) + sy * cos(rowAngleRad)
            val projE = ex * sin(rowAngleRad) + ey * cos(rowAngleRad)
            return if (projS <= projE) seg
            else ClippedSegment(seg.row, seg.endLat, seg.endLon, seg.startLat, seg.startLon, seg.length)
        }

        fun flipSegment(seg: ClippedSegment): ClippedSegment =
            ClippedSegment(seg.row, seg.endLat, seg.endLon, seg.startLat, seg.startLon, seg.length)

        val orderedSegments = mutableListOf<ClippedSegment>()
        rowPairs.forEachIndexed { pairIdx, pair ->
            var pairSegs = mutableListOf<ClippedSegment>()
            for (rowNum in pair) {
                segmentsByRow[rowNum]?.let { segs -> pairSegs.addAll(segs.map { orientSegment(it) }) }
            }
            pairSegs.sortWith(Comparator { a, b ->
                val aProj = ((a.startLon + a.endLon) / 2 - centroidLon) * mPerDegLon * sin(rowAngleRad) +
                    ((a.startLat + a.endLat) / 2 - centroidLat) * M_PER_DEG_LAT * cos(rowAngleRad)
                val bProj = ((b.startLon + b.endLon) / 2 - centroidLon) * mPerDegLon * sin(rowAngleRad) +
                    ((b.startLat + b.endLat) / 2 - centroidLat) * M_PER_DEG_LAT * cos(rowAngleRad)
                aProj.compareTo(bProj)
            })
            if (pairIdx % 2 == 1) {
                pairSegs.reverse()
                pairSegs = pairSegs.map { flipSegment(it) }.toMutableList()
            }
            orderedSegments.addAll(pairSegs)
        }
        if (orderedSegments.isEmpty()) return emptyList()

        val totalLength = orderedSegments.sumOf { it.length }
        if (totalLength <= 0) return emptyList()

        val spacingMetres = totalLength / (totalSamples + 1)
        val jitterRange = spacingMetres * 0.4

        fun jitteredStep(): Double {
            val offset = random.nextDouble(-jitterRange, jitterRange)
            return maxOf(spacingMetres * 0.25, spacingMetres + offset)
        }

        val sites = mutableListOf<SampleSite>()
        var accumulatedDistance = 0.0
        var nextSiteDistance = random.nextDouble(spacingMetres * 0.5, spacingMetres * 1.5)
        var siteIndex = startIndex

        for (seg in orderedSegments) {
            val segStartDist = accumulatedDistance
            val segEndDist = accumulatedDistance + seg.length
            while (nextSiteDistance <= segEndDist && sites.size < totalSamples) {
                val distAlong = nextSiteDistance - segStartDist
                val fraction = distAlong / seg.length
                val lat = seg.startLat + fraction * (seg.endLat - seg.startLat)
                val lon = seg.startLon + fraction * (seg.endLon - seg.startLon)
                sites.add(
                    SampleSite(
                        id = UUID.randomUUID().toString(),
                        paddockId = paddock.id,
                        paddockName = paddock.name,
                        rowNumber = seg.row.number,
                        latitude = lat,
                        longitude = lon,
                        siteIndex = siteIndex,
                    ),
                )
                siteIndex += 1
                nextSiteDistance += jitteredStep()
            }
            accumulatedDistance = segEndDist
        }

        if (sites.size < totalSamples) {
            val remaining = totalSamples - sites.size
            val segCount = orderedSegments.size
            for (i in 0 until remaining) {
                val seg = orderedSegments[i % segCount]
                val fraction = (i + 1).toDouble() / (remaining + 1)
                val lat = seg.startLat + fraction * (seg.endLat - seg.startLat)
                val lon = seg.startLon + fraction * (seg.endLon - seg.startLon)
                sites.add(
                    SampleSite(
                        id = UUID.randomUUID().toString(),
                        paddockId = paddock.id,
                        paddockName = paddock.name,
                        rowNumber = seg.row.number,
                        latitude = lat,
                        longitude = lon,
                        siteIndex = siteIndex,
                    ),
                )
                siteIndex += 1
            }
        }
        return sites
    }

    private fun computeMidlineLanes(paddock: Paddock): List<MidlineLane> {
        val polygon = paddock.polygonPoints ?: return emptyList()
        val rows = paddock.rows ?: return emptyList()
        if (rows.isEmpty() || polygon.size < 3) return emptyList()

        val centroidLat = polygon.sumOf { it.latitude } / polygon.size
        val centroidLon = polygon.sumOf { it.longitude } / polygon.size
        val mPerDegLon = M_PER_DEG_LAT * cos(centroidLat * Math.PI / 180.0)
        val rowAngleRad = (paddock.rowDirection ?: 0.0) * Math.PI / 180.0

        fun rowProj(r: PaddockRow): Double {
            val s = r.startPoint ?: return 0.0
            val e = r.endPoint ?: return 0.0
            val cx = ((s.longitude + e.longitude) / 2 - centroidLon) * mPerDegLon
            val cy = ((s.latitude + e.latitude) / 2 - centroidLat) * M_PER_DEG_LAT
            return cx * cos(rowAngleRad) - cy * sin(rowAngleRad)
        }

        val sortedRows = rows.filter { it.startPoint != null && it.endPoint != null }
            .sortedBy { rowProj(it) }
        if (sortedRows.isEmpty()) return emptyList()

        fun orientRow(row: PaddockRow): Pair<CoordinatePoint, CoordinatePoint> {
            val start = row.startPoint!!
            val end = row.endPoint!!
            val sx = (start.longitude - centroidLon) * mPerDegLon
            val sy = (start.latitude - centroidLat) * M_PER_DEG_LAT
            val ex = (end.longitude - centroidLon) * mPerDegLon
            val ey = (end.latitude - centroidLat) * M_PER_DEG_LAT
            val projS = sx * sin(rowAngleRad) + sy * cos(rowAngleRad)
            val projE = ex * sin(rowAngleRad) + ey * cos(rowAngleRad)
            return if (projS <= projE) start to end else end to start
        }

        val rowPairs = mutableListOf<List<PaddockRow>>()
        var i = 0
        while (i < sortedRows.size) {
            if (i + 1 < sortedRows.size) {
                rowPairs.add(listOf(sortedRows[i], sortedRows[i + 1]))
                i += 2
            } else {
                rowPairs.add(listOf(sortedRows[i]))
                i += 1
            }
        }

        val lanes = mutableListOf<MidlineLane>()
        for (pair in rowPairs) {
            val rawStart: CoordinatePoint
            val rawEnd: CoordinatePoint
            if (pair.size == 2) {
                val (s1, e1) = orientRow(pair[0])
                val (s2, e2) = orientRow(pair[1])
                rawStart = CoordinatePoint((s1.latitude + s2.latitude) / 2, (s1.longitude + s2.longitude) / 2)
                rawEnd = CoordinatePoint((e1.latitude + e2.latitude) / 2, (e1.longitude + e2.longitude) / 2)
            } else {
                val (s, e) = orientRow(pair[0])
                rawStart = s
                rawEnd = e
            }
            val extDirLat = rawEnd.latitude - rawStart.latitude
            val extDirLon = rawEnd.longitude - rawStart.longitude
            val extLen = sqrt(
                extDirLat * extDirLat * M_PER_DEG_LAT * M_PER_DEG_LAT +
                    extDirLon * extDirLon * mPerDegLon * mPerDegLon,
            )
            val extFactor = if (extLen > 0) 500.0 / extLen else 0.0
            val extStart = CoordinatePoint(
                rawStart.latitude - extDirLat * extFactor,
                rawStart.longitude - extDirLon * extFactor,
            )
            val extEnd = CoordinatePoint(
                rawEnd.latitude + extDirLat * extFactor,
                rawEnd.longitude + extDirLon * extFactor,
            )
            val clipped = clipMidlineToPolygon(extStart, extEnd, polygon)
            if (clipped != null) lanes.add(MidlineLane(clipped.first, clipped.second))
            else lanes.add(MidlineLane(rawStart, rawEnd))
        }
        return lanes
    }

    private fun clipMidlineToPolygon(
        start: CoordinatePoint,
        end: CoordinatePoint,
        polygon: List<CoordinatePoint>,
    ): Pair<CoordinatePoint, CoordinatePoint>? {
        val ax = start.longitude
        val ay = start.latitude
        val bx = end.longitude
        val by = end.latitude
        val dx = bx - ax
        val dy = by - ay

        val tValues = mutableListOf<Double>()
        val n = polygon.size
        for (idx in 0 until n) {
            val j = (idx + 1) % n
            val cx = polygon[idx].longitude
            val cy = polygon[idx].latitude
            val ex = polygon[j].longitude - cx
            val ey = polygon[j].latitude - cy
            val denom = dx * ey - dy * ex
            if (abs(denom) <= 1e-15) continue
            val t = ((cx - ax) * ey - (cy - ay) * ex) / denom
            val u = ((cx - ax) * dy - (cy - ay) * dx) / denom
            if (u in 0.0..1.0 && t > -0.001 && t < 1.001) {
                tValues.add(minOf(maxOf(t, 0.0), 1.0))
            }
        }
        if (pointInPolygon(ay, ax, polygon)) tValues.add(0.0)
        if (pointInPolygon(by, bx, polygon)) tValues.add(1.0)
        if (tValues.size < 2) return null
        tValues.sort()
        val t0 = tValues.first()
        val t1 = tValues.last()
        if (t1 - t0 <= 1e-10) return null
        return CoordinatePoint(ay + t0 * dy, ax + t0 * dx) to
            CoordinatePoint(ay + t1 * dy, ax + t1 * dx)
    }

    private fun clipRowToPolygon(
        start: CoordinatePoint,
        end: CoordinatePoint,
        polygon: List<CoordinatePoint>,
    ): List<RowSegment> {
        val ax = start.longitude
        val ay = start.latitude
        val bx = end.longitude
        val by = end.latitude
        val dx = bx - ax
        val dy = by - ay

        val tValues = mutableListOf(0.0, 1.0)
        val n = polygon.size
        for (idx in 0 until n) {
            val j = (idx + 1) % n
            val cx = polygon[idx].longitude
            val cy = polygon[idx].latitude
            val ex = polygon[j].longitude - cx
            val ey = polygon[j].latitude - cy
            val denom = dx * ey - dy * ex
            if (abs(denom) <= 1e-15) continue
            val t = ((cx - ax) * ey - (cy - ay) * ex) / denom
            val u = ((cx - ax) * dy - (cy - ay) * dx) / denom
            if (u in 0.0..1.0 && t > -0.001 && t < 1.001) {
                tValues.add(minOf(maxOf(t, 0.0), 1.0))
            }
        }
        tValues.sort()

        val segments = mutableListOf<RowSegment>()
        for (idx in 0 until tValues.size - 1) {
            val t0 = tValues[idx]
            val t1 = tValues[idx + 1]
            if (t1 - t0 <= 1e-10) continue
            val midT = (t0 + t1) / 2.0
            val midLat = ay + midT * dy
            val midLon = ax + midT * dx
            if (pointInPolygon(midLat, midLon, polygon)) {
                segments.add(
                    RowSegment(ay + t0 * dy, ax + t0 * dx, ay + t1 * dy, ax + t1 * dx),
                )
            }
        }
        return segments
    }

    private fun pointInPolygon(lat: Double, lon: Double, polygon: List<CoordinatePoint>): Boolean {
        val n = polygon.size
        if (n < 3) return false
        var inside = false
        var j = n - 1
        for (i in 0 until n) {
            val yi = polygon[i].latitude
            val xi = polygon[i].longitude
            val yj = polygon[j].latitude
            val xj = polygon[j].longitude
            if (((yi > lat) != (yj > lat)) &&
                (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)
            ) {
                inside = !inside
            }
            j = i
        }
        return inside
    }
}
