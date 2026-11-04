package com.rork.vinetrack.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.R

/** Extra brand surface colours not covered by Material's ColorScheme. */
data class VineExtraColors(
    val appBackground: Color,
    val cardBackground: Color,
    val cardBorder: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val isDark: Boolean,
)

val LocalVineColors = staticCompositionLocalOf {
    VineExtraColors(
        appBackground = VineColors.AppBackgroundLight,
        cardBackground = VineColors.CardBackgroundLight,
        cardBorder = VineColors.SeparatorLight,
        textPrimary = VineColors.TextPrimaryLight,
        textSecondary = VineColors.TextSecondaryLight,
        isDark = false,
    )
}

private val DarkColorScheme = darkColorScheme(
    primary = VineColors.Primary,
    secondary = VineColors.LeafGreen,
    // Selected FilterChip / SegmentedButton use secondaryContainer: route them
    // through the shared action blue so no screen shows the default lavender.
    secondaryContainer = Color(0xFF1B3A5E),
    onSecondaryContainer = Color(0xFF7AB8FF),
    tertiary = VineColors.EarthBrown,
    background = VineColors.AppBackgroundDark,
    surface = VineColors.CardBackgroundDark,
    error = VineColors.Destructive,
)

private val LightColorScheme = lightColorScheme(
    primary = VineColors.Primary,
    secondary = VineColors.LeafGreen,
    secondaryContainer = Color(0xFFD6E8FF),
    onSecondaryContainer = Color(0xFF0050A8),
    tertiary = VineColors.EarthBrown,
    background = VineColors.AppBackgroundLight,
    surface = VineColors.CardBackgroundLight,
    error = VineColors.Destructive,
)

/**
 * Inter — the open-source typeface metrically closest to Apple's SF Pro.
 * Bundled statics cover the four weights the app uses; other weights
 * resolve to the nearest bundled file.
 */
val InterFontFamily = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
    Font(R.font.inter_bold, FontWeight.Bold),
)

/**
 * SF-style type ramp using the existing licensed Inter assets on Android.
 * Keep font scaling accessible (sp) and use semantic Material roles instead
 * of platform-restricted Apple font files or absolute pixel sizing.
 */
private val VineTypography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = InterFontFamily, fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
        displayMedium = displayMedium.copy(fontFamily = InterFontFamily, fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
        displaySmall = displaySmall.copy(fontFamily = InterFontFamily, fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
        headlineLarge = headlineLarge.copy(fontFamily = InterFontFamily, fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
        headlineMedium = headlineMedium.copy(fontFamily = InterFontFamily, fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
        headlineSmall = headlineSmall.copy(fontFamily = InterFontFamily, fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
        titleLarge = titleLarge.copy(fontFamily = InterFontFamily, fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
        titleMedium = titleMedium.copy(fontFamily = InterFontFamily, fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
        titleSmall = titleSmall.copy(fontFamily = InterFontFamily, fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
        bodyLarge = bodyLarge.copy(fontFamily = InterFontFamily, fontSize = 17.sp, lineHeight = 23.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
        bodyMedium = bodyMedium.copy(fontFamily = InterFontFamily, fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
        bodySmall = bodySmall.copy(fontFamily = InterFontFamily, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
        labelLarge = labelLarge.copy(fontFamily = InterFontFamily, fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
        labelMedium = labelMedium.copy(fontFamily = InterFontFamily, fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.sp),
        labelSmall = labelSmall.copy(fontFamily = InterFontFamily, fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.sp),
    )
}

@Composable
fun AppTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val extra = if (darkTheme) {
        VineExtraColors(
            appBackground = VineColors.AppBackgroundDark,
            cardBackground = VineColors.CardBackgroundDark,
            cardBorder = VineColors.SeparatorDark,
            textPrimary = VineColors.TextPrimaryDark,
            textSecondary = VineColors.TextSecondaryDark,
            isDark = true,
        )
    } else {
        VineExtraColors(
            appBackground = VineColors.AppBackgroundLight,
            cardBackground = VineColors.CardBackgroundLight,
            cardBorder = VineColors.SeparatorLight,
            textPrimary = VineColors.TextPrimaryLight,
            textSecondary = VineColors.TextSecondaryLight,
            isDark = false,
        )
    }

    CompositionLocalProvider(LocalVineColors provides extra) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = VineTypography,
            content = content
        )
    }
}
