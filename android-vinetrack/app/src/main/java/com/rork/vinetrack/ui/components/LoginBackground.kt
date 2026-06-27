package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import com.rork.vinetrack.ui.theme.VineColors

/** Deep vineyard gradient with sweeping vine rows, mirrors iOS LoginVineyardBackground. */
@Composable
fun LoginVineyardBackground(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height

        drawRect(
            brush = Brush.linearGradient(
                colors = listOf(VineColors.LoginTop, VineColors.LoginMid, VineColors.LoginBottom),
                start = Offset(0f, 0f),
                end = Offset(w, h),
            )
        )

        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(Color.White.copy(alpha = 0.15f), Color.Transparent),
                center = Offset(0f, 0f),
                radius = w.coerceAtLeast(h) * 0.9f,
            )
        )

        // Sweeping highlight band
        val sweep = Path().apply {
            moveTo(-w * 0.12f, h * 0.34f)
            cubicTo(w * 0.24f, h * 0.20f, w * 0.66f, h * 0.36f, w * 1.18f, h * 0.06f)
            lineTo(w * 1.18f, h * 0.16f)
            cubicTo(w * 0.70f, h * 0.45f, w * 0.23f, h * 0.28f, -w * 0.12f, h * 0.48f)
            close()
        }
        drawPath(
            path = sweep,
            brush = Brush.horizontalGradient(
                listOf(Color.White.copy(alpha = 0.10f), Color.White.copy(alpha = 0.02f))
            )
        )

        // Vine rows
        val rows = Path()
        for (i in 0 until 10) {
            val startY = h * (0.37f + i * 0.047f)
            val endY = h * (0.23f + i * 0.020f)
            rows.moveTo(w * 0.45f, startY)
            rows.quadraticTo(w * (0.65f + i * 0.018f), h * 0.31f, w * 1.10f, endY)
        }
        for (i in 0 until 6) {
            val y = h * (0.26f + i * 0.055f)
            rows.moveTo(-w * 0.08f, y)
            rows.quadraticTo(w * 0.24f, y - h * 0.08f, w * 0.72f, h * (0.20f + i * 0.018f))
        }
        drawPath(rows, color = Color.White.copy(alpha = 0.10f), style = Stroke(width = 2f, cap = StrokeCap.Round))
    }
}
