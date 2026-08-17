import Foundation

/// Failure kinds a versioned write can produce that are NOT revision conflicts.
///
/// Kept distinct from a conflict because the remedies are opposites: these want a retry (or a
/// sign-in), whereas retrying a conflict resends the same stale `base_revision` and is refused
/// every single time.
nonisolated enum VersionedWriteError: Error, Equatable {
    /// 401/403 — a permission problem. There is no second version for anyone to review.
    case unauthorized
    /// Any other non-2xx, including a 409 that explained itself as a constraint violation.
    case server(status: Int, body: String)
}

/// The single place an HTTP response to a versioned write becomes a decision.
///
/// Mirrors `VersionedWriteClassifier.kt` on Android. Every entity on the sql/198 contract
/// routes its classification through one implementation per platform, because retry policy
/// hangs off this decision and hand-rolled copies eventually disagree. The one that drifted
/// would either retry a conflict forever or — far worse — report a refused write as saved,
/// which is the exact failure the revision contract was introduced to end.
///
/// The canonical inputs and expected outputs are asserted against the identical Android
/// literals by `SyncRevisionParityTests` / `SyncRevisionParityTest`.
nonisolated enum VersionedWriteClassifier {

    /// Classify one versioned write response from a raw status and body.
    ///
    /// - Parameters:
    ///   - rowId: primary key of the row written, used to key any conflict record.
    ///   - baseRevision: the revision this write asserted, echoed into a conflict.
    ///   - status: HTTP status code.
    ///   - body: raw response body. The only place a new revision or a conflict marker
    ///     appears, which is why `.select()` (`return=representation`) is mandatory here.
    ///   - decodeRow: parses the returned representation, or returns nil when the body
    ///     carried no row.
    /// - Returns: `.applied` only when the server both accepted the write AND returned the row
    ///   it stored.
    /// - Throws: ``VersionedWriteError`` for auth and server failures, so the caller's
    ///   transport-retry path handles them.
    nonisolated static func classify<Row>(
        rowId: String,
        baseRevision: Int64?,
        status: Int,
        body: String?,
        decodeRow: (String) -> Row?
    ) throws -> VersionedWriteOutcome<Row> where Row: Sendable {
        let text = body ?? ""
        if (200...299).contains(status) {
            guard let row = decodeRow(text) else {
                // A 2xx with an EMPTY representation is the legacy silent-skip signature: a
                // BEFORE UPDATE trigger returning NULL, so the row was never written while
                // HTTP reported success. Reporting that as saved is the original defect — the
                // grower saw a tick and their edit was gone. Surfaced as a conflict so the
                // local copy stays queued and recoverable.
                return .conflict(rowId: rowId, baseRevision: baseRevision, serverRevision: nil)
            }
            return .applied(row)
        }
        if SyncRevisionContract.isRevisionConflict(status: status, body: text) {
            return .conflict(
                rowId: rowId,
                // Prefer the server's echo; fall back to what we sent so a conflict record is
                // never revisionless just because the body was terse.
                baseRevision: SyncRevisionContract.baseRevision(fromBody: text) ?? baseRevision,
                serverRevision: SyncRevisionContract.serverRevision(fromBody: text)
            )
        }
        // Auth is checked AFTER the conflict marker on purpose: a REVISION_CONFLICT that
        // somehow arrived with a 403 is still a conflict, and retrying it would be futile.
        if status == 401 || status == 403 { throw VersionedWriteError.unauthorized }
        throw VersionedWriteError.server(status: status, body: text)
    }

    /// Classify a thrown SDK error, for call sites that go through supabase-swift rather than
    /// raw HTTP (the status and body are not separately available there).
    ///
    /// Returns nil when the error is NOT a revision conflict, so the caller rethrows it
    /// unchanged and a genuine transport failure keeps its retry semantics.
    nonisolated static func conflict<Row>(
        rowId: String,
        baseRevision: Int64?,
        from error: any Error
    ) -> VersionedWriteOutcome<Row>? where Row: Sendable {
        guard SyncRevisionContract.isRevisionConflict(error) else { return nil }
        return .conflict(
            rowId: rowId,
            baseRevision: SyncRevisionContract.baseRevision(from: error) ?? baseRevision,
            serverRevision: SyncRevisionContract.serverRevision(from: error)
        )
    }
}
