package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PaddockRow
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Free Drive automatic row completion — a direct port of the iOS
 * `TripTrackingService` Free Drive rules (`updateFreeDriveStability`,
 * `accumulateDistanceAlong`, `finalizeIfThresholdMet`, `isNearPathEnd`,
 * `rowLength`). Pure and deterministic: the caller feeds one resolved GPS fix
 * at a time and persists any path this returns.
 *
 * Paths use the trip's X.5 driving-path numbers (the same numbers as
 * `completedPaths`). Row geometry is looked up on the block's own local row
 * numbers via [localOffset] (global row number minus local row number), so
 * multi-block trips measure the right row.
 */
class FreeDriveRowCompletion {
    private data class Sample(val timeMs: Long, val path: Double, val inCorridor: Boolean)

    private val samples = ArrayDeque<Sample>()
    private val distanceByPath = mutableMapOf<Double, Double>()
    private var lastLat: Double? = null
    private var lastLon: Double? = null
    private var lastCompletedPath: Double? = null
    private var lastCompletedAtMs: Long? = null

    /** The settled Free Drive path, or null until the first lock. */
    var stablePath: Double? = null
        private set

    fun reset() {
        samples.clear(); distanceByPath.clear(); stablePath = null
        lastLat = null; lastLon = null; lastCompletedPath = null; lastCompletedAtMs = null
    }

    /** Metres accumulated along [path] so far (diagnostics/tests). */
    fun accumulated(path: Double): Double = distanceByPath[path] ?: 0.0

    /**
     * Feed one fix. Returns the path to mark completed now, or null.
     *
     * @param livePath the X.5 driving path nearest this fix.
     * @param inCorridor fix is within the row corridor (max(1 m, rowWidth/2)).
     * @param perpendicularM distance from the fix to the nearest row centreline.
     * @param alreadyDone paths already completed or skipped on this trip.
     */
    fun observe(
        livePath: Double,
        inCorridor: Boolean,
        perpendicularM: Double,
        rowWidthM: Double,
        latitude: Double,
        longitude: Double,
        timeMs: Long,
        rows: List<PaddockRow>,
        localOffset: Int,
        alreadyDone: Set<Double>,
    ): Double? {
        updateStability(livePath, inCorridor, timeMs)
        val stable = stablePath
        if (inCorridor && stable != null && abs(stable - livePath) < 0.01) {
            accumulate(stable, latitude, longitude)
            val proximity = max(0.5, rowWidthM / 2.0)
            if (perpendicularM <= proximity &&
                finalizeIfThresholdMet(stable, latitude, longitude, timeMs, rows, localOffset, alreadyDone)) {
                return stable
            }
        } else {
            // Off-corridor or candidate not yet stable: move the segment anchor so
            // the next valid on-path fix doesn't count the gap.
            lastLat = latitude; lastLon = longitude
        }
        return null
    }

    private fun updateStability(livePath: Double, inCorridor: Boolean, timeMs: Long) {
        samples.addLast(Sample(timeMs, livePath, inCorridor))
        while (samples.isNotEmpty() && timeMs - samples.first().timeMs > WINDOW_MS) samples.removeFirst()
        val counts = samples.filter { it.inCorridor }.groupingBy { it.path }.eachCount()
        val candidate = counts.maxByOrNull { it.value }?.key ?: return
        var dwell = 0
        for (s in samples.reversed()) {
            if (!s.inCorridor) break
            if (abs(s.path - candidate) < 0.01) dwell++ else break
        }
        val current = stablePath
        if (current == null) {
            if ((counts[candidate] ?: 0) >= 2) stablePath = candidate
        } else if (abs(current - candidate) > 0.01 && dwell >= MIN_SWITCH_SAMPLES) {
            stablePath = candidate
        }
    }

    private fun accumulate(path: Double, latitude: Double, longitude: Double) {
        val pLat = lastLat; val pLon = lastLon
        lastLat = latitude; lastLon = longitude
        if (pLat == null || pLon == null) return
        val segment = distanceM(pLat, pLon, latitude, longitude)
        // Reject GPS jumps and noise.
        if (segment <= 0.5 || segment >= 50) return
        distanceByPath[path] = (distanceByPath[path] ?: 0.0) + segment
    }

    private fun finalizeIfThresholdMet(
        path: Double, latitude: Double, longitude: Double, timeMs: Long,
        rows: List<PaddockRow>, localOffset: Int, alreadyDone: Set<Double>,
    ): Boolean {
        if (alreadyDone.any { abs(it - path) < 0.01 }) return false
        val lastPath = lastCompletedPath; val lastAt = lastCompletedAtMs
        if (lastPath != null && lastAt != null && abs(lastPath - path) < 0.01 && timeMs - lastAt < COOLDOWN_MS) return false
        val accumulated = distanceByPath[path] ?: 0.0
        val localPath = path - localOffset
        val length = rowLength(localPath, rows)
        val complete = if (length != null && length > 1) {
            if (length <= SHORT_ROW_M) {
                accumulated >= max(3.0, length * 0.5) || nearPathEnd(localPath, rows, latitude, longitude, SHORT_ROW_END_TOLERANCE_M)
            } else {
                val nearEnd = nearPathEnd(localPath, rows, latitude, longitude, NEAR_ROW_END_TOLERANCE_M)
                accumulated >= length * (if (nearEnd) 0.6 else 0.95)
            }
        } else accumulated >= FALLBACK_M
        if (complete) { lastCompletedPath = path; lastCompletedAtMs = timeMs }
        return complete
    }

    companion object {
        const val WINDOW_MS = 6_000L
        const val MIN_SWITCH_SAMPLES = 3
        const val COOLDOWN_MS = 2_500L
        const val SHORT_ROW_M = 40.0
        const val SHORT_ROW_END_TOLERANCE_M = 5.0
        const val NEAR_ROW_END_TOLERANCE_M = 12.0
        const val FALLBACK_M = 10.0

        private fun neighbours(localPath: Double, rows: List<PaddockRow>): List<PaddockRow> =
            listOf(floor(localPath).toInt(), ceil(localPath).toInt()).mapNotNull { n -> rows.firstOrNull { it.number == n } }

        /** Path X.5 sits between rows X and X+1; either neighbour gives the length. */
        fun rowLength(localPath: Double, rows: List<PaddockRow>): Double? =
            neighbours(localPath, rows).firstNotNullOfOrNull { row ->
                val s = row.startPoint ?: return@firstNotNullOfOrNull null
                val e = row.endPoint ?: return@firstNotNullOfOrNull null
                distanceM(s.latitude, s.longitude, e.latitude, e.longitude).takeIf { it > 1 }
            }

        fun nearPathEnd(localPath: Double, rows: List<PaddockRow>, latitude: Double, longitude: Double, tolerance: Double): Boolean =
            neighbours(localPath, rows).any { row ->
                listOfNotNull(row.startPoint, row.endPoint).any { distanceM(it.latitude, it.longitude, latitude, longitude) <= tolerance }
            }

        fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val r = 6_371_000.0
            val dLat = Math.toRadians(lat2 - lat1); val dLon = Math.toRadians(lon2 - lon1)
            val a = sin(dLat / 2) * sin(dLat / 2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
            return 2 * r * asin(sqrt(a))
        }
    }
}
