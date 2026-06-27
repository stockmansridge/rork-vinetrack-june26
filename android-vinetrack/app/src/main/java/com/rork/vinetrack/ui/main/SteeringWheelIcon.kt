package com.rork.vinetrack.ui.main

import androidx.compose.foundation.Canvas
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke

/**
 * Steering-wheel tab glyph drawn on a [Canvas], mirroring the iOS `steeringwheel`
 * SF Symbol used for the Trip tab. Drawing it ourselves (rather than reaching for
 * a Material icon, which has no steering wheel) keeps it crisp at tab size and
 * lets it pick up the navigation bar's selected/unselected tint automatically via
 * [LocalContentColor].
 */
@Composable
fun SteeringWheelIcon(modifier: Modifier = Modifier) {
    val tint = LocalContentColor.current
    Canvas(modifier) {
        val side = size.minDimension
        val center = Offset(size.width / 2f, size.height / 2f)
        val ring = side / 2f * 0.92f
        val stroke = side * 0.085f
        val hub = side * 0.13f

        // Outer rim.
        drawCircle(color = tint, radius = ring, center = center, style = Stroke(width = stroke))
        // Centre hub.
        drawCircle(color = tint, radius = hub, center = center)
        // Three spokes (left, right, down) from the hub to the rim.
        val edge = ring - stroke / 2f
        drawLine(tint, Offset(center.x + hub, center.y), Offset(center.x + edge, center.y), strokeWidth = stroke)
        drawLine(tint, Offset(center.x - hub, center.y), Offset(center.x - edge, center.y), strokeWidth = stroke)
        drawLine(tint, Offset(center.x, center.y + hub), Offset(center.x, center.y + edge), strokeWidth = stroke)
    }
}
