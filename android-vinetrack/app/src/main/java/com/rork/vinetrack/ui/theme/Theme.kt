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
    tertiary = VineColors.EarthBrown,
    background = VineColors.AppBackgroundDark,
    surface = VineColors.CardBackgroundDark,
    error = VineColors.Destructive,
)

private val LightColorScheme = lightColorScheme(
    primary = VineColors.Primary,
    secondary = VineColors.LeafGreen,
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

private val VineTypography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = InterFontFamily),
        displayMedium = displayMedium.copy(fontFamily = InterFontFamily),
        displaySmall = displaySmall.copy(fontFamily = InterFontFamily),
        headlineLarge = headlineLarge.copy(fontFamily = InterFontFamily),
        headlineMedium = headlineMedium.copy(fontFamily = InterFontFamily, fontWeight = FontWeight.Bold),
        headlineSmall = headlineSmall.copy(fontFamily = InterFontFamily),
        titleLarge = titleLarge.copy(fontFamily = InterFontFamily, fontWeight = FontWeight.Bold),
        titleMedium = titleMedium.copy(fontFamily = InterFontFamily, fontWeight = FontWeight.SemiBold),
        titleSmall = titleSmall.copy(fontFamily = InterFontFamily),
        bodyLarge = bodyLarge.copy(fontFamily = InterFontFamily),
        bodyMedium = bodyMedium.copy(fontFamily = InterFontFamily),
        bodySmall = bodySmall.copy(fontFamily = InterFontFamily),
        labelLarge = labelLarge.copy(fontFamily = InterFontFamily, fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp),
        labelMedium = labelMedium.copy(fontFamily = InterFontFamily),
        labelSmall = labelSmall.copy(fontFamily = InterFontFamily),
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
