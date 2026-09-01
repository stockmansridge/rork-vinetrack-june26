import Testing
import Foundation
@testable import VineTrack

/// Regression suite for the 3.0.1 (85) "sync succeeded but no blocks" issue.
///
/// Root cause: `pullRemotePaddocks` trusted the incremental `lastSync`
/// watermark without ever checking that the local block cache still held the
/// blocks the server has. An emptied/corrupt cache with a live watermark
/// pulled nothing, advanced the watermark and reported success forever.
///
/// These tests pin the permanent consistency-recovery pass, the sync-status
/// gate, and the paddock-cache decode diagnostics. Pure logic — no network.
@MainActor
struct PaddockCacheRecoveryTests {

    // MARK: - Mock repository

    @MainActor
    final class MockRepo: PaddockSyncRepositoryProtocol {
        var serverRows: [BackendPaddock] = []
        var fetchAllCalls: Int = 0
        var fetchIdsCalls: Int = 0
        var failFetchIds: Bool = false
        /// When set, `fetchAllPaddocks` returns this instead of `serverRows`
        /// (simulates a full fetch that cannot deliver every reported id).
        var fetchAllOverride: [BackendPaddock]?
        var upserted: [BackendPaddockUpsert] = []

        func fetchPaddocks(vineyardId: UUID, since: Date?) async throws -> [BackendPaddock] {
            let rows = serverRows.filter { $0.vineyardId == vineyardId }
            guard let since else { return rows }
            return rows.filter { ($0.updatedAt ?? .distantPast) >= since }
        }

        func fetchAllPaddocks(vineyardId: UUID) async throws -> [BackendPaddock] {
            fetchAllCalls += 1
            if let fetchAllOverride { return fetchAllOverride }
            return serverRows.filter { $0.vineyardId == vineyardId }
        }

        func fetchAllAccessiblePaddocks() async throws -> [BackendPaddock] {
            serverRows.filter { $0.deletedAt == nil }
        }

        func fetchPaddockIds(vineyardId: UUID) async throws -> [BackendPaddockIdRow] {
            fetchIdsCalls += 1
            if failFetchIds { throw URLError(.timedOut) }
            return serverRows
                .filter { $0.vineyardId == vineyardId }
                .map { BackendPaddockIdRow(id: $0.id, deletedAt: $0.deletedAt) }
        }

        func upsertPaddock(_ paddock: BackendPaddockUpsert) async throws {
            upserted.append(paddock)
        }

        func upsertPaddocks(_ paddocks: [BackendPaddockUpsert]) async throws {
            upserted.append(contentsOf: paddocks)
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
    }

    // MARK: - Fixtures

    struct Env {
        let directory: URL
        let persistence: PersistenceStore
        let store: MigratedDataStore
        let metadata: PaddockSyncMetadata
        let repo: MockRepo
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
            .appendingPathComponent("paddock-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let metadata = PaddockSyncMetadata(persistence: persistence)
        let repo = MockRepo()
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

    // MARK: - Consistency recovery

    @Test("Non-null watermark + empty local cache + live server blocks → full hydration")
    func emptyCacheWithStaleWatermarkIsFullyHydrated() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let blockA = backendPaddock(vineyardId: vineyard, name: "Block A")
        let blockB = backendPaddock(vineyardId: vineyard, name: "Block B")
        env.repo.serverRows = [blockA, blockB]
        // Watermark AFTER the server rows' updated_at: the incremental pull
        // returns nothing — exactly the broken production state.
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.fetchAllCalls == 1)
        #expect(Set(env.store.paddocks.map { $0.id }) == Set([blockA.id, blockB.id]))
    }

