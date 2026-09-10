package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingPhotoAttachment
import com.rork.vinetrack.data.model.PendingPhotoStatus
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus

/**
 * The production preservation step every replay/retry path runs before it is
 * allowed to change local evidence.
 *
 * Kept free of Android types so the real retry path — real queued payloads,
 * real ownership resolution, real quarantine, real operator messages — is
 * directly executable in tests rather than only through a hand-built scope.
 */
internal object AffectedPinReplayOrchestration {
    data class Permit(
        val writeIds: Set<String>,
        val replayPhotoIds: Set<String>,
        val retainedPhotoPermits: Set<PinDeleteSync.RetainedPhotoPermit>,
    )

    /**
     * Production queue-freeze boundary shared by lifecycle replay entry points.
     * All retained-photo identities are frozen for cleanup safety; only pending
     * and failed photos are eligible for upload replay.
     */
    fun prepare(
        writes: List<PendingWrite>,
        photos: List<PendingPhotoAttachment>,
        preserve: (List<PendingWrite>, Set<String>) -> RecoveryPreservation.Result,
    ): Permit? {
        val result = preserve(writes, photos.mapTo(mutableSetOf()) { it.vineyardId })
        if (!result.didRun) return null
        return Permit(
            writeIds = result.permittedWriteIds,
            replayPhotoIds = photos.filter {
                it.status == PendingPhotoStatus.PENDING || it.status == PendingPhotoStatus.FAILED
            }.mapTo(mutableSetOf()) { it.id },
            retainedPhotoPermits = photos.mapTo(mutableSetOf()) {
                PinDeleteSync.RetainedPhotoPermit(it.id, it.revision)
            },
        )
    }
}

internal object RecoveryPreservation {
    const val STORAGE_FAILURE_MESSAGE: String =
        "Recovery evidence couldn't be saved to this device, so nothing was synced or refreshed. " +
            "Free up device storage, then retry."

    const val QUARANTINE_FAILURE_MESSAGE: String =
        "Some saved changes couldn't be linked to a vineyard and couldn't be held back safely, " +
            "so nothing was synced or refreshed. Retry, and if it repeats these items need attention."

    const val QUARANTINED_ITEM_MESSAGE: String =
        "This saved change couldn't be linked to a vineyard, so it was held back for attention."

    data class Result(
        val didRun: Boolean,
        /** Operator message when the step refused to proceed; null when it ran. */
        val message: String?,
        /** Items held back because their vineyard could not be identified. */
        val quarantinedWriteIds: Set<String>,
        /** Exact queued-write snapshot that may be consumed by this replay pass. */
        val permittedWriteIds: Set<String>,
    )

    /**
     * Resolve ownership for every queued pin/trip write, preserve the first
     * evidence for each resolved vineyard, hold back anything unidentifiable,
     * then run [replay] only if that all succeeded.
     */
    fun preserveBeforeReplay(
        pendingWrites: List<PendingWrite>,
        tripOwners: Map<String, String>,
        pinOwners: Map<String, String>,
        fallbackVineyardId: String?,
        additionalVineyardIds: Set<String> = emptySet(),
        preserve: (String) -> Boolean,
        quarantine: (Set<String>) -> Boolean,
        replay: () -> Unit = {},
    ): Result {
        val resolvedScope = RecoverySnapshotStore.resolveReplayScope(
            pendingWrites = pendingWrites,
            tripOwners = tripOwners,
            pinOwners = pinOwners,
            fallbackVineyardId = fallbackVineyardId,
        )
        val scope = resolvedScope.copy(
            vineyardIds = resolvedScope.vineyardIds + additionalVineyardIds,
        )
        return when (
            val outcome = RecoveryReplayGate.run(
                scope = scope,
                preserve = preserve,
                quarantineUnresolved = quarantine,
                replay = replay,
            )
        ) {
            is RecoveryReplayGate.Outcome.Ran -> Result(
                didRun = true,
                message = null,
                quarantinedWriteIds = outcome.quarantinedWriteIds,
                permittedWriteIds = pendingWrites.mapTo(mutableSetOf()) { it.id } - outcome.quarantinedWriteIds,
            )
            is RecoveryReplayGate.Outcome.PreservationFailed ->
                Result(false, STORAGE_FAILURE_MESSAGE, emptySet(), emptySet())
            is RecoveryReplayGate.Outcome.QuarantineFailed ->
                Result(false, QUARANTINE_FAILURE_MESSAGE, emptySet(), emptySet())
        }
    }

    /**
     * Hold every unidentifiable item back and confirm from a fresh read that it
     * really is held. Returns false if any item is still replay-eligible, so the
     * caller refuses to proceed rather than risk changing unpreserved evidence.
     */
    fun quarantine(
        writeIds: Set<String>,
        hold: (String, String) -> Unit,
        readBack: () -> List<PendingWrite>,
    ): Boolean {
        writeIds.forEach { id -> hold(id, QUARANTINED_ITEM_MESSAGE) }
        return readBack()
            .filter { it.id in writeIds }
            .all { it.status == PendingWriteStatus.BLOCKED }
    }
}
