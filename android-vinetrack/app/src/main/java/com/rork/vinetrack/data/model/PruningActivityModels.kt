package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.util.UUID

/**
 * MULTI-BLOCK PRUNING ACTIVITIES (sql/166) — the client twin of the backend
 * contract.
 *
 * A pruning activity is ONE piece of work: one crew, one date, one start and
 * finish time, one set of labour hours, one rate, one note, one linked Work
 * Task. It may cover ONE OR MANY blocks. The split is strict:
 *
 *  * ACTIVITY level ([PruningActivityDraft]) — vineyard, date, worker/crew,
 *    method, start/finish, duration, labour hours, hourly rate, notes, linked
 *    Work Task, creator, reversal state and sync identity.
 *  * ALLOCATION level ([BlockPruningSelection]) — block, season, rows,
 *    quarters, row equivalents and vines.
 *
 * Labour and timing exist EXACTLY ONCE on the parent and are never apportioned
 * or duplicated across blocks — not in the editor, not in the payload, not in
 * the offline draft.
 */

/** Deterministic allocation ids, byte-identical to `derive_pruning_allocation_id` (sql/166 §3). */
object PruningAllocationIds {
    fun make(activityId: String, paddockId: String): String {
        val name = "vinetrack-pruning-allocation|${activityId.lowercase()}|${paddockId.lowercase()}"
        return UUID.nameUUIDFromBytes(name.toByteArray(Charsets.UTF_8)).toString()
    }
}

/**
 * One block's contribution to an activity. Retains rows, quarters, row
 * equivalents and vines for THAT block only — never labour.
 */
@Serializable
data class BlockPruningSelection(
    val paddockId: String,
    /** Stable allocation id; derived from (activity, block) when absent. */
    val allocationId: String? = null,
    val blockName: String = "",
    /** The selected quarters — the canonical rows/quarters representation. */
    val segments: List<PruningSegment> = emptyList(),
    /** Client vine estimate for this block; the server re-attributes on sync. */
    val estimatedVines: Int = 0,
    /** Season the SERVER filed this allocation under (null until acknowledged). */
    val serverSeasonId: String? = null,
    val serverSeasonYear: Int? = null,
) {
    /** Distinct row numbers touched, ascending. */
    val rows: List<Int> get() = segments.map { it.row }.distinct().sorted()

    /** Quarters selected in this block. */
    val quarters: Int get() = segments.size

    /** A full row = 1.0, each quarter = 0.25. */
    val rowEquivalents: Double get() = segments.size / 4.0

    val isEmpty: Boolean get() = segments.isEmpty()

    /** Toggles one quarter, preserving every other selection in this block. */
    fun toggling(segment: PruningSegment): BlockPruningSelection =
        if (segments.contains(segment)) {
            copy(segments = segments.filterNot { it == segment })
        } else {
            copy(segments = segments + segment)
        }

    fun allocationIdFor(activityId: String): String =
        allocationId ?: PruningAllocationIds.make(activityId, paddockId)
}

/**
 * The editor's working state — a real parent activity plus a MAP of block
 * allocations keyed by block id. Switching blocks changes which allocation the
 * UI is editing; it never clears the others.
 */
