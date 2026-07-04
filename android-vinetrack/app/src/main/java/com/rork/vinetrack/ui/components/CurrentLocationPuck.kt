package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState

/** Google-Maps-style location blue. */
private val PuckBlue = Color(0xFF4285F4)

/**
 * Standard "where I am now" location puck: blue dot with a white ring and a
 * soft halo, plus a heading wedge when a GPS course is available. Used instead
 * of a pin marker so the live position is never confused with saved record
 * pins (matches the iOS `UserAnnotation()` puck).
 *
 * The marker is flat and rotated by [bearingDegrees], so the wedge points in
 * the direction of travel regardless of map orientation.
 */
@Composable
fun CurrentLocationPuck(
    state: MarkerState,
    bearingDegrees: Float?,
    zIndex: Float = 10f,
) {
    val hasHeading = bearingDegrees != null
    MarkerComposable(
        // Only two bitmap variants (with/without wedge); rotation is a marker
        // property, so heading changes never regenerate the bitmap.
        hasHeading,
        state = state,
        rotation = bearingDegrees ?: 0f,
        flat = true,
        anchor = Offset(0.5f, 0.5f),
        zIndex = zIndex,
    ) {
        Canvas(modifier = Modifier.size(46.dp)) {
            val c = center
            // Soft accuracy-style halo.
            drawCircle(color = PuckBlue.copy(alpha = 0.18f), radius = size.minDimension / 2f, center = c)
            if (hasHeading) {
                // Heading wedge pointing "up" (rotation aims it at the course).
                val tipY = c.y - size.minDimension / 2f + 3.dp.toPx()
                val wedge = Path().apply {
                    moveTo(c.x, tipY)
                    lineTo(c.x - 7.dp.toPx(), c.y - 9.dp.toPx())
                    lineTo(c.x + 7.dp.toPx(), c.y - 9.dp.toPx())
                    close()
                }
                drawPath(path = wedge, color = PuckBlue.copy(alpha = 0.85f))
            }
            // White ring + solid blue dot.
            drawCircle(color = Color.White, radius = 9.dp.toPx(), center = c)
            drawCircle(color = PuckBlue, radius = 6.5.dp.toPx(), center = c)
        }
    }
}
