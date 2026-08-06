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
        if (!hasSelectedType) return "Select a pin type."
        if (latitude == null || longitude == null) return "A map location is required."
        return when (scope) {
            SCOPE_POINT -> null
            SCOPE_ROW -> when {
                paddockId == null -> "Select the block that owns the rows."
                ManualIssueContract.canonicalSegments(segments).isEmpty() -> "Select at least one row."
                else -> null
            }
            SCOPE_BLOCK -> if (paddockId == null) "Select a block." else null
            else -> "A map location is required."
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