@Serializable
data class PruningActivityDraft(
    /** Stable client-generated activity id — the idempotency key for retries. */
    val id: String,
    val vineyardId: String,
    /** ISO date, yyyy-MM-dd. The season of EVERY allocation derives from this. */
    val date: String,
    val worker: String = "",
    val method: String = "spur",
    /** Optional HH:mm times. */
    val startTime: String? = null,
    val finishTime: String? = null,
    /** ACTIVITY-level labour. Never split across blocks. */
    val labourHours: Double? = null,
    val hourlyRate: Double? = null,
    val notes: String = "",
    val workTaskId: String? = null,
    /** Every block allocation, keyed by block id. */
    val allocations: Map<String, BlockPruningSelection> = emptyMap(),
    /** The block currently open in the editor (UI focus only). */
    val focusedPaddockId: String? = null,
    val createdAtMs: Long = 0L,
    val updatedAtMs: Long = 0L,
    val enteredBy: String? = null,
    val reversedAtMs: Long = 0L,
    /** Set once the server has acknowledged this activity (sql/166 response). */
    val serverAcknowledged: Boolean = false,
    val serverSeasonYear: Int? = null,
    val vintageYear: Int? = null,
) {
    val isReversed: Boolean get() = reversedAtMs > 0L

    /** Allocations that actually contribute work, in stable block order. */
    val activeAllocations: List<BlockPruningSelection>
        get() = allocations.values.filterNot { it.isEmpty }.sortedBy { it.paddockId }

    val blockCount: Int get() = activeAllocations.size

    val totalQuarters: Int get() = activeAllocations.sumOf { it.quarters }

    val totalRowEquivalents: Double get() = totalQuarters / 4.0

    val totalEstimatedVines: Int get() = activeAllocations.sumOf { it.estimatedVines }

    /** "Cab Franc + Sauvignon Blanc" — the parent record's block summary. */
    val blockSummary: String
        get() = activeAllocations
            .map { it.blockName.ifBlank { "Block" } }
            .distinct()
            .joinToString(" + ")

    /** Hours between the recorded start and finish times (HH:mm). */
    val durationHours: Double?
        get() {
            val start = parseHhmmMinutes(startTime) ?: return null
            val finish = parseHhmmMinutes(finishTime) ?: return null
            val span = finish - start
            return if (span > 0) span / 60.0 else null
        }

    /** Labour cost of the WHOLE activity — counted once, never per block. */
    val labourCost: Double?
        get() {
            val hours = labourHours ?: return null
            val rate = hourlyRate ?: return null
            return hours * rate
        }

    /** The canonical pruning season year of every allocation (sql/161). */
    val seasonYear: Int get() = PruningSeasonIds.seasonYearFor(date)

    /** A saveable activity needs at least one block with at least one quarter. */
    val canSave: Boolean get() = activeAllocations.isNotEmpty()

    private fun parseHhmmMinutes(value: String?): Int? {
        val parts = value?.split(":") ?: return null
        if (parts.size < 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].take(2).toIntOrNull() ?: return null
        return hour * 60 + minute
    }

    companion object {
        fun new(
            vineyardId: String,
            date: LocalDate = LocalDate.now(),
            method: String = "spur",
            worker: String = "",
        ): PruningActivityDraft = PruningActivityDraft(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            date = date.toString(),
            worker = worker,
            method = method,
            createdAtMs = System.currentTimeMillis(),
        )

        /**
         * Opens an EXISTING single-block entry as an activity with exactly one
         * allocation. Nothing is recomputed: the date, worker, method, times,
         * labour, notes, task link, vines and reversal state come straight from
         * the stored record, and the entry's own id becomes the activity id —
         * exactly how sql/166 back-fills history.
         */
        fun fromLegacyEntry(entry: PruningEntry, blockName: String = ""): PruningActivityDraft =
            PruningActivityDraft(
                id = entry.id,
                vineyardId = entry.vineyardId,
                date = entry.date,
                worker = entry.worker,
                method = entry.method,
                startTime = entry.startTime,
                finishTime = entry.finishTime,
                labourHours = entry.labourHours,
                hourlyRate = null,
                notes = entry.notes,
                workTaskId = entry.workTaskId,
                allocations = mapOf(
                    entry.paddockId to BlockPruningSelection(
                        paddockId = entry.paddockId,
                        allocationId = entry.id,
                        blockName = blockName,
                        segments = entry.segments,
                        estimatedVines = entry.estimatedVines,
                        serverSeasonId = entry.serverSeasonId,
                        serverSeasonYear = entry.serverSeasonYear,
                    ),
                ),
                focusedPaddockId = entry.paddockId,
                createdAtMs = entry.createdAtMs,
                updatedAtMs = entry.updatedAtMs,
                enteredBy = entry.enteredBy,
                reversedAtMs = entry.reversedAtMs,
                serverAcknowledged = entry.serverSeasonId != null,
                serverSeasonYear = entry.serverSeasonYear,
            )
    }
}

/**
 * The multi-block editor engine — pure, testable, and the ONLY place the
 * allocation map changes.
 *
 * Invariants it guarantees:
 *  * selecting or deselecting quarters in one block never touches another,
 *  * switching the focused block preserves every earlier selection,
 *  * removing a block removes only its allocation,
 *  * labour, timing, rate and notes live on the parent and are untouched by
 *    every allocation operation.
 */
object PruningAllocationEditor {

    /** Focuses [paddockId], creating an EMPTY allocation if it has none yet. */
    fun focus(
        draft: PruningActivityDraft,
        paddockId: String,
        blockName: String = "",
    ): PruningActivityDraft {
        val existing = draft.allocations[paddockId]
        val allocations = if (existing == null) {
            draft.allocations + (paddockId to BlockPruningSelection(
                paddockId = paddockId,
                blockName = blockName,
            ))
        } else if (blockName.isNotBlank() && existing.blockName != blockName) {
            draft.allocations + (paddockId to existing.copy(blockName = blockName))
        } else {
            draft.allocations
        }
        return draft.copy(allocations = allocations, focusedPaddockId = paddockId)
    }

