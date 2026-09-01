import Testing
import Foundation
@testable import VineTrack

/// Focused safety suite for the block-sync hardening that followed the
/// 3.0.1 (85) cache-recovery work. Pins six production guarantees:
///
///  1. Pending changes for a NON-selected vineyard survive another
///     vineyard's sync (never reclaimed as "orphans").
///  2. A nil `lastSync` watermark (e.g. after a recovery reset) never turns
///     arbitrary cached rows into new server records — only known pending
///     local creations are seeded, and a seed failure fails the sync.
///  3. Decode recovery hydrates the server cache BEFORE push processing and
///     preserves + surfaces pending entries whose payload cannot be found.
///  4. Recovered blocks must be durably persisted and readable back from
///     disk before the sync advances its watermark or claims success.
///  5. Force Refresh never silently discards pending offline block changes.
///  6. Watermarks are server-derived, so an existing row edited during the
///     sync window is still received by the next incremental pull.
///
/// Pure logic — no network.
@MainActor
struct PaddockSyncSafetyTests {

    // MARK: - Mock repository (server-behaving: upserts land in serverRows)

    @MainActor
    final class ServerMockRepo: PaddockSyncRepositoryProtocol {
        var serverRows: [BackendPaddock] = []
        var upserted: [BackendPaddockUpsert] = []
        var failUpserts: Bool = false
        var fetchAllCalls: Int = 0

        func fetchPaddocks(vineyardId: UUID, since: Date?) async throws -> [BackendPaddock] {
            let rows = serverRows.filter { $0.vineyardId == vineyardId }
            guard let since else { return rows }
            // Mirrors the production `.gte("updated_at", ...)` comparison.
            return rows.filter { ($0.updatedAt ?? .distantPast) >= since }
        }

        func fetchAllPaddocks(vineyardId: UUID) async throws -> [BackendPaddock] {
            fetchAllCalls += 1
            return serverRows.filter { $0.vineyardId == vineyardId }
        }

        func fetchAllAccessiblePaddocks() async throws -> [BackendPaddock] {
            serverRows.filter { $0.deletedAt == nil }
        }

        func fetchPaddockIds(vineyardId: UUID) async throws -> [BackendPaddockIdRow] {
            serverRows
                .filter { $0.vineyardId == vineyardId }
                .map { BackendPaddockIdRow(id: $0.id, deletedAt: $0.deletedAt) }
        }

        func upsertPaddock(_ paddock: BackendPaddockUpsert) async throws {
            try await upsertPaddocks([paddock])
        }

        func upsertPaddocks(_ paddocks: [BackendPaddockUpsert]) async throws {
            if failUpserts { throw URLError(.notConnectedToInternet) }
            upserted.append(contentsOf: paddocks)
            let now = Date()
            for upsert in paddocks {
                let row = Self.backendRow(from: upsert, updatedAt: now)
                if let idx = serverRows.firstIndex(where: { $0.id == upsert.id }) {
                    serverRows[idx] = row
                } else {
                    serverRows.append(row)
                }
            }
        }

        func softDeletePaddock(id: UUID) async throws {}

        func paddockReferenceCounts(id: UUID) async throws -> PaddockReferenceCounts {
            PaddockReferenceCounts(
                pins: 0, trips: 0, tripCostAllocations: 0, workTasks: 0,
                workTaskPaddocks: 0, damageRecords: 0, growthStageRecords: 0,
                sprayJobPaddocks: 0, paddockSoilProfiles: 0, totalReferences: 0
            )
        }

        func hardDeletePaddock(id: UUID) async throws {}
        func restorePaddock(id: UUID) async throws {}

