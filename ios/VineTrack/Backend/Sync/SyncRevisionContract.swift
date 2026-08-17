import Foundation

/// Client half of the sql/198 server-authoritative revision contract.
///
/// ONE implementation, shared by every versioned entity (`resistance_plans`,
/// `pruning_seasons`, `pruning_yield_settings`), because three subtly different PT409
/// parsers is exactly how one of them ends up classifying a conflict as a network error
/// and silently dropping a grower's edit.
///
/// THE RULE: a device wall clock records WHEN a human edited. It does not record WHICH
/// server version they based that edit on. Those are different facts, and only the second
/// one can decide whether a write is stale. `server_revision` is that second fact, issued
/// by the server and unforgeable by clients.
///
/// Mirrors `SyncRevisionContract.kt` on Android. Both platforms must agree on decode, on
/// what is sent, and on what counts as a conflict — see `SyncRevisionParityTests`.
nonisolated enum SyncRevisionContract {

    /// Machine-readable marker raised by `reject_stale_client_write()` (sql/198).
    ///
    /// Matched on the MESSAGE rather than only on the HTTP status: a gateway or proxy can
    /// rewrite a status code, but the message travels in the body.
    nonisolated static let conflictMessage = "REVISION_CONFLICT"

    /// PostgREST maps SQLSTATE class `PT` to an HTTP status; `PT409` -> 409 Conflict.
    nonisolated static let conflictSQLState = "PT409"

    /// Whether an error from a write is a revision conflict rather than a transport, auth
    /// or server failure.
    ///
    /// Deliberately tolerant. A 409 whose body did not survive, and a REVISION_CONFLICT
    /// that arrived with some other status, are both still conflicts — and misclassifying
    /// either one as "sync failed" would send the app into a blind retry loop that can
    /// never succeed, because the same stale `base_revision` will be rejected every time.
    nonisolated static func isRevisionConflict(_ error: any Error) -> Bool {
        if error is SyncRevisionConflictError { return true }
        let text = describe(error)
        if text.contains(conflictMessage) { return true }
        if text.contains(conflictSQLState) { return true }
        return false
    }

    /// The server's current revision, read out of the PostgREST error body.
    ///
    /// sql/198 puts it in the error DETAIL as a JSON object. Nil when the body could not be
    /// parsed — the conflict is still a conflict, it just cannot say which version won, and
    /// a conflict with a missing revision must never be downgraded to a success.
    nonisolated static func serverRevision(from error: any Error) -> Int64? {
        detailValue(describe(error), key: "server_revision")
    }

    /// The `base_revision` the server rejected, echoed back for diagnostics.
    nonisolated static func baseRevision(from error: any Error) -> Int64? {
        detailValue(describe(error), key: "base_revision")
    }

    /// Best-effort textual form of an arbitrary error, so the PostgREST body can be
    /// inspected whichever SDK layer wrapped it.
    nonisolated static func describe(_ error: any Error) -> String {
        "\(error) \(error.localizedDescription)"
    }

    /// Pulls one integer out of the `"server_revision": 8` style JSON detail.
    ///
    /// A tolerant scan rather than a typed decode: the value arrives inside a
    /// double-encoded `details` string in some PostgREST versions and as a real nested
    /// object in others, and this value is diagnostic — it must never be the reason a
    /// conflict fails to register.
    nonisolated static func detailValue(_ text: String, key: String) -> Int64? {
        guard let keyRange = text.range(of: "\(key)") else { return nil }
        let tail = text[keyRange.upperBound...]
        var digits = ""
        var seenSeparator = false
        for character in tail {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if digits.isEmpty {
                // Skip the `": "` (and any escaping) between the key and the number.
                if character == ":" || character == "\"" || character == " " || character == "\\" {
                    seenSeparator = true
                    continue
                }
                return seenSeparator ? nil : nil
            }
            break
        }
        return digits.isEmpty ? nil : Int64(digits)
    }
}

/// Thrown by a remote when the server refused a write on revision grounds.
///
/// A distinct type, NOT a generic backend error: a caller that cannot tell a conflict from
/// a 500 will retry it, and a retry carrying the same stale `base_revision` is guaranteed
/// to be refused again. Conflicts need a human; transport failures need a retry.
/// Same-looking failures, opposite handling.
nonisolated struct SyncRevisionConflictError: Error, Sendable, Equatable {
    nonisolated let rowId: String
    nonisolated let entity: String
    nonisolated let baseRevision: Int64?
    nonisolated let serverRevision: Int64?

    nonisolated var localizedDescription: String { SyncRevisionContract.conflictMessage }
}

/// A rejected write, preserved in full.
///
/// Carries BOTH authored versions rather than a `hasConflict` flag. A flag would tell the
/// grower that something went wrong while having thrown away the plan they actually wrote,
/// which is worse than the silent data loss this whole contract exists to fix — at least
/// that failure was invisible rather than taunting.
nonisolated struct SyncRevisionConflict<Payload: Codable & Sendable>: Codable, Sendable {
    /// Primary key of the row that conflicted.
    nonisolated var rowId: String
    /// Table name, e.g. `resistance_plans`. Distinguishes conflicts in one store.
    nonisolated var entity: String
    /// What THIS device authored and has not yet landed. Still queued.
    nonisolated var localPending: Payload
    /// The server's current version. Nil only when the follow-up read also failed — the
    /// local copy is still preserved, which is the part that matters.
    nonisolated var serverCurrent: Payload?
    /// The revision the local edit was based on.
    nonisolated var baseRevision: Int64?
    /// The revision the server was actually at when it refused the write.
    nonisolated var serverRevision: Int64?
    nonisolated var detectedAtEpochMs: Int64
}

/// Outcome of one versioned write. An enum so a caller cannot forget the conflict branch.
nonisolated enum VersionedWriteOutcome<Row: Sendable>: Sendable {
    /// The server accepted the write and returned the authoritative row, including its NEW
    /// `server_revision`.
    case applied(Row)
    /// Refused: someone else wrote since this device last read the row.
    case conflict(rowId: String, baseRevision: Int64?, serverRevision: Int64?)
}
