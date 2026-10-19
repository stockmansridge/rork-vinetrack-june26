package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.PinAisleGeometry
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.TripBlockResolver
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.Trip
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/** Read-only movement-relative context, NOT vehicle/operator facing. Never publishes coverage. */
internal data class LiveRowSideGuidance(
    val left: Double? = null,
    val right: Double? = null,
    val message: String? = null,
    val blockId: String? = null,
) {
    companion object {
        /** Uses the current accepted fix, not the persisted (distance-filtered) route tail. */
        fun resolve(trip: Trip, blocks: List<Paddock>, sample: LocationTracker.MovementSample?, nowMs: Long): LiveRowSideGuidance {
            fun waiting(message: String) = LiveRowSideGuidance(message = message)
            if (trip.isPaused) return waiting("Row guidance paused")
            val fix = sample ?: return waiting("Row guidance · waiting for a reliable fix")
            if (nowMs - fix.timestampMs !in 0L..5_000L ||
                !fix.latitude.isFinite() || fix.latitude !in -90.0..90.0 ||
                !fix.longitude.isFinite() || fix.longitude !in -180.0..180.0
            ) return waiting("Row guidance · waiting for a reliable fix")
            val scoped = blocks.filter { it.vineyardId == trip.vineyardId && it.deletedAt == null }
            val block = TripBlockResolver.resolve(trip, scoped, fix.latitude, fix.longitude)?.paddock
                ?: return waiting("Row guidance · outside mapped rows")
            // Overlapping block polygons are not enough evidence to choose a row identity.
            val ids = trip.effectivePaddockIds
            if (scoped.count { (ids.isEmpty() || it.id in ids) && RowAttachment.containsPoint(it, fix.latitude, fix.longitude) } != 1)
                return waiting("Row guidance · ambiguous block")
            val rows = block.rows.orEmpty()
            if (rows.any { row ->
                val start = row.startPoint; val end = row.endPoint
                start == null || end == null || !start.latitude.isFinite() || !start.longitude.isFinite() ||
                    !end.latitude.isFinite() || !end.longitude.isFinite() ||
                    start.latitude !in -90.0..90.0 || end.latitude !in -90.0..90.0 ||
                    start.longitude !in -180.0..180.0 || end.longitude !in -180.0..180.0
            } || rows.map { it.number }.distinct().size != rows.size)
                return waiting("Row guidance · mapped rows unavailable")
            // Course proves movement direction only: backing up and turning around can
            // produce identical GPS samples. Never assert forward-travel/facing evidence.
            val heading = fix.speedMetresPerSecond
                ?.takeIf { it.isFinite() && it >= PinAisleGeometry.MIN_COURSE_SPEED_MPS }
                ?.let { PinAisleGeometry.validHeading(fix.bearingDegrees) }
                ?: return waiting("Row guidance · waiting for travel direction")
            fun knownSide(): LiveRowSideGuidance? {
                val nearest = RowAttachment.nearestRow(block, fix.latitude, fix.longitude) ?: return null
                val row = rows.singleOrNull { it.number == nearest.rowNumber } ?: return null
                return singleMappedSide(block.copy(rows = listOf(row)), fix, heading)
            }
            if (rows.size == 1) return knownSide()
                ?: waiting("Row guidance · waiting for reliable row geometry / fix")
            if (PinAisleGeometry.approximateAisle(block, fix.latitude, fix.longitude) == null)
                return knownSide() ?: waiting("Row guidance · outside mapped rows")
            val aisle = PinAisleGeometry.aisleContaining(block, fix.latitude, fix.longitude, fix.accuracyMetres)
                ?: return waiting(ACCURACY_WAITING)
            val pair = aisle.nearRowNumber to aisle.farRowNumber
            // Display-only stricter admission. The pin helper permits uncertainty up
            // to the full aisle width; that cannot distinguish adjacent physical aisles.
            val accuracy = fix.accuracyMetres?.takeIf { it.isFinite() && it >= 0.0 }
                ?: return waiting(ACCURACY_WAITING)
            if (pair.toList().any { number ->
                !uncertaintyClearsRowAndEnds(rows.single { it.number == number }, fix, accuracy)
            }) return waiting(ACCURACY_WAITING)
            // A cross-row/headland course cannot establish an along-aisle side.
            if (listOf(pair.first, pair.second).any { number ->
                val row = rows.single { it.number == number }
                val start = row.startPoint!!; val end = row.endPoint!!
                val east = (end.longitude - start.longitude) * cos(Math.toRadians(fix.latitude))
                val north = end.latitude - start.latitude
                val axis = Math.toDegrees(atan2(east, north))
                val difference = abs(PinAisleGeometry.signedAngularDifference(heading, axis))
                (abs(east) + abs(north) < 1e-10) || minOf(difference, abs(180.0 - difference)) > 30.0
            }) return waiting("Row guidance · waiting for along-row travel")
            fun side(name: String): Double? = PinAisleGeometry.rowOnSide(block, pair, fix.latitude, fix.longitude, heading, name)
                ?.let { selected -> rows.singleOrNull { it.number == selected.rowNumber }?.calculationRowNumber?.takeIf { it.isFinite() } }
            val left = side("left"); val right = side("right")
            return LiveRowSideGuidance(left, right,
                if (left == null && right == null) "Row guidance · waiting for reliable sides" else TRAVEL_REFERENCE, block.id)
        }

        const val ACCURACY_WAITING = "Row guidance waiting · GPS cannot distinguish adjacent rows"
        const val TRAVEL_REFERENCE = "Sides follow travel direction, not vehicle facing"

        private fun uncertaintyClearsRowAndEnds(row: PaddockRow, fix: LocationTracker.MovementSample, accuracy: Double): Boolean {
            val start = row.startPoint ?: return false
            val end = row.endPoint ?: return false
            val scale = 111_320.0 * cos(Math.toRadians(fix.latitude))
            val ax = (start.longitude - fix.longitude) * scale
            val ay = (start.latitude - fix.latitude) * 111_320.0
            val dx = (end.longitude - start.longitude) * scale
            val dy = (end.latitude - start.latitude) * 111_320.0
            val length = hypot(dx, dy).takeIf { it > 0.0 } ?: return false
            val along = -(ax * dx + ay * dy) / length
            val distance = hypot(ax + along * dx / length, ay + along * dy / length)
            return along > accuracy && length - along > accuracy &&
                distance > maxOf(accuracy, PinAisleGeometry.MIN_AISLE_OFFSET_M)
        }

        // A single explicitly mapped row can establish ONE side, never an invented aisle.
        // Require saved spacing, an interior projection and an accuracy circle clear of the row/ends.
        private fun singleMappedSide(block: Paddock, fix: LocationTracker.MovementSample, heading: Double): LiveRowSideGuidance? {
            val row = block.rows?.singleOrNull() ?: return null
            val start = row.startPoint ?: return null; val end = row.endPoint ?: return null
            val width = block.rowWidth?.takeIf { it.isFinite() && it > 0.0 } ?: return null
            val accuracy = fix.accuracyMetres?.takeIf { it.isFinite() && it >= 0.0 && it < width / 2.0 } ?: return null
            val longitudeScale = 111_320.0 * cos(Math.toRadians(fix.latitude))
            val ax = (start.longitude - fix.longitude) * longitudeScale
            val ay = (start.latitude - fix.latitude) * 111_320.0
            val dx = (end.longitude - start.longitude) * longitudeScale
            val dy = (end.latitude - start.latitude) * 111_320.0
            val length = hypot(dx, dy).takeIf { it > 0.0 } ?: return null
            val t = -(ax * dx + ay * dy) / (length * length)
            if (t * length <= accuracy || (1.0 - t) * length <= accuracy) return null
            val angular = abs(PinAisleGeometry.signedAngularDifference(heading, Math.toDegrees(atan2(dx, dy))))
            if (minOf(angular, abs(180.0 - angular)) > 30.0) return null
            val x = ax + t * dx; val y = ay + t * dy
            val distance = hypot(x, y)
            if (distance <= maxOf(accuracy, PinAisleGeometry.MIN_AISLE_OFFSET_M) || distance > width * 0.75) return null
            val radians = Math.toRadians(heading)
            val rightOffset = x * cos(radians) - y * sin(radians)
            if (abs(rightOffset) <= accuracy) return null
            val label = row.calculationRowNumber.takeIf { it.isFinite() } ?: return null
            return LiveRowSideGuidance(left = label.takeIf { rightOffset < 0 }, right = label.takeIf { rightOffset > 0 }, message = TRAVEL_REFERENCE, blockId = block.id)
        }
    }
}
