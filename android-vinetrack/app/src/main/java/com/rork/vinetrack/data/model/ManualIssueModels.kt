package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Manual Issue contract — categories, priorities, statuses, location scopes,
 * row segments, validation, and marker derivation.
 *
 * A manual issue is a lightweight, manually created issue / action / planning
 * marker for a point, a row selection, or a whole block. It never creates a
 * repair, growth observation, Work Task, labour, cost, machinery or pruning
 * record. This file is pure logic (no I/O) and mirrors
 * `ManualIssueModels.swift` on iOS exactly — the parity tests on both
 * platforms assert the same fixture values.
 */

object ManualIssueCategories {
    const val GENERAL = "general"
    const val ACTION_REQUIRED = "action_required"
    const val INSPECTION = "inspection"
    const val PLANNING = "planning"
    const val INFRASTRUCTURE = "infrastructure"
    const val VINE_OR_ROW = "vine_or_row"
    const val SAFETY = "safety"
    const val OTHER = "other"

    val all: List<String> = listOf(
        GENERAL, ACTION_REQUIRED, INSPECTION, PLANNING,
        INFRASTRUCTURE, VINE_OR_ROW, SAFETY, OTHER,
    )

    fun label(value: String): String = when (value) {
        GENERAL -> "General"
        ACTION_REQUIRED -> "Action required"
        INSPECTION -> "Inspection"
        PLANNING -> "Planning"
        INFRASTRUCTURE -> "Infrastructure"
        VINE_OR_ROW -> "Vine or row issue"
        SAFETY -> "Safety"
        OTHER -> "Other"
        else -> "General"
    }
}

object ManualIssuePriorities {
    const val LOW = "low"
    const val NORMAL = "normal"
    const val HIGH = "high"
    const val URGENT = "urgent"

    val all: List<String> = listOf(LOW, NORMAL, HIGH, URGENT)

    fun label(value: String): String = when (value) {
        LOW -> "Low"
        NORMAL -> "Normal"
        HIGH -> "High"
        URGENT -> "Urgent"
        else -> "Normal"
    }

    /** Urgent first when sorting lists by priority. */
    fun sortOrder(value: String): Int = when (value) {
        URGENT -> 0
        HIGH -> 1
        NORMAL -> 2
        LOW -> 3
        else -> 2
    }
}

object ManualIssueStatuses {
    const val OPEN = "open"
    const val IN_PROGRESS = "in_progress"
    const val COMPLETED = "completed"
    const val CANCELLED = "cancelled"

    val all: List<String> = listOf(OPEN, IN_PROGRESS, COMPLETED, CANCELLED)

    fun label(value: String): String = when (value) {
        OPEN -> "Open"
        IN_PROGRESS -> "In progress"
        COMPLETED -> "Completed"
        CANCELLED -> "Cancelled"
        else -> "Open"
    }

    /** Statuses shown by the default map/list filter. */
    fun isActive(value: String): Boolean = value == OPEN || value == IN_PROGRESS
}

object ManualIssueScopes {
    const val POINT = "point"
    const val ROW = "row"
    const val BLOCK = "block"

    val all: List<String> = listOf(POINT, ROW, BLOCK)

    fun label(value: String): String = when (value) {
        POINT -> "Point"
        ROW -> "Rows"
        BLOCK -> "Whole block"
        else -> "Point"
    }
}

/**
 * One selected quarter of a block row — the same canonical shape as the
 * pruning tracker's segments (row number >= 1, segment/quarter 1–4). A whole
 * row is all four quarters.
 */
@Serializable
data class ManualIssueSegment(
    val row: Int,
    val segment: Int,
)

