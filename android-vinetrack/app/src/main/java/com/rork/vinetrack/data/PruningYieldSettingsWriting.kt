package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningYieldSettings
import com.rork.vinetrack.data.sync.VersionedWriteOutcome

/**
 * The versioned-write half of [PruningYieldSettingsRepository], named separately so the
 * offline replay ([PruningYieldSettingsSync]) depends on the WRITE CONTRACT rather than on a
 * concrete Supabase client.
 *
 * This exists so the conflict semantics can be tested for real. The queue's behaviour on a
 * REVISION_CONFLICT — keep the row, mark it CONFLICT, never retry it — is the part that
 * decides whether a grower's calculator settings survive, and it cannot be exercised at all
 * while the only implementation needs a live network. A seam here means
 * `PruningYieldSettingsRevisionSyncTest` drives the real replay loop.
 */
interface PruningYieldSettingsWriting {
    /**
     * Upsert a block's saved configuration under the sql/198 revision contract.
     *
     * Returns [VersionedWriteOutcome.Applied] with the authoritative server row (carrying its
     * NEW `server_revision`), or [VersionedWriteOutcome.Conflict] when the row moved on since
     * this device last read it. A conflict is NEVER thrown — a thrown conflict gets
     * classified as a transport failure and retried forever with the same stale
     * `base_revision`.
     */
    suspend fun upsertSettings(
        settings: PruningYieldSettings,
        clientUpdatedAt: String,
    ): VersionedWriteOutcome<PruningYieldSettings>
}
