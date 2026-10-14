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
                    val corridor: Double) {
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
    fun reset(boundaryMs: Long? = null) {
        run = null; departureId = null; departureCount = 0
        if (boundaryMs != null) notBeforeMs = max(notBeforeMs, boundaryMs)
    }
    fun resetSession(boundaryMs: Long = System.currentTimeMillis()) { reset(boundaryMs); speeds.clear() }

    /** Strict endpoint/corridor observations, no endpoint-only or numeric-identity shortcut. */
    fun observe(document: TripOccurrenceCoverage.Document, fix: Fix, nowMs: Long, operational: Boolean): JsonObject? {
        val target = document.targetId
        val paths = paths(document)
        val path = paths.singleOrNull { it.occurrenceId == target }
        if (!operational || path == null || document.status(path.occurrenceId) != "incomplete" || !qualified(fix, nowMs, path)) { run = null; return null }
        val (fraction, cross) = path.projection(fix)
        // A different physical corridor within the accuracy envelope is ambiguous even if not today's cursor.
        val ambiguous = paths.distinctBy { it.physicalId to it.blockId }.any { other ->
            if (other.physicalId == path.physicalId && other.blockId == path.blockId) false else {
                val p = other.projection(fix)
                p.first in -0.05..1.05 && p.second <= other.corridor + (fix.accuracy ?: 0.0)
            }
        }
        if (fraction !in 0.0..1.0 || cross > path.corridor || ambiguous) { run = null; return null }
        val key = "${document.planId}:${document.planRevision}:${path.occurrenceId}:${document.state(path.occurrenceId)}"
        val prior = run
        if (prior == null || prior.key != key) {
            run = if (fraction <= 0.1 || fraction >= 0.9) Run(key, path, fix, fraction, fix, fraction) else null
            return null
        }
        val dt = (fix.timeMs-prior.last.timeMs)/1000.0
        val step = distance(prior.last, fix)
        val along = abs(fraction-prior.fraction)*path.length
        val direction = if (prior.entry <= 0.1) 1 else -1
        if (dt < 0.75 || dt > 10 || step/dt > 12 || step < 0.5 || along < step*0.8 ||
            (fraction-prior.fraction)*direction < 0.002) { run = null; return null }
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
        if (!qualified(fix, nowMs, path)) { departureCount = 0; return false }
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
    private fun qualified(fix: Fix, nowMs: Long, path: Path): Boolean =
        fix.latitude.isFinite() && fix.longitude.isFinite() && fix.timeMs >= notBeforeMs && nowMs-fix.timeMs in 0..5000 &&
            fix.accuracy?.let { it.isFinite() && it > 0 && it <= min(3.0, path.corridor) && path.length >= it*6 } == true && path.length >= 3

    companion object {
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
                (ae.latitude+be.latitude)/2,(ae.longitude+be.longitude)/2,min(3.0,width*0.35)).also { require(it.length >= 3) }
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
