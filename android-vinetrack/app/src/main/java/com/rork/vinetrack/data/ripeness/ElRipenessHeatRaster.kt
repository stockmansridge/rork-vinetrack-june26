package com.rork.vinetrack.data.ripeness

/**
 * Turns one block's contract grid into an ARGB pixel buffer.
 *
 * Kept free of Android graphics types so the pixel maths can be pinned by plain
 * JVM unit tests. Two invariants matter more than anything else here:
 *
 * 1. **The buffer is transparent outside the block polygon.** A `null` grid
 *    cell — which is exactly what `buildBlockHeat` writes for every sample
 *    point that failed the point-in-polygon test — becomes alpha 0. No block
 *    can ever tint its neighbour, because a block's raster only ever contains
 *    its own polygon's cells.
 * 2. **Only full-precision values are read.** Colour comes from the raw IDW
 *    value and alpha from the raw cell weight. The six-decimal display copies
 *    in the contract's expected file are never fed back in.
 *
 * Mirrors the Swift `ELRipenessHeatRaster`.
 */
object ElRipenessHeatRaster {

    /**
     * A raw pixel buffer plus the geometry needed to place it on a map.
     *
     * [pixels] is ARGB_8888, row 0 = **north**, laid out row-major.
     */
    data class Raster(
        val width: Int,
        val height: Int,
        val pixels: IntArray,
    ) {
        fun pixel(x: Int, y: Int): Int = pixels[y * width + x]

        fun alphaAt(x: Int, y: Int): Int = (pixel(x, y) ushr 24) and 0xFF

        // Data classes with an array member need these written out by hand.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Raster) return false
            return width == other.width && height == other.height && pixels.contentEquals(other.pixels)
        }

        override fun hashCode(): Int =
            (width * 31 + height) * 31 + pixels.contentHashCode()
    }

    /**
     * Builds the pixel buffer for a block.
     *
     * The contract grid stores row 0 at the **south** edge; raster row 0 is the
     * **north** edge, so rows are flipped here rather than at draw time.
     *
     * @return `null` when the block paints nothing at all (`none`, `stale` and
     *   `no_polygon` modes, which carry no grid), or when every cell was
     *   transparent.
     */
    fun raster(block: ElRipenessHeatmap.BlockHeat): Raster? {
        val grid = block.grid ?: return null
        val weights = block.weightGrid ?: return null
        val height = grid.size
        if (height <= 0) return null
        val width = grid.firstOrNull()?.size ?: 0
        if (width <= 0) return null

        val pixels = IntArray(width * height)
        var painted = false

        for (row in 0 until height) {
            // Flip: raster row 0 is north, grid row 0 is south.
            val gridRow = height - 1 - row
            val values = grid[gridRow]
            val weightRow = if (gridRow < weights.size) weights[gridRow] else emptyList()

            for (column in 0 until width) {
                if (column >= values.size) continue
                val value = values[column] ?: continue
                val weight = if (column < weightRow.size) weightRow[column] else null

                val alpha = ElRipenessHeatmap.alpha255(value, weight)
                if (alpha <= 0) continue

                val rgb = ElRipenessHeatmap.elColour(value)
                pixels[row * width + column] =
                    (alpha shl 24) or (rgb.r shl 16) or (rgb.g shl 8) or rgb.b
                painted = true
            }
        }

        return if (painted) Raster(width, height, pixels) else null
    }

    /**
     * The map rectangle the buffer must be stretched across.
     *
     * The half-cell expansion matters: the contract samples grid *nodes* at
     * `minLat + step * i`, so the outermost nodes sit exactly on the bounds.
     * Drawing the bitmap edge-to-edge on those bounds would place pixel centres
     * half a cell inboard and shift the whole surface. Expanding by half a cell
     * re-aligns pixel centres with the sampled nodes.
     */
    data class DrawBounds(
        val south: Double,
        val west: Double,
        val north: Double,
        val east: Double,
    )

    fun drawBounds(block: ElRipenessHeatmap.BlockHeat): DrawBounds? {
        val bounds = block.gridBounds ?: return null
        val grid = block.grid ?: return null
        val rows = grid.size
        val columns = grid.firstOrNull()?.size ?: 0
        if (rows <= 1 || columns <= 1) return null

        val latStep = (bounds.maxLat - bounds.minLat) / (rows - 1)
        val lngStep = (bounds.maxLng - bounds.minLng) / (columns - 1)
        return DrawBounds(
            south = bounds.minLat - latStep / 2.0,
            west = bounds.minLng - lngStep / 2.0,
            north = bounds.maxLat + latStep / 2.0,
            east = bounds.maxLng + lngStep / 2.0,
        )
    }
}