/** Canonical manual issue as returned by the sql/169 RPCs (`manual_issue_json`). */
@Serializable
data class ManualIssue(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String? = null,
    val title: String,
    val description: String? = null,
    val category: String = ManualIssueCategories.GENERAL,
    val priority: String = ManualIssuePriorities.NORMAL,
    val status: String = ManualIssueStatuses.OPEN,
    @SerialName("location_scope") val locationScope: String = ManualIssueScopes.POINT,
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("snapped_latitude") val snappedLatitude: Double? = null,
    @SerialName("snapped_longitude") val snappedLongitude: Double? = null,
    @SerialName("driving_row_number") val drivingRowNumber: Double? = null,
    @SerialName("pin_row_number") val pinRowNumber: Double? = null,
    @SerialName("pin_side") val pinSide: String? = null,
    @SerialName("along_row_distance_m") val alongRowDistanceM: Double? = null,
    @SerialName("snapped_to_row") val snappedToRow: Boolean = false,
    @SerialName("assigned_user_id") val assignedUserId: String? = null,
    @SerialName("due_date") val dueDate: String? = null,
    @SerialName("linked_work_task_id") val linkedWorkTaskId: String? = null,
    @SerialName("photo_path") val photoPath: String? = null,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("client_updated_at") val clientUpdatedAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("completed_at") val completedAt: String? = null,
    @SerialName("completed_by_user_id") val completedByUserId: String? = null,
    @SerialName("completed_by") val completedBy: String? = null,
    /**
     * Structured row selection — present (possibly empty) for row scope, null
     * otherwise. Authoritative over the marker coordinate.
     */
    val segments: List<ManualIssueSegment>? = null,
) {
    val isActive: Boolean get() = ManualIssueStatuses.isActive(status) && deletedAt == null

    /**
     * Customer-facing location line: row summary for row scope, "Whole block"
     * for block scope, attached-row wording for a snapped point.
     */
    val locationSummary: String
        get() = when (locationScope) {
            ManualIssueScopes.ROW -> ManualIssueContract.rowSelectionSummary(segments.orEmpty())
                .ifEmpty { "Rows" }
            ManualIssueScopes.BLOCK -> "Whole block"
            else -> ManualIssueContract.attachedRowLabel(drivingRowNumber, pinRowNumber, pinSide)
                ?: "Point on map"
        }
}

/** A simple (latitude, longitude) pair for the pure marker-derivation maths. */
data class ManualIssueLatLng(val latitude: Double, val longitude: Double)

/** Pure contract helpers shared by the composer, sync layer and tests. */
object ManualIssueContract {

    const val DEFAULT_CATEGORY = ManualIssueCategories.GENERAL
    const val DEFAULT_PRIORITY = ManualIssuePriorities.NORMAL
    const val DEFAULT_STATUS = ManualIssueStatuses.OPEN

    /**
     * De-duplicated segments sorted by (row, segment) — the canonical order
     * the server stores and returns.
     */
    fun canonicalSegments(segments: List<ManualIssueSegment>): List<ManualIssueSegment> =
        segments.toSet().sortedWith(compareBy({ it.row }, { it.segment }))

    /**
     * Client-side mirror of the server's `_manual_issue_validate` — returns a
     * user-facing error, or null when the draft is valid. The server remains
     * authoritative; this only enables inline form validation.
     */
    fun validationError(
        title: String,
        scope: String,
        latitude: Double?,
        longitude: Double?,
        paddockId: String?,
        segments: List<ManualIssueSegment>,
    ): String? {
        if (title.trim().isEmpty()) return "A title is required."
        if (latitude == null || longitude == null) return "A map location is required."
        return when (scope) {
            ManualIssueScopes.POINT -> null
            ManualIssueScopes.ROW -> when {
                paddockId == null -> "Select the block that owns the rows."
                canonicalSegments(segments).isEmpty() -> "Select at least one row."
                else -> null
            }
            ManualIssueScopes.BLOCK -> if (paddockId == null) "Select a block." else null
            else -> "A map location is required."
        }
    }

    /**
     * Midpoint of one row quarter: fraction (quarter − 0.5) / 4 along the row
     * line, by linear lat/lng interpolation. Quarter 1 starts at the row's
     * start point.
     */
    fun segmentMidpoint(
        rowStart: ManualIssueLatLng,
        rowEnd: ManualIssueLatLng,
        quarter: Int,
    ): ManualIssueLatLng {
        val fraction = (quarter.toDouble() - 0.5) / 4.0
        return ManualIssueLatLng(
            latitude = rowStart.latitude + (rowEnd.latitude - rowStart.latitude) * fraction,
            longitude = rowStart.longitude + (rowEnd.longitude - rowStart.longitude) * fraction,
        )
    }

