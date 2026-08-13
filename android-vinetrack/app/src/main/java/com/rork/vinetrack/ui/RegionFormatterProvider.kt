package com.rork.vinetrack.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.RegionSettings

/**
 * The single authoritative region/unit formatting context for the whole Android
 * app.
 *
 * ## Why this exists
 *
 * The selected vineyard's Region & Units settings live in
 * [AppUiState.regionSettings] and are exposed as [AppUiState.regionFormatter].
 * That state was already correct — loaded from cache on vineyard selection,
 * refreshed from the backend, and replaced with the server's response on save —
 * but only a handful of screens actually *consumed* it. Every other screen
 * formatted with hardcoded literals such as `"%.2f ha"`, so a vineyard switched
 * to acres kept rendering hectares.
 *
 * Threading a `fmt` parameter through ~70 screens (and their private, deeply
 * nested row/card composables) is neither practical nor safe: every missed call
 * site silently keeps its hardcoded unit. A [staticCompositionLocalOf] instead
 * makes the vineyard's formatter reachable from *any* composable, so a nested
 * detail row can format correctly without its parent passing anything down.
 *
 * ## Scope rules
 *
 * - The value is derived ONLY from the active vineyard's `regionSettings`.
 *   Never from the device/system locale, never from a user-level preference,
 *   and never from a screen-level default.
 * - Because it is provided from [AppUiState], switching vineyard or saving new
 *   settings replaces the formatter and recomposes every consumer — no logout,
 *   no manual per-screen reload, and no leakage between vineyards.
 * - The default is the Australian baseline, which performs no conversion. It
 *   applies only before a vineyard is selected (login, vineyard chooser), so
 *   pre-settings paint matches historical behaviour exactly.
 *
 * Read it with [LocalRegionFormatter] `.current`, or via the [regionFormatter]
 * convenience accessor.
 */
val LocalRegionFormatter: ProvidableCompositionLocal<RegionFormatter> =
    staticCompositionLocalOf { RegionFormatter(RegionSettings.defaults) }

/**
 * Convenience accessor for [LocalRegionFormatter], so call sites read
 * `regionFormatter.formatArea(...)` instead of `LocalRegionFormatter.current`.
 */
val regionFormatter: RegionFormatter
    @Composable get() = LocalRegionFormatter.current

/**
 * Publishes [settings] as the app-wide formatting context.
 *
 * Installed once at the root so every route — including full-screen sheets and
 * dialogs, which compose in the same tree — inherits the active vineyard's
 * units. The formatter is [remember]ed on the settings value so recomposition
 * doesn't rebuild it on every frame, while a genuine settings change (save, or
 * vineyard switch) produces a new instance and refreshes all consumers.
 */
@Composable
fun ProvideRegionFormatter(
    settings: RegionSettings,
    content: @Composable () -> Unit,
) {
    val formatter = remember(settings) { RegionFormatter(settings) }
    CompositionLocalProvider(LocalRegionFormatter provides formatter, content = content)
}
