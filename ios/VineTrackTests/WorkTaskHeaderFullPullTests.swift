import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskHeaderFullPullTests {
    @MainActor
    final class Server: WorkTaskSyncRepositoryProtocol {
        var rows: [BackendWorkTask] = []
        var cursors: [Date?] = []
        var afterFetch: (() -> Void)?

        func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTask] {
            cursors.append(since)
            let snapshot = rows.filter { row in
                guard row.vineyardId == vineyardId else { return false }
                guard let since else { return true }
                return (row.updatedAt ?? .distantPast) >= since
            }
            afterFetch?()
            afterFetch = nil
            return snapshot
        }

        func upsertMany(_ items: [BackendWorkTaskUpsert]) async throws {}
        func softDelete(id: UUID) async throws {}
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: "\(text)T12:00:00Z")!
    }

    private func row(_ id: UUID, vineyard: UUID, day: Date, cost: Double = 0, updated: Date? = nil, deleted: Date? = nil, name: String = "Pruning") -> BackendWorkTask {
        BackendWorkTask(
            id: id, vineyardId: vineyard, paddockId: nil, paddockName: nil,
            date: day, taskType: name, durationHours: 1,
            resources: cost == 0 ? [] : [WorkTaskResource(hourlyRate: cost)],
            notes: nil, isArchived: false, archivedAt: nil, archivedBy: nil,
            isFinalized: false, finalizedAt: nil, finalizedBy: nil,
            startDate: nil, endDate: nil, areaHa: nil, taskDescription: nil,
            status: nil, costingMethod: nil, pieceRatePerVine: nil,
            pieceVineCount: nil, pruningActivityId: nil, createdBy: nil,
            createdAt: nil, updatedAt: updated ?? day, deletedAt: deleted,
            clientUpdatedAt: nil
        )
    }

    private func environment() -> (UUID, MigratedDataStore, OperationsSyncMetadata, Server, WorkTaskSyncService) {
        UserDefaults.standard.set(true, forKey: "vinetrack_work_task_sync_reset_v1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-task-full-pull-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let metadata = OperationsSyncMetadata(key: "header-test-\(UUID())", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        metadata.setLastSync(date("2026-09-10"), for: vineyard)
        return (vineyard, store, metadata, server, service)
    }

    @Test func recoversSeventeenToTwentyFourAndIsIdempotentWithOldServerTimestamps() async throws {
        let (vineyard, store, metadata, server, service) = environment()
        let missingDays = ["2026-09-03", "2026-08-30", "2026-08-29", "2026-08-28", "2026-08-27", "2026-08-26", "2026-08-26"]
        let ids = (0..<24).map { _ in UUID() }
        server.rows = ids.enumerated().map { i, id in
            row(id, vineyard: vineyard,
                day: i == 0 ? date("2026-06-23") : (i < 17 ? date("2026-07-10") : date(missingDays[i - 17])),
                cost: i == 1 ? 7703 : (i >= 17 ? 425 : 0), updated: date("2026-08-01"))
        }
        store.workTasks = Array(server.rows.prefix(17)).map { $0.toWorkTask() }
        try await service.pull(vineyardId: vineyard)
        #expect(metadata.lastSync(for: vineyard) != nil)
        #expect(server.cursors.count == 1 && server.cursors[0] == nil)
        #expect(store.workTasks.count == 24)
        #expect(Set(store.workTasks.map(\.id)).count == 24)
        #expect(store.workTasks.filter { $0.date >= date("2026-07-01") }.count == 23)
        #expect(store.workTasks.filter { $0.date >= date("2026-07-01") }.reduce(0.0) { $0 + $1.totalCost } == 10678)
        try await service.pull(vineyardId: vineyard)
        #expect(server.cursors.count == 2 && server.cursors.allSatisfy { $0 == nil })
        #expect(store.workTasks.count == 24)
        #expect(Set(store.workTasks.map(\.id)).count == 24)
    }

    @Test func nextPullRecoversRowCommittedDuringPreviousFetch() async throws {
        let (vineyard, store, _, server, service) = environment()
        let new = row(UUID(), vineyard: vineyard, day: date("2026-09-03"), updated: date("2026-09-01"))
        server.afterFetch = { server.rows.append(new) }
        try await service.pull(vineyardId: vineyard)
        #expect(store.workTasks.isEmpty)
        try await service.pull(vineyardId: vineyard)
        #expect(store.workTasks.map(\.id) == [new.id])
        #expect(server.cursors.allSatisfy { $0 == nil })
    }

    @Test func softDeletionRemovesLocalCounterpartWithoutDeletingUnseenOfflineRows() async throws {
        let (vineyard, store, metadata, server, service) = environment()
        let removed = row(UUID(), vineyard: vineyard, day: date("2026-08-26"), deleted: date("2026-09-02"))
        let offline = WorkTask(vineyardId: vineyard, date: date("2026-09-01"), taskType: "Offline")
        store.workTasks = [removed.toWorkTask(), offline]
        metadata.markDirty(offline.id, at: date("2026-09-02"))
        server.rows = [removed]
        try await service.pull(vineyardId: vineyard)
        #expect(store.workTasks.map(\.id) == [offline.id])
        #expect(service.isPendingUpsert(offline.id))
        #expect(!service.isPendingDelete(removed.id))
    }

    @Test func newerPendingEditWinsOverOlderRemoteSnapshot() async throws {
        let (vineyard, store, metadata, server, service) = environment()
        let remote = row(UUID(), vineyard: vineyard, day: date("2026-08-26"), updated: date("2026-09-01"))
        var edited = remote.toWorkTask()
        edited.taskType = "Local edit"
        store.workTasks = [edited]
        metadata.markDirty(edited.id, at: date("2026-09-02"))
        server.rows = [remote]
        try await service.pull(vineyardId: vineyard)
        #expect(store.workTasks.count == 1)
        #expect(store.workTasks[0].taskType == "Local edit")
        #expect(service.isPendingUpsert(edited.id))
    }
}
