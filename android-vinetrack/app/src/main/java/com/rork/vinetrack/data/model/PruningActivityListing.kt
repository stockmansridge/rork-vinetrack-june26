package com.rork.vinetrack.data.model

/**
 * How a multi-block pruning activity is PRESENTED in a list — one row per
 * parent activity, never one row per block.
 *
 * Shared, pure and identical to the iOS `PruningActivityListing`, so the
 * Tracker history, the mobile Activity Report and the editor summary can never
 * label the same activity differently.
 */
object PruningActivityListing {

    /**
     * The compact block label of one activity:
     *  * one block  → "Cab Franc"
     *  * two blocks → "Cab Franc + Sauv Blanc"
     *  * three+     → "Cab Franc + Sauv Blanc +2 more"
     */
    fun blockLabel(names: List<String>): String {
        val clean = names.map { it.trim().ifBlank { "Block" } }.distinct()
        return when {
            clean.isEmpty() -> "No blocks"
            clean.size <= 2 -> clean.joinToString(" + ")
            else -> clean.take(2).joinToString(" + ") + " +${clean.size - 2} more"
        }
    }

    /**
     * True when a free-text search matches the activity: ANY allocation
     * matching is a match for the whole parent record.
     */
    fun matches(
        query: String,
        blockNames: List<String>,
        worker: String,
        notes: String,
        rowLabels: List<String>,
    ): Boolean {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return true
        val haystack = (blockNames + worker + notes + rowLabels).joinToString(" ").lowercase()
        return haystack.contains(needle)
    }

    /** "42–44, 66–67" — contiguous runs of the rows an allocation covered. */
    fun rowRangeLabel(rows: List<Int>): String {
        if (rows.isEmpty()) return "—"
        val sorted = rows.distinct().sorted()
        val parts = mutableListOf<String>()
        var start = sorted.first()
        var previous = start
        for (row in sorted.drop(1)) {
            if (row == previous + 1) {
                previous = row
                continue
            }
            parts.add(if (start == previous) "$start" else "$start–$previous")
            start = row
            previous = row
        }
        parts.add(if (start == previous) "$start" else "$start–$previous")
        return parts.joinToString(", ")
    }
}

/** One quarter a write could not attribute, with the block it belongs to. */
data class PruningQuarterConflict(
    val paddockId: String?,
    val blockName: String = "",
    val row: Int? = null,
    val quarter: Int? = null,
    val reason: String? = null,
) {
    val label: String get() = "Row ${row ?: "?"} · q${quarter ?: "?"}"
}

/**
 * The reconciliation result of ONE activity write (sql/166). A save is never
 * reported as fully successful while conflicts exist: the user is told exactly
 * how many quarters landed, how many were already recorded elsewhere, and which
 * blocks to open to review them.
 */
data class PruningActivityReconciliation(
    val activityId: String,
    val blockSummary: String,
    val quartersRequested: Int = 0,
    val quartersRecorded: Int = 0,
    val conflicts: List<PruningQuarterConflict> = emptyList(),
    val seasonYear: Int? = null,
    val vintageYear: Int? = null,
    val workTaskConflict: Boolean = false,
    val isReversal: Boolean = false,
    val quartersReleased: Int = 0,
    val isStale: Boolean = false,
    val error: String? = null,
) {
    val quartersConflicted: Int get() = conflicts.size

    val hasConflicts: Boolean get() = conflicts.isNotEmpty()

    /** Blocks the user can open to review refused quarters. */
    val conflictBlockIds: List<String> get() = conflicts.mapNotNull { it.paddockId }.distinct()

    fun conflicts(paddockId: String): List<PruningQuarterConflict> =
        conflicts.filter { it.paddockId == paddockId }

    /** Only a clean, acknowledged write counts as fully synced. */
    val isFullySynced: Boolean get() = error == null && !isStale && !hasConflicts

    val headline: String
        get() = when {
            error != null -> "Activity not saved yet"
            isReversal -> "Activity reversed"
            hasConflicts -> "Activity saved with conflicts"
            else -> "Activity saved"
        }

    val detail: String
        get() {
            if (error != null) {
                return "Queued — the server hasn't confirmed this activity yet. It will retry automatically."
            }
            if (isReversal) {
                return "$quartersReleased ${quarterWord(quartersReleased)} reopened across $blockSummary."
            }
            val parts = mutableListOf("$quartersRecorded ${quarterWord(quartersRecorded)} recorded")
            if (hasConflicts) {
                val blocks = conflicts.map { it.blockName.ifBlank { "another block" } }.distinct()
                parts.add(
                    "$quartersConflicted ${quarterWord(quartersConflicted)} " +
                        "were already recorded elsewhere (${blocks.joinToString(", ")})"
                )
            }
            if (workTaskConflict) parts.add("the Work Task link is already used by another activity")
            return parts.joinToString(" · ") + "."
        }

    private fun quarterWord(count: Int): String = if (count == 1) "quarter" else "quarters"
}