    /**
     * Representative marker for a row selection: the arithmetic mean of the
     * selected segment midpoints. The structured selection stays
     * authoritative — this is only where the map pin is drawn. Rows missing
     * from [rowLines] are skipped; null when no selected row has geometry.
     */
    fun markerCoordinate(
        segments: List<ManualIssueSegment>,
        rowLines: Map<Int, Pair<ManualIssueLatLng, ManualIssueLatLng>>,
    ): ManualIssueLatLng? {
        val canonical = canonicalSegments(segments)
        var latSum = 0.0
        var lonSum = 0.0
        var count = 0
        for (segment in canonical) {
            val line = rowLines[segment.row] ?: continue
            val mid = segmentMidpoint(line.first, line.second, segment.segment)
            latSum += mid.latitude
            lonSum += mid.longitude
            count += 1
        }
        if (count == 0) return null
        return ManualIssueLatLng(latSum / count, lonSum / count)
    }

    /**
     * Block marker: arithmetic mean of the boundary points (matches the
     * centroid used by the existing pin map surfaces).
     */
    fun blockCentroid(points: List<ManualIssueLatLng>): ManualIssueLatLng? {
        if (points.isEmpty()) return null
        return ManualIssueLatLng(
            latitude = points.sumOf { it.latitude } / points.size,
            longitude = points.sumOf { it.longitude } / points.size,
        )
    }

    /**
     * Customer-facing summary of a row selection. Whole rows collapse into
     * compact ranges ("Rows 2–4"); partial rows list their sections
     * ("Row 5 (sections 1–2)"). Whole rows come first, joined by " · ".
     * Must produce byte-identical output to the Swift mirror.
     */
    fun rowSelectionSummary(segments: List<ManualIssueSegment>): String {
        val canonical = canonicalSegments(segments)
        if (canonical.isEmpty()) return ""
        val byRow = canonical.groupBy({ it.row }, { it.segment }).mapValues { it.value.toSet() }
        val wholeRows = byRow.filterValues { it.size == 4 }.keys.sorted()
        val partialRows = byRow.filterValues { it.size < 4 }.keys.sorted()

        val parts = mutableListOf<String>()
        if (wholeRows.isNotEmpty()) {
            val ranges = mutableListOf<String>()
            var start = wholeRows[0]
            var prev = wholeRows[0]
            for (row in wholeRows.drop(1)) {
                if (row == prev + 1) {
                    prev = row
                } else {
                    ranges.add(if (start == prev) "$start" else "$start–$prev")
                    start = row
                    prev = row
                }
            }
            ranges.add(if (start == prev) "$start" else "$start–$prev")
            val label = if (wholeRows.size == 1) "Row" else "Rows"
            parts.add("$label ${ranges.joinToString(", ")}")
        }
        for (row in partialRows) {
            val quarters = byRow[row].orEmpty().sorted()
            val contiguous = quarters.size > 1 && quarters.last() - quarters.first() == quarters.size - 1
            val sections = if (contiguous) {
                "${quarters.first()}–${quarters.last()}"
            } else {
                quarters.joinToString(", ")
            }
            val label = if (quarters.size == 1) "section" else "sections"
            parts.add("Row $row ($label $sections)")
        }
        return parts.joinToString(" · ")
    }

    /**
     * Customer-facing wording for a snapped point: the pin is "on row 19.5"
     * while the exact path-row value stays intact in the data.
     */
    fun attachedRowLabel(drivingRowNumber: Double?, pinRowNumber: Double?, side: String?): String? {
        val row = drivingRowNumber ?: pinRowNumber ?: return null
        val rowText = if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()
        if (side == "Left" || side == "Right") {
            return "On row $rowText · ${side.lowercase()} side"
        }
        return "On row $rowText"
    }
}

/**
 * Arguments for `create_manual_issue`. Serial names match the RPC argument
 * names exactly; serializable so a queued offline create replays
 * byte-identically.
 */
