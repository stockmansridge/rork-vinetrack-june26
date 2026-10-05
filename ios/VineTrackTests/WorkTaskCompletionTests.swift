import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskCompletionTests {
    private let zone = TimeZone(identifier: "Australia/Adelaide")!
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { instant("2026-10-05T01:20:30Z") }
    private var task: WorkTask {
        WorkTask(date: instant("2026-09-28T00:00:00Z"), taskType: "Pruning", durationHours: 3,
            resources: [WorkTaskResource(hourlyRate: 27, count: 2)], notes: "Keep me",
            startDate: instant("2026-09-28T00:00:00Z"), status: "planned",
            costingMethodRaw: "piece_rate", pieceRatePerVine: 1.27, pieceVineCount: 499,
            pruningActivityId: UUID())
    }

    @Test func customerABCSeparatesWorkBusinessAndAuditDates() throws {
        let original = task
        let complete = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "ios-user"))
        #expect(complete.date == original.date)
        #expect(complete.startDate == original.startDate)
        #expect(complete.endDate == instant("2026-09-29T14:30:00Z"))
        #expect(complete.isFinalized)
        #expect(complete.finalizedAt == now)
        #expect(complete.finalizedBy == "ios-user")
        let reopened = WorkTaskCompletion.reopen(complete)
        #expect(reopened.isFinalized == false)
        #expect(reopened.endDate == nil && reopened.finalizedAt == nil && reopened.finalizedBy == nil)
        #expect(reopened.date == original.date && reopened.startDate == original.startDate)
        #expect(reopened.resources == original.resources)
        #expect(reopened.pieceRatePerVine == original.pieceRatePerVine)
        #expect(reopened.pieceVineCount == original.pieceVineCount)
        #expect(reopened.pruningActivityId == original.pruningActivityId)
        #expect(reopened.status == "planned")
        let again = try #require(WorkTaskCompletion.complete(reopened, selected: instant("2026-10-01T00:00:00Z"), timeZone: zone, now: now.addingTimeInterval(90), userId: "ios-user"))
        #expect(again.endDate == instant("2026-09-30T14:30:00Z"))
        #expect(again.finalizedAt == now.addingTimeInterval(90))
    }

    @Test func dateOnlyEditOmitsAuditColumns() throws {
        let complete = try #require(WorkTaskCompletion.complete(task, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "user"))
        let edit = try #require(WorkTaskCompletion.editDate(complete, selected: instant("2026-10-01T00:00:00Z"), timeZone: zone, now: now.addingTimeInterval(90)))
        #expect(edit.isFinalized && edit.finalizedAt == complete.finalizedAt && edit.finalizedBy == complete.finalizedBy)
        let payload = BackendWorkTask.upsert(from: edit, createdBy: nil, clientUpdatedAt: now)
        let patch = BackendWorkTaskCompletionPatch(task: payload, dateOnly: true)
        let bytes = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["end_date", "client_updated_at"])
    }

    @Test func reopeningSendsExplicitNullsAndNoResourceFields() throws {
        let reopened = WorkTaskCompletion.reopen(task)
        let payload = BackendWorkTask.upsert(from: reopened, createdBy: nil, clientUpdatedAt: now)
        let patch = BackendWorkTaskCompletionPatch(task: payload, dateOnly: false)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(object["end_date"] is NSNull)
        #expect(object["finalized_at"] is NSNull)
        #expect(object["finalized_by"] is NSNull)
        #expect(object["is_finalized"] as? Bool == false)
        #expect(Set(object.keys) == ["end_date", "is_finalized", "finalized_at", "finalized_by", "client_updated_at"])
        let full = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(full["end_date"] is NSNull && full["finalized_at"] is NSNull && full["finalized_by"] is NSNull)
    }

    @Test func validatesVineyardDatesAndLegacyDisplayWithoutBackfill() {
        var legacy = task
        legacy.isFinalized = true
        legacy.finalizedAt = instant("2026-10-04T15:00:00Z")
        #expect(WorkTaskCompletion.displayedDate(legacy) == legacy.finalizedAt)
        #expect(WorkTaskCompletion.calendar(zone).component(.day, from: WorkTaskCompletion.displayedDate(legacy)!) == 5)
        #expect(legacy.endDate == nil)
        legacy.finalizedAt = nil
        #expect(WorkTaskCompletion.displayedDate(legacy) == nil)
        legacy.isFinalized = false
        legacy.status = "completed"
        #expect(WorkTaskCompletion.displayedDate(legacy) == nil)
        #expect(!WorkTaskCompletion.isValid(instant("2026-09-27T00:00:00Z"), task: task, timeZone: zone, now: now))
        #expect(!WorkTaskCompletion.isValid(instant("2026-10-06T00:00:00Z"), task: task, timeZone: zone, now: now))
        #expect(WorkTaskCompletion.isValid(instant("2026-09-28T00:00:00Z"), task: task, timeZone: zone, now: now))
    }

    @MainActor final class Server: WorkTaskSyncRepositoryProtocol {
        var upserts: [BackendWorkTaskUpsert] = []
        var patches: [BackendWorkTaskCompletionPatch] = []
        var duringUpload: (() -> Void)?
        var duringAsyncUpload: (() async throws -> Void)?
        func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTask] { [] }
        func upsertMany(_ items: [BackendWorkTaskUpsert]) async throws { upserts += items; duringUpload?() }
        func updateCompletion(_ patch: BackendWorkTaskCompletionPatch) async throws {
            patches.append(patch)
            duringUpload?()
            try await duringAsyncUpload?()
        }
        func softDelete(id: UUID) async throws {}
    }

    @Test func offlineCompletionReloadsDiskAndReplaysOriginalAudit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let original = task
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = original.vineyardId
        store.addWorkTask(original)
        let metadata = OperationsSyncMetadata(key: "completion-test", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        let complete = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "original-user"))
        service.saveCompletion(complete, dateOnly: false)
        let restartedStore = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        restartedStore.selectedVineyardId = original.vineyardId
        restartedStore.reloadCurrentVineyardData()
        let restored = try #require(restartedStore.workTasks.first { $0.id == original.id })
        #expect(restored.endDate == complete.endDate && restored.finalizedAt == now && restored.finalizedBy == "original-user")
        let restartedMetadata = OperationsSyncMetadata(key: "completion-test", persistence: persistence)
        #expect(restartedMetadata.completionMode(for: original.id) == false)
        let restarted = WorkTaskSyncService(repository: server, metadata: restartedMetadata)
        restarted.configure(store: restartedStore, auth: NewBackendAuthService())
        try await restarted.push(vineyardId: original.vineyardId)
        let uploaded = try #require(server.patches.first)
        #expect(uploaded.task.endDate == complete.endDate && uploaded.task.finalizedAt == now && uploaded.task.finalizedBy == "original-user")
        #expect(restartedMetadata.pendingUpserts.isEmpty)
    }

    @Test func pendingCreateFoldsCompletionIntoFullUpsert() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-create-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let original = task
        store.selectedVineyardId = original.vineyardId
        let metadata = OperationsSyncMetadata(key: "completion-create", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        store.addWorkTask(original)
        let complete = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "original-user"))
        service.saveCompletion(complete, dateOnly: false)
        #expect(metadata.completionMode(for: original.id) == nil)
        try await service.push(vineyardId: original.vineyardId)
        #expect(server.patches.isEmpty)
        let uploaded = try #require(server.upserts.first)
        #expect(uploaded.isFinalized && uploaded.endDate == complete.endDate)
        #expect(uploaded.finalizedAt == now && uploaded.finalizedBy == "original-user")
        #expect(uploaded.date == original.date && uploaded.startDate == original.startDate && uploaded.resources == original.resources)
    }

    @Test func dateCorrectionAndReopenReplayWithoutTouchingWorkOrAuditDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-correct-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let original = task
        store.selectedVineyardId = original.vineyardId
        let completed = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "original-user"))
        store.addWorkTask(completed)
        let metadata = OperationsSyncMetadata(key: "completion-correct", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        let edited = try #require(WorkTaskCompletion.editDate(completed, selected: instant("2026-10-01T00:00:00Z"), timeZone: zone, now: now.addingTimeInterval(90)))
        service.saveCompletion(edited, dateOnly: true)
        let restoredMetadata = OperationsSyncMetadata(key: "completion-correct", persistence: persistence)
        #expect(restoredMetadata.completionMode(for: original.id) == true)
        let resumed = WorkTaskSyncService(repository: server, metadata: restoredMetadata)
        resumed.configure(store: store, auth: NewBackendAuthService())
        try await resumed.push(vineyardId: original.vineyardId)
        let correction = try #require(server.patches.last)
        #expect(correction.dateOnly)
        #expect(correction.task.finalizedAt == now && correction.task.finalizedBy == "original-user")
        #expect(correction.task.endDate == instant("2026-09-30T14:30:00Z"))
        #expect(correction.task.date == original.date && correction.task.startDate == original.startDate)
        resumed.saveCompletion(WorkTaskCompletion.reopen(edited), dateOnly: false)
        try await resumed.push(vineyardId: original.vineyardId)
        let reopen = try #require(server.patches.last)
        #expect(!reopen.dateOnly && !reopen.task.isFinalized)
        #expect(reopen.task.endDate == nil && reopen.task.finalizedAt == nil && reopen.task.finalizedBy == nil)
        #expect(store.workTasks.first?.resources == original.resources)
    }

    @Test func remoteCompletionMappingRetainsBusinessDateAndIgnoresStatus() throws {
        let vineyard = UUID()
        let id = UUID()
        let json = """
        {"id":"\(id)","vineyard_id":"\(vineyard)","date":"2026-09-28T00:00:00Z","start_date":"2026-09-28T00:00:00Z","end_date":"2026-09-29T14:30:00Z","is_finalized":true,"finalized_at":"2026-10-05T01:20:30Z","finalized_by":"android-user","status":"planned"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let remote = try decoder.decode(BackendWorkTask.self, from: Data(json.utf8)).toWorkTask()
        #expect(remote.isFinalized)
        #expect(remote.date == instant("2026-09-28T00:00:00Z"))
        #expect(remote.endDate == instant("2026-09-29T14:30:00Z"))
        #expect(remote.finalizedAt == now && remote.finalizedBy == "android-user")
        #expect(remote.status == "planned")
    }

    @Test func overlappingCompletionPushWaitsUntilOlderUploadFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-serial-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let original = task
        store.selectedVineyardId = original.vineyardId
        store.addWorkTask(original)
        let metadata = OperationsSyncMetadata(key: "completion-serial", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        let complete = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "user"))
        service.saveCompletion(complete, dateOnly: false)
        server.duringAsyncUpload = {
            service.saveCompletion(WorkTaskCompletion.reopen(complete), dateOnly: false)
            try await service.push(vineyardId: original.vineyardId)
        }
        try await service.push(vineyardId: original.vineyardId)
        #expect(server.patches.count == 1)
        #expect(metadata.pendingUpserts[original.id] != nil)
        server.duringAsyncUpload = nil
        try await service.push(vineyardId: original.vineyardId)
        #expect(server.patches.count == 2)
        #expect(server.patches.last?.task.isFinalized == false)
        #expect(server.patches.last?.task.finalizedAt == nil)
        #expect(metadata.pendingUpserts.isEmpty)
    }

    @Test func inFlightUploadCannotClearNewerDateCorrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-race-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let original = task
        store.selectedVineyardId = original.vineyardId
        store.addWorkTask(original)
        let metadata = OperationsSyncMetadata(key: "completion-race", persistence: persistence)
        let server = Server()
        let service = WorkTaskSyncService(repository: server, metadata: metadata)
        service.configure(store: store, auth: NewBackendAuthService())
        let complete = try #require(WorkTaskCompletion.complete(original, selected: instant("2026-09-30T00:00:00Z"), timeZone: zone, now: now, userId: "user"))
        let edit = try #require(WorkTaskCompletion.editDate(complete, selected: instant("2026-10-01T00:00:00Z"), timeZone: zone, now: now))
        service.saveCompletion(complete, dateOnly: false)
        server.duringUpload = { service.saveCompletion(edit, dateOnly: true) }
        try await service.push(vineyardId: original.vineyardId)
        #expect(metadata.pendingUpserts[original.id] != nil)
        #expect(store.workTasks.first?.endDate == edit.endDate)
        #expect(store.workTasks.first?.finalizedAt == now)
    }
}
