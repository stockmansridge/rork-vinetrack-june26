package com.rork.vinetrack.data.ripeness

/** Small polygon helpers shared by the heatmap's labels and camera fit. */
object ElRipenessGeometry {

    /**
     * Area-weighted centroid of a simple polygon, falling back to the vertex
     * mean for degenerate (zero-area) rings so a label always has somewhere to
     * sit.
     */
    fun centroid(polygon: List<ElRipenessHeatmap.LatLng>): ElRipenessHeatmap.LatLng? {
        if (polygon.isEmpty()) return null
        if (polygon.size < 3) {
            return ElRipenessHeatmap.LatLng(
                polygon.sumOf { it.lat } / polygon.size,
                polygon.sumOf { it.lng } / polygon.size,
            )
        }

        var twiceArea = 0.0
        var lat = 0.0
        var lng = 0.0
        for (i in polygon.indices) {
            val a = polygon[i]
            val b = polygon[(i + 1) % polygon.size]
            val cross = a.lng * b.lat - b.lng * a.lat
            twiceArea += cross
            lng += (a.lng + b.lng) * cross
            lat += (a.lat + b.lat) * cross
        }

        if (twiceArea == 0.0) {
            return ElRipenessHeatmap.LatLng(
                polygon.sumOf { it.lat } / polygon.size,
                polygon.sumOf { it.lng } / polygon.size,
            )
        }
        val factor = 1.0 / (3.0 * twiceArea)
        return ElRipenessHeatmap.LatLng(lat * factor, lng * factor)
    }
}
