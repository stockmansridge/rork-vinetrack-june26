package com.rork.vinetrack.data

/**
 * Runs a replay mutation only after every resolved vineyard has durable evidence.
 *
 * Preservation always precedes any handling of unresolved original rows. The
 * callback must establish a safe hold/exclusion before replay is permitted.
 * Production currently refuses affected passes without mutating unidentified
 * rows because not every replay caller supports selective, revalidated permits.
 * Ownership is never guessed.
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
        // Never alter queue evidence before every owning vineyard is preserved.
        val failed = scope.vineyardIds.filterNot(preserve).toSet()
        if (failed.isNotEmpty()) return Outcome.PreservationFailed(failed)
        if (unresolved.isNotEmpty() && !quarantineUnresolved(unresolved)) {
            return Outcome.QuarantineFailed(unresolved)
        }
        replay()
        return Outcome.Ran(unresolved)
    }
}
