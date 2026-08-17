package com.rork.vinetrack.data.sync

import com.rork.vinetrack.data.BackendError

/**
 * The single place an HTTP response to a versioned write becomes a decision.
 *
 * Every entity on the sql/198 contract (`resistance_plans`, `pruning_seasons`,
 * `pruning_yield_settings`) routes through here, because retry policy hangs off this
 * classification and three hand-rolled `when` blocks would eventually disagree. The one that
 * drifted would either retry a conflict forever or — far worse — report a refused write as
 * saved, which is the exact failure the revision contract was introduced to end.
 *
 * Mirrored on iOS by `VersionedWriteClassifier.swift`. The canonical inputs and expected
 * outputs are asserted on both platforms by `SyncRevisionParityTest` /
 * `SyncRevisionParityTests`.
 */
object VersionedWriteClassifier {

    /**
     * Classify one versioned write response.
     *
     * @param rowId primary key of the row written, used to key any conflict record.
     * @param baseRevision the revision this write asserted, echoed into a conflict.
     * @param status HTTP status code.
     * @param body raw response body; the only place a new revision or a conflict marker
     *   appears, which is why `return=representation` is mandatory on these writes.
     * @param decodeRow parses the returned representation into the domain row, or null when
     *   the body carried no row.
     *
     * @return [VersionedWriteOutcome.Applied] only when the server both accepted the write
     *   AND returned the row it stored.
     * @throws BackendError.Unauthorized on 401/403 — a permission problem, never a conflict.
     * @throws BackendError.Server on any other non-2xx, so the caller's transport-retry path
     *   handles it.
     */
    fun <T> classify(
        rowId: String,
        baseRevision: Long?,
        status: Int,
        body: String?,
        decodeRow: (String) -> T?,
    ): VersionedWriteOutcome<T> {
        val text = body ?: ""
        val isSuccess = status in 200..299
        if (isSuccess) {
            val row = runCatching { decodeRow(text) }.getOrNull()
            return if (row == null) {
                // A 2xx with an EMPTY representation is the legacy silent-skip signature: a
                // BEFORE UPDATE trigger returning NULL, so the row was never written while
                // HTTP reported success. Reporting that as saved is the original defect —
                // the grower saw a tick and their edit was gone. Surfaced as a conflict so
                // the local copy stays queued and recoverable.
                VersionedWriteOutcome.Conflict(
                    rowId = rowId,
                    baseRevision = baseRevision,
                    serverRevision = null,
                )
            } else {
                VersionedWriteOutcome.Applied(row)
            }
        }
        if (SyncRevisionContract.isRevisionConflict(status, text)) {
            return VersionedWriteOutcome.Conflict(
                rowId = rowId,
                // Prefer the server's echo; fall back to what we sent so a conflict record
                // is never revisionless just because the body was terse.
                baseRevision = SyncRevisionContract.baseRevisionFrom(text) ?: baseRevision,
                serverRevision = SyncRevisionContract.serverRevisionFrom(text),
            )
        }
        // Auth is checked AFTER the conflict marker on purpose: a REVISION_CONFLICT that
        // somehow arrived with a 403 is still a conflict, and retrying it would be futile.
        if (status == 401 || status == 403) throw BackendError.Unauthorized
        throw BackendError.Server(status, text)
    }
}
