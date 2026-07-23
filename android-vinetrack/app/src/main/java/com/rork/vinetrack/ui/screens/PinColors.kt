package com.rork.vinetrack.ui.screens

import androidx.compose.ui.graphics.Color
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Shared pin colour resolution used across the Pins map, list and stats views so
 * a pin always shows in its *actual* configured colour (iOS `nameColorMap` /
 * `Color.fromString(pin.buttonColor)` parity), not a generic mode accent.
 *
 * The Android `Pin` model doesn't persist a colour, so — like iOS — the colour is
 * resolved by matching the pin's button name against the vineyard's launcher
 * button configuration. When no configured button matches, we fall back to the
 * mode accent so a colour is always available.
 */

/** Colour tokens shared by the editor and resolver — must all be handled by [launcherColor]. */
internal val launcherColorTokens: List<String> = listOf(
    "blue", "brown", "green", "darkgreen", "red", "gray",
    "yellow", "orange", "purple", "pink", "cyan", "indigo",
)

/** Repairs accent (wine red) and Growth accent (leaf green) — iOS observation parity. */
internal val RepairColor = VineColors.VineRed
internal val GrowthColor = VineColors.LeafGreen

/** Map an iOS `ButtonConfig.color` token to the matching Android brand colour. */
internal fun launcherColor(token: String): Color = when (token.trim().lowercase()) {
    "blue" -> VineColors.Primary
    "brown" -> VineColors.EarthBrown
    "green" -> VineColors.LeafGreen
    "darkgreen" -> VineColors.DarkGreen
    "red" -> VineColors.Destructive
    "gray", "grey" -> Color(0xFF8E8E93)
    "yellow" -> Color(0xFFE6B800)
    "orange" -> VineColors.Orange
    "purple" -> VineColors.Purple
    "pink" -> VineColors.Pink
    "cyan" -> VineColors.Cyan
    "indigo" -> VineColors.Indigo
    else -> VineColors.Primary
}

/** Mode-specific accent for a pin's stored `mode` raw value. */
internal fun pinModeColor(mode: String?): Color =
    if (mode?.contains("growth", ignoreCase = true) == true) GrowthColor else RepairColor

/**
 * Build a button-name → colour-token map from the vineyard's launcher button
 * configuration (iOS `nameColorMap` parity). First config wins per name.
 */
internal fun pinColorMap(state: AppUiState): Map<String, String> {
    val map = HashMap<String, String>()
    (state.repairButtons + state.growthButtons).forEach { cfg ->
        val name = cfg.name
        if (name.isNotBlank() && cfg.color.isNotBlank() && !map.containsKey(name)) {
            map[name] = cfg.color
        }
    }
    return map
}

/**
 * Resolve a pin's display colour. The stored `button_color` token (written at
 * drop time by both apps — iOS `Color.fromString(pin.buttonColor)` parity)
 * always wins; only when no colour was stored do we fall back to matching the
 * pin's button name against the vineyard's launcher configuration, then the
 * mode accent.
 */
internal fun pinColor(pin: Pin, colorMap: Map<String, String>): Color {
    pin.buttonColor?.trim()?.takeIf { it.isNotBlank() }?.let { return launcherColor(it) }
    val token = pin.buttonName?.takeIf { it.isNotBlank() }?.let { colorMap[it] }
        ?: colorMap[pin.displayTitle]
    return if (!token.isNullOrBlank()) launcherColor(token) else pinModeColor(pin.mode)
}
