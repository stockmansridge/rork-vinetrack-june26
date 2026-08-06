package com.rork.vinetrack.data.model

/**
 * Resolved placement for one pin under the canonical assignment rules
 * (sql/171 `pin_placements`). Produced by [PinPlacementContract.resolve] —
 * the client mirror of the server-authoritative contract, used for offline
 * caches and optimistic records where the server fields aren't present yet.
 */
data class PinPlacement(
    /**
     * Effective location scope: "point" / "row" / "block", or null when the
     * pin has genuinely no usable location. Derived for legacy pins saved
     * before `location_scope` existed.
     */
    val locationScope: String?,
    /** One of the [PinPlacementContract] BASIS_* values. */
    val basis: String,
    /** True unless the basis is [PinPlacementContract.BASIS_UNASSIGNED]. */
    val isAssigned: Boolean,
    /**
     * Null for any valid point / row / block assignment;
     * [PinPlacementContract.WARNING_METADATA_INCOMPLETE] when a stored
     * scope's structured data is missing but a safe fallback assignment
     * exists (never the amber warning);
     * [PinPlacementContract.WARNING_UNASSIGNED] only when nothing usable
     * exists.
     */
    val warningCode: String?,
    /** Segment-derived display summary ("Rows 41–43"), null without segments. */
    val rowSummary: String?,
    val hasRowSegments: Boolean,
)

/**
 * Pure client mirror of the sql/171 canonical pin placement contract.
 * Shared by lists, detail panels, map callouts and exports so the same pin
 * always resolves to the same placement everywhere. Mirrors
 * `PinPlacementContract` in the iOS app — outputs must match exactly.
 */
object PinPlacementContract {

    // Assignment basis (sql/171 `location_assignment_basis`).
    const val BASIS_POINT_COORDINATES = "point_coordinates"
    const val BASIS_SNAPPED_POINT = "snapped_point"
    const val BASIS_ROW_SEGMENTS = "row_segments"
    const val BASIS_BLOCK = "block"
    const val BASIS_LEGACY_BLOCK = "legacy_block"
    const val BASIS_UNASSIGNED = "unassigned"

    // Warning codes (sql/171 `location_warning_code`).
    const val WARNING_UNASSIGNED = "unassigned_location"
    const val WARNING_METADATA_INCOMPLETE = "location_metadata_incomplete"

    /**
     * Wording for the strong amber state — shown ONLY when a pin genuinely
     * has no usable location ([WARNING_UNASSIGNED]).
     */
    const val UNASSIGNED_LOCATION_LABEL = "Unassigned location"

    /** Wording for a valid point assignment that has no block association. */
    const val POINT_LOCATION_LABEL = "Point location"

    /**
     * Resolves the canonical placement. Must stay logic-identical to the
     * sql/171 `pin_placements` view and the Swift mirror.
     *
     * @param storedScope the pin's stored `location_scope`, if any.
     * @param hasBlock `paddock_id` present.
     * @param segments live row segments (`pin_row_segments`).
     * @param hasCoordinates a valid marker coordinate exists.
     * @param snappedToRow confident row snap recorded.
     * @param hasRowValues any of pin_row_number / driving_row_number /
     *   legacy row_number present on the base pin row.
     */
    fun resolve(
        storedScope: String?,
        hasBlock: Boolean,
        segments: List<ManualIssueSegment>,
        hasCoordinates: Boolean,
        snappedToRow: Boolean,
        hasRowValues: Boolean,
    ): PinPlacement {
        val hasSegments = segments.isNotEmpty()
        val scopeStored = storedScope == "point" || storedScope == "row" || storedScope == "block"

        val effectiveScope: String? = when {
            scopeStored -> storedScope
            hasSegments -> "row"
            hasBlock && hasRowValues -> "point"
            hasBlock -> "block"
            hasCoordinates -> "point"
            else -> null
        }

        val basis: String = when (effectiveScope) {
            "row" -> when {
                hasBlock && hasSegments -> BASIS_ROW_SEGMENTS
                hasCoordinates && (snappedToRow || hasRowValues) -> BASIS_SNAPPED_POINT
                hasCoordinates -> BASIS_POINT_COORDINATES
                hasBlock -> BASIS_BLOCK
                else -> BASIS_UNASSIGNED
            }
            "block" -> when {
                hasBlock -> if (scopeStored) BASIS_BLOCK else BASIS_LEGACY_BLOCK
                hasCoordinates -> BASIS_POINT_COORDINATES
                else -> BASIS_UNASSIGNED
            }
            "point" -> when {
                hasCoordinates && (snappedToRow || (hasBlock && hasRowValues)) -> BASIS_SNAPPED_POINT
                hasCoordinates -> BASIS_POINT_COORDINATES
                else -> BASIS_UNASSIGNED
            }
            else -> BASIS_UNASSIGNED
        }

        val warning: String? = when {
            basis == BASIS_UNASSIGNED -> WARNING_UNASSIGNED
            scopeStored && effectiveScope == "row" && basis != BASIS_ROW_SEGMENTS ->
                WARNING_METADATA_INCOMPLETE
            scopeStored && effectiveScope == "block" && basis != BASIS_BLOCK ->
                WARNING_METADATA_INCOMPLETE
            else -> null
        }

        val summary = if (hasSegments) ManualIssueContract.rowSelectionSummary(segments) else ""
        return PinPlacement(
            locationScope = effectiveScope,
            basis = basis,
            isAssigned = basis != BASIS_UNASSIGNED,
            warningCode = warning,
            rowSummary = summary.ifEmpty { null },
            hasRowSegments = hasSegments,
        )
    }

