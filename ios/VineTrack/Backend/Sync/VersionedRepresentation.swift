import Foundation

/// Reads the concurrency-relevant fields out of a PostgREST `return=representation` body.
///
/// WHY NOT A FULL `Codable` DECODE. The representation is only consulted for two facts: the
/// row id the server converged on, and the NEW `server_revision` it issued. A full decode
/// would drag every other column — and every timestamp format the server might use — into
/// the success path, where a date-format mismatch would make ``VersionedWriteClassifier``
/// see "no row" and report a write the server ACCEPTED as a conflict. That is precisely the
/// failure this contract exists to prevent, so the parse is kept to the two fields that
/// actually decide anything.
///
/// The values the row now holds are the values this device just sent (the server accepted
/// them), so the caller re-stamps its own payload with the returned id and revision rather
/// than round-tripping columns it already has.
///
/// Shared by `pruning_seasons` and `pruning_yield_settings`; mirrors the fields Android reads
/// back from its own representation decode.
nonisolated enum VersionedRepresentation {

    /// One row's identity and issued revision.
    nonisolated struct Row: Sendable, Equatable {
        /// The id the server converged on. For an `on_conflict` target other than the
        /// primary key (pruning_yield_settings converges on `vineyard_id,paddock_id`) this
        /// can legitimately differ from the id this device sent, and the server's id is the
        /// one that must be adopted.
        nonisolated let id: UUID?
        /// The revision the server issued for this write. Nil when the column was absent —
        /// a server predating sql/198. Absence is NOT an error and must not be read as a
        /// failed write.
        nonisolated let serverRevision: Int64?
    }

    /// First row of a representation body, or nil when the body carried no row at all.
    ///
    /// Nil is meaningful: an empty array (or an empty body) is the legacy silent-skip
    /// signature — a `BEFORE UPDATE` trigger returning NULL, so HTTP reported success while
    /// nothing was written. ``VersionedWriteClassifier`` turns that into a conflict so the
    /// local copy stays queued.
    ///
    /// Accepts both a bare object and the single-element array PostgREST returns for an
    /// upsert, because the shape varies with the request and neither is an error.
    nonisolated static func first(in body: String?) -> Row? {
        guard let body, !body.isEmpty else { return nil }
        guard let data = body.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object: [String: Any]?
        if let array = parsed as? [[String: Any]] {
            object = array.first
        } else {
            object = parsed as? [String: Any]
        }
        guard let object else { return nil }
        return Row(id: uuid(object["id"]), serverRevision: int64(object["server_revision"]))
    }

    private nonisolated static func uuid(_ value: Any?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }

    /// Tolerant integer read: PostgREST renders `bigint` as a JSON number, but a proxy that
    /// re-serialises the body can turn it into a string. Both are the same revision.
    private nonisolated static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}