    @Test("Partial local cache + unchanged server blocks → missing blocks restored")
    func partialCacheIsBackfilled() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let blockA = backendPaddock(vineyardId: vineyard, name: "Block A")
        let blockB = backendPaddock(vineyardId: vineyard, name: "Block B")
        env.store.applyRemotePaddockUpsert(blockA.toPaddock())
        env.repo.serverRows = [blockA, blockB]
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.fetchAllCalls == 1)
        #expect(Set(env.store.paddocks.map { $0.id }) == Set([blockA.id, blockB.id]))
    }

    @Test("Empty cache + genuinely empty server vineyard → success without repeated full pulls")
    func emptyServerVineyardDoesNotFullFetchRepeatedly() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        env.repo.serverRows = []

        await env.service.sync(vineyardId: vineyard)
        await env.service.sync(vineyardId: vineyard)
        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.repo.fetchAllCalls == 0)
        #expect(env.store.paddocks.isEmpty)
        #expect(env.metadata.lastSync(for: vineyard) != nil)
    }

    @Test("Soft-deleted server blocks are not restored by recovery")
    func softDeletedBlocksStayDeleted() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let live = backendPaddock(vineyardId: vineyard, name: "Live block")
        let deleted = backendPaddock(vineyardId: vineyard, name: "Removed block", deletedAt: Date())
        env.repo.serverRows = [live, deleted]
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.store.paddocks.map { $0.id } == [live.id])
    }

    @Test("Pending local creations survive recovery and stay queued for upload")
    func pendingLocalCreationSurvivesRecovery() async throws {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let pendingLocal = backendPaddock(vineyardId: vineyard, name: "Pending local block").toPaddock()
        env.store.applyRemotePaddockUpsert(pendingLocal)
        env.service.markPaddockDirty(pendingLocal.id)
        let serverBlock = backendPaddock(vineyardId: vineyard, name: "Server block")
        env.repo.serverRows = [serverBlock]
        env.metadata.setLastSync(Date(), for: vineyard)

        // Pull directly (no push) so recovery itself is what must preserve it.
        try await env.service.pullRemotePaddocks(vineyardId: vineyard)

        #expect(env.store.paddocks.contains { $0.id == pendingLocal.id })
        #expect(env.store.paddocks.contains { $0.id == serverBlock.id })
        #expect(env.metadata.pendingUpserts[pendingLocal.id] != nil)
    }

    @Test("Recovering one vineyard does not erase another vineyard's cached blocks")
    func recoveryLeavesOtherVineyardSlicesIntact() async {
        let env = makeEnv()
        let vineyardA = UUID()
        let vineyardB = UUID()
        env.store.selectedVineyardId = vineyardA
        let otherBlock = backendPaddock(vineyardId: vineyardB, name: "Other vineyard block").toPaddock()
        env.store.applyRemotePaddockUpsert(otherBlock) // persisted to the shared disk cache
        let blockA = backendPaddock(vineyardId: vineyardA, name: "Block A")
        env.repo.serverRows = [blockA]
        env.metadata.setLastSync(Date(), for: vineyardA)

        await env.service.sync(vineyardId: vineyardA)

        #expect(env.service.syncStatus == .success)
        #expect(env.store.paddocks.map { $0.id } == [blockA.id])
        #expect(env.store.cachedPaddockIds(for: vineyardB) == Set([otherBlock.id]))
    }

    // MARK: - Sync status gate

    @Test("Repository failure leaves the watermark unchanged and reports failure")
    func repositoryFailureKeepsWatermarkAndFails() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        env.repo.serverRows = [backendPaddock(vineyardId: vineyard, name: "Block A")]
        env.repo.failFetchIds = true
        let originalWatermark = Date(timeIntervalSinceNow: -60)
        env.metadata.setLastSync(originalWatermark, for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        guard case .failure = env.service.syncStatus else {
            Issue.record("Expected failure status, got \(env.service.syncStatus)")
            return
        }
        #expect(env.metadata.lastSync(for: vineyard) == originalWatermark)
    }

    @Test("'Synced' is reported only once local and server active ids are consistent")
    func successRequiresActiveIdConsistency() async {
        let env = makeEnv()
        let vineyard = UUID()
        env.store.selectedVineyardId = vineyard
        let blockA = backendPaddock(vineyardId: vineyard, name: "Block A")
        let blockB = backendPaddock(vineyardId: vineyard, name: "Block B")
        env.repo.serverRows = [blockA, blockB]
        let originalWatermark = Date(timeIntervalSinceNow: -60)
        env.metadata.setLastSync(originalWatermark, for: vineyard)

        // Full fetch cannot deliver blockB → the sync must NOT claim success
        // and must NOT advance the watermark.
        env.repo.fetchAllOverride = [blockA]
        await env.service.sync(vineyardId: vineyard)
        guard case .failure(let message) = env.service.syncStatus else {
            Issue.record("Expected failure while hydration is incomplete")
            return
        }
        #expect(message.contains("Block sync incomplete"))
        #expect(env.metadata.lastSync(for: vineyard) == originalWatermark)

        // Once the full fetch is healthy again the same sync path succeeds.
        env.repo.fetchAllOverride = nil
        await env.service.sync(vineyardId: vineyard)
        #expect(env.service.syncStatus == .success)
        #expect(Set(env.store.paddocks.map { $0.id }) == Set([blockA.id, blockB.id]))
        // The watermark is server-derived and never regresses. Here the
        // recovered rows' server `updated_at` predates the existing
        // watermark, so it is preserved rather than advanced by the client
        // clock (which could skip rows edited during the sync window).
        let advanced = env.metadata.lastSync(for: vineyard)
        #expect(advanced != nil && advanced! >= originalWatermark)
    }

    // MARK: - Persistence diagnostics

    @Test("Paddock cache decode failure surfaces diagnostics and triggers server recovery")
    func decodeFailureIsDiagnosedQuarantinedAndRecovered() async throws {
        let env = makeEnv()
        let vineyard = UUID()

        // Corrupt the shared multi-vineyard block cache on disk.
        let cacheURL = env.directory.appendingPathComponent("vinetrack_paddocks.json")
        try Data("{definitely-not-json".utf8).write(to: cacheURL)

        var capturedKey: String?
        var capturedError: Error?
        env.persistence.onDecodeFailure = { key, error in
            capturedKey = key
            capturedError = error
        }

        // Any read of the cache must surface the failure instead of silently
        // treating it as "no blocks".
        let idsAfterCorruption = env.store.cachedPaddockIds(for: vineyard)
        #expect(idsAfterCorruption.isEmpty)
        #expect(capturedKey == "vinetrack_paddocks")
        #expect(capturedError != nil)
        #expect(PaddockCacheRecovery.isRecoveryPending())

        // The corrupt payload is quarantined, not overwritten.
        let files = try FileManager.default.contentsOfDirectory(atPath: env.directory.path)
        #expect(!files.contains("vinetrack_paddocks.json"))
        #expect(files.contains { $0.hasPrefix("vinetrack_paddocks.corrupt-") })

        // The next sync consumes the flag, drops the stale watermark and
        // re-hydrates everything from the server.
        env.store.selectedVineyardId = vineyard
        let blockA = backendPaddock(vineyardId: vineyard, name: "Block A")
        env.repo.serverRows = [blockA]
        env.metadata.setLastSync(Date(), for: vineyard)

        await env.service.sync(vineyardId: vineyard)

        #expect(env.service.syncStatus == .success)
        #expect(env.store.paddocks.map { $0.id } == [blockA.id])
        #expect(!PaddockCacheRecovery.isRecoveryPending())
    }
}
