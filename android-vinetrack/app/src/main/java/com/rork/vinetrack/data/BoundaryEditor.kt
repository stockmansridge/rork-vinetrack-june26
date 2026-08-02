package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint

/**
 * An insertion control sitting halfway along one polygon segment.
 *
 * [insertIndex] is the position the NEW point takes in the ordered coordinate
 * list, so the polygon order is preserved:
 *
 * ```
 * before: 1 → 2 → 3          midpoint 1→2 tapped (insertIndex 1)
 * after:  1 → new 2 → 3 → 4
 * ```
 *
 * For the closing segment (last point → point 1) the new point is appended to
 * the END of the list, which keeps the ring order correct.
 */
data class BoundaryMidpoint(
    val point: CoordinatePoint,
    /** Index the inserted point takes in the ordered list. */
    val insertIndex: Int,
    /** Zero-based index of the segment's first point. */
    val fromIndex: Int,
    /** Zero-based index of the segment's second point (wraps to 0 on the closing edge). */
    val toIndex: Int,
) {
    /** TalkBack label, e.g. "Add boundary point between points 1 and 2". */
    val accessibilityLabel: String
        get() = "Add boundary point between points ${fromIndex + 1} and ${toIndex + 1}"

    /** Stable identity for Compose keys — segment based, not position based. */
    val key: String get() = "midpoint-$fromIndex-$toIndex"
}

/** One reversible boundary edit. */
sealed interface BoundaryEdit {
    /** A point appended at the end (map tap or "Add at Centre"). */
    data class Added(val index: Int) : BoundaryEdit

    /** A point inserted mid-list from a midpoint control. */
    data class Inserted(val index: Int) : BoundaryEdit

    /** A point dragged to a new position; [from] is where it started. */
    data class Moved(val index: Int, val from: CoordinatePoint) : BoundaryEdit

    /** The whole boundary was cleared; [points] is the full previous ring. */
    data class Cleared(val points: List<CoordinatePoint>) : BoundaryEdit
}

/**
 * Pure boundary geometry + edit rules for the block map editor.
 *
 * Kept free of Compose and Maps SDK types so the whole insert / undo / framing
 * contract is unit-testable on the JVM (`BoundaryEditorTest`).
 */
object BoundaryEditor {

    /** Lowest zoom the editor allows — below this the imagery has no detail. */
    const val MIN_ZOOM: Float = 3f

    /**
     * Highest zoom the editor allows. The satellite source is native to z19 and
     * the over-zoom layer upscales one more level cleanly; beyond that the SDK
     * would ask for tiles the imagery service cannot serve, which is what left
     * users staring at a grey screen.
     */
    const val MAX_ZOOM: Float = 20f

    /** Zoom used when the editor can only centre on a single coordinate. */
    const val SINGLE_POINT_ZOOM: Float = 18f

    /** Zoom used when only the vineyard's registered location is known. */
    const val VINEYARD_CENTRE_ZOOM: Float = 16f

    fun clampZoom(zoom: Float): Float = zoom.coerceIn(MIN_ZOOM, MAX_ZOOM)

    /** True when a coordinate is usable (rejects null island and out-of-range). */
    fun isValidPoint(point: CoordinatePoint?): Boolean {
        if (point == null) return false
        val lat = point.latitude
        val lng = point.longitude
        if (lat.isNaN() || lng.isNaN()) return false
        if (lat !in -90.0..90.0 || lng !in -180.0..180.0) return false
        return !(lat == 0.0 && lng == 0.0)
    }

    /**
     * True when a previously stored camera can safely be restored: it must
     * belong to the block being edited and carry a usable coordinate + zoom.
     */
    fun canRestoreCamera(
        savedKey: String?,
        currentKey: String,
        point: CoordinatePoint?,
        zoom: Float?,
    ): Boolean {
        if (savedKey == null || savedKey != currentKey) return false
        if (!isValidPoint(point)) return false
        if (zoom == null || zoom.isNaN()) return false
        return zoom in MIN_ZOOM..MAX_ZOOM
    }

    /**
     * Midpoint insertion controls for the current ring.
     *
     * * fewer than 2 points → none,
     * * exactly 2 points → the single open segment,
     * * 3+ points → every segment INCLUDING the closing one.
     */
    fun midpoints(points: List<CoordinatePoint>): List<BoundaryMidpoint> {
        if (points.size < 2) return emptyList()
        val n = points.size
        val segments = if (n == 2) 1 else n
        return (0 until segments).map { i ->
            val j = (i + 1) % n
            val a = points[i]
            val b = points[j]
            BoundaryMidpoint(
                point = CoordinatePoint(
                    latitude = (a.latitude + b.latitude) / 2.0,
                    longitude = (a.longitude + b.longitude) / 2.0,
                ),
                insertIndex = i + 1,
                fromIndex = i,
                toIndex = j,
            )
        }
    }

    /** Applies a midpoint insertion, returning the new ordered ring. */
    fun insert(points: List<CoordinatePoint>, midpoint: BoundaryMidpoint): List<CoordinatePoint> {
        val index = midpoint.insertIndex.coerceIn(0, points.size)
        return points.toMutableList().apply { add(index, midpoint.point) }
    }

    /** Reverses one edit, returning the previous ring. */
    fun undo(points: List<CoordinatePoint>, edit: BoundaryEdit): List<CoordinatePoint> = when (edit) {
        is BoundaryEdit.Added ->
            if (edit.index in points.indices) points.toMutableList().apply { removeAt(edit.index) } else points
        is BoundaryEdit.Inserted ->
            if (edit.index in points.indices) points.toMutableList().apply { removeAt(edit.index) } else points
        is BoundaryEdit.Moved ->
            if (edit.index in points.indices) points.toMutableList().apply { this[edit.index] = edit.from } else points
        is BoundaryEdit.Cleared -> edit.points
    }
}
