package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSeasonIds

/**
 * What "synced" means for the Pruning Tracker.
 *
 * An empty outbox only proves this device stopped trying. A pruning record is
 * SYNCED when both of these are true:
 *
 *  1. the server acknowledged it — `record_pruning_entry` / `update_pruning_entry`
 *     returned a season, or a pull found the stored row, and
 *  2. this device adopted the CANONICAL season the server resolved from the
 *     activity date (sql/161): `season_year = year(entry_date)`.
 *
 * A record whose stored season year disagrees with the year of its own work is
 * therefore never counted as synced, even with an empty queue — that is exactly
 * the 2026-work-under-season-2027 defect, and it must stay visible until the
 * reviewed server-side repair (sql/164) has run.
 *
 * Reversed entries are audit history: they are excluded from the count, but a
 * queued reversal still holds [queuedWrites] above zero.
 */
data class PruningSyncStatus(
    /** Active (non-reversed) records held for the vineyard. */
    val recordCount: Int = 0,
    /** Acknowledged by the server AND on the canonical season. */
    val confirmed: Int = 0,
    /** Still waiting in the outbox. */
    val queued: Int = 0,
    /** Written locally, never acknowledged by the server. */
    val awaitingAck: Int = 0,
    /** Acknowledged, but filed under a season that isn't the year of the work. */
    val seasonMismatched: Int = 0,
    /** Unresolved pruning writes of any kind (entries, seasons, reversals). */
    val queuedWrites: Int = 0,
) {
    /** True only when every record is server-confirmed on its canonical season. */
    val isFullySynced: Boolean get() = queuedWrites == 0 && confirmed == recordCount

    /** Never reaches 100 until [isFullySynced] — the whole point of the change. */
    val percentSynced: Int
        get() = when {
            isFullySynced -> 100
            recordCount == 0 -> 99
            else -> minOf(99, confirmed * 100 / recordCount)
        }

    /** True when something is genuinely outstanding and worth surfacing. */
    val needsAttention: Boolean get() = !isFullySynced
}

/** Pure evaluation of the sync contract above — no Android dependencies. */
object PruningSyncIntegrity {

    /**
     * The season the server has this entry under matches the year of the work
     * AND this device has adopted that exact row.
     */
    fun isServerConfirmed(entry: PruningEntry): Boolean {
        val serverSeasonId = entry.serverSeasonId ?: return false
        val serverSeasonYear = entry.serverSeasonYear ?: return false
        return serverSeasonId == entry.seasonId &&
            serverSeasonYear == PruningSeasonIds.seasonYearFor(entry.date)
    }

    fun evaluate(
        entries: List<PruningEntry>,
        queuedEntryIds: Set<String>,
        queuedWrites: Int,
    ): PruningSyncStatus {
        val active = entries.filterNot { it.isReversed }
        var confirmed = 0
        var queued = 0
        var awaitingAck = 0
        var mismatched = 0
        for (entry in active) {
            when {
                entry.id in queuedEntryIds -> queued++
                entry.serverSeasonId == null -> awaitingAck++
                !isServerConfirmed(entry) -> mismatched++
                else -> confirmed++
            }
        }
        return PruningSyncStatus(
            recordCount = active.size,
            confirmed = confirmed,
            queued = queued,
            awaitingAck = awaitingAck,
            seasonMismatched = mismatched,
            queuedWrites = queuedWrites,
        )
    }
}
