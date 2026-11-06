package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.*
import java.util.UUID
import kotlin.math.*

/** Foreground-only traversal evidence, bound to immutable plan/occurrence geometry. Never restored across pauses. */
class OccurrenceTraversalTracker {
    data class Fix(val latitude: Double, val longitude: Double, val accuracy: Double?, val timeMs: Long)
    data class Path(val occurrenceId: String, val physicalId: String, val blockId: String,
                    val startLat: Double, val startLon: Double, val endLat: Double, val endLon: Double,
                    val corridor: Double, val lane: Double = corridor) {
        val length: Double get() = hypot((endLon-startLon)*111320*cos(Math.toRadians(startLat)), (endLat-startLat)*111320)
        fun projection(fix: Fix): Pair<Double, Double> {
            val x = (fix.longitude-startLon)*111320*cos(Math.toRadians(startLat)); val y = (fix.latitude-startLat)*111320
            val dx = (endLon-startLon)*111320*cos(Math.toRadians(startLat)); val dy = (endLat-startLat)*111320
            val fraction = (x*dx+y*dy)/(length*length)
            return fraction to abs(x*dy-y*dx)/length
        }
    }
    private data class Run(val key: String, val path: Path, val first: Fix, val entry: Double,
                           var last: Fix, var fraction: Double, var count: Int = 1)
    private var run: Run? = null
    private var departureId: String? = null
    private var departureStart: Long = 0
    private var departureLast: Long = 0
    private var departureCount: Int = 0
    private val speeds: ArrayDeque<Pair<Long, Double>> = ArrayDeque()
    private var notBeforeMs: Long = Long.MIN_VALUE
    /** Consecutive fixes clearly in another aisle during a run (the in-row lock release). */
    private var awayCount: Int = 0
    private var awayStartMs: Long = 0
    fun reset(boundaryMs: Long? = null) {
        run = null; departureId = null; departureCount = 0; awayCount = 0
        if (boundaryMs != null) notBeforeMs = max(notBeforeMs, boundaryMs)
    }
    fun resetSession(boundaryMs: Long = System.currentTimeMillis()) { reset(boundaryMs); speeds.clear() }

    /**
     * End-to-end traversal of the target pass, tolerant of ordinary phone GPS.
     *
     * The server (sql/276 `apply_trip_occurrence_action_v1`) accepts an automatic
     * "done" only for a run that enters within the first 10% of the pass, exits
     * within the last 10% (either direction), spans >= 80% of it, with >= 4
     * samples over >= 3 s. Every run reported here meets that contract.
     *
     * Client-side noise filtering matches iOS Free Drive tolerance instead of
     * survey-grade GPS: fixes up to [MAX_ACCURACY_M] are used, the fix must lie
     * within the target aisle ([Path.lane], half the aisle width, min 1 m), and
     * the target must be clearly the nearest planned aisle. Once a run has
     * started the tractor is treated as locked in that row (vines prevent a
     * sideways move): noisy fixes, including ones that look like another aisle,
     * are skipped rather than discarding the pass. A run only ends by leaving a
     * row end, a gap over 10 s, reversing more than 15%, or sustained evidence of
     * another aisle ([LOCK_RELEASE_FIXES] fixes over [LOCK_RELEASE_MS]). Only the
     * target pass can ever complete.
     */
    fun observe(document: TripOccurrenceCoverage.Document, fix: Fix, nowMs: Long, operational: Boolean): JsonObject? {
        val target = document.targetId
        val paths = paths(document)
        val path = paths.singleOrNull { it.occurrenceId == target }
        if (!operational || path == null || document.status(path.occurrenceId) != "incomplete") { run = null; return null }
        if (!qualified(fix, nowMs, path)) return null
        val (rawFraction, cross) = path.projection(fix)
        val key = "${document.planId}:${document.planRevision}:${path.occurrenceId}:${document.state(path.occurrenceId)}"
        val prior = run?.takeIf { it.key == key }
        if (prior == null) run = null
        // Past either row end: the pass is over (or never started).
        if (rawFraction !in -0.15..1.15) { run = null; awayCount = 0; return null }
        // In-row lock: vines stop a tractor changing aisle mid-row, so a fix that looks
        // like another aisle is GPS error until it's sustained (same rule as [departed]).
        if (cross > path.lane * 2) {
            if (prior == null) return null
            if (awayCount == 0 || fix.timeMs - prior.last.timeMs > 10_000) awayStartMs = fix.timeMs
            awayCount++
            if (awayCount >= LOCK_RELEASE_FIXES && fix.timeMs - awayStartMs >= LOCK_RELEASE_MS) { run = null; awayCount = 0 }
            return null
        }
        val inAisle = cross <= path.lane && rawFraction in -0.05..1.05
        // The target must be clearly the nearest planned aisle (overlapping blocks stay ambiguous).
        val ambiguous = paths.distinctBy { it.physicalId to it.blockId }.any { other ->
            if (other.physicalId == path.physicalId && other.blockId == path.blockId) false else {
                val p = other.projection(fix)
                p.first in -0.05..1.05 && p.second <= cross + AMBIGUITY_MARGIN_M
            }
        }
        if (!inAisle || ambiguous) return null
        awayCount = 0
        val fraction = rawFraction.coerceIn(0.0, 1.0)
        if (prior == null) {
            run = if (fraction <= 0.1 || fraction >= 0.9) Run(key, path, fix, fraction, fix, fraction) else null
            return null
        }
        val dt = (fix.timeMs-prior.last.timeMs)/1000.0
        if (dt > 10) { run = if (fraction <= 0.1 || fraction >= 0.9) Run(key, path, fix, fraction, fix, fraction) else null; return null }
        val direction = if (prior.entry <= 0.1) 1 else -1
        val progress = (fraction-prior.fraction)*direction
        if (progress < -0.15) { run = null; return null }
        val step = distance(prior.last, fix)
        // Skip (don't reset on) duplicate, too-soon, jumped or non-advancing fixes.
        if (dt < 0.75 || step/dt > 12 || progress < 0.002) return null
        prior.last = fix; prior.fraction = fraction; prior.count++
        val duration = (fix.timeMs-prior.first.timeMs)/1000.0
        val span = abs(fraction-prior.entry)
        val arrived = if (direction == 1) fraction >= 0.9 else fraction <= 0.1
        if (!arrived || prior.count < 4 || duration < 3 || span < 0.8) return null
        run = null
        return buildJsonObject {
            put("occurrenceId", path.occurrenceId); put("ruleVersion", "traversal-v1"); put("runId", UUID.randomUUID().toString())
            put("qualifiedSamples", prior.count); put("durationSeconds", duration); put("longitudinalSpan", span)
            put("entryFraction", prior.entry); put("exitFraction", fraction); put("unambiguous", true)
        }
    }

