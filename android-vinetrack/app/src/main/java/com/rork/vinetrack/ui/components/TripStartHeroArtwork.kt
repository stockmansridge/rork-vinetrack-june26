package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.withTransform

/**
 * Decorative Start Trip hero: a blue tractor between brighter green vine rows.
 * Drawn locally for offline use; no remote image or trip behaviour is involved.
 */
@Composable
fun TripStartHeroArtwork(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.fillMaxWidth()) {
        val blue = Color(0xFF1269D9)
        val lightBlue = Color(0xFF3D99F7)
        val darkBlue = Color(0xFF164B99)
        val brightGreen = Color(0xFF2DD448)
        val leafHighlight = Color(0xFF83EA3E)
        val stem = Color(0xFF8B633A)
        val tyre = Color(0xFF263543)
        val rim = Color(0xFFB7D6EF)

        // Work in a fixed coordinate system; the art scales to the available
        // sheet width without constraining the Start Trip layout.
        withTransform({
            scale(
                scaleX = size.width / 300f,
                scaleY = size.height / 120f,
                pivot = Offset.Zero,
            )
        }) {
            fun vine(cx: Float) {
                drawLine(stem, Offset(cx, 109f), Offset(cx, 20f), strokeWidth = 4f)
                for (row in 0..3) {
                    val y = 25f + row * 21f
                    drawOval(
                        brightGreen,
                        topLeft = Offset(cx - 34f, y - 12f),
                        size = Size(34f, 19f),
                    )
                    drawOval(
                        leafHighlight,
                        topLeft = Offset(cx + 2f, y - 12f),
                        size = Size(34f, 19f),
                    )
                }
            }

            vine(39f)
            vine(261f)

            // Rear wheel and main tractor body are layered for dimensionality.
            drawCircle(tyre, radius = 23f, center = Offset(132f, 92f))
            drawCircle(rim, radius = 11f, center = Offset(132f, 92f))
            drawCircle(darkBlue, radius = 5f, center = Offset(132f, 92f))
            drawRoundRect(
                color = blue,
                topLeft = Offset(113f, 57f),
                size = Size(91f, 31f),
                cornerRadius = CornerRadius(9f),
            )
            drawRoundRect(
                color = lightBlue,
                topLeft = Offset(143f, 28f),
                size = Size(43f, 38f),
                cornerRadius = CornerRadius(8f),
            )
            drawRoundRect(
                color = Color(0xFFD8EEFF),
                topLeft = Offset(151f, 34f),
                size = Size(27f, 23f),
                cornerRadius = CornerRadius(5f),
            )
            drawRoundRect(
                color = darkBlue,
                topLeft = Offset(178f, 48f),
                size = Size(43f, 34f),
                cornerRadius = CornerRadius(7f),
            )
            drawLine(darkBlue, Offset(200f, 49f), Offset(200f, 25f), strokeWidth = 5f)
            drawRoundRect(
                color = lightBlue,
                topLeft = Offset(207f, 55f),
                size = Size(21f, 12f),
                cornerRadius = CornerRadius(4f),
            )
            drawCircle(tyre, radius = 16f, center = Offset(215f, 93f))
            drawCircle(rim, radius = 8f, center = Offset(215f, 93f))
            drawCircle(darkBlue, radius = 3f, center = Offset(215f, 93f))
            drawLine(
                Color(0xFFB6C9D9),
                Offset(119f, 113f),
                Offset(233f, 113f),
                strokeWidth = 2f,
            )
        }
    }
}