    /**
     * Convenience resolution from a synced/cached [Pin]. Older cache entries
     * without embedded segments fall back safely under the same rules —
     * the block stays visible and the amber warning never appears for merely
     * incomplete optional row metadata.
     */
    fun placementFor(pin: Pin): PinPlacement = resolve(
        storedScope = pin.locationScope,
        hasBlock = pin.paddockId != null,
        segments = pin.rowSegments.orEmpty().map { ManualIssueSegment(it.rowNumber, it.segmentNumber) },
        hasCoordinates = pin.latitude != null && pin.longitude != null,
        snappedToRow = pin.snappedToRow,
        hasRowValues = pin.pinRowNumber != null || pin.drivingRowNumber != null || pin.rowNumber != null,
    )

    /**
     * The block/row context line shown under a pin in lists, detail panels
     * and callouts. A known block is NEVER hidden because a row value is
     * absent; [UNASSIGNED_LOCATION_LABEL] appears only for a genuinely
     * unassigned record. Must produce byte-identical output to the Swift
     * mirror.
     *
     * @param blockName resolved block display name, null when unknown.
     * @param placement canonical placement for the pin.
     * @param attachedRowText pre-formatted attached row ("15" / "19.5"),
     *   null when the pin has no row attachment.
     */
    fun blockContextLine(
        blockName: String?,
        placement: PinPlacement,
        attachedRowText: String?,
    ): String {
        val block = blockName?.takeIf { it.isNotEmpty() }
        return when (placement.basis) {
            BASIS_ROW_SEGMENTS -> {
                val summary = placement.rowSummary ?: "Rows"
                if (block != null) "$block — $summary" else summary
            }
            BASIS_SNAPPED_POINT -> when {
                block != null && attachedRowText != null -> "$block row $attachedRowText"
                block != null -> block
                attachedRowText != null -> "Row $attachedRowText"
                else -> POINT_LOCATION_LABEL
            }
            BASIS_BLOCK, BASIS_LEGACY_BLOCK -> block ?: "Block"
            // A point pin may still carry an inferred block — show it.
            BASIS_POINT_COORDINATES -> block ?: POINT_LOCATION_LABEL
            else -> UNASSIGNED_LOCATION_LABEL
        }
    }

    /**
     * Formats an attached row for display, trimming whole values (15) and
     * preserving exact fractional path rows (19.5) — never rounding.
     */
    fun attachedRowText(
        pinRowNumber: Double?,
        drivingRowNumber: Double?,
        legacyRowNumber: Int?,
    ): String? {
        val row = pinRowNumber ?: drivingRowNumber
        if (row != null) {
            return if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()
        }
        if (legacyRowNumber != null) return "$legacyRowNumber.5"
        return null
    }
}
