package com.rork.vinetrack.ui.screens

import androidx.compose.ui.graphics.Color
import com.rork.vinetrack.data.PinCategoryCatalog
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Shared pin colour resolution used across the Pins map, list and stats views.
 *
 * Repairs pins follow the canonical category colour contract
 * ([PinCategoryCatalog], mirrored 1:1 by iOS `PinCategoryCatalog.swift`): the
 * colour is derived deterministically from the pin's stable category id, so
 * two "Vine Issue" pins can never render in different colours across devices
 * or platforms. Unknown / missing categories (including historical records)
 * render as the neutral unassigned gray — never another category's colour.
 *
 * Growth observations keep their observation accents (stored colour → button
 * configuration → leaf green) and manual issues keep the amber accent, since
 * those record types are not part of the repairs category catalogue.
 */

/** Colour tokens shared by the editor and resolver — must all be handled by [launcherColor]. */
internal val launcherColorTokens: List<String> = listOf(
    "blue", "brown", "green", "darkgreen", "red", "gray",
    "yellow", "orange", "purple", "pink", "cyan", "indigo",
)

/** Repairs accent (wine red) and Growth accent (leaf green) — iOS observation parity. */
internal val RepairColor = VineColors.VineRed
internal val GrowthColor = VineColors.LeafGreen

/**
 * Manual Issue accent (amber). Deliberately distinct from the repairs red,
 * growth green, and completed/healthy tints so a manual issue is never
 * mistaken for another record type. The create RPC also stamps
 * button_color='orange' on the row, so this fallback rarely fires.
 */
internal val ManualIssueColor = VineColors.Orange

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
internal fun pinModeColor(mode: String?): Color = when {
    mode?.contains("manual", ignoreCase = true) == true -> ManualIssueColor
    mode?.contains("growth", ignoreCase = true) == true -> GrowthColor
    else -> RepairColor
}

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
 * Resolve a pin's display colour.
 *
 * Repairs pins: canonical category contract — colour derived from the stable
 * category id ([PinCategoryCatalog.canonicalId] over `category`, then
 * `button_name`, then `title`). Never from the editable button configuration
 * or an arbitrary stored colour token, so every device renders the same
 * category identically. Unknown/missing → unassigned gray, never a crash.
 *
 * Growth pins: stored colour → launcher configuration → leaf green accent.
 * Manual issues: fixed amber accent.
 */
internal fun pinColor(pin: Pin, colorMap: Map<String, String>): Color {
    val mode = pin.mode
    return when {
        mode?.contains("manual", ignoreCase = true) == true -> ManualIssueColor
        mode?.contains("growth", ignoreCase = true) == true -> {
            pin.buttonColor?.trim()?.takeIf { it.isNotBlank() }?.let { return launcherColor(it) }
            val token = pin.buttonName?.takeIf { it.isNotBlank() }?.let { colorMap[it] }
                ?: colorMap[pin.displayTitle]
            if (!token.isNullOrBlank()) launcherColor(token) else GrowthColor
        }
        else -> launcherColor(
            PinCategoryCatalog.colorTokenForRaw(
                pin.category?.takeIf { it.isNotBlank() }
                    ?: pin.buttonName?.takeIf { it.isNotBlank() }
                    ?: pin.title,
            ),
        )
    }
}
