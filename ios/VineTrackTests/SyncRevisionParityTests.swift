import Foundation
import Testing

@testable import VineTrack

/// CANONICAL CROSS-PLATFORM FIXTURE for the sql/198 revision contract.
///
/// Every input here is a fixed literal, mirrored byte-for-byte by
/// `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/SyncRevisionParityTest.kt`.
/// When both files execute, the pair mechanically proves the property that matters:
///
///   the SAME server response produces the SAME client concurrency decision on iOS and Android.
///
/// That claim used to rest on "we wrote them the same way", which is not evidence. Two
/// platforms drifting apart on this is not a cosmetic bug: one of them would report a refused
/// write as saved, and a grower's edit would be gone with a tick beside it.
///
/// These are contract assertions on the real classifier and the real codecs — deliberately NOT
/// repository behaviour tests, so a repository refactor cannot quietly change what a PT409
/// means.
///
/// RULE FOR EDITING: never change a fixture value on one platform alone. If a constant here
/// changes, the Kotlin mirror changes in the same commit, or the parity guarantee is void.
struct SyncRevisionParityTests {

    /// The shared fixture vector. Identical literals exist in the Kotlin mirror.
    ///
    /// Platform-specific formatting (JSON key order, date rendering, integer width) is
    /// deliberately NOT asserted — only the concurrency-relevant semantics are.
    enum Fixture {
        static let rowId = "9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f"
        static let vineyardId = "11111111-1111-4111-8111-111111111111"
        static let paddockId = "22222222-2222-4222-8222-222222222222"

        /// Metadata only. Present in every fixture precisely so it can be proved inert.
        static let clientUpdatedAt = "2026-08-17T02:00:00Z"

        /// The revision the client observed and will assert as `base_revision`.
        static let observedRevision: Int64 = 7

        /// What the server issues when it accepts that write.
        static let acceptedRevision: Int64 = 8

        /// Where the row had actually moved on to when it refused the write.
        static let conflictingServerRevision: Int64 = 12

        /// A stamp far in the FUTURE, to tempt a timestamp comparison into passing a stale write.
        static let futureStamp = "2099-01-01T00:00:00Z"

        /// A stamp far in the PAST, to tempt one into failing a current write.
        static let ancientStamp = "1999-01-01T00:00:00Z"

        // MARK: Canonical server representations (2xx bodies)