    /** A correction survives jitter; only four fresh, accurate outside observations over >=3s release it. */
    fun departed(document: TripOccurrenceCoverage.Document, selectedId: String, fix: Fix, nowMs: Long): Boolean {
        val path = paths(document).singleOrNull { it.occurrenceId == selectedId } ?: return false
        if (!strictlyQualified(fix, nowMs, path)) { departureCount = 0; return false }
        val p = path.projection(fix)
        val outside = p.second > path.corridor + requireNotNull(fix.accuracy) + 2 || p.first < -0.15 || p.first > 1.15
        if (!outside) { departureCount = 0; return false }
        if (departureId != selectedId || fix.timeMs-departureLast !in 750..10000 || departureCount == 0) {
            departureId = selectedId; departureStart = fix.timeMs; departureCount = 0
        }
        departureLast = fix.timeMs; departureCount++
        return departureCount >= 4 && fix.timeMs-departureStart >= 3000
    }
    fun recordSpeed(timeMs: Long, speed: Double?, accuracy: Double?, nowMs: Long) {
        if (timeMs < notBeforeMs || nowMs-timeMs !in 0..5000 || accuracy == null || accuracy !in 0.0..8.0 || speed == null || speed !in 0.5..12.0) return
        if (speeds.lastOrNull()?.first?.let { timeMs <= it } == true) return
        speeds.addLast(timeMs to speed)
        while (speeds.size > 120 || speeds.firstOrNull()?.first?.let { timeMs-it > 180000 } == true) speeds.removeFirst()
    }
    /** Stopping does not erase the recent moving window; stale windows become unavailable. */
    fun remainingSeconds(document: TripOccurrenceCoverage.Document, nowMs: Long): Long? {
        val window = speeds.filter { nowMs-it.first in 0..180000 }
        if (window.size < 4 || window.last().first-window.first().first < 3000) return null
        val remaining = document.order.filter { document.status(it) == "incomplete" }
        val paths = paths(document).associateBy { it.occurrenceId }
        if (remaining.any { it !in paths }) return null
        return (remaining.sumOf { paths.getValue(it).length } / window.map { it.second }.average()).roundToLong()
    }
    /** Fresh, finite fix with phone-grade accuracy. Used for traversal evidence. */
    private fun qualified(fix: Fix, nowMs: Long, path: Path): Boolean =
        fix.latitude.isFinite() && fix.longitude.isFinite() && fix.timeMs >= notBeforeMs && nowMs-fix.timeMs in 0..5000 &&
            fix.accuracy?.let { it.isFinite() && it > 0 && it <= MAX_ACCURACY_M } == true && path.length >= 3

