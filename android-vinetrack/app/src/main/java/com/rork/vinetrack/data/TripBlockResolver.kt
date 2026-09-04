package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Trip

/** Pure multi-block location resolver shared by live row lock and trip pins. */
object TripBlockResolver {
    data class Resolution(
        val paddock: Paddock,
        val rowHit: RowAttachment.RowHit?,
        val globalRowNumber: Int?,
    )

    /**
     * Resolve only among the trip's effective blocks. Polygon containment wins;
     * overlapping polygons are disambiguated by the closest usable row.
     * The primary block is only a legacy/no-geometry fallback.
     */
    fun resolve(
        trip: Trip,
        paddocks: List<Paddock>,
        latitude: Double,
        longitude: Double,
    ): Resolution? {
        val byId = paddocks.associateBy { it.id }
        val effectiveIds = trip.effectivePaddockIds
        val candidates = effectiveIds.mapNotNull(byId::get)
        val hasCompleteList = trip.paddockIds.isNotEmpty()
        val scoped = if (candidates.isNotEmpty()) candidates else paddocks
        val containing = scoped.filter { RowAttachment.containsPoint(it, latitude, longitude) }

        val selected = when {
            containing.size == 1 -> containing.single()
            containing.size > 1 -> containing
                .map { it to RowAttachment.nearestRow(it, latitude, longitude) }
                .filter { it.second != null }
                .minByOrNull { it.second!!.perpendicularDistanceM }
                ?.first
                ?: containing.first()
            !hasCompleteList -> trip.paddockId?.let(byId::get)
            candidates.none { it.hasGeometry } -> trip.paddockId?.let(byId::get) ?: candidates.firstOrNull()
            else -> null
        } ?: return null

        val hit = RowAttachment.nearestRow(selected, latitude, longitude)
        // Trip sequences on both platforms use the configured row number as the
        // global row identity (including non-contiguous multi-block ranges).
        return Resolution(selected, hit, hit?.rowNumber)
    }

    /** Choose the sequence path adjacent to the resolved row and nearest target. */
    fun livePath(globalRowNumber: Int, sequence: List<Double>, currentPath: Double?): Double {
        val candidates = listOf(globalRowNumber - 0.5, globalRowNumber + 0.5)
        val inPlan = candidates.filter { candidate -> sequence.any { kotlin.math.abs(it - candidate) < 0.01 } }
        return (inPlan.ifEmpty { candidates }).minByOrNull { candidate ->
            kotlin.math.abs(candidate - (currentPath ?: candidate))
        } ?: (globalRowNumber - 0.5)
    }
}