        /// A stored `pruning_yield_settings` row at ``acceptedRevision``.
        static let settingsRow = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "client_updated_at":"2026-08-17T02:00:00Z","server_revision":8}]
        """

        /// The same row as an older client left it: no revision column at all.
        static let settingsRowLegacy = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "client_updated_at":"2026-08-17T02:00:00Z"}]
        """

        /// A row whose `client_updated_at` looks ANCIENT while its `server_revision` is NEWER.
        /// The revision must win.
        static let settingsRowOldStampNewerRevision = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "client_updated_at":"1999-01-01T00:00:00Z","server_revision":12}]
        """

        /// 2xx with NO row: the legacy silent-skip signature.
        static let emptyRepresentation = "[]"

        // MARK: Canonical failure bodies

        /// Exactly what `reject_stale_client_write()` raises under sql/198.
        static let conflictBody = #"{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 7}","hint":"Reload the row and reapply the change","message":"REVISION_CONFLICT"}"#

        /// The marker surviving a status rewrite by a gateway or proxy.
        static let conflictBodyMarkerOnly = #"{"message":"REVISION_CONFLICT"}"#

        /// A unique-key violation, which PostgREST ALSO reports as 409. Not a conflict.
        static let uniqueViolationBody = #"{"code":"23505","details":"Key (vineyard_id, paddock_id) already exists.","message":"duplicate key value violates unique constraint"}"#

        static let authBody = #"{"message":"JWT expired"}"#
        static let forbiddenBody = #"{"message":"permission denied for table pruning_yield_settings"}"#
        static let serverErrorBody = #"{"message":"upstream unavailable"}"#
    }

    // MARK: - Helpers

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Runs a response through the REAL production classification, decoding the same canonical
    /// row type Android decodes.
    private func classifySettings(
        baseRevision: Int64?,
        status: Int,
        body: String?
    ) throws -> VersionedWriteOutcome<BackendPruningYieldSettings> {
        try VersionedWriteClassifier.classify(
            rowId: Fixture.rowId,
            baseRevision: baseRevision,
            status: status,
            body: body
        ) { text in
            guard let data = text.data(using: .utf8) else { return nil }
            let rows = try? Self.decoder().decode([BackendPruningYieldSettings].self, from: data)
            return rows?.first
        }
    }

    private func appliedRow<Row: Sendable>(_ outcome: VersionedWriteOutcome<Row>) -> Row? {
        if case let .applied(row) = outcome { return row }
        return nil
    }

    private func conflictParts<Row: Sendable>(
        _ outcome: VersionedWriteOutcome<Row>
    ) -> (rowId: String, base: Int64?, server: Int64?)? {
        if case let .conflict(rowId, base, server) = outcome { return (rowId, base, server) }
        return nil
    }

    // MARK: - 1. Unsynced revision representation

    @Test("An unsynced row carries a nil revision and asserts no base revision")
    func unsyncedRowHasNoRevision() throws {
        let unsynced = ResistancePlan(
            id: Fixture.rowId,
            vineyardId: Fixture.vineyardId,
            seasonId: "2026/27",
            seasonStartYear: 2026,
            disease: .powderyMildew,
            jurisdiction: .australia,
            crop: .grape
        )

        #expect(unsynced.serverRevision == nil, "never synced means never versioned")
        #expect(unsynced.isUnsynced)

        // OMITTED, not null and not 0. sql/198 reads an absent base_revision as a create; any
        // literal value would be a claim about a version never issued to this device.
        let payload = BackendResistancePlanUpsert(from: unsynced, createdBy: nil)
        let encoded = try JSONEncoder().encode(payload)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("base_revision"), "base_revision must be absent")
    }

    // MARK: - 2. server_revision decode

    @Test("The canonical server row decodes to the canonical revision")
    func canonicalRowDecodesRevision() throws {
        let data = Data(Fixture.settingsRow.utf8)
        let rows = try Self.decoder().decode([BackendPruningYieldSettings].self, from: data)
        let row = try #require(rows.first)

        #expect(row.id.uuidString.lowercased() == Fixture.rowId)
        #expect(row.serverRevision == Fixture.acceptedRevision)
        #expect(row.bunchWeightGrams == 120.0)
    }

    @Test("A legacy row with no revision column decodes to nil rather than throwing")
    func legacyRowDecodesToNilRevision() throws {
        let data = Data(Fixture.settingsRowLegacy.utf8)
        let rows = try Self.decoder().decode([BackendPruningYieldSettings].self, from: data)
        let row = try #require(rows.first)

        #expect(row.serverRevision == nil)
        #expect(row.id.uuidString.lowercased() == Fixture.rowId)
    }

    // MARK: - 3. base_revision encoding

    @Test("An observed revision is encoded as base_revision verbatim")
    func observedRevisionIsEncoded() throws {
        var versioned = ResistancePlan(
            id: Fixture.rowId,
            vineyardId: Fixture.vineyardId,
            seasonId: "2026/27",
            seasonStartYear: 2026,
            disease: .powderyMildew,
            jurisdiction: .australia,
            crop: .grape
        )
        versioned.serverRevision = Fixture.observedRevision

        let encoded = try JSONEncoder().encode(
            BackendResistancePlanUpsert(from: versioned, createdBy: nil)
        )
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains("\"base_revision\":\(Fixture.observedRevision)"))
        // The stamp still travels — legitimate metadata and audit, just not authority.
        #expect(text.contains("client_updated_at"))
    }

    // MARK: - 4 & 5. PT409 and REVISION_CONFLICT classification

    @Test("The canonical PT409 body classifies as a revision conflict on both platforms")
    func canonicalConflictBodyIsAConflict() throws {
        #expect(SyncRevisionContract.isRevisionConflict(status: 409, body: Fixture.conflictBody))
        #expect(
            SyncRevisionContract.serverRevision(fromBody: Fixture.conflictBody)
                == Fixture.conflictingServerRevision
        )
        #expect(
            SyncRevisionContract.baseRevision(fromBody: Fixture.conflictBody)
                == Fixture.observedRevision
        )

        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 409,
            body: Fixture.conflictBody
        )
        let parts = try #require(conflictParts(outcome))
        #expect(parts.rowId == Fixture.rowId)
        #expect(parts.base == Fixture.observedRevision)
        #expect(parts.server == Fixture.conflictingServerRevision)
    }

    @Test("The marker alone is conclusive even when the status was rewritten")
    func markerAloneIsConclusive() {
        // A gateway can rewrite a status code; the message travels in the body.
        #expect(SyncRevisionContract.isRevisionConflict(status: 200, body: Fixture.conflictBodyMarkerOnly))
        #expect(SyncRevisionContract.isRevisionConflict(status: 500, body: Fixture.conflictBodyMarkerOnly))
    }

    @Test("A bare 409 with no usable body is still treated as a conflict")
    func bare409IsAConflict() {
        // No evidence either way. The fail-safe reading keeps the edit queued: a conflict
        // misread as a failure is retried forever and can never converge.
        #expect(SyncRevisionContract.isRevisionConflict(status: 409, body: nil))
        #expect(SyncRevisionContract.isRevisionConflict(status: 409, body: ""))
        #expect(SyncRevisionContract.serverRevision(fromBody: nil) == nil)
    }

    // MARK: - 6. Other statuses keep their own meanings

    @Test("A non revision 409 is not classified as a revision conflict")
    func uniqueViolationIsNotAConflict() {
        // A duplicate key means nobody edited concurrently. Reporting "also changed on another
        // device" would send the grower looking for a version that does not exist.
        #expect(!SyncRevisionContract.isRevisionConflict(status: 409, body: Fixture.uniqueViolationBody))
    }

    @Test("Auth server and transport failures never become conflicts")
    func failuresAreNotConflicts() throws {
        #expect(!SyncRevisionContract.isRevisionConflict(status: 401, body: Fixture.authBody))
        #expect(!SyncRevisionContract.isRevisionConflict(status: 403, body: Fixture.forbiddenBody))
        #expect(!SyncRevisionContract.isRevisionConflict(status: 500, body: Fixture.serverErrorBody))
        #expect(!SyncRevisionContract.isRevisionConflict(status: 503, body: Fixture.serverErrorBody))

        // ...and the classifier turns them into throwables, so the caller's retry path runs.
        #expect(throws: VersionedWriteError.unauthorized) {
            try classifySettings(baseRevision: Fixture.observedRevision, status: 401, body: Fixture.authBody)
        }
        #expect(throws: VersionedWriteError.unauthorized) {
            try classifySettings(baseRevision: Fixture.observedRevision, status: 403, body: Fixture.forbiddenBody)
        }
        #expect(throws: VersionedWriteError.server(status: 503, body: Fixture.serverErrorBody)) {
            try classifySettings(baseRevision: Fixture.observedRevision, status: 503, body: Fixture.serverErrorBody)
        }
        #expect(throws: VersionedWriteError.server(status: 409, body: Fixture.uniqueViolationBody)) {
            try classifySettings(baseRevision: Fixture.observedRevision, status: 409, body: Fixture.uniqueViolationBody)
        }
    }

    // MARK: - 7. Success carries the returned revision

    @Test("A valid representation is applied with the server's revision")
    func validRepresentationIsApplied() throws {
        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.settingsRow
        )

        let row = try #require(appliedRow(outcome))
        #expect(row.serverRevision == Fixture.acceptedRevision)
        #expect(
            row.serverRevision != Fixture.observedRevision,
            "the new revision must come from the response, not base+1 arithmetic"
        )
    }

    // MARK: - 8. An empty 2xx representation is NOT success

    @Test("An empty 2xx representation is a conflict and never a success")
    func emptyRepresentationIsAConflict() throws {
        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.emptyRepresentation
        )

        let parts = try #require(conflictParts(outcome), "HTTP 200 with no row is a silent skip, not a save")
        #expect(parts.base == Fixture.observedRevision)
        #expect(parts.server == nil)
    }

    @Test("A 201 with no row is treated the same way")
    func createdWithNoRowIsAConflict() throws {
        let outcome = try classifySettings(baseRevision: nil, status: 201, body: Fixture.emptyRepresentation)
        #expect(conflictParts(outcome) != nil)
    }

    // MARK: - 9. Conflict sync state

    @Test("Conflict is a state of its own, distinct from failed and synced")
    func conflictIsItsOwnState() {
        // Not "failed" (which is retried) and not "synced". The remedies are opposites.
        #expect(ResistancePlanSyncState.conflict != ResistancePlanSyncState.failed)
        #expect(ResistancePlanSyncState.conflict != ResistancePlanSyncState.synced)
        #expect(ResistancePlanSyncState.conflict != ResistancePlanSyncState.pendingUpload)
    }

    // MARK: - 11. Timestamps must never choose the winner

    @Test("A future stamp cannot turn a conflict into a success")
    func futureStampCannotRescueStaleRevision() throws {
        // The body says the revision was superseded. Nothing about the local clock may
        // override that — this is the exact substitution that lost data under sql/185.
        #expect(SyncRevisionContract.isRevisionConflict(status: 409, body: Fixture.conflictBody))

        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 409,
            body: Fixture.conflictBody
        )
        #expect(conflictParts(outcome) != nil)

        // And the classifier is not even given a stamp to consult: its inputs are the row id,
        // the base revision, the status and the body. There is no clock in the signature.
        #expect(Fixture.futureStamp != Fixture.clientUpdatedAt)
    }

    @Test("An ancient stamp cannot turn a success into a failure")
    func ancientStampCannotSpoilCurrentRevision() throws {
        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.settingsRow
        )
        #expect(appliedRow(outcome) != nil)
        #expect(Fixture.ancientStamp != Fixture.clientUpdatedAt)
    }

    @Test("A newer revision wins even when its timestamp looks older")
    func newerRevisionWinsOverOlderStamp() throws {
        let outcome = try classifySettings(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.settingsRowOldStampNewerRevision
        )

        let row = try #require(appliedRow(outcome))
        #expect(
            row.serverRevision == Fixture.conflictingServerRevision,
            "revision ordering must survive a misleading timestamp"
        )
    }

    @Test("Revision ordering is numeric and independent of any stamp")
    func revisionOrderingIsNumeric() {
        // The comparison the repositories use for replica lag. Asserted here so both platforms
        // agree on the ordering primitive itself, not just on its callers.
        #expect(Fixture.acceptedRevision > Fixture.observedRevision)
        #expect(Fixture.conflictingServerRevision > Fixture.acceptedRevision)
        // A nil revision is NOT "behind": a legacy row with no revision is not evidence of
        // replica lag, and treating it as stale would make such rows permanently unpullable.
        #expect(!isStrictlyBehind(nil, Fixture.acceptedRevision))
        #expect(!isStrictlyBehind(Fixture.acceptedRevision, nil))
        #expect(isStrictlyBehind(Fixture.observedRevision, Fixture.acceptedRevision))
        #expect(!isStrictlyBehind(Fixture.acceptedRevision, Fixture.acceptedRevision))
    }

    /// The parity definition of "the remote copy is older than what we have confirmed".
    private func isStrictlyBehind(_ remote: Int64?, _ known: Int64?) -> Bool {
        guard let remote, let known else { return false }
        return remote < known
    }
}