        static func backendRow(from upsert: BackendPaddockUpsert, updatedAt: Date) -> BackendPaddock {
            BackendPaddock(
                id: upsert.id, vineyardId: upsert.vineyardId, name: upsert.name,
                rowDirection: upsert.rowDirection, rowWidth: upsert.rowWidth,
                rowOffset: upsert.rowOffset, vineSpacing: upsert.vineSpacing,
                vineCountOverride: upsert.vineCountOverride,
                rowLengthOverride: upsert.rowLengthOverride,
                flowPerEmitter: upsert.flowPerEmitter,
                emitterSpacing: upsert.emitterSpacing,
                intermediatePostSpacing: upsert.intermediatePostSpacing,
                budburstDate: upsert.budburstDate, floweringDate: upsert.floweringDate,
                veraisonDate: upsert.veraisonDate, harvestDate: upsert.harvestDate,
                plantingYear: upsert.plantingYear,
                calculationModeOverride: upsert.calculationModeOverride,
                resetModeOverride: upsert.resetModeOverride,
                polygonPoints: upsert.polygonPoints, rows: upsert.rows,
                varietyAllocations: upsert.varietyAllocations,
                createdBy: upsert.createdBy, updatedBy: nil, createdAt: updatedAt,
                updatedAt: updatedAt, deletedAt: nil,
                clientUpdatedAt: upsert.clientUpdatedAt, syncVersion: 1
            )
        }
    }

    // MARK: - Fixtures

    struct Env {
        let directory: URL
        let persistence: PersistenceStore
        let store: MigratedDataStore
        let metadata: PaddockSyncMetadata
        let repo: ServerMockRepo
        let service: PaddockSyncService
    }

    private func makeEnv() -> Env {
        // The one-time UserDefaults migrations must not fire mid-test and
        // reset watermarks the test just configured.
        UserDefaults.standard.set(true, forKey: "vinetrack_paddock_sync_reset_v1")
        UserDefaults.standard.set(true, forKey: "vinetrack_paddock_sync_variety_repull_v2")
        UserDefaults.standard.set(true, forKey: "vinetrack_paddock_cache_recovery_v1")
        UserDefaults.standard.removeObject(forKey: PaddockCacheRecovery.pendingDefaultsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-safety-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let metadata = PaddockSyncMetadata(persistence: persistence)
        let repo = ServerMockRepo()
        let service = PaddockSyncService(repository: repo, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        return Env(
            directory: directory,
            persistence: persistence,
            store: store,
            metadata: metadata,
            repo: repo,
            service: service
        )
    }

    private func backendPaddock(
        id: UUID = UUID(),
        vineyardId: UUID,
        name: String,
        updatedAt: Date = Date(timeIntervalSinceNow: -3_600),
        deletedAt: Date? = nil
    ) -> BackendPaddock {
        BackendPaddock(
            id: id, vineyardId: vineyardId, name: name,
            rowDirection: nil, rowWidth: nil, rowOffset: nil, vineSpacing: nil,
            vineCountOverride: nil, rowLengthOverride: nil, flowPerEmitter: nil,
            emitterSpacing: nil, intermediatePostSpacing: nil,
            budburstDate: nil, floweringDate: nil, veraisonDate: nil,
            harvestDate: nil, plantingYear: nil,
            calculationModeOverride: nil, resetModeOverride: nil,
            polygonPoints: nil, rows: nil, varietyAllocations: nil,
            createdBy: nil, updatedBy: nil, createdAt: nil,
            updatedAt: updatedAt, deletedAt: deletedAt,
            clientUpdatedAt: updatedAt, syncVersion: 1
        )
    }

    // MARK: - 1. Multi-vineyard pending protection

    @Test("Pending block in vineyard B survives vineyard A's sync, then uploads from B")
    func pendingBlockInOtherVineyardSurvivesSelectedVineyardSync() async {
        let env = makeEnv()
        let vineyardA = UUID()
        let vineyardB = UUID()

        // Offline: create/edit a block while vineyard B is selected.
        env.store.selectedVineyardId = vineyardB
        let blockB = Paddock(vineyardId: vineyardB, name: "B pending block")
        env.store.addPaddock(blockB)
        #expect(env.metadata.pendingUpserts[blockB.id] != nil)

        // Switch to vineyard A and sync A.
        env.store.selectedVineyardId = vineyardA
        env.store.reloadCurrentVineyardData()
        let blockA = backendPaddock(vineyardId: vineyardA, name: "Block A")
        env.repo.serverRows = [blockA]

        await env.service.sync(vineyardId: vineyardA)

        #expect(env.service.syncStatus == .success)
        // B's pending entry and cached block remain untouched…
        #expect(env.metadata.pendingUpserts[blockB.id] != nil)
        #expect(env.store.cachedPaddockIds(for: vineyardB).contains(blockB.id))
        // …and nothing of B's was uploaded during A's sync.
        #expect(!env.repo.upserted.contains { $0.id == blockB.id })

        // Switching back to B uploads it normally.
        env.store.selectedVineyardId = vineyardB
        env.store.reloadCurrentVineyardData()
        #expect(env.store.paddocks.contains { $0.id == blockB.id })

        await env.service.sync(vineyardId: vineyardB)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.upserted.contains { $0.id == blockB.id })
        #expect(env.repo.serverRows.contains { $0.id == blockB.id })
        #expect(env.metadata.pendingUpserts[blockB.id] == nil)
        #expect(env.store.paddocks.contains { $0.id == blockB.id })
    }

    // MARK: - 2. Nil watermark must not resurrect hard-deleted blocks

    @Test("Stale local block hard-deleted remotely stays deleted after a recovery watermark reset")
    func staleLocalBlockHardDeletedRemotelyIsNotResurrected() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        // A stale cached block whose server row was hard-deleted. It is NOT a
        // pending local creation — so a nil watermark must not re-upload it.
        let stale = backendPaddock(vineyardId: vineyard, name: "Hard-deleted block").toPaddock()
        env.store.applyRemotePaddockUpsert(stale)
        env.repo.serverRows = []
        #expect(env.metadata.lastSync(for: vineyard) == nil)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.upserted.isEmpty)
        #expect(env.store.paddocks.isEmpty)
        #expect(!env.store.persistedPaddockIds(for: vineyard).contains(stale.id))
    }