    /** Toggles one quarter of one block. Every other block is preserved verbatim. */
    fun toggleSegment(
        draft: PruningActivityDraft,
        paddockId: String,
        segment: PruningSegment,
        blockName: String = "",
    ): PruningActivityDraft {
        val focused = focus(draft, paddockId, blockName)
        val current = focused.allocations.getValue(paddockId)
        return focused.copy(allocations = focused.allocations + (paddockId to current.toggling(segment)))
    }

    /** Replaces one block's whole quarter set (e.g. "select all rows"). */
    fun setSegments(
        draft: PruningActivityDraft,
        paddockId: String,
        segments: List<PruningSegment>,
        blockName: String = "",
    ): PruningActivityDraft {
        val focused = focus(draft, paddockId, blockName)
        val current = focused.allocations.getValue(paddockId)
        return focused.copy(
            allocations = focused.allocations + (paddockId to current.copy(segments = segments.distinct())),
        )
    }

    /** Stores this block's own vine estimate. Never an activity-level value. */
    fun setEstimatedVines(
        draft: PruningActivityDraft,
        paddockId: String,
        vines: Int,
    ): PruningActivityDraft {
        val current = draft.allocations[paddockId] ?: return draft
        return draft.copy(
            allocations = draft.allocations + (paddockId to current.copy(estimatedVines = vines)),
        )
    }

    /** Removes ONE block. The activity and every other allocation survive. */
    fun removeBlock(draft: PruningActivityDraft, paddockId: String): PruningActivityDraft {
        val allocations = draft.allocations - paddockId
        val focus = if (draft.focusedPaddockId == paddockId) {
            allocations.values.sortedBy { it.paddockId }.firstOrNull()?.paddockId
        } else {
            draft.focusedPaddockId
        }
        return draft.copy(allocations = allocations, focusedPaddockId = focus)
    }

    /** Drops blocks the user opened but never selected anything in. */
    fun pruneEmptyBlocks(draft: PruningActivityDraft): PruningActivityDraft {
        val kept = draft.allocations.filterValues { !it.isEmpty }
        val focus = draft.focusedPaddockId?.takeIf { kept.containsKey(it) }
            ?: kept.values.sortedBy { it.paddockId }.firstOrNull()?.paddockId
        return draft.copy(allocations = kept, focusedPaddockId = focus)
    }

    /**
     * Adopts the CANONICAL server state (sql/166 response) wholesale: the
     * activity fields, every allocation, each allocation's canonical season and
     * the vintage. The local draft is replaced, never merged — the server is
     * authoritative once it has acknowledged.
     */
    fun adoptCanonical(
        draft: PruningActivityDraft,
        canonical: PruningActivityCanonical,
    ): PruningActivityDraft {
        val activity = canonical.activity ?: return draft
        val blockNames = draft.allocations.mapValues { it.value.blockName }
        val allocations = canonical.allocations.associate { alloc ->
            alloc.paddockId to BlockPruningSelection(
                paddockId = alloc.paddockId,
                allocationId = alloc.id,
                blockName = alloc.blockName.ifBlank { blockNames[alloc.paddockId].orEmpty() },
                segments = alloc.segments.map {
                    PruningSegment(row = it.row, quarter = it.segment, rowId = it.rowId)
                },
                estimatedVines = alloc.estimatedVines,
                serverSeasonId = alloc.pruningSeasonId,
                serverSeasonYear = alloc.seasonYear,
            )
        }
        val focus = draft.focusedPaddockId?.takeIf { allocations.containsKey(it) }
            ?: allocations.values.sortedBy { it.paddockId }.firstOrNull()?.paddockId
        return draft.copy(
            date = activity.entryDate?.take(10) ?: draft.date,
            worker = activity.workerOrCrew ?: draft.worker,
            method = activity.method ?: draft.method,
            labourHours = activity.labourHours,
            hourlyRate = activity.hourlyRate,
            notes = activity.notes ?: draft.notes,
            workTaskId = activity.workTaskId,
            allocations = allocations,
            focusedPaddockId = focus,
            reversedAtMs = if (activity.isReversed == true) {
                draft.reversedAtMs.takeIf { it > 0L } ?: System.currentTimeMillis()
            } else {
                0L
            },
            serverAcknowledged = true,
            serverSeasonYear = activity.seasonYear,
            vintageYear = activity.vintageYear,
        )
    }

