package com.rork.vinetrack.data

/**
 * Runs a replay mutation only after every resolved vineyard has durable evidence.
 *
 * Genuinely unresolved queued items (no payload vineyard, no known trip, no known
 * pin) are handled explicitly: they are quarantined so no replay can change their
 * evidence, and the rest of the queue — which IS safely resolved and preserved —
 * is allowed to proceed. An unidentified item therefore never blocks ordinary
 * offline pin work from syncing, and is never guessed into a vineyard either.
 */
internal object RecoveryReplayGate {
    sealed interface Outcome {
        /** Replay ran. [quarantinedWriteIds] were held back for attention. */
        data class Ran(val quarantinedWriteIds: Set<String>) : Outcome

        /** Durable evidence preservation failed for these vineyards. Nothing ran. */
        data class PreservationFailed(val vineyardIds: Set<String>) : Outcome

        /** Unidentified items could not be held back safely. Nothing ran. */
        data class QuarantineFailed(val writeIds: Set<String>) : Outcome

        val didRun: Boolean get() = this is Ran
    }

    fun run(
        scope: RecoverySnapshotStore.ReplayScope,
        preserve: (String) -> Boolean,
        quarantineUnresolved: (Set<String>) -> Boolean = { it.isEmpty() },
        replay: () -> Unit,
    ): Outcome {
        val unresolved = scope.unresolvedWriteIds
        if (unresolved.isNotEmpty() && !quarantineUnresolved(unresolved)) {
            return Outcome.QuarantineFailed(unresolved)
        }
        val failed = scope.vineyardIds.filterNot(preserve).toSet()
        if (failed.isNotEmpty()) return Outcome.PreservationFailed(failed)
        replay()
        return Outcome.Ran(unresolved)
    }
}