    @Test("Failed initial-seed upload fails the sync and leaves queue + watermark intact")
    func failedInitialSeedUploadFailsAndPreservesState() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let pending = Paddock(vineyardId: vineyard, name: "Pending creation")
        env.store.addPaddock(pending)
        #expect(env.metadata.pendingUpserts[pending.id] != nil)
        env.repo.failUpserts = true

        // Exercise the nil-watermark seed path directly (push bypassed): the
        // failure must THROW, never be swallowed.
        await #expect(throws: (any Error).self) {
            _ = try await env.service.pullRemotePaddocks(vineyardId: vineyard)
        }
        #expect(env.metadata.pendingUpserts[pending.id] != nil)
        #expect(env.metadata.lastSync(for: vineyard) == nil)

        // The full sync path reports failure, not success.
        await env.service.sync(vineyardId: vineyard)
        guard case .failure = env.service.syncStatus else {
            Issue.record("Expected failure when uploads fail, got \(env.service.syncStatus)")
            return
        }
        #expect(env.metadata.pendingUpserts[pending.id] != nil)
        #expect(env.metadata.lastSync(for: vineyard) == nil)
    }

    @Test("A genuine pending local creation still uploads with a nil watermark")
    func genuinePendingLocalCreationStillUploads() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let created = Paddock(vineyardId: vineyard, name: "New local block")
        env.store.addPaddock(created)
        env.repo.serverRows = []

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.upserted.contains { $0.id == created.id })
        #expect(env.repo.serverRows.contains { $0.id == created.id })
        #expect(env.metadata.pendingUpserts[created.id] == nil)
        #expect(env.store.paddocks.contains { $0.id == created.id })
        #expect(env.store.persistedPaddockIds(for: vineyard).contains(created.id))
    }

    // MARK: - 3. Decode recovery is safe for pending work

    @Test("Decode recovery hydrates the server cache and preserves + surfaces unrecoverable pending work")
    func decodeRecoveryHydratesFirstAndPreservesUnrecoverablePending() async throws {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let serverBlock = backendPaddock(vineyardId: vineyard, name: "Server block")
        env.repo.serverRows = [serverBlock]

        // Pending metadata whose payloads lived ONLY in the (soon corrupt)
        // cache: an edit of a server block and a creation unknown to the server.
        let lostEditId = serverBlock.id
        let lostCreationId = UUID()
        env.service.markPaddockDirty(lostEditId)
        env.service.markPaddockDirty(lostCreationId)
        SyncIssueCenter.shared.clearIssues([lostEditId, lostCreationId])

        // Corrupt the on-disk cache and trip the decode-failure detection.
        let cacheURL = env.directory.appendingPathComponent("vinetrack_paddocks.json")
        try Data("{definitely-not-json".utf8).write(to: cacheURL)
        _ = env.store.allCachedPaddocks()
        #expect(PaddockCacheRecovery.isRecoveryPending())
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        // Authoritative server cache hydrated before push processing.
        #expect(env.store.paddocks.map { $0.id } == [serverBlock.id])
        // The pending creation was NOT reclaimed as an orphan…
        #expect(env.metadata.pendingUpserts[lostCreationId] != nil)
        // …and no bogus payload was invented for it.
        #expect(!env.repo.upserted.contains { $0.id == lostCreationId })
        // Both unrecoverable payloads surfaced as diagnostics — never a
        // silent claim that the pending work survived.
        #expect(SyncIssueCenter.shared.issues[lostCreationId] != nil)
        #expect(SyncIssueCenter.shared.issues[lostEditId] != nil)
        // The lost edit's dirty flag was consumed by the server restore.
        #expect(env.metadata.pendingUpserts[lostEditId] == nil)
    }

    // MARK: - 4. Durable persistence before success

    @Test("Recovered blocks are readable back from disk after a successful sync")
    func recoveredBlocksAreReadableFromDisk() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let blockA = backendPaddock(vineyardId: vineyard, name: "Block A")
        let blockB = backendPaddock(vineyardId: vineyard, name: "Block B")
        env.repo.serverRows = [blockA, blockB]
        // Stale watermark + empty cache → the consistency recovery path.
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        // Verify with a completely FRESH store reading the same directory.
        let fresh = PersistenceStore(directory: env.directory)
        let onDisk: [Paddock] = fresh.load(key: "vinetrack_paddocks") ?? []
        #expect(Set(onDisk.map { $0.id }) == Set([blockA.id, blockB.id]))
    }

    @Test("A persistence failure during recovery fails the sync and keeps the watermark")
    func persistenceFailureDuringRecoveryFailsTheSync() async throws {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        env.repo.serverRows = [backendPaddock(vineyardId: vineyard, name: "Block A")]
        let original = Date(timeIntervalSinceNow: -60)
        env.metadata.setLastSync(original, for: vineyard)
        // Destroy the storage directory so the atomic batch write cannot land.
        try FileManager.default.removeItem(at: env.directory)

        await env.service.sync(vineyardId: vineyard)

        guard case .failure = env.service.syncStatus else {
            Issue.record("Expected failure when the recovered blocks cannot be persisted, got \(env.service.syncStatus)")
            return
        }
        #expect(env.metadata.lastSync(for: vineyard) == original)
    }

    // MARK: - 5. Force Refresh protects pending work

    @Test("Force refresh preserves a pending offline block edit instead of discarding it")
    func forceRefreshPreservesPendingLocalEdits() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let serverRow = backendPaddock(vineyardId: vineyard, name: "Server name")
        env.repo.serverRows = [serverRow]
        // The same block edited offline, still queued for upload.
        var localEdit = serverRow.toPaddock()
        localEdit.name = "Offline local edit"
        env.store.applyRemotePaddockUpsert(localEdit)
        env.service.markPaddockDirty(localEdit.id)

        let result = await env.service.forceRepullAllPaddocks(vineyardId: vineyard)

        #expect(result.error == nil)
        #expect(env.store.paddocks.first { $0.id == localEdit.id }?.name == "Offline local edit")
        #expect(env.metadata.pendingUpserts[localEdit.id] != nil)
    }

    // MARK: - 6. Watermark race

    @Test("An existing block edited during the sync window is received by the next pull")
    func blockEditedDuringSyncWindowIsPulledByNextSync() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let t0 = Date(timeIntervalSinceNow: -3_600)
        let block = backendPaddock(vineyardId: vineyard, name: "Original", updatedAt: t0)
        env.repo.serverRows = [block]

        await env.service.sync(vineyardId: vineyard)
        #expect(env.service.syncStatus == .success)
        #expect(env.store.paddocks.first { $0.id == block.id }?.name == "Original")

        // The row changes with a server `updated_at` OLDER than the client
        // completion clock the old implementation stored as its watermark —
        // exactly the row the old scheme would have skipped forever.
        let edited = backendPaddock(
            id: block.id,
            vineyardId: vineyard,
            name: "Edited during sync",
            updatedAt: Date(timeIntervalSinceNow: -1_800)
        )
        env.repo.serverRows = [edited]

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.store.paddocks.first { $0.id == block.id }?.name == "Edited during sync")
    }
}
