package com.rork.vinetrack.data

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/**
 * Shared helper for rendering the vineyard logo into locally generated PDF
 * headers. Mirrors the iOS `PDFHeaderHelper`: the logo is drawn as a square at
 * the top-left and the header text is shifted to its right. Returns the X
 * coordinate the caller should use for the title/subtitle text (the original
 * margin when there's no logo, so headers are unchanged for logo-less vineyards).
 */
object PdfHeaderUtil {

    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    fun drawLogo(
        canvas: Canvas,
        logo: Bitmap?,
        margin: Float,
        top: Float,
        size: Float = 44f,
    ): Float {
        if (logo == null) return margin
        val dst = RectF(margin, top, margin + size, top + size)
        canvas.drawBitmap(logo, null, dst, bitmapPaint)
        return margin + size + 12f
    }
}