    /** Unchanged strict gate for releasing a manual selection (see [departed]). */
    private fun strictlyQualified(fix: Fix, nowMs: Long, path: Path): Boolean =
        fix.latitude.isFinite() && fix.longitude.isFinite() && fix.timeMs >= notBeforeMs && nowMs-fix.timeMs in 0..5000 &&
            fix.accuracy?.let { it.isFinite() && it > 0 && it <= min(3.0, path.corridor) && path.length >= it*6 } == true && path.length >= 3

    companion object {
        /** Phone GPS commonly reports 3-8 m; beyond this a fix is too vague to place in an aisle. */
        const val MAX_ACCURACY_M = 10.0
        /** Another planned aisle this close to being as near as the target makes the fix ambiguous. */
        const val AMBIGUITY_MARGIN_M = 0.5
        /** Sustained evidence needed to release the in-row lock: fixes clearly in another aisle... */
        const val LOCK_RELEASE_FIXES = 4
        /** ...spanning at least this long. */
        const val LOCK_RELEASE_MS = 3_000L
        /** Only frozen, paired physical rows define an aisle. Boundary offsets are not guessed. */
        fun paths(document: TripOccurrenceCoverage.Document): List<Path> = document.raw.getValue("items").jsonArray.mapNotNull { value -> runCatching {
            val item = value.jsonObject; val ref = item.getValue("physicalPathRef").jsonObject
            require(ref["geometryRevision"]?.jsonPrimitive?.content != "unresolved")
            val rows = ref.getValue("rowSnapshots").jsonArray
            require(rows.size == 2 && ref.getValue("rowIds").jsonArray.size == 2)
            fun coordinate(row: Int, end: String, axis: String) = rows[row].jsonObject.getValue(end).jsonObject.getValue(axis).jsonPrimitive.double
            val a = Fix(coordinate(0,"startPoint","latitude"),coordinate(0,"startPoint","longitude"),null,0)
            val b = Fix(coordinate(1,"startPoint","latitude"),coordinate(1,"startPoint","longitude"),null,0)
            val ae = Fix(coordinate(0,"endPoint","latitude"),coordinate(0,"endPoint","longitude"),null,0)
            val be = Fix(coordinate(1,"endPoint","latitude"),coordinate(1,"endPoint","longitude"),null,0)
            // Crossed/oppositely encoded rows cannot safely be averaged without a verified orientation.
            require(distance(a,b) < distance(a,be) && distance(ae,be) < distance(ae,b))
            val width = min(distance(a,b),distance(ae,be))
            require(width in 1.5..15.0)
            Path(item.getValue("occurrenceId").jsonPrimitive.content, ref.getValue("pathId").jsonPrimitive.content,
                item.getValue("blockId").jsonPrimitive.content,(a.latitude+b.latitude)/2,(a.longitude+b.longitude)/2,
                (ae.latitude+be.latitude)/2,(ae.longitude+be.longitude)/2,min(3.0,width*0.35),max(1.0,width/2)).also { require(it.length >= 3) }
        }.getOrNull() }
        /** Physical neighbours projected onto the screen's horizontal axis; never inferred from numeric order. */
        fun adjacentLabels(document: TripOccurrenceCoverage.Document, occurrenceId: String?, cameraBearing: Double): Pair<Double, Double>? = runCatching {
            require(paths(document).any { it.occurrenceId == occurrenceId })
            val item = document.raw.getValue("items").jsonArray.single { it.jsonObject["occurrenceId"]?.jsonPrimitive?.content == occurrenceId }.jsonObject
            val rows = item.getValue("physicalPathRef").jsonObject.getValue("rowSnapshots").jsonArray
            val angle = Math.toRadians(cameraBearing)
            val referenceLat = rows.flatMap { row -> listOf("startPoint", "endPoint").map {
                row.jsonObject.getValue(it).jsonObject.getValue("latitude").jsonPrimitive.double
            } }.average()
            val projected = rows.map { row ->
                val r = row.jsonObject
                val s = r.getValue("startPoint").jsonObject; val e = r.getValue("endPoint").jsonObject
                val lat = (s.getValue("latitude").jsonPrimitive.double + e.getValue("latitude").jsonPrimitive.double)/2
                val lon = (s.getValue("longitude").jsonPrimitive.double + e.getValue("longitude").jsonPrimitive.double)/2
                val horizontal = lon*cos(Math.toRadians(referenceLat))*cos(angle)-lat*sin(angle)
                r.getValue("number").jsonPrimitive.double to horizontal
            }.sortedBy { it.second }
            require(abs(projected[0].second-projected[1].second)*111320 > 0.5)
            projected[0].first to projected[1].first
        }.getOrNull()
        private fun distance(a: Fix, b: Fix): Double = hypot((a.longitude-b.longitude)*111320*cos(Math.toRadians(a.latitude)),(a.latitude-b.latitude)*111320)
    }
}
