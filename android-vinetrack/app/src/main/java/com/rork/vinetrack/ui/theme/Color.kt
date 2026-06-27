package com.rork.vinetrack.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * VineTrack brand palette, mirrored from the iOS `VineyardTheme`.
 * Colours map directly from the SwiftUI `Color(red:green:blue:)` values.
 */
object VineColors {
    // Brand palette
    val LeafGreen = Color(0xFF5C8C4D)      // 0.36, 0.55, 0.30
    val BrandTrack = Color(0xFF85B830)     // wordmark "Track" green (iOS BrandColors.track)
    val DarkGreen = Color(0xFF33662E)      // 0.20, 0.40, 0.18
    val EarthBrown = Color(0xFF735238)     // 0.45, 0.32, 0.22
    val Olive = Color(0xFF7A8450)          // muted olive (iOS VineyardTheme.olive)
    val VineRed = Color(0xFF8C2E38)        // 0.55, 0.18, 0.22
    val Cream = Color(0xFFF7F2E0)          // 0.97, 0.95, 0.88
    val Stone = Color(0xFFC7BCA8)          // 0.78, 0.74, 0.66

    // Semantic (system blue accent, as in iOS)
    val Primary = Color(0xFF007AFF)
    val PrimaryAccent = LeafGreen
    val Success = LeafGreen
    val Warning = Color(0xFFFF9500)
    val Destructive = Color(0xFFFF3B30)
    val Info = Color(0xFF007AFF)
    val Indigo = Color(0xFF5856D6)
    val Cyan = Color(0xFF32ADE6)
    val Pink = Color(0xFFFF2D55)
    val Purple = Color(0xFFAF52DE)
    val Orange = Color(0xFFFF9500)

    // Login gradient (deep vineyard greens)
    val LoginTop = Color(0xFF0F6E33)       // 0.06, 0.43, 0.20
    val LoginMid = Color(0xFF064721)       // 0.02, 0.28, 0.13
    val LoginBottom = Color(0xFF032C17)    // 0.01, 0.17, 0.09
    val LoginPickerActive = Color(0xFF034D21) // 0.01, 0.30, 0.13

    // Light surfaces
    val AppBackgroundLight = Color(0xFFF2F2F7)
    val CardBackgroundLight = Color(0xFFFFFFFF)
    val GroupedCardLight = Color(0xFFFFFFFF)
    val TextPrimaryLight = Color(0xFF1A1A1A)
    val TextSecondaryLight = Color(0xFF6B6B70)
    val SeparatorLight = Color(0x33000000)

    // Dark surfaces
    val AppBackgroundDark = Color(0xFF000000)
    val CardBackgroundDark = Color(0xFF1C1C1E)
    val TextPrimaryDark = Color(0xFFF5F5F5)
    val TextSecondaryDark = Color(0xFF9A9AA0)
    val SeparatorDark = Color(0x33FFFFFF)
}
