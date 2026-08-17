import Foundation
import Testing

@testable import VineTrack

/// sql/198 revision-contract tests for `pruning_seasons` on iOS.
///
/// Mirrors `PruningSeasonRevisionSyncTest.kt` on Android. These assert the REAL production
/// pieces — the real wire encoder, the real row decoder, the real shared classifier and the
/// real persisted outbox metadata — rather than a test double that could agree with itself.
///
/// The property under test throughout: a DEVICE CLOCK never decides whether an edit is stale.
/// Only the server-issued `server_revision` does. Every clock-based fixture here exists to
/// prove the clock is inert.
@MainActor
struct PruningSeasonRevisionSyncTests {

    // MARK: - Fixture

    private enum Fixture {
        static let rowId = UUID(uuidString: "9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f")!
        static let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        static let paddockId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        static let seasonYear = 2026

        /// The revision the client observed and will assert as `base_revision`.
        static let observedRevision: Int64 = 6
        /// What the server issues when it accepts that write.
        static let acceptedRevision: Int64 = 7
        /// Where the row had actually moved on to when it refused a stale write.
        static let conflictingServerRevision: Int64 = 12

        /// A stored row at ``acceptedRevision``.
        static let seasonRow = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "season_year":2026,"start_date":"2026-06-01","due_date":"2026-09-15",
          "pruning_method":"spur","assigned_crew":"Crew A","working_days":[1,2,3,4,5],
          "estimated_labour_hours":120.0,"notes":"","status":"active",
          "client_updated_at":"2026-08-17T02:00:00Z","server_revision":7}]
        """

        /// The same row as an OLDER CLIENT left it: no revision column at all.
        static let seasonRowLegacy = """
        [{"id":"9f8e7d6c-5b4a-4392-8271-0a1b2c3d4e5f",
          "vineyard_id":"11111111-1111-4111-8111-111111111111",
          "paddock_id":"22222222-2222-4222-8222-222222222222",
          "season_year":2026,"start_date":"2026-06-01","due_date":"2026-09-15",
          "pruning_method":"spur","assigned_crew":"Crew A","working_days":[1,2,3,4,5],
          "estimated_labour_hours":120.0,"notes":"","status":"active",
          "client_updated_at":"2026-08-17T02:00:00Z"}]
        """

        /// Exactly what `reject_stale_client_write()` raises under sql/198.
        static let conflictBody = #"{"code":"PT409","details":"{\"code\": \"REVISION_CONFLICT\", \"server_revision\": 12, \"base_revision\": 6}","hint":"Reload the row and reapply the change","message":"REVISION_CONFLICT"}"#

        /// The active-season unique index — a 409 that is NOT a revision conflict.
        static let uniqueViolationBody = #"{"code":"23505","details":"Key (vineyard_id, paddock_id, season_year) already exists.","message":"duplicate key value violates unique constraint \"pruning_seasons_active_unique\""}"#

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

    private func setup(serverRevision: Int64?) -> PruningBlockSetup {
        PruningBlockSetup(
            id: Fixture.rowId,
            vineyardId: Fixture.vineyardId,
            paddockId: Fixture.paddockId,
            seasonYear: Fixture.seasonYear,
            method: .spur,
            crew: "Crew A",
            notes: "",
            serverRevision: serverRevision
        )
    }

    /// Encodes through the REAL production payload builder.
    private func encodedUpsert(
        _ setup: PruningBlockSetup,
        clientUpdatedAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) throws -> String {
        let payload = BackendPruningSeason.upsert(from: setup, createdBy: nil, clientUpdatedAt: clientUpdatedAt)
        return String(decoding: try Self.encoder().encode(payload), as: UTF8.self)
    }

    /// Runs a response through the REAL production classification, with the same decode the
    /// repository performs.
    private func classify(
        baseRevision: Int64?,
        status: Int,
        body: String?
    ) throws -> VersionedWriteOutcome<PruningBlockSetup> {
        let local = setup(serverRevision: baseRevision)
        return try VersionedWriteClassifier.classify(
            rowId: Fixture.rowId.uuidString,
            baseRevision: baseRevision,
            status: status,
            body: body
        ) { text in
            guard let row = VersionedRepresentation.first(in: text) else { return nil }
            var applied = local
            applied.serverRevision = row.serverRevision
            return applied
        }
    }

    private func appliedRow(_ outcome: VersionedWriteOutcome<PruningBlockSetup>) -> PruningBlockSetup? {
        if case let .applied(row) = outcome { return row }
        return nil
    }

    private func conflictParts(
        _ outcome: VersionedWriteOutcome<PruningBlockSetup>
    ) -> (rowId: String, base: Int64?, server: Int64?)? {
        if case let .conflict(rowId, base, server) = outcome { return (rowId, base, server) }
        return nil
    }

    /// A persistence store over its own throwaway directory, so a "restart" can be simulated by
    /// constructing a SECOND reader over the same files.
    private func temporaryPersistence() throws -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinetrack-season-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PersistenceStore(directory: directory)
    }

    private func temporaryMetadata(key: String) throws -> (ManagementSyncMetadata, PersistenceStore) {
        let persistence = try temporaryPersistence()
        return (ManagementSyncMetadata(key: key, persistence: persistence), persistence)
    }

    // MARK: - 1. Create

    @Test("A brand-new season omits base_revision entirely")
    func createOmitsBaseRevision() throws {
        let unsynced = setup(serverRevision: nil)
        #expect(unsynced.serverRevision == nil, "never synced means never versioned")

        let text = try encodedUpsert(unsynced)

        // OMITTED, not null and not 0. sql/198 reads an absent base_revision as a create; any
        // literal value would be a claim about a version the server never issued this device.
        #expect(!text.contains("base_revision"), "base_revision must be absent for a create")
        // The metadata timestamp still travels — it is display/audit data, and the legacy
        // trigger path used by older released clients still reads it.
        #expect(text.contains("client_updated_at"))
    }

    // MARK: - 2. Normal update

    @Test("A synced season asserts its observed revision as base_revision")
    func updateSendsObservedRevision() throws {
        let text = try encodedUpsert(setup(serverRevision: Fixture.observedRevision))

        #expect(text.contains("\"base_revision\":6"), "the observed revision travels verbatim")
    }

    @Test("A successful write adopts the revision the server returned, never base + 1")
    func successAdoptsReturnedRevision() throws {
        let outcome = try classify(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.seasonRow
        )

        let row = try #require(appliedRow(outcome))
        #expect(row.serverRevision == Fixture.acceptedRevision)
        // Guarding against the tempting shortcut: here base + 1 happens to equal 7, so assert
        // the value came from the RESPONSE by proving a gapped server revision is honoured too.
        let gapped = try classify(
            baseRevision: Fixture.observedRevision,
            status: 200,
            body: Fixture.seasonRow.replacingOccurrences(of: "\"server_revision\":7", with: "\"server_revision\":41")
        )
        #expect(appliedRow(gapped)?.serverRevision == 41, "the server's number wins, not arithmetic")
    }

    // MARK: - 3. Slow clock

    @Test("A slow device clock does not affect the concurrency decision")
    func slowClockStillSucceeds() throws {
        // Server is at revision 6; this phone's clock is hours BEHIND real time.
        let hoursBehind = Date(timeIntervalSince1970: 1_786_000_000 - 6 * 3600)
        let text = try encodedUpsert(setup(serverRevision: Fixture.observedRevision), clientUpdatedAt: hoursBehind)

        // The edit is based on the CURRENT revision, so it must be accepted whatever the clock
        // says. Under the old timestamp rule this write was silently discarded.
        #expect(text.contains("\"base_revision\":6"))

        let outcome = try classify(baseRevision: Fixture.observedRevision, status: 200, body: Fixture.seasonRow)
        #expect(appliedRow(outcome) != nil, "a valid edit from a slow phone must succeed")
    }

    @Test("Clock skew changes nothing about what is asserted as base_revision")
    func clockSkewDoesNotChangeBaseRevision() throws {
        let behind = try encodedUpsert(
            setup(serverRevision: Fixture.observedRevision),
            clientUpdatedAt: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let ahead = try encodedUpsert(
            setup(serverRevision: Fixture.observedRevision),
            clientUpdatedAt: Date(timeIntervalSince1970: 4_000_000_000)
        )

        // Two payloads differing ONLY in the clock must make the identical concurrency claim.
        #expect(behind.contains("\"base_revision\":6"))
        #expect(ahead.contains("\"base_revision\":6"))
    }

    // MARK: - 4. Fast clock

    @Test("A fast device clock cannot poison the row against later writers")
    func fastClockDoesNotLockOutTheRow() throws {
        // Phone A runs hours AHEAD and writes successfully at revision 6 -> 7.
        let ahead = Date(timeIntervalSince1970: 1_786_000_000 + 6 * 3600)
        let firstText = try encodedUpsert(setup(serverRevision: Fixture.observedRevision), clientUpdatedAt: ahead)
        #expect(firstText.contains("\"base_revision\":6"))

        let first = try classify(baseRevision: Fixture.observedRevision, status: 200, body: Fixture.seasonRow)
        let stored = try #require(appliedRow(first))
        #expect(stored.serverRevision == Fixture.acceptedRevision)

        // A SECOND edit based on the revision the server just returned must also succeed, with
        // a NORMAL clock. Previously the fast device's future timestamp sat on the row and
        // refused every other writer until real time caught up.
        let secondText = try encodedUpsert(stored, clientUpdatedAt: Date(timeIntervalSince1970: 1_786_000_100))
        #expect(secondText.contains("\"base_revision\":7"), "the next edit builds on the returned revision")

        let second = try classify(
            baseRevision: Fixture.acceptedRevision,
            status: 200,
            body: Fixture.seasonRow.replacingOccurrences(of: "\"server_revision\":7", with: "\"server_revision\":8")
        )
        #expect(appliedRow(second)?.serverRevision == 8)
    }

    // MARK: - 5. Genuine stale revision

    @Test("A genuinely stale revision is a conflict even when the local stamp is newer")
    func staleRevisionIsAConflict() throws {
        // The client read revision 6; another client moved the row to 12.
        let outcome = try classify(
            baseRevision: Fixture.observedRevision,
            status: 409,
            body: Fixture.conflictBody
        )

        let parts = try #require(conflictParts(outcome), "PT409 REVISION_CONFLICT must classify as a conflict")
        #expect(parts.base == Fixture.observedRevision)
        #expect(parts.server == Fixture.conflictingServerRevision)
        // The revision decides — not the fact that this device's clock reads later than the
        // server's stored timestamp.
    }

    @Test("A non-revision 409 is NOT reported as a concurrency conflict")
    func uniqueViolationIsNotAConflict() throws {
        // The active-season unique index means nobody raced this edit; the write is simply
        // invalid. Calling it a conflict would send the grower hunting for a second version
        // that does not exist while the real cause goes unreported.
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

        // The legacy silent-skip signature. Reporting it as saved is the original defect: the
        // grower saw a tick and their edit was gone.
        #expect(conflictParts(outcome) != nil)
    }

    // MARK: - 6/7. Conflict retains the outbox, and survives a restart

    @Test("A conflict keeps the queued edit and survives an app restart")
    func conflictSurvivesRestart() throws {
        let (metadata, persistence) = try temporaryMetadata(key: "test_pruning_season_metadata")
        let queuedAt = Date(timeIntervalSince1970: 1_786_000_000)

        metadata.markDirty(Fixture.rowId, at: queuedAt)
        metadata.markRevisionConflict(
            Fixture.rowId,
            baseRevision: Fixture.observedRevision,
            serverRevision: Fixture.conflictingServerRevision
        )

        // Still queued: the authored values are the grower's only copy of this edit.
        #expect(metadata.pendingUpserts[Fixture.rowId] == queuedAt, "a conflict must NOT clear the outbox")
        #expect(metadata.conflictedIds.contains(Fixture.rowId))

        // RESTART: a second instance over the same files, as a cold launch would build.
        let restarted = ManagementSyncMetadata(key: "test_pruning_season_metadata", persistence: persistence)

        #expect(restarted.pendingUpserts[Fixture.rowId] == queuedAt, "the authored payload must survive a restart")
        let mark = try #require(restarted.revisionConflict(for: Fixture.rowId), "conflict state must survive a restart")
        #expect(mark.baseRevision == Fixture.observedRevision)
        #expect(mark.serverRevision == Fixture.conflictingServerRevision)
    }

    @Test("A conflicted row is excluded from the replay candidate set")
    func conflictIsNotRetryable() throws {
        let (metadata, _) = try temporaryMetadata(key: "test_pruning_season_retry")
        let other = UUID()
        metadata.markDirty(Fixture.rowId, at: Date())
        metadata.markDirty(other, at: Date())
        metadata.markRevisionConflict(Fixture.rowId, baseRevision: 6, serverRevision: 12)

        // The same filter the push loop applies: conflicted rows are skipped, everything else
        // still replays. Retrying a conflict resends the same stale base_revision and is
        // refused every single time, so it would be an infinite loop that never converges.
        let replayable = metadata.pendingUpserts.keys.filter { !metadata.conflictedIds.contains($0) }

        #expect(replayable == [other])
        #expect(metadata.pendingUpserts.count == 2, "the conflicted edit stays queued, just not retried")
    }

    @Test("Clearing the queue for a row also clears its conflict")
    func resolvingClearsConflict() throws {
        let (metadata, _) = try temporaryMetadata(key: "test_pruning_season_clear")
        metadata.markDirty(Fixture.rowId, at: Date())
        metadata.markRevisionConflict(Fixture.rowId, baseRevision: 6, serverRevision: 12)

        metadata.clearDirty([Fixture.rowId])

        #expect(metadata.conflictedIds.isEmpty, "nothing queued means nothing left to review")
    }

    // MARK: - 8. Transport failure stays retryable

    @Test("A transport failure is retryable and is never mistaken for a conflict")
    func networkFailureRemainsRetryable() {
        let offline = URLError(.notConnectedToInternet)

        #expect(!SyncRevisionContract.isRevisionConflict(offline), "no connection is not a conflict")
        let detail = BackendErrorDiagnostics.classify(offline, endpoint: "Pruning Seasons")
        #expect(detail.kind == .retryable, "a dropped connection must retry, unlike a conflict")
    }

    @Test("Auth and server failures throw rather than becoming conflicts")
    func authAndServerFailuresThrow() {
        #expect(throws: VersionedWriteError.self) {
            _ = try classify(baseRevision: 6, status: 401, body: #"{"message":"JWT expired"}"#)
        }
        #expect(throws: VersionedWriteError.self) {
            _ = try classify(baseRevision: 6, status: 500, body: #"{"message":"upstream unavailable"}"#)
        }
    }

    // MARK: - 9. Replica lag

    @Test("A pull from a lagging replica cannot undo a confirmed newer write")
    func replicaLagIsIgnored() {
        // The write was confirmed at revision 8; an immediate read hits a replica still on 7.
        #expect(SyncRevisionContract.isRemoteBehind(observed: 8, remote: 7))
        // Once the replica catches up, normal merging resumes — no timestamp involved.
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: 8), "equal is merged, not rejected")
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: 9))
    }

    @Test("An unknown revision on either side is not treated as replica lag")
    func unknownRevisionIsNotLag() {
        // A legacy row is not evidence of lag; treating it as behind would make such rows
        // permanently unpullable, freezing them at whatever this device last cached.
        #expect(!SyncRevisionContract.isRemoteBehind(observed: nil, remote: 7))
        #expect(!SyncRevisionContract.isRemoteBehind(observed: 8, remote: nil))
        #expect(!SyncRevisionContract.isRemoteBehind(observed: nil, remote: nil))
    }

    @Test("The observed-revision anchor persists across a restart")
    func observedRevisionPersists() throws {
        let (metadata, persistence) = try temporaryMetadata(key: "test_pruning_season_observed")
        metadata.setObservedRevision(Fixture.acceptedRevision, for: Fixture.rowId)

        let restarted = ManagementSyncMetadata(key: "test_pruning_season_observed", persistence: persistence)

        #expect(restarted.observedRevision(for: Fixture.rowId) == Fixture.acceptedRevision)
    }

    // MARK: - 10. Old-client row

    @Test("A row last written by an older client decodes, then becomes versioned on first edit")
    func oldClientRowIsAdopted() throws {
        let data = Data(Fixture.seasonRowLegacy.utf8)
        let rows = try Self.decoder().decode([BackendPruningSeason].self, from: data)
        let row = try #require(rows.first, "a legacy row must decode, not throw")

        #expect(row.serverRevision == nil, "the original writer knew nothing about revisions")
        let local = row.toPruningBlockSetup()
        #expect(local.serverRevision == nil)
        #expect(local.crew == "Crew A", "the rest of the row is intact")

        // Editing it omits base_revision, which sql/198 accepts, and the response then makes
        // the row versioned from that write on. The original writer never had to know.
        let text = try encodedUpsert(local)
        #expect(!text.contains("base_revision"))

        let outcome = try classify(baseRevision: nil, status: 200, body: Fixture.seasonRow)
        #expect(appliedRow(outcome)?.serverRevision == Fixture.acceptedRevision)
    }

    @Test("The canonical server row decodes its revision")
    func canonicalRowDecodesRevision() throws {
        let rows = try Self.decoder().decode([BackendPruningSeason].self, from: Data(Fixture.seasonRow.utf8))
        let row = try #require(rows.first)

        #expect(row.serverRevision == Fixture.acceptedRevision)
        #expect(row.toPruningBlockSetup().serverRevision == Fixture.acceptedRevision)
    }

    // MARK: - 11. Revisions are server state, never authored locally

    @Test("A local edit cannot invent or downgrade a server revision")
    func localSaveRestampsRevisionFromCache() throws {
        let store = PruningStore(persistence: try temporaryPersistence())
        let synced = setup(serverRevision: Fixture.observedRevision)
        store.applyRemoteSeasonUpsert(synced)

        // An editor rebuilds the setup from its form fields, so the value it holds carries NO
        // revision (or, if it was copied from a stale screen, an old one). Either would be a
        // forgery: nil downgrades a synced season to a create, and an old number is refused
        // forever.
        var edited = setup(serverRevision: nil)
        edited.crew = "Crew B"
        store.upsertSetup(edited)

        let stored = store.setups.first { $0.id == Fixture.rowId }
        #expect(stored?.crew == "Crew B", "the grower's values are kept")
        #expect(stored?.serverRevision == Fixture.observedRevision, "the revision is re-stamped from cache")
    }
}
