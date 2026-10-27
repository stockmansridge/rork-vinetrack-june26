import Foundation
import XCTest
@testable import VineTrack

final class YieldPullResponsivenessTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, PersistenceStore, MigratedDataStore, OperationsSyncMetadata, NewBackendAuthService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disk = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: disk)
        let a = Vineyard(name: "Synthetic Yield A"), b = Vineyard(name: "Synthetic Yield B")
        store.vineyards = [a, b]
        store.selectedVineyardId = a.id
        let metadata = OperationsSyncMetadata(key: "yield-pull-test", persistence: disk)
        metadata.setLastSync(Date(timeIntervalSince1970: 100), for: a.id)
        return (root, disk, store, metadata, NewBackendAuthService())
    }

    @MainActor func testMultiRowPullYieldsBetweenCompleteDurableApplicationsAndAppliesAllRows() async throws {
        let (root, disk, store, metadata, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        let sessions = (0..<10).map { _ in YieldEstimationSession(vineyardId: vineyard, createdAt: Date(timeIntervalSince1970: 100)) }
        let service = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: sessions.map { SyntheticYieldPullRepository.row($0) }), metadata: metadata)
        service.configure(store: store, auth: auth)
        var completed = 0
        var betweenRowsObserved = false
        var observer: Task<Void, Never>?
        service.remoteRowMeasurementForTesting = { _, _ in
            completed += 1
            XCTAssertEqual(YieldRepository(persistence: disk).loadAllSessions().count, completed)
            if completed == 1 {
                observer = Task(priority: .high) { @MainActor in
                    betweenRowsObserved = completed > 0 && completed < sessions.count
                    XCTAssertEqual(YieldRepository(persistence: disk).loadAllSessions().count, completed)
                }
            }
        }
        try await service.pull(vineyardId: vineyard)
        await observer?.value
        XCTAssertTrue(betweenRowsObserved, "Other MainActor work must run between complete rows")
        XCTAssertEqual(completed, 10)
        XCTAssertEqual(Set(store.yieldSessions.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(Set(YieldRepository(persistence: disk).loadAllSessions().map(\.id)), Set(sessions.map(\.id)))
    }

    @MainActor private func assertRevoked(_ transition: @escaping @MainActor (MigratedDataStore) -> Void) async throws {
        let (root, disk, store, metadata, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        let sessions = (0..<10).map { _ in YieldEstimationSession(vineyardId: vineyard) }
        let service = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: sessions.map { SyntheticYieldPullRepository.row($0) }), metadata: metadata)
        service.configure(store: store, auth: auth)
        var completed = 0
        service.remoteRowMeasurementForTesting = { _, _ in
            completed += 1
            if completed == 1 { transition(store) }
        }
        do {
            try await service.pull(vineyardId: vineyard)
            XCTFail("Stale pull must throw cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(YieldRepository(persistence: disk).loadAllSessions().map(\.id), [sessions[0].id])
    }

    @MainActor func testVineyardChangeStopsRemainingRows() async throws {
        try await assertRevoked { store in store.applyDefaultVineyardSelection(defaultId: store.vineyards[1].id) }
    }

    @MainActor func testVineyardRoundTripCannotReviveOriginalPull() async throws {
        try await assertRevoked { store in
            let a = store.vineyards[0].id
            store.applyDefaultVineyardSelection(defaultId: store.vineyards[1].id)
            store.applyDefaultVineyardSelection(defaultId: a)
        }
    }

    @MainActor func testSameUserAccountIncarnationStopsOriginalPull() async throws {
        let suite = "YieldPullResponsivenessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = VineyardWriteAuthority(defaults: defaults)
        let owner = UUID()
        authority.bind(userId: owner)
        // Install the original account before capturing the pull predicate.
        let (root, disk, store, metadata, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { owner }
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        let sessions = (0..<3).map { _ in YieldEstimationSession(vineyardId: vineyard) }
        let service = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: sessions.map { SyntheticYieldPullRepository.row($0) }), metadata: metadata)
        service.configure(store: store, auth: auth)
        var completed = 0
        service.remoteRowMeasurementForTesting = { _, _ in
            completed += 1
            authority.bind(userId: nil)
            authority.bind(userId: owner)
        }
        do { try await service.pull(vineyardId: vineyard); XCTFail("Original incarnation resumed") }
        catch is CancellationError {}
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(YieldRepository(persistence: disk).loadAllSessions().count, 1)
    }

    @MainActor func testAccountProviderChangeStopsRemainingRows() async throws {
        try await assertRevoked { store in store.currentUserIdProvider = { UUID() } }
    }

    @MainActor func testFetchSuspensionRejectsSelectionRoundTripBeforeFirstApplication() async throws {
        let (root, _, store, metadata, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        let row = SyntheticYieldPullRepository.row(YieldEstimationSession(vineyardId: vineyard))
        let repository = SuspendedYieldRepository {
            await MainActor.run {
                store.applyDefaultVineyardSelection(defaultId: store.vineyards[1].id)
                store.applyDefaultVineyardSelection(defaultId: vineyard)
            }
            return [row]
        }
        let service = YieldEstimationSessionSyncService(repository: repository, metadata: metadata)
        service.configure(store: store, auth: auth)
        var applied = 0
        service.remoteRowMeasurementForTesting = { _, _ in applied += 1 }
        do { try await service.pull(vineyardId: vineyard); XCTFail("Stale fetched rows applied") }
        catch is CancellationError {}
        XCTAssertEqual(applied, 0)
    }

    @MainActor func testRowPersistencePrecedesMetadataAndNextRow() async throws {
        let (root, disk, store, _, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataRoot = root.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)
        let metadataDisk = PersistenceStore(directory: metadataRoot)
        let metadata = OperationsSyncMetadata(key: "ordering", persistence: metadataDisk)
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        metadata.setLastSync(Date(), for: vineyard)
        let sessions = (0..<3).map { _ in YieldEstimationSession(vineyardId: vineyard) }
        let service = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: sessions.map { SyntheticYieldPullRepository.row($0) }), metadata: metadata)
        service.configure(store: store, auth: auth)
        var events: [String] = []
        disk.onPersistenceMeasurementForTesting = { sample in
            if sample.operation == .durableSave && sample.succeeded { events.append("row persisted") }
        }
        metadataDisk.onPersistenceMeasurementForTesting = { sample in
            if (sample.operation == .save || sample.operation == .durableSave) && sample.succeeded {
                events.append("metadata persisted")
            }
        }
        service.remoteRowMeasurementForTesting = { _, _ in events.append("row complete") }
        try await service.pull(vineyardId: vineyard)
        XCTAssertEqual(events, Array(repeating: ["row persisted", "metadata persisted", "row complete"], count: 3).flatMap { $0 })
        XCTAssertTrue(metadata.pendingUpserts.isEmpty)
    }

    @MainActor func testScheduledResultsMatchUnscheduledProductionPrimitiveAndRetainPendingCompletion() async throws {
        let (root, disk, store, metadata, auth) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let vineyard = try XCTUnwrap(store.selectedVineyardId)
        let block = UUID(), stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = (0..<10).map { index in
            YieldEstimationSession(vineyardId: vineyard, createdAt: stamp, selectedPaddockIds: [block],
                samplesPerHectare: 17, sampleSites: [SampleSite(paddockId: block, paddockName: "Block", rowNumber: 3,
                    latitude: -34, longitude: 138, siteIndex: 1,
                    bunchCountEntry: BunchCountEntry(bunchesPerVine: Double(index + 12), recordedAt: stamp))],
                blockBunchWeightsKg: [block: 0.183], isCompleted: true, completedAt: stamp,
                applyDamage: index % 2 == 0, blockVineCounts: [block.uuidString: 1200])
        }
        let controlRoot = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let controlDisk = PersistenceStore(directory: controlRoot)
        let control = MigratedDataStore(persistence: controlDisk)
        control.selectedVineyardId = vineyard
        let rows = sessions.map { SyntheticYieldPullRepository.row($0) }
        for row in rows { control.applyRemoteYieldSessionUpsert(try XCTUnwrap(row.toYieldEstimationSession())) }
        let service = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: rows), metadata: metadata)
        service.configure(store: store, auth: auth)
        try await service.pull(vineyardId: vineyard)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(store.yieldSessions), try encoder.encode(control.yieldSessions))
        XCTAssertEqual(try encoder.encode(YieldRepository(persistence: disk).loadAllSessions()),
                       try encoder.encode(YieldRepository(persistence: controlDisk).loadAllSessions()))
        // A pulled draft must still not acknowledge or overwrite a pending completion.
        let original = sessions[0]
        try store.yieldRepo.saveLocalSession(original, at: stamp)
        let token = store.yieldRepo.pendingSessionIntents()[original.id]?.token
        var draft = original
        draft.isCompleted = false
        draft.completedAt = nil
        let stale = YieldEstimationSessionSyncService(repository: SyntheticYieldPullRepository(rows: [SyntheticYieldPullRepository.row(draft)]), metadata: metadata)
        stale.configure(store: store, auth: auth)
        try await stale.pull(vineyardId: vineyard)
        XCTAssertEqual(store.yieldRepo.pendingSessionIntents()[original.id]?.token, token)
        XCTAssertTrue(try XCTUnwrap(store.yieldRepo.loadAllSessions().first { $0.id == original.id }).isCompleted)
    }
}

private nonisolated struct SuspendedYieldRepository: YieldEstimationSessionSyncRepositoryProtocol {
    let response: @Sendable () async throws -> [BackendYieldEstimationSession]
    init(_ response: @escaping @Sendable () async throws -> [BackendYieldEstimationSession]) { self.response = response }
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendYieldEstimationSession] { try await response() }
    func upsertMany(_ items: [BackendYieldEstimationSessionUpsert]) async throws {}
    func softDelete(id: UUID) async throws {}
}
