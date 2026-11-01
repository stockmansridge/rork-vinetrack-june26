package com.rork.vinetrack.data

/**
 * P0 3.1.9: makes an occurrence-restore tank conflict an effective, durable
 * fail-closed state instead of a transient message.
 *
 * The hold lives in the Trip's own occurrence journal (already durable, owner/
 * vineyard/Trip scoped and committed synchronously), so it survives restart.
 * While held:
 *  - no TRIP_TANK marker is reconstructed at restore;
 *  - [TripTankSync] leaves any marker unclaimed and untouched;
 *  - [ScopedTankActualSync] does not upload that Trip's actuals;
 *  - [StartTankCommitCoordinator] refuses new Start Tank commits;
 *  - the ViewModel refuses End Tank, fill timer, legacy start and finishing;
 *  - occurrence lifecycle replay already stops on any journal hold.
 *
 * Local tank sessions, actuals, the start-tank journal and pending markers are
 * never altered. The hold is released only when a fresh server row merges
 * safely with local evidence, the same proof [TripTankSync] requires.
 */
internal object OccurrenceTankConflictGate {
    enum class Outcome { NONE, HELD, ALREADY_HELD, RELEASED, STILL_HELD_UNVERIFIED }

    /** Restore boundary. Call before the snapshot is saved and before any TRIP_TANK marker is reconstructed. */
    fun onRestore(
        journal: TripOccurrenceJournal,
        result: OccurrenceRestoreLocalProgress.Result,
        freshServerRow: Boolean,
    ): Outcome {
        val state = journal.load() ?: error("Occurrence journal missing.")
        val held = TripOccurrenceJournal.isTankConflictHeld(state)
        return when {
            result.tankConflict -> if (journal.holdTankConflict()) Outcome.HELD else Outcome.ALREADY_HELD
            !held -> Outcome.NONE
            freshServerRow -> { journal.releaseTankConflict(); Outcome.RELEASED }
            else -> Outcome.STILL_HELD_UNVERIFIED
        }
    }

    fun replayAllowed(result: OccurrenceRestoreLocalProgress.Result, outcome: Outcome): Boolean =
        result.tankReplayRequired && (outcome == Outcome.NONE || outcome == Outcome.RELEASED)

    /**
     * Gate predicate. No journal (legacy Trip) is not held; an unreadable journal for
     * this Trip fails closed.
     */
    fun isHeld(journal: TripOccurrenceJournal?): Boolean {
        if (journal == null) return false
        return runCatching { TripOccurrenceJournal.isTankConflictHeld(journal.load()) }.getOrDefault(true)
    }
}
