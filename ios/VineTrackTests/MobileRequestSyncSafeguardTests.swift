import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MobileRequestSyncSafeguardTests {
    @Test func workerDeleteAndFinancialRequestsRespectEveryRole() async throws {
        for role in [BackendRole.owner, .manager, .supervisor, .operator] {
            var deleteCalls = 0
            var financialCalls = 0
            let financials = try await OwnerManagerRequestGate.financials(role: role) {
                financialCalls += 1
                return [125.0]
            }
            do {
                try await OwnerManagerRequestGate.deleteWorkerType(role: role) { deleteCalls += 1 }
                #expect(role == .owner || role == .manager)
            } catch {
                #expect(error is WorkerTypeDeletePermissionError)
            }
            let allowed = role == .owner || role == .manager
            #expect(deleteCalls == (allowed ? 1 : 0))
            #expect(financialCalls == (allowed ? 1 : 0))
            #expect(financials == (allowed ? [125.0] : []))
        }
        let unknown: [Double] = try await OwnerManagerRequestGate.financials(role: nil) {
            Issue.record("Unknown membership issued financial request")
            return [99]
        }
        #expect(unknown.isEmpty)
    }

    @Test func lowerRolesCannotInitiateOrDeduplicateWorkerDeletes() {
        for role in [BackendRole.supervisor, .operator] {
            let store = MigratedDataStore(persistence: temporaryPersistence())
            let vineyardId = UUID()
            store.selectedVineyardId = vineyardId
            store.canDeleteWorkerType = { _ in OwnerManagerRequestGate.allows(role) }
            let first = OperatorCategory(vineyardId: vineyardId, name: "Picker", costPerHour: 25)
            let second = OperatorCategory(vineyardId: vineyardId, name: "Picker", costPerHour: 30)
            store.operatorCategories = [first, second]
            var queued = 0
            store.onOperatorCategoryDeleted = { _ in queued += 1 }
            store.deleteOperatorCategory(first)
            #expect(store.deduplicateOperatorCategories() == 0)
            #expect(store.operatorCategories.count == 2)
            #expect(queued == 0)
        }
    }

    @Test func workerDeleteReplayClearsSuccessAbsentAndPermissionButRetainsNetworkFailure() async throws {
        for outcome in ["success", "Worker type not found", "already deleted", "42501 Insufficient permissions to delete worker type", "network unavailable"] {
            let disk = temporaryPersistence()
            let metadata = ManagementSyncMetadata(key: "worker-delete-test", persistence: disk)
            let id = UUID()
            metadata.markDeleted(id, at: Date())
            let repo = SafeguardWorkerRepository(outcome: outcome)
            let service = OperatorCategorySyncService(repository: repo, metadata: metadata)
            do { try await service.replayWorkerTypeDeletes(vineyardId: UUID()) }
            catch { #expect(outcome == "network unavailable") }
            let retained = outcome == "network unavailable"
            #expect(service.pendingDeleteCount == (retained ? 1 : 0))
            let reloaded = ManagementSyncMetadata(key: "worker-delete-test", persistence: disk)
            #expect((reloaded.pendingDeletes[id] != nil) == retained)
            if !retained {
                try await service.replayWorkerTypeDeletes(vineyardId: UUID())
                let calls = await repo.deleteCalls
                #expect(calls == 1)
            }
        }
    }

    @Test func growthReplayWaitsForPinAcknowledgementAndKeepsOriginalLinkAcrossRestart() async throws {
        let disk = temporaryPersistence()
        let vineyardId = UUID(), pinId = UUID()
        let record = GrowthStageRecord(vineyardId: vineyardId, pinId: pinId, stageCode: "EL-4")
        disk.save([record], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: disk)
        metadata.markDirty(record.id, at: Date())
        let repo = SafeguardGrowthRepository()
        let waiting = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: disk, acknowledgedPinIds: { _ in [] })
        try await waiting.pushQueuedGrowthRecords(vineyardId: vineyardId)
        let before = await repo.uploaded
        #expect(before.isEmpty)
        #expect(metadata.pendingUpserts[record.id] != nil)
        #expect(!metadata.isUnknownOutcome(record.id))
        let restartedMetadata = GrowthStageRecordSyncMetadata(persistence: disk)
        let acknowledged = GrowthStageRecordSyncService(repository: repo, metadata: restartedMetadata, persistence: disk, acknowledgedPinIds: { _ in [pinId] })
        try await acknowledged.pushQueuedGrowthRecords(vineyardId: vineyardId)
        let after = await repo.uploaded
        #expect(after.count == 1)
        #expect(after.first?.pinId == pinId)
        #expect(after.first?.id == record.id)
        #expect(acknowledged.pendingUpsertCount == 0)
    }

    @Test func initialEmptyGrowthPullCannotBypassPinGateAndLegacyCanProceed() async throws {
        let disk = temporaryPersistence()
        let vineyardId = UUID()
        let linked = GrowthStageRecord(vineyardId: vineyardId, pinId: UUID(), stageCode: "EL-4")
        let legacy = GrowthStageRecord(vineyardId: vineyardId, stageCode: "EL-9")
        disk.save([linked, legacy], key: "vinetrack_growth_stage_records")
        let repo = SafeguardGrowthRepository()
        let service = GrowthStageRecordSyncService(repository: repo, persistence: disk, acknowledgedPinIds: { _ in [] })
        try await service.pullRemote(vineyardId: vineyardId)
        let uploaded = await repo.uploaded
        #expect(uploaded.map(\.id) == [legacy.id])
        #expect(service.pendingUpsertCount == 1)
        #expect(service.records.first { $0.id == linked.id }?.pinId == linked.pinId)
    }

    @Test func pinAcknowledgementReadFailureDefersWithoutLosingGrowth() async throws {
        let disk = temporaryPersistence()
        let vineyardId = UUID()
        let linked = GrowthStageRecord(vineyardId: vineyardId, pinId: UUID(), stageCode: "EL-4")
        disk.save([linked], key: "vinetrack_growth_stage_records")
        let metadata = GrowthStageRecordSyncMetadata(persistence: disk)
        metadata.markDirty(linked.id, at: Date())
        let repo = SafeguardGrowthRepository()
        let service = GrowthStageRecordSyncService(repository: repo, metadata: metadata, persistence: disk, acknowledgedPinIds: { _ in throw SafeguardResponseError(message: "offline") })
        try await service.pushQueuedGrowthRecords(vineyardId: vineyardId)
        let uploaded = await repo.uploaded
        #expect(uploaded.isEmpty)
        #expect(service.pendingUpsertCount == 1)
    }

    private func temporaryPersistence() -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PersistenceStore(directory: directory)
    }
}

private nonisolated struct SafeguardResponseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor SafeguardWorkerRepository: OperatorCategorySyncRepositoryProtocol {
    let outcome: String
    private(set) var deleteCalls = 0
    init(outcome: String) { self.outcome = outcome }
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendOperatorCategory] { [] }
    func upsertMany(_ items: [BackendOperatorCategoryUpsert]) async throws {}
    func softDelete(id: UUID) async throws {
        deleteCalls += 1
        if outcome != "success" { throw SafeguardResponseError(message: outcome) }
    }
}

private actor SafeguardGrowthRepository: GrowthStageRecordSyncRepositoryProtocol {
    private(set) var uploaded: [BackendGrowthStageRecordUpsert] = []
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] { [] }
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws { uploaded.append(record) }
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws { uploaded += records }
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        AttachmentReferenceConfirmation(recordId: recordId, vineyardId: vineyardId, photoPath: nil, photoPaths: photoPaths)
    }
    func softDeleteGrowthStageRecord(id: UUID) async throws {}
}
