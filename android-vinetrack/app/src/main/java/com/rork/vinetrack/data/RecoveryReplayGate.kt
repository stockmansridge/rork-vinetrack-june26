package com.rork.vinetrack.data

/** Runs a replay mutation only after every resolved vineyard has durable evidence. */
internal object RecoveryReplayGate {
    fun run(
        scope: RecoverySnapshotStore.ReplayScope,
        preserve: (String) -> Boolean,
        replay: () -> Unit,
    ): Boolean {
        if (scope.unresolvedWriteIds.isNotEmpty()) return false
        if (!scope.vineyardIds.all(preserve)) return false
        replay()
        return true
    }
}