    /**
     * Projects a draft onto the LEGACY per-block entries so every existing
     * screen, report, forecast and progress calculation keeps working while the
     * activity model rolls out.
     *
     * Labour and timing are carried by the PRIMARY allocation only (the lowest
     * block id, matching the server's `allocation_index = 0` mirror), so any
     * legacy `sum(labourHours)` still counts the activity's hours exactly once.
     */
    fun toLegacyEntries(draft: PruningActivityDraft): List<PruningEntry> {
        val active = draft.activeAllocations
        val primary = active.firstOrNull()?.paddockId
        return active.mapIndexed { index, alloc ->
            val isPrimary = alloc.paddockId == primary
            PruningEntry(
                id = alloc.allocationIdFor(draft.id),
                vineyardId = draft.vineyardId,
                paddockId = alloc.paddockId,
                seasonId = alloc.serverSeasonId
                    ?: PruningSeasonIds.makeForDate(draft.vineyardId, alloc.paddockId, draft.date),
                date = draft.date,
                segments = alloc.segments,
                worker = draft.worker,
                labourHours = if (isPrimary) draft.labourHours else null,
                startTime = if (isPrimary) draft.startTime else null,
                finishTime = if (isPrimary) draft.finishTime else null,
                method = draft.method,
                notes = draft.notes,
                estimatedVines = alloc.estimatedVines,
                workTaskId = if (isPrimary) draft.workTaskId else null,
                pruningActivityId = draft.id,
                allocationIndex = index,
                createdAtMs = draft.createdAtMs,
                updatedAtMs = draft.updatedAtMs,
                enteredBy = draft.enteredBy,
                reversedAtMs = draft.reversedAtMs,
                serverSeasonId = alloc.serverSeasonId,
                serverSeasonYear = alloc.serverSeasonYear,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Canonical server payload (sql/166 `pruning_activity_json`)
// ---------------------------------------------------------------------------

@Serializable
data class PruningActivityCanonical(
    val activity: CanonicalActivity? = null,
    val allocations: List<CanonicalAllocation> = emptyList(),
    val totals: CanonicalTotals? = null,
) {
    @Serializable
    data class CanonicalActivity(
        val id: String? = null,
        @SerialName("vineyard_id") val vineyardId: String? = null,
        @SerialName("entry_date") val entryDate: String? = null,
        @SerialName("worker_or_crew") val workerOrCrew: String? = null,
        val method: String? = null,
        @SerialName("start_time") val startTime: String? = null,
        @SerialName("finish_time") val finishTime: String? = null,
        @SerialName("duration_hours") val durationHours: Double? = null,
        @SerialName("labour_hours") val labourHours: Double? = null,
        @SerialName("hourly_rate") val hourlyRate: Double? = null,
        @SerialName("labour_cost") val labourCost: Double? = null,
        val notes: String? = null,
        @SerialName("work_task_id") val workTaskId: String? = null,
        @SerialName("season_year") val seasonYear: Int? = null,
        @SerialName("vintage_year") val vintageYear: Int? = null,
        @SerialName("is_reversed") val isReversed: Boolean? = null,
        @SerialName("reversed_at") val reversedAt: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
    )

    @Serializable
    data class CanonicalAllocation(
        val id: String = "",
        @SerialName("allocation_index") val allocationIndex: Int = 0,
        @SerialName("paddock_id") val paddockId: String = "",
        @SerialName("block_name") val blockName: String = "",
        @SerialName("pruning_season_id") val pruningSeasonId: String? = null,
        @SerialName("season_year") val seasonYear: Int? = null,
        @SerialName("vintage_year") val vintageYear: Int? = null,
        val rows: List<Int> = emptyList(),
        val quarters: Int = 0,
        @SerialName("row_equivalents") val rowEquivalents: Double = 0.0,
        @SerialName("estimated_vines") val estimatedVines: Int = 0,
        @SerialName("is_reversed") val isReversed: Boolean = false,
        val segments: List<CanonicalSegment> = emptyList(),
    )

    @Serializable
    data class CanonicalSegment(
        val row: Int = 0,
        val segment: Int = 0,
        @SerialName("row_id") val rowId: String? = null,
        val label: String? = null,
    )

    @Serializable
    data class CanonicalTotals(
        @SerialName("allocation_count") val allocationCount: Int = 0,
        @SerialName("block_summary") val blockSummary: String = "",
        val quarters: Int = 0,
        @SerialName("row_equivalents") val rowEquivalents: Double = 0.0,
        @SerialName("estimated_vines") val estimatedVines: Int = 0,
        @SerialName("labour_hours") val labourHours: Double? = null,
        @SerialName("hourly_rate") val hourlyRate: Double? = null,
        @SerialName("labour_cost") val labourCost: Double? = null,
    )
}
