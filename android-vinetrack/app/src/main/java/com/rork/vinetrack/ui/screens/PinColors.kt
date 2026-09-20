package com.rork.vinetrack.ui.screens

import androidx.compose.ui.graphics.Color
import com.rork.vinetrack.data.PinCategoryCatalog
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.theme.VineColors

/** Cross-platform token palette. Values mirror iOS `PinColorTokenContract` exactly. */
internal val pinColorHexByToken: Map<String, Long> = linkedMapOf(
    "red" to 0xFFFF3B30, "orange" to 0xFFFF9500, "yellow" to 0xFFFFCC00,
    "green" to 0xFF34C759, "darkgreen" to 0xFF1B7F3B, "mint" to 0xFF00C7BE,
    "teal" to 0xFF30B0C7, "cyan" to 0xFF32ADE6, "blue" to 0xFF007AFF,
    "indigo" to 0xFF5856D6, "purple" to 0xFFAF52DE, "pink" to 0xFFFF2D55,
    "brown" to 0xFFA2845E, "gray" to 0xFF8E8E93, "black" to 0xFF000000,
    "white" to 0xFFFFFFFF,
)

internal val launcherColorTokens: List<String> = pinColorHexByToken.keys.toList()
internal val RepairColor: Color = launcherColor("red")
internal val GrowthColor: Color = launcherColor("darkgreen")
internal val ManualIssueColor: Color = launcherColor("orange")

internal fun normalizedPinColorToken(token: String?): String? {
    val normalized = token?.trim()?.lowercase()?.let { if (it == "grey") "gray" else it }
    return normalized?.takeIf { it in pinColorHexByToken }
}

/** Configurable pin colours never use brand or platform-native colour values. */
internal fun launcherColor(token: String): Color =
    Color(pinColorHexByToken[normalizedPinColorToken(token)] ?: pinColorHexByToken.getValue("gray"))

internal fun pinModeColor(mode: String?): Color = when {
    mode?.contains("manual", ignoreCase = true) == true -> ManualIssueColor
    mode?.contains("growth", ignoreCase = true) == true -> GrowthColor
    else -> RepairColor
}

private fun normalizedName(value: String?): String? =
    value?.trim()?.lowercase()?.takeIf { it.isNotBlank() }

/** Vineyard-scoped authoritative launcher configuration used by every Pins surface. */
internal data class PinColorConfiguration(
    val vineyardId: String?,
    val repairButtons: List<LauncherButton>,
    val growthButtons: List<LauncherButton>,
) {
    fun tokenForName(name: String?): String? {
        val normalized = normalizedName(name) ?: return null
        return (repairButtons + growthButtons).firstOrNull {
            normalizedName(it.name) == normalized
        }?.color?.let(::normalizedPinColorToken)
    }
}

internal fun pinColorMap(state: AppUiState): PinColorConfiguration = PinColorConfiguration(
    vineyardId = state.selectedVineyardId,
    repairButtons = state.repairButtons,
    growthButtons = state.growthButtons,
)

/**
 * Resolve current configured colour, then legacy snapshot, then canonical/mode fallback.
 * Stable id wins; canonical repair id and normalized name keep legacy rows compatible.
 */
internal fun pinColorToken(pin: Pin, configuration: PinColorConfiguration): String {
    if (pin.mode?.contains("manual", ignoreCase = true) == true) {
        return normalizedPinColorToken(pin.buttonColor) ?: "orange"
    }
    val sameVineyard = configuration.vineyardId?.equals(pin.vineyardId, ignoreCase = true) == true
    val buttons = if (pin.mode?.contains("growth", ignoreCase = true) == true) {
        configuration.growthButtons
    } else {
        configuration.repairButtons
    }
    if (sameVineyard) {
        pin.launcherButtonId?.let { id ->
            buttons.firstOrNull { it.id == id }?.color?.let(::normalizedPinColorToken)?.let { return it }
        }
        val rawName = pin.category?.takeIf { it.isNotBlank() }
            ?: pin.buttonName?.takeIf { it.isNotBlank() }
            ?: pin.title
        PinCategoryCatalog.canonicalId(rawName)?.let { canonical ->
            buttons.firstOrNull { PinCategoryCatalog.canonicalId(it.name) == canonical }
                ?.color?.let(::normalizedPinColorToken)?.let { return it }
        }
        val normalized = normalizedName(pin.buttonName) ?: normalizedName(pin.displayTitle)
        buttons.firstOrNull { normalizedName(it.name) == normalized }
            ?.color?.let(::normalizedPinColorToken)?.let { return it }
    }
    normalizedPinColorToken(pin.buttonColor)?.let { return it }
    return if (pin.mode?.contains("growth", ignoreCase = true) == true) {
        "darkgreen"
    } else {
        PinCategoryCatalog.colorTokenForRaw(
            pin.category?.takeIf { it.isNotBlank() }
                ?: pin.buttonName?.takeIf { it.isNotBlank() }
                ?: pin.title,
        )
    }
}

internal fun pinColor(pin: Pin, configuration: PinColorConfiguration): Color =
    launcherColor(pinColorToken(pin, configuration))
