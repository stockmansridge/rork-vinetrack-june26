package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Vineyard-shared custom pin type (sql/170 `vineyard_custom_pin_types`).
 * Shared by every authorised user of the vineyard on iOS / Android / portal —
 * never device- or user-specific. Inactive items stay on historical pins but
 * are hidden from new selection.
 */
@Serializable
data class CustomPinType(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String,
    val color: String? = null,
    val icon: String? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/**
 * Arguments for `create_vineyard_custom_pin_type`. Serial names match the RPC
 * argument names exactly; serializable so an offline create replays
 * byte-identically with its stable client-generated id.
 */
@Serializable
data class CustomPinTypeCreateParams(
    @SerialName("p_id") val id: String,
    @SerialName("p_vineyard_id") val vineyardId: String,
    @SerialName("p_name") val name: String,
    @SerialName("p_color") val color: String? = null,
    @SerialName("p_icon") val icon: String? = null,
)

/**
 * Arguments for `create_custom_pin` (sql/170) — the simplified Custom-tab
 * save. Deliberately has no category / priority / assignee / due-date / side:
 * safe backend defaults apply and the creation UI never shows those fields.
 */
@Serializable
data class CustomPinCreateParams(
    @SerialName("p_id") val id: String,
    @SerialName("p_vineyard_id") val vineyardId: String,
    @SerialName("p_title") val title: String,
    @SerialName("p_location_scope") val locationScope: String,
    @SerialName("p_custom_type_id") val customTypeId: String? = null,
    @SerialName("p_paddock_id") val paddockId: String? = null,
    @SerialName("p_notes") val notes: String? = null,
    @SerialName("p_latitude") val latitude: Double? = null,
    @SerialName("p_longitude") val longitude: Double? = null,
    @SerialName("p_snapped_latitude") val snappedLatitude: Double? = null,
    @SerialName("p_snapped_longitude") val snappedLongitude: Double? = null,
    @SerialName("p_driving_row_number") val drivingRowNumber: Double? = null,
    @SerialName("p_pin_row_number") val pinRowNumber: Double? = null,
    @SerialName("p_along_row_distance_m") val alongRowDistanceM: Double? = null,
    @SerialName("p_snapped_to_row") val snappedToRow: Boolean = false,
    @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    @SerialName("p_segments") val segments: List<ManualIssueSegment>? = null,
)

/**
 * Pure contract for the unified "Add Pin / Action" composer, shared by the
 * composer UI, sync layer and tests. Mirrors `UnifiedPinContract.swift` on
 * iOS exactly — parity tests on both platforms assert the same values.
 *
 * The composer is location-first (point / row / block), then one of three
 * tabs in this exact order on every platform: Repair | Growth | Custom.
 * Left/Right side selection is not part of this workflow.
 */
object UnifiedPinContract {

    /** Tab ids in canonical display order — identical wording on iOS/Android/portal. */
    val TABS: List<String> = listOf("Repair", "Growth", "Custom")

    /** Location methods reuse the established scope ids from sql/169. */
    const val SCOPE_POINT = ManualIssueScopes.POINT
    const val SCOPE_ROW = ManualIssueScopes.ROW
    const val SCOPE_BLOCK = ManualIssueScopes.BLOCK

    /** Customer-facing Quick Action label — EXACT wording on iOS/Android/portal. */
    const val QUICK_ACTION_TITLE = "Manual Pin / Repair / Observation"

    /** Quick Action supporting text — identical on every platform. */
    const val QUICK_ACTION_SUBTITLE = "Drop a pin, select a row or select a block"

    /**
     * Shared semantic burgundy for the Quick Action card. iOS `VineyardTheme.burgundy`
     * and Android `VineColors.Burgundy` are both defined from this exact value so the
     * platforms cannot drift. Saved Repair/Growth/Custom pin colours are unaffected.
     */
    const val QUICK_ACTION_COLOR_HEX = "#800020"

    /** Darker companion used only as the card gradient's second stop. */
    const val QUICK_ACTION_COLOR_DARK_HEX = "#5C0017"

    /**
     * Minimum height (dp on Android, pt on iOS) of each of the three
     * location-choice controls — approximately double the original ~64 card.
     */
    const val METHOD_BUTTON_MIN_HEIGHT = 128

    /** Location-choice titles in canonical order — identical on both platforms. */
    val METHOD_TITLES: List<String> = listOf("Drop a pin manually", "Select a row", "Select a block")

    /** Location-choice subtitles, index-aligned with [METHOD_TITLES]. */
    val METHOD_SUBTITLES: List<String> = listOf(
        "Tap a point on the map — no block selection needed",
        "Tap rows or row sections — the block is detected automatically",
        "Flag a whole block",
    )

    /** The Growth tab's Growth Stage launcher — rendered exactly once, first. */
    const val GROWTH_STAGE_BUTTON = "Growth Stage"

    /** Colour token stored on growth-stage pins (matches the existing iOS pins). */
    const val GROWTH_STAGE_PIN_COLOR = "darkgreen"

    /** Shared validation wording — asserted verbatim by tests on both platforms. */
    const val ERROR_SELECT_TYPE = "Select a pin type."
    const val ERROR_LOCATION_REQUIRED = "A map location is required."
    const val ERROR_TAP_MAP = "Tap the map to place the pin."
    const val ERROR_SELECT_ROW = "Select at least one row."
    const val ERROR_SELECT_BLOCK = "Select a block."

    /** Safe message when selected row geometry can't be associated with a block. */
    const val ERROR_ROW_BLOCK = "Couldn't match the selected row to a block."

    /**
     * Title/button name stored on a growth-stage pin — the SAME identifier the
     * existing iOS growth-stage pin workflow stores (`Growth Stage {E-L code}`).
     */
    fun growthStagePinTitle(stageCode: String): String = "$GROWTH_STAGE_BUTTON $stageCode"

    /** Dedupe key for Repair/Growth catalogue tiles (left/right duplicates collapse). */
    fun catalogueKey(name: String, color: String?): String = name + "|" + (color ?: "")

    /**
     * The Growth tab's ordered items: Growth Stage exactly once (first), then the
     * existing catalogue names deduplicated — never a second stage list.
     */
    fun growthTabItems(existingNames: List<String>): List<String> =
        listOf(GROWTH_STAGE_BUTTON) +
            existingNames
                .filterNot { it.trim().equals(GROWTH_STAGE_BUTTON, ignoreCase = true) }
                .distinct()

    /**
     * Row-first selection: the user taps rows directly and the block is DERIVED
     * from the tapped row's geometry — never chosen through a block dropdown.
     * Tapping a row in a different block switches the derived block and starts a
     * fresh selection (a pin belongs to exactly one block); tapping within the
     * current block toggles the tapped segments.
     */
    fun applyRowTap(
        currentBlockId: String?,
        tappedBlockId: String,
        currentSegments: Set<ManualIssueSegment>,
        tappedSegments: Set<ManualIssueSegment>,
    ): Pair<String, Set<ManualIssueSegment>> {
        if (currentBlockId != tappedBlockId) return tappedBlockId to tappedSegments
        val allSelected = tappedSegments.isNotEmpty() && currentSegments.containsAll(tappedSegments)
        return tappedBlockId to if (allSelected) currentSegments - tappedSegments else currentSegments + tappedSegments
    }

    /**
     * Validation shared by all three tabs. Point never requires a block; row
     * requires a block plus at least one segment; block requires a block.
     * Identical rules across iOS, Android and the portal contract.
     */
    fun validationError(
        scope: String,
        hasSelectedType: Boolean,
        latitude: Double?,
        longitude: Double?,
        paddockId: String?,
        segments: List<ManualIssueSegment>,
    ): String? {
        if (!hasSelectedType) return ERROR_SELECT_TYPE
        if (latitude == null || longitude == null) return ERROR_LOCATION_REQUIRED
        return when (scope) {
            SCOPE_POINT -> null
            SCOPE_ROW -> when {
                ManualIssueContract.canonicalSegments(segments).isEmpty() -> ERROR_SELECT_ROW
                paddockId == null -> ERROR_ROW_BLOCK
                else -> null
            }
            SCOPE_BLOCK -> if (paddockId == null) ERROR_SELECT_BLOCK else null
            else -> ERROR_LOCATION_REQUIRED
        }
    }

    /** Trimmed custom item name; null when blank (blank names are rejected). */
    fun normalizeCustomTypeName(name: String): String? =
        name.trim().takeIf { it.isNotEmpty() }

    /**
     * True when [name] duplicates an existing ACTIVE item using trimmed,
     * case-insensitive comparison — the same rule the server enforces.
     */
    fun isDuplicateCustomTypeName(name: String, existing: List<CustomPinType>): Boolean {
        val normalized = normalizeCustomTypeName(name)?.lowercase() ?: return false
        return existing.any { it.isActive && it.name.trim().lowercase() == normalized }
    }
}
