import Foundation
import Testing

@testable import VineTrack

/// sql/198 revision-contract tests for `pruning_yield_settings` on iOS.
///
/// Mirrors `PruningYieldSettingsRevisionSyncTest.kt` on Android. Asserts the REAL production
/// encoder, row decoder, shared classifier and persisted outbox metadata.
///
/// This entity has one extra obligation the others do not. `client_updated_at` lost its role as
/// the CONCURRENCY authority, but it still has a second, unrelated job here: the sql/181
/// resurrection trigger detects a genuine client upsert by that value CHANGING
/// (`new.client_updated_at is distinct from old.client_updated_at`) and un-deletes a
/// soft-deleted block configuration on that basis. Removing the field, or freezing it, would
/// break un-deleting a block's settings — so the rule is "remove timestamp ORDERING as the
/// concurrency authority", not "remove the timestamp".
@MainActor
struct PruningYieldSettingsRevisionSyncTests {

    // MARK: - Fixture

    private enum Fixture {
        static let rowId = UUID(uuidString: "9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f")!
        static let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let paddockId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

        static let observedRevision: Int64 = 6
        static let acceptedRevision: Int64 = 7
        static let conflictingServerRevision: Int64 = 12

        static let settingsRow = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "client_updated_at":"2026-08-17T02:00:00Z","server_revision":7}]
        """

        /// The same row as an OLDER CLIENT left it: no revision column at all.
        static let settingsRowLegacy = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "client_updated_at":"2026-08-17T02:00:00Z"}]
        """

        /// The row the server returns after RESURRECTING a soft-deleted configuration:
        /// `deleted_at` back to null, and a fresh revision.
        static let settingsRowResurrected = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,"deleted_at":null,
          "client_updated_at":"2026-08-17T03:00:00Z","server_revision":8}]
        """

        /// A row that is still soft-deleted.
        static let settingsRowDeleted = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "prune_method":"spur","bunches_per_bud":1.5,"buds_per_spur":2.0,
          "spurs_per_vine":6.0,"buds_per_cane":10.0,"canes_per_vine":4.0,
          "vines_per_ha":2200.0,"bunch_weight_grams":120.0,
          "deleted_at":"2026-08-16T01:00:00Z",
          "client_updated_at":"2026-08-16T00:00:00Z","server_revision":5}]
        """

        static let conflictBody = #"{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 6}","hint":"Reload the row and reapply the change","message":"REVISION_CONFLICT"}"#

        static let uniqueViolationBody = #"{"code":"23505","details":"Key (vineyard_id, paddock_id) already exists.","message":"duplicate key value violates unique constraint"}"#

        static let emptyRepresentation = "[]"
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func settings(serverRevision: Int64?, bunchWeightGrams: Double = 120) -> PruningYieldSettings {
        PruningYieldSettings(
            id: Fixture.rowId,
            vineyardId: Fixture.vineyardId,
            paddockId: Fixture.paddockId,
            vinesPerHa: 2200,
            bunchWeightGrams: bunchWeightGrams,
            serverRevision: serverRevision
        )
    }

    private func encodedUpsert(
        _ settings: PruningYieldSettings,
        clientUpdatedAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) throws -> String {
        let payload = BackendPruningYieldSettings.upsert(
            from: settings,
            createdBy: nil,
            clientUpdatedAt: clientUpdatedAt
        )
        return String(decoding: try Self.encoder().encode(payload), as: UTF8.self)
    }

    /// Runs a response through the REAL production classification, with the same decode the
    /// repository performs.
    private func classify(
        baseRevision: Int64?,
        status: Int,
        body: String?
    ) throws -> VersionedWriteOutcome<PruningYieldSettings> {
        let local = settings(serverRevision: baseRevision)
        return try VersionedWriteClassifier.classify(
            rowId: Fixture.rowId.uuidString,
            baseRevision: baseRevision,
            status: status,
            body: body
        ) { text in
            guard let row = VersionedRepresentation.first(in: text) else { return nil }
            var applied = local
            if let id = row.id { applied.id = id }
            applied.serverRevision = row.serverRevision
            return applied
        }
    }

    private func appliedRow(_ outcome: VersionedWriteOutcome<PruningYieldSettings>) -> PruningYieldSettings? {
        if case let .applied(row) = outcome { return row }
        return nil
    }

    private func conflictParts(
        _ outcome: VersionedWriteOutcome<PruningYieldSettings>
    ) -> (rowId: String, base: Int64?, server: Int64?)? {
        if case let .conflict(rowId, base, server) = outcome { return (rowId, base, server) }
        return nil
    }

    private func temporaryPersistence() throws -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinetrack-settings-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PersistenceStore(directory: directory)
    }

    private func temporaryMetadata(key: String) throws -> (OperationsSyncMetadata, PersistenceStore) {
        let persistence = try temporaryPersistence()
        return (OperationsSyncMetadata(key: key, persistence: persistence), persistence)
    }

    // MARK: - 1. Create

    @Test("A brand-new block configuration omits base_revision entirely")
    func createOmitsBaseRevision() throws {
        let text = try encodedUpsert(settings(serverRevision: nil))

        // OMITTED, not null and not 0 — sql/198 reads an absent base_revision as a create.
        #expect(!text.contains("base_revision"))
        #expect(text.contains("client_updated_at"))
    }

    // MARK: - 2. Normal update

    @Test("A synced configuration asserts its observed revision as base_revision")
    func updateSendsObservedRevision() throws {
        let text = try encodedUpsert(settings(serverRevision: Fixture.observedRevision))

        #expect(text.contains("\"base_revision\":6"))
    }

    @Test("A successful write adopts the revision the server returned, never base + 1")
    func successAdoptsReturnedRevision() throws {
        let outcome = try classify(baseRevision: Fixture.observedRevision, status: 200, body: Fixture.settingsRow)
        #expect(appliedRow(outcome)?.serverRevision == Fixture.acceptedRevision)

        // Prove the number came from the RESPONSE rather than arithmetic on the base.
        let gapped = try classify(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.settingsRow.replacingOccurrences(of: "\"server_revision\":7", with: "\"server_revision\":41")
        )
        #expect(appliedRow(gapped)?.serverRevision == 41)
    }

    @Test("The id the block converged on is adopted from the representation")
    func convergedIdIsAdopted() throws {
        // The conflict target is (vineyard_id, paddock_id), NOT the primary key, so the
        // surviving row can be one another device minted. Keeping the local id would leave this
        // device writing to a row that no longer exists.
        let serverId = "abcdefab-1234-4123-8123-abcdefabcdef"
        let body = Fixture.settingsRow.replacingOccurrences(
            of: "\"id\":\"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f\"",
            with: "\"id\":\"\(serverId)\""
        )

        let outcome = try classify(baseRevision: Fixture.observedRevision, status: 200, body: body)

        #expect(appliedRow(outcome)?.id.uuidString.lowercased() == serverId)
    }

    // MARK: - 3. Slow clock

    @Test("A slow device clock does not affect the concurrency decision")
    func slowClockStillSucceeds() throws {
        let hoursBehind = Date(timeIntervalSince1970: 1_786_000_000 - 6 * 3600)
        let text = try encodedUpsert(settings(serverRevision: Fixture.observedRevision), clientUpdatedAt: hoursBehind)

        #expect(text.contains("\"base_revision\":6"))

        let outcome = try classify(baseRevision: Fixture.observedRevision, status: 200, body: Fixture.settingsRow)
        #expect(appliedRow(outcome) != nil, "a valid edit from a slow phone must succeed")
    }

    @Test("Clock skew changes nothing about what is asserted as base_revision")
    func clockSkewDoesNotChangeBaseRevision() throws {
        let behind = try encodedUpsert(
            settings(serverRevision: Fixture.observedRevision),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let ahead = try encodedUpsert(
            settings(serverRevision: Fixture.observedRevision),
            clientUpdatedAt: Date(timeIntervalSince1970: 4_000_000_000)
        )

        #expect(behind.contains("\"base_revision\":6"))
        #expect(ahead.contains("\"base_revision\":6"))
    }

    // MARK: - 4. Fast clock

    @Test("A fast device clock cannot poison the row against later writers")
    func fastClockDoesNotLockOutTheRow() throws {
        let ahead = Date(timeIntervalSince1970: 1_786_000_000 + 6 * 3600)
        let firstText = try encodedUpsert(settings(serverRevision: Fixture.observedRevision), clientUpdatedAt: ahead)
        #expect(firstText.contains("\"base_revision\":6"))

        let stored = try #require(
            appliedRow(try classify(baseRevision: Fixture.observedRevision, status: 200, body: Fixture.settingsRow))
        )
        #expect(stored.serverRevision == Fixture.acceptedRevision)

        // A second edit based on the returned revision succeeds with a NORMAL clock.
        let secondText = try encodedUpsert(stored, clientUpdatedAt: Date(timeIntervalSince1970: 1_786_000_100))
        #expect(secondText.contains("\"base_revision\":7"))
    }

    // MARK: - 5. Genuine stale revision

    @Test("A genuinely stale revision is a conflict even when the local stamp is newer")
    func staleRevisionIsAConflict() throws {
        let outcome = try classify(baseRevision: Fixture.observedRevision, status: 409, body: Fixture.conflictBody)

        let parts = try #require(conflictParts(outcome))
        #expect(parts.base == Fixture.observedRevision)
        #expect(parts.server == Fixture.conflictingServerRevision)
    }

    @Test("A non-revision 409 is NOT reported as a concurrency conflict")
    func uniqueViolationIsNotAConflict() {
        #expect(throws: VersionedWriteError.self) {
            _ = try classify(baseRevision: Fixture.observedRevision, status: 409, body: Fixture.uniqueViolationBody)
        }
    }

    @Test("An empty 2xx representation is treated as a refused write, not a success")
    func emptyRepresentationIsNotSuccess() throws {
        let outcome = try classify(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.emptyRepresentation
        )

        #expect(conflictParts(outcome) != nil)
    }

    // MARK: - 6/7. Conflict retains the outbox, and survives a restart

    @Test("A conflict keeps the queued edit and survives an app restart")
    func conflictSurvivesRestart() throws {
        let (metadata, persistence) = try temporaryMetadata(key: "test_pys_metadata")
        let queuedAt = Date(timeIntervalSince1970: 1_786_000_000)

        metadata.markDirty(Fixture.rowId, at: queuedAt)
        metadata.markRevisionConflict(
            Fixture.rowId,
            baseRevision: Fixture.observedRevision,
            serverRevision: Fixture.conflictingServerRevision
        )

        #expect(metadata.pendingUpserts[Fixture.rowId] == queuedAt, "a conflict must NOT clear the outbox")

        // RESTART: a second instance over the same files.
        let restarted = OperationsSyncMetadata(key: "test_pys_metadata", persistence: persistence)

        #expect(restarted.pendingUpserts[Fixture.rowId] == queuedAt, "the authored payload must survive")
        let mark = try #require(restarted.revisionConflict(for: Fixture.rowId))
        #expect(mark.baseRevision == Fixture.observedRevision)
        #expect(mark.serverRevision == Fixture.conflictingServerRevision)
    }

    @Test("A conflicted row is excluded from the replay candidate set")
    func conflictIsNotRetryable() throws {
        let (metadata, _) = try temporaryMetadata(key: "test_pys_retry")
        let other = UUID()
        metadata.markDirty(Fixture.rowId, at: Date())
        metadata.markDirty(other, at: Date())
        metadata.markRevisionConflict(Fixture.rowId, baseRevision: 6, serverRevision: 12)

        let replayable = metadata.pendingUpserts.keys.filter { !metadata.conflictedIds.contains($0) }

        #expect(replayable == [other])
        #expect(metadata.pendingUpserts.count == 2, "the conflicted edit stays queued, just not retried")
    }

    @Test("A fresh local edit supersedes a stale failure but keeps the row queued")
    func freshEditClearsFailureFlag() throws {
        let (metadata, _) = try temporaryMetadata(key: "test_pys_fresh")
        metadata.markDirty(Fixture.rowId, at: Date())
        metadata.markUpsertsFailed([Fixture.rowId])

        metadata.markDirty(Fixture.rowId, at: Date())

        #expect(!metadata.isUpsertFailed(Fixture.rowId))
        #expect(metadata.pendingUpserts[Fixture.rowId] != nil)
    }

    // MARK: - 8. Transport failure stays retryable

    @Test("A transport failure is retryable and is never mistaken for a conflict")
    func networkFailureRemainsRetryable() {
        let offline = URLError(.networkConnectionLost)

        #expect(!SyncRevisionContract.isRevisionConflict(offline))
        #expect(BackendErrorDiagnostics.classify(offline, endpoint: "Pruning Yield Settings").kind == .retryable)
    }

    @Test("Auth and server failures throw rather than becoming conflicts")
    func authAndServerFailuresThrow() {
        #expect(throws: VersionedWriteError.self) {
            _ = try classify(baseRevision: 6, status: 403, body: #"{"message":"permission denied"}"#)
        }
        #expect(throws: VersionedWriteError.self) {
            _ = try classify(baseRevision: 6, status: 503, body: #"{"message":"upstream unavailable"}"#)
        }
    }

    // MARK: - 9. Replica lag

    @Test("A pull from a lagging replica cannot undo a confirmed newer write")
    func replicaLagIsIgnored() {
        #expect(SyncRevisionContract.isRemoteBehind(observed: 8, remote: 7))
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: 8))
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: 9))
        // A legacy row is not evidence of lag.
        #expect(!SyncRevisionContract.isRemoteBehind(observed: nil, remote: 7))
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: nil))
    }

    // MARK: - 10. Old-client row

    @Test("A row last written by an older client decodes, then becomes versioned on first edit")
    func oldClientRowIsAdopted() throws {
        let rows = try Self.decoder().decode([BackendPruningYieldSettings].self, from: Data(Fixture.settingsRowLegacy.utf8))
        let row = try #require(rows.first, "a legacy row must decode, not throw")

        #expect(row.serverRevision == nil)
        let local = row.toPruningYieldSettings()
        #expect(local.serverRevision == nil)
        #expect(local.bunchWeightGrams == 120.0, "the rest of the row is intact")

        let text = try encodedUpsert(local)
        #expect(!text.contains("base_revision"))

        let outcome = try classify(baseRevision: nil, status: 200, body: Fixture.settingsRow)
        #expect(appliedRow(outcome)?.serverRevision == Fixture.acceptedRevision)
    }

    @Test("The canonical server row carries its revision into the local model")
    func canonicalRowCarriesRevision() throws {
        let rows = try Self.decoder().decode([BackendPruningYieldSettings].self, from: Data(Fixture.settingsRow.utf8))
        let row = try #require(rows.first)

        #expect(row.serverRevision == Fixture.acceptedRevision)
        #expect(row.toPruningYieldSettings().serverRevision == Fixture.acceptedRevision)
    }

    // MARK: - 11. Soft-delete resurrection (sql/181) must still work

    @Test("client_updated_at is ALWAYS sent, so the resurrection trigger can still fire")
    func resurrectionTimestampIsAlwaysSent() throws {
        // sql/181 un-deletes a soft-deleted configuration when a client upsert arrives with a
        // client_updated_at DIFFERENT to the stored one. If the revision work had dropped this
        // field (or sent it as null), un-deleting a block's settings would silently stop
        // working — the row would stay soft-deleted and the grower's saved values would look
        // permanently gone.
        let unsynced = try encodedUpsert(settings(serverRevision: nil))
        let synced = try encodedUpsert(settings(serverRevision: Fixture.observedRevision))

        #expect(unsynced.contains("client_updated_at"), "present even on a create")
        #expect(synced.contains("client_updated_at"), "present on a versioned update too")
        #expect(!unsynced.contains("\"client_updated_at\":null"), "never null — null defeats the trigger")
        #expect(!synced.contains("\"client_updated_at\":null"))
    }

    @Test("Two successive edits send DIFFERENT client_updated_at values")
    func resurrectionChangeDetectionStillWorks() throws {
        // The trigger's test is `is distinct from`, so two edits must not send an identical
        // stamp. A frozen or constant timestamp would look like "no genuine client write" and
        // the row would stay deleted.
        let first = try encodedUpsert(
            settings(serverRevision: Fixture.observedRevision),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let second = try encodedUpsert(
            settings(serverRevision: Fixture.observedRevision, bunchWeightGrams: 130),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_786_003_600)
        )

        #expect(first != second)
        #expect(first.contains("2026") || first.contains("T"), "an ISO timestamp is sent, not an opaque token")
        // Same concurrency claim, different metadata stamp: ordering is no longer the authority,
        // but change DETECTION still has something to detect.
        #expect(first.contains("\"base_revision\":6"))
        #expect(second.contains("\"base_revision\":6"))
    }

    @Test("A resurrected row is applied with the fresh revision the server issued")
    func resurrectedRowAdoptsNewRevision() throws {
        let rows = try Self.decoder().decode(
            [BackendPruningYieldSettings].self,
            from: Data(Fixture.settingsRowResurrected.utf8)
        )
        let row = try #require(rows.first)

        #expect(row.deletedAt == nil, "the resurrection cleared the tombstone")
        #expect(row.serverRevision == 8, "and issued a new revision the next edit must assert")
    }

    @Test("A still-deleted row is recognised as a tombstone, not as live settings")
    func deletedRowIsATombstone() throws {
        let rows = try Self.decoder().decode(
            [BackendPruningYieldSettings].self,
            from: Data(Fixture.settingsRowDeleted.utf8)
        )
        let row = try #require(rows.first)

        #expect(row.deletedAt != nil)
        #expect(row.serverRevision == 5, "a tombstone still carries a revision")
    }

    // MARK: - 12. client_updated_at keeps its non-concurrency uses

    @Test("client_updated_at still populates the local updatedAt used for display")
    func timestampStillFeedsDisplayMetadata() throws {
        let rows = try Self.decoder().decode([BackendPruningYieldSettings].self, from: Data(Fixture.settingsRow.utf8))
        let row = try #require(rows.first)

        let local = row.toPruningYieldSettings()

        // Still surfaced as "when this was last edited" — metadata and audit, which is exactly
        // the role sql/198 leaves it. It simply no longer decides who wins.
        #expect(local.updatedAt == row.clientUpdatedAt)
    }

    @Test("A revision-only change is not treated as a user edit")
    func revisionIsNotAUserInput() {
        let before = settings(serverRevision: Fixture.observedRevision)
        var after = before
        after.serverRevision = Fixture.acceptedRevision

        // Autosave suppression compares INPUTS. If the revision counted as an input, every pull
        // would look like a user edit, fire a save, and burn a revision on every sync.
        #expect(before.inputsEqual(to: after))
    }

    // MARK: - 13. Observed-revision anchor

    @Test("The observed-revision anchor persists across a restart")
    func observedRevisionPersists() throws {
        let (metadata, persistence) = try temporaryMetadata(key: "test_pys_observed")
        metadata.setObservedRevision(Fixture.acceptedRevision, for: Fixture.rowId)

        let restarted = OperationsSyncMetadata(key: "test_pys_observed", persistence: persistence)

        #expect(restarted.observedRevision(for: Fixture.rowId) == Fixture.acceptedRevision)
    }

    @Test("A nil revision clears the anchor rather than storing a fabricated one")
    func nilRevisionClearsAnchor() throws {
        let (metadata, _) = try temporaryMetadata(key: "test_pys_anchor")
        metadata.setObservedRevision(Fixture.acceptedRevision, for: Fixture.rowId)

        metadata.setObservedRevision(nil, for: Fixture.rowId)

        #expect(metadata.observedRevision(for: Fixture.rowId) == nil)
    }
}
