package com.rork.vinetrack.data

/**
 * Pure pixel heuristics for the satellite tile source.
 *
 * The Esri World Imagery service does NOT 404 when a tile is past the local
 * level of detail — it answers HTTP 200 with a flat light-grey placeholder
 * reading "Map data not yet available". Rendering that placeholder is exactly
 * what turned the block boundary map grey on over-zoom, so the tile provider
 * detects it and falls back to a lower zoom that it upscales instead.
 */
object SatelliteTileHeuristics {

    /** Channel spread below which a pixel counts as neutral grey. */
    private const val NEUTRAL_SPREAD = 8

    /** Minimum channel value for the placeholder's light-grey background. */
    private const val LIGHT_FLOOR = 200

    /**
     * True when [pixels] (ARGB) look like the "Map data not yet available"
     * placeholder: virtually every pixel is neutral grey and most of them are
     * light. Real imagery always carries a colour cast (vegetation green, soil
     * red) so it never satisfies both conditions.
     */
    fun isUnavailableTile(pixels: IntArray): Boolean {
        if (pixels.size < 16) return false
        var neutral = 0
        var light = 0
        for (pixel in pixels) {
            val r = (pixel shr 16) and 0xFF
            val g = (pixel shr 8) and 0xFF
            val b = pixel and 0xFF
            val max = maxOf(r, g, b)
            val min = minOf(r, g, b)
            if (max - min > NEUTRAL_SPREAD) continue
            neutral++
            if (min >= LIGHT_FLOOR) light++
        }
        val total = pixels.size
        return neutral >= total * 0.98 && light >= total * 0.80
    }
}
