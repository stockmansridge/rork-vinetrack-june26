package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Decorative tool identity; never used for map markers or semantic status. */
@Composable
fun BrightToolIcon(icon: ImageVector, colors: List<Color>, size: Dp = 44.dp) {
    val shape = RoundedCornerShape(size * 0.27f)
    Box(
        modifier = Modifier.size(size).clip(shape)
            .background(Brush.linearGradient(colors))
            .border(0.5.dp, Color.White.copy(alpha = 0.22f), shape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.46f))
    }
}
