package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityReconciliation
import com.rork.vinetrack.data.model.PruningQuarterConflict

/**
 * Maps the raw sql/166 activity response onto the reconciliation result the UI
 * shows the user.
 *
 * The rule this enforces: an activity write is NEVER reported as fully
 * successful while the server refused quarters. `attributed` is what actually
 * landed; `conflicts` are quarters another record already owns (never stolen).
 */
object PruningActivityReconciliations {

    fun from(
        result: PruningSyncRepository.ActivityResult,
        blockNames: Map<String, String> = emptyMap(),
        blockSummary: String = "",
        activityId: String = "",
        isReversal: Boolean = false,
    ): PruningActivityReconciliation {
        val allocationConflicts = result.allocationResults.flatMap { it.conflicts }
        val raw = result.conflicts.ifEmpty { allocationConflicts }
        val conflicts = raw.map { conflict ->
            PruningQuarterConflict(
                paddockId = conflict.paddockId,
                blockName = conflict.paddockId?.let { blockNames[it] }.orEmpty(),
                row = conflict.row,
                quarter = conflict.segment,
                reason = conflict.reason,
            )
        }
        val canonicalTotals = result.canonical?.totals
        return PruningActivityReconciliation(
            activityId = result.activityId ?: activityId,
            blockSummary = canonicalTotals?.blockSummary?.ifBlank { blockSummary } ?: blockSummary,
            quartersRequested = result.allocationResults.sumOf { it.requested ?: 0 },
            quartersRecorded = canonicalTotals?.quarters
                ?: result.allocationResults.sumOf { it.attributed ?: 0 },
            conflicts = conflicts,
            seasonYear = result.canonical?.activity?.seasonYear,
            vintageYear = result.canonical?.activity?.vintageYear,
            workTaskConflict = result.workTaskConflict == true,
            isReversal = isReversal || result.reversed == true,
            quartersReleased = result.quartersReleased ?: 0,
            isStale = result.stale == true,
            error = result.error,
        )
    }
}
