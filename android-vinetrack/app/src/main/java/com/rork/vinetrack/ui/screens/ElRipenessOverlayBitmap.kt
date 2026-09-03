package com.rork.vinetrack.ui.screens

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import com.rork.vinetrack.data.ripeness.ElRipenessHeatRaster
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap

/**
 * Builds the drawable bitmap for one block's heat surface.
 *
 * Two clips, not one — matching the Swift renderer:
 *
 * 1. The raster itself only ever contains cells that passed *this* block's
 *    point-in-polygon test; everything else is already alpha 0.
 * 2. The upscaled bitmap is masked by the block polygon a second time.
 *
 * The second clip is not redundant. The 48x48 grid is stretched across the
 * block with bilinear filtering, and interpolation between an alpha-0 cell and
 * its painted neighbour produces partial alpha that would otherwise bleed up to
 * half a cell past the boundary — visible as a soft halo across a shared edge
 * with the neighbouring block. Masking after the upscale makes cross-block
 * bleed structurally impossible rather than merely unlikely.
 */
object ElRipenessOverlayBitmap {

    /**
     * Upscale factor applied before masking. The contract grid is only 48x48;
     * without an upscale the polygon mask would be quantised to whole grid
     * cells and the block edge would look like a staircase.
     */
    private const val UPSCALE = 8

    /** Caps the intermediate bitmap so a huge block cannot balloon memory. */
    private const val MAX_EDGE = 1024

    /**
     * @param raster the block's pixel buffer (row 0 = north).
     * @param bounds the half-cell-expanded rect the buffer is stretched across.
     * @param polygon the block boundary, used for the second clip.
     */
    fun build(
        raster: ElRipenessHeatRaster.Raster,
        bounds: ElRipenessHeatRaster.DrawBounds,
        polygon: List<ElRipenessHeatmap.LatLng>,
    ): Bitmap? {
        if (raster.width <= 0 || raster.height <= 0) return null

        val source = Bitmap.createBitmap(
            raster.pixels,
            raster.width,
            raster.height,
            Bitmap.Config.ARGB_8888,
        )
        if (polygon.size < 3) return source

        val targetWidth = (raster.width * UPSCALE).coerceAtMost(MAX_EDGE)
        val targetHeight = (raster.height * UPSCALE).coerceAtMost(MAX_EDGE)

        val output = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { isFilterBitmap = true }

        canvas.drawBitmap(
            source,
            Rect(0, 0, raster.width, raster.height),
            RectF(0f, 0f, targetWidth.toFloat(), targetHeight.toFloat()),
            paint,
        )
        source.recycle()

        val latSpan = bounds.north - bounds.south
        val lngSpan = bounds.east - bounds.west
        if (latSpan <= 0.0 || lngSpan <= 0.0) return output

        // The polygon in bitmap pixel space. Y is flipped: bitmap row 0 is the
        // northern edge, latitude increases northward.
        val path = Path()
        polygon.forEachIndexed { index, point ->
            val x = ((point.lng - bounds.west) / lngSpan * targetWidth).toFloat()
            val y = ((bounds.north - point.lat) / latSpan * targetHeight).toFloat()
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()

        // DST_IN keeps only the destination pixels covered by the mask.
        val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
        }
        val mask = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
        Canvas(mask).drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = -0x1 })
        canvas.drawBitmap(mask, 0f, 0f, maskPaint)
        mask.recycle()

        return output
    }
}