@Serializable
data class ManualIssueCreateParams(
    @SerialName("p_id") val id: String,
    @SerialName("p_vineyard_id") val vineyardId: String,
    @SerialName("p_title") val title: String,
    @SerialName("p_location_scope") val locationScope: String,
    @SerialName("p_paddock_id") val paddockId: String? = null,
    @SerialName("p_description") val description: String? = null,
    @SerialName("p_category") val category: String = ManualIssueContract.DEFAULT_CATEGORY,
    @SerialName("p_priority") val priority: String = ManualIssueContract.DEFAULT_PRIORITY,
    @SerialName("p_latitude") val latitude: Double? = null,
    @SerialName("p_longitude") val longitude: Double? = null,
    @SerialName("p_snapped_latitude") val snappedLatitude: Double? = null,
    @SerialName("p_snapped_longitude") val snappedLongitude: Double? = null,
    @SerialName("p_driving_row_number") val drivingRowNumber: Double? = null,
    @SerialName("p_pin_row_number") val pinRowNumber: Double? = null,
    @SerialName("p_pin_side") val pinSide: String? = null,
    @SerialName("p_along_row_distance_m") val alongRowDistanceM: Double? = null,
    @SerialName("p_snapped_to_row") val snappedToRow: Boolean = false,
    @SerialName("p_assigned_user_id") val assignedUserId: String? = null,
    @SerialName("p_due_date") val dueDate: String? = null,
    @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    @SerialName("p_segments") val segments: List<ManualIssueSegment>? = null,
)

/**
 * Mirror of a manual issue as a shared map pin so it renders on every
 * existing pin surface (map, list, stats, exports) — it IS the same `pins`
 * row, same id. Null when the issue has no marker coordinate.
 */
fun ManualIssue.toMapPin(): Pin? {
    val lat = latitude ?: return null
    val lon = longitude ?: return null
    return Pin(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        title = title,
        category = category,
        buttonName = title,
        buttonColor = "orange",
        mode = "ManualIssue",
        notes = description,
        isCompleted = status == ManualIssueStatuses.COMPLETED,
        latitude = lat,
        longitude = lon,
        photoPath = photoPath,
        drivingRowNumber = drivingRowNumber,
        pinRowNumber = pinRowNumber,
        pinSide = pinSide,
        alongRowDistanceM = alongRowDistanceM,
        snappedLatitude = snappedLatitude,
        snappedLongitude = snappedLongitude,
        snappedToRow = snappedToRow,
        priority = priority,
        status = status,
        locationScope = locationScope,
        assignedUserId = assignedUserId,
        dueDate = dueDate,
        linkedWorkTaskId = linkedWorkTaskId,
        createdAt = createdAt,
        deletedAt = deletedAt,
        updatedAt = updatedAt,
        clientUpdatedAt = clientUpdatedAt,
        completedAt = completedAt,
        completedBy = completedBy,
    )
}

/** Arguments for `update_manual_issue` — same shape minus the vineyard id. */
@Serializable
data class ManualIssueUpdateParams(
    @SerialName("p_id") val id: String,
    @SerialName("p_title") val title: String,
    @SerialName("p_location_scope") val locationScope: String,
    @SerialName("p_paddock_id") val paddockId: String? = null,
    @SerialName("p_description") val description: String? = null,
    @SerialName("p_category") val category: String = ManualIssueContract.DEFAULT_CATEGORY,
    @SerialName("p_priority") val priority: String = ManualIssueContract.DEFAULT_PRIORITY,
    @SerialName("p_latitude") val latitude: Double? = null,
    @SerialName("p_longitude") val longitude: Double? = null,
    @SerialName("p_snapped_latitude") val snappedLatitude: Double? = null,
    @SerialName("p_snapped_longitude") val snappedLongitude: Double? = null,
    @SerialName("p_driving_row_number") val drivingRowNumber: Double? = null,
    @SerialName("p_pin_row_number") val pinRowNumber: Double? = null,
    @SerialName("p_pin_side") val pinSide: String? = null,
    @SerialName("p_along_row_distance_m") val alongRowDistanceM: Double? = null,
    @SerialName("p_snapped_to_row") val snappedToRow: Boolean = false,
    @SerialName("p_assigned_user_id") val assignedUserId: String? = null,
    @SerialName("p_due_date") val dueDate: String? = null,
    @SerialName("p_client_updated_at") val clientUpdatedAt: String,
    @SerialName("p_segments") val segments: List<ManualIssueSegment>? = null,
)
