import Foundation
import Observation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskBatchReconciliationTests {
    @Test func unchangedFullPullKeepsOrderWithoutSavingOrPublishing() async throws {
        let h = try WorkTaskBatchHarness(count: 128)
        defer { h.cleanup() }
        h.store.workTasks.reverse()
        h.store.workTaskLabourLines.reverse()
        try h.persistVisibleCollections()

        for kind in WorkTaskBatchKind.allCases {
            let before = try h.visibleSnapshot(kind)
            let bytes = try Data(contentsOf: h.file(kind))
            let published = h.observe(kind)
            h.capture()
            try await h.pull(kind)
            #expect(try h.visibleSnapshot(kind) == before)
            #expect(try Data(contentsOf: h.file(kind)) == bytes)
            #expect(h.collectionSaves(kind).isEmpty && h.metadataSaves.isEmpty)
            #expect(h.measurements.filter { $0.dataset == kind.dataset && $0.operation == .read }.count == 1)
            #expect(!published.value)
        }
        #expect(h.taskServer.cursors == [nil] && h.labourServer.cursors == [nil])
    }

    @Test func changedPullCommitsOnceBeforePublicationAndAcknowledgement() async throws {
        let h = try WorkTaskBatchHarness(count: 64)
        defer { h.cleanup() }
        for kind in WorkTaskBatchKind.allCases {
            let id = h.firstID(kind)
            h.metadata(kind).markDirty(id, at: WorkTaskBatchHarness.older)
            h.setRemoteNote(kind, "Confirmed remote change")
            let before = try h.visibleSnapshot(kind)
            let published = h.observe(kind)
            var observedCommit = false
            h.capture()
            h.persistence.onPersistenceMeasurementForTesting = { measurement in
                h.measurements.append(measurement)
                if measurement.dataset == kind.dataset && measurement.operation == .durableSave {
                    observedCommit = true
                    #expect(measurement.succeeded)
                    #expect(!published.value)
                    #expect((try? h.visibleSnapshot(kind)) == before)
                    #expect(h.metadata(kind).pendingUpserts[id] != nil)
                }
            }
            try await h.pull(kind)
            #expect(observedCommit && h.collectionSaves(kind).count == 1)
            #expect(published.value)
            #expect(h.metadataSaves.count == 1)
            #expect(h.visibleNotes(kind).first == "Confirmed remote change")
            #expect(h.metadata(kind).pendingUpserts[id] == nil)
            #expect(h.reloadedMetadata(kind).pendingUpserts[id] == nil)
            #expect(try h.persistedVisibleSnapshot(kind) == h.visibleSnapshot(kind))
            try h.expectOtherVineyardUnchanged(kind)
        }
    }

    @Test func sameIDsDoNotHidePlanningVersionCompletionOrHistoricalCostChanges() async throws {
        let h = try WorkTaskBatchHarness()
        defer { h.cleanup() }
        var changed = h.tasks[0]
        changed.syncVersion = 19
        changed.assignedTo = UUID()
        changed.assignedExternalResourceId = UUID()
        changed.scheduleBasis = "el_stage"
        changed.targetELStage = 35
        changed.completedAt = WorkTaskBatchHarness.remoteDate
        changed.completedBy = UUID()
        changed.isFinalized = true
        changed.finalizedAt = WorkTaskBatchHarness.remoteDate
        changed.finalizedBy = "Original audit author"
        changed.endDate = WorkTaskBatchHarness.remoteDate
        changed.resources[0].hourlyRate = 39.123456789
        changed.pieceRatePerVine = 0.7654321
        h.taskServer.rows = [taskRow(changed)]
        h.capture()
        try await h.pull(.tasks)
        #expect(h.store.workTasks == [changed])
        #expect(h.collectionSaves(.tasks).count == 1)
        let restored: [WorkTask] = try #require(PersistenceStore(directory: h.directory).load(key: WorkTaskRepository.storageKey))
        #expect(restored.first { $0.id == changed.id } == changed)

        // A server token can change without any display field changing.
        changed.syncVersion = 20
        h.taskServer.rows = [taskRow(changed)]
        h.capture()
        try await h.pull(.tasks)
        #expect(h.store.workTasks[0].syncVersion == 20)
        #expect(h.collectionSaves(.tasks).count == 1)
    }

    @Test func failedCollectionCommitRetainsVisibleRowsAndQueuedIntentThenRetries() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness()
            defer { h.cleanup() }
            let id = h.firstID(kind)
            h.metadata(kind).markDirty(id, at: WorkTaskBatchHarness.older)
            h.setRemoteNote(kind, "Remote after retry")
            let before = try h.visibleSnapshot(kind)
            let bytes = try Data(contentsOf: h.file(kind))
            let published = h.observe(kind)
            h.persistence.durableSaveFailureForTesting = { $0 == kind.key ? CocoaError(.fileWriteUnknown) : nil }
            do {
                try await h.pull(kind)
                Issue.record("A failed collection commit must fail the pull")
            } catch {}
            #expect(try h.visibleSnapshot(kind) == before)
            #expect(try Data(contentsOf: h.file(kind)) == bytes)
            #expect(!published.value)
            #expect(h.metadata(kind).pendingUpserts[id] != nil)
            #expect(h.reloadedMetadata(kind).pendingUpserts[id] != nil)
            h.persistence.durableSaveFailureForTesting = nil
            try await h.pull(kind)
            #expect(h.visibleNotes(kind).first == "Remote after retry")
            #expect(h.reloadedMetadata(kind).pendingUpserts[id] == nil)
        }
    }

    @Test func matchingVisibleRowsStillRepairStaleOrMissingDisk() async throws {
        for kind in WorkTaskBatchKind.allCases {
            for missing in [false, true] {
                let h = try WorkTaskBatchHarness()
                defer { h.cleanup() }
                h.setRemoteNote(kind, "Already visible")
                h.setVisibleNote(kind, "Already visible", persist: false)
                if missing { try FileManager.default.removeItem(at: h.file(kind)) }
                let published = h.observe(kind)
                h.capture()
                try await h.pull(kind)
                #expect(h.collectionSaves(kind).count == 1)
                #expect(try h.persistedVisibleSnapshot(kind) == h.visibleSnapshot(kind))
                #expect(!published.value)
                if !missing { try h.expectOtherVineyardUnchanged(kind) }
            }
        }
    }

    @Test func corruptCollectionIsRetainedWithoutPublicationOrAcknowledgement() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness()
            defer { h.cleanup() }
            let id = h.firstID(kind)
            h.metadata(kind).markDirty(id, at: WorkTaskBatchHarness.older)
            h.setRemoteNote(kind, "Must not replace corrupt evidence")
            let before = try h.visibleSnapshot(kind)
            let corrupt = Data("retained-corrupt-work-task-cache".utf8)
            try corrupt.write(to: h.file(kind), options: .atomic)
            let published = h.observe(kind)
            h.capture()
            do {
                try await h.pull(kind)
                Issue.record("A corrupt collection must fail reconciliation")
            } catch {}
            #expect(try Data(contentsOf: h.file(kind)) == corrupt)
            #expect(try h.visibleSnapshot(kind) == before)
            #expect(h.collectionSaves(kind).isEmpty && h.metadataSaves.isEmpty)
            #expect(!published.value && h.reloadedMetadata(kind).pendingUpserts[id] != nil)
        }
    }

    @Test func responseForPreviousVineyardNeverPublishesIntoNewSelection() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness()
            defer { h.cleanup() }
            h.setRemoteNote(kind, "Refreshed previous vineyard")
            h.beforeFetch(kind) {
                h.store.selectedVineyardId = h.otherVineyard
                h.store.workTasks = h.otherTasks
                h.store.workTaskLabourLines = h.otherLines
            }
            try await h.pull(kind)
            #expect(h.store.selectedVineyardId == h.otherVineyard)
            #expect(h.store.workTasks == h.otherTasks && h.store.workTaskLabourLines == h.otherLines)
            try h.expectOtherVineyardUnchanged(kind)
            #expect(try h.persistedNotes(kind).first == "Refreshed previous vineyard")
        }
    }

    @Test func ownerChangesOrCancellationAfterFetchCannotApplyOrAcknowledge() async throws {
        for kind in WorkTaskBatchKind.allCases {
            for cancel in [false, true] {
                let h = try WorkTaskBatchHarness()
                defer { h.cleanup() }
                let id = h.firstID(kind)
                h.metadata(kind).markDirty(id, at: WorkTaskBatchHarness.older)
                h.setRemoteNote(kind, "Obsolete response")
                let before = try h.visibleSnapshot(kind)
                let bytes = try Data(contentsOf: h.file(kind))
                h.beforeFetch(kind) {
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    else { h.auth.userId = UUID() }
                }
                let operation = Task { @MainActor in try await h.pull(kind) }
                do {
                    try await operation.value
                    Issue.record("An obsolete or cancelled response must not commit")
                } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
                #expect(try h.visibleSnapshot(kind) == before)
                #expect(try Data(contentsOf: h.file(kind)) == bytes)
                #expect(h.reloadedMetadata(kind).pendingUpserts[id] != nil)
            }
        }
    }

    @Test func ownerChangeDuringInitialSeedIsCheckedAgainBeforeCommit() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness(count: 2)
            defer { h.cleanup() }
            h.metadata(kind).resetAllLastSync()
            h.setRemoteNote(kind, "Fetched before owner changed")
            if kind == .tasks { h.taskServer.rows = Array(h.taskServer.rows.prefix(1)) }
            else { h.labourServer.rows = Array(h.labourServer.rows.prefix(1)) }
            h.beforeSeed(kind) { h.auth.userId = UUID() }
            let before = try h.visibleSnapshot(kind)
            let bytes = try Data(contentsOf: h.file(kind))
            do {
                try await h.pull(kind)
                Issue.record("An owner switch during seed must invalidate the response")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
            #expect(try h.visibleSnapshot(kind) == before)
            #expect(try Data(contentsOf: h.file(kind)) == bytes)
        }
    }

    @Test func wrongVineyardResponseFailsBeforeAnyMutationOrAcknowledgement() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness()
            defer { h.cleanup() }
            h.metadata(kind).markDirty(h.firstID(kind), at: WorkTaskBatchHarness.older)
            h.setRemoteNote(kind, "Valid row must also stay uncommitted")
            if kind == .tasks { h.taskServer.rows.append(taskRow(h.otherTasks[0])) }
            else { h.labourServer.rows.append(try labourRow(h.otherLines[0])) }
            let before = try h.visibleSnapshot(kind)
            let bytes = try Data(contentsOf: h.file(kind))
            h.capture()
            do {
                try await h.pull(kind)
                Issue.record("Mixed vineyard responses must be rejected")
            } catch {}
            #expect(try h.visibleSnapshot(kind) == before)
            #expect(try Data(contentsOf: h.file(kind)) == bytes)
            #expect(h.collectionSaves(kind).isEmpty && h.metadataSaves.isEmpty)
            #expect(h.reloadedMetadata(kind).pendingUpserts[h.firstID(kind)] != nil)
        }
    }

    @Test func freshEditDuringFetchAndLocalOnlyRowsRetainTheirPendingIntent() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness(count: 2)
            defer { h.cleanup() }
            if kind == .tasks { h.taskServer.rows = Array(h.taskServer.rows.prefix(1)) }
            else { h.labourServer.rows = Array(h.labourServer.rows.prefix(1)) }
            let absentID = h.visibleIDs(kind)[1]
            h.metadata(kind).markDirty(absentID, at: WorkTaskBatchHarness.newer)
            h.beforeFetch(kind) {
                h.setVisibleNote(kind, "Edited during fetch", persist: true)
                h.metadata(kind).markDirty(h.firstID(kind), at: WorkTaskBatchHarness.newer)
            }
            try await h.pull(kind)
            #expect(h.visibleNotes(kind).first == "Edited during fetch")
            #expect(h.visibleIDs(kind).count == 2)
            #expect(h.metadata(kind).pendingUpserts[h.firstID(kind)] == WorkTaskBatchHarness.newer)
            #expect(h.metadata(kind).pendingUpserts[absentID] == WorkTaskBatchHarness.newer)
            #expect(try h.persistedVisibleSnapshot(kind) == h.visibleSnapshot(kind))
        }
    }

    @Test func timestampTieAndPendingCompletionKeepExistingAcceptanceRules() async throws {
        let h = try WorkTaskBatchHarness()
        defer { h.cleanup() }
        h.setRemoteNote(.tasks, "Remote tie")
        h.taskMetadata.markDirty(h.tasks[0].id, at: WorkTaskBatchHarness.remoteDate)
        try await h.pull(.tasks)
        #expect(h.store.workTasks == h.tasks && h.taskMetadata.pendingUpserts[h.tasks[0].id] != nil)
        h.taskMetadata.markDirty(h.tasks[0].id, at: WorkTaskBatchHarness.older)
        h.taskMetadata.setCompletionMode(true, for: h.tasks[0].id)
        try await h.pull(.tasks)
        #expect(h.store.workTasks == h.tasks && h.taskMetadata.completionMode(for: h.tasks[0].id) == true)

        h.setRemoteNote(.labour, "Labour tie accepted")
        h.labourMetadata.markDirty(h.lines[0].id, at: WorkTaskBatchHarness.remoteDate)
        try await h.pull(.labour)
        #expect(h.store.workTaskLabourLines[0].notes == "Labour tie accepted")
        #expect(h.labourMetadata.pendingUpserts[h.lines[0].id] == nil)
    }

    @Test func duplicateRowsRetainSequentialAcknowledgementAndDeleteOrdering() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness(count: 3)
            defer { h.cleanup() }
            let ids = h.visibleIDs(kind)
            h.metadata(kind).markDirty(ids[0], at: WorkTaskBatchHarness.newer)
            h.metadata(kind).setCompletionMode(false, for: ids[0])
            h.metadata(kind).markDirty(ids[1], at: WorkTaskBatchHarness.remoteDate)
            if kind == .tasks {
                var duplicate = h.tasks[2]; duplicate.notes = "Untouched local duplicate"
                h.store.workTasks.append(duplicate)
                var reinserted = h.tasks[0]; reinserted.notes = "Reinserted after tombstone"
                var first = h.tasks[1]; first.notes = "First accepted revision"
                var second = h.tasks[1]; second.notes = "Later duplicate after acknowledgement"
                var touched = h.tasks[2]; touched.notes = "Only first local match changed"
                h.taskServer.rows = [taskRow(h.tasks[0], deleted: WorkTaskBatchHarness.remoteDate), taskRow(reinserted, updated: WorkTaskBatchHarness.older), taskRow(first, updated: WorkTaskBatchHarness.newer), taskRow(second, updated: WorkTaskBatchHarness.older), taskRow(touched)]
            } else {
                var duplicate = h.lines[2]; duplicate.notes = "Untouched local duplicate"
                h.store.workTaskLabourLines.append(duplicate)
                var reinserted = h.lines[0]; reinserted.notes = "Reinserted after tombstone"
                var first = h.lines[1]; first.notes = "First accepted revision"
                var second = h.lines[1]; second.notes = "Later duplicate after acknowledgement"
                var touched = h.lines[2]; touched.notes = "Only first local match changed"
                h.labourServer.rows = try [labourRow(h.lines[0], deleted: WorkTaskBatchHarness.remoteDate), labourRow(reinserted, updated: WorkTaskBatchHarness.older), labourRow(first, updated: WorkTaskBatchHarness.newer), labourRow(second, updated: WorkTaskBatchHarness.older), labourRow(touched)]
            }
            try h.persistVisibleCollections()
            try await h.pull(kind)
            #expect(h.visibleIDs(kind) == [ids[1], ids[2], ids[2], ids[0]])
            #expect(h.visibleNotes(kind) == ["Later duplicate after acknowledgement", "Only first local match changed", "Untouched local duplicate", "Reinserted after tombstone"])
            #expect(h.metadata(kind).pendingUpserts.isEmpty && h.metadata(kind).completionMode(for: ids[0]) == nil)
        }
    }

    @Test func batchedAcknowledgementsPersistAllMarkerRemovalsAndRetainUnrelatedState() throws {
        let h = try WorkTaskBatchHarness()
        defer { h.cleanup() }
        let upsert = UUID(), removed = UUID(), retained = UUID()
        var state = OperationsSyncMetadata.State()
        state.pendingUpserts = [upsert: WorkTaskBatchHarness.older, retained: WorkTaskBatchHarness.newer]
        state.pendingDeletes = [removed: WorkTaskBatchHarness.older, retained: WorkTaskBatchHarness.newer]
        state.failedUpserts = [upsert, retained]
        state.failedDeletes = [removed, retained]
        state.workTaskCompletionModes = [upsert: true, retained: false]
        state.revisionConflicts = [upsert: .init(baseRevision: 3, serverRevision: 4, detectedAt: WorkTaskBatchHarness.older), retained: .init(baseRevision: 5, serverRevision: 6, detectedAt: WorkTaskBatchHarness.newer)]
        state.observedRevisions = [upsert: 4, retained: 6]
        state.lastSyncByVineyard = [h.vineyard: WorkTaskBatchHarness.older]
        let key = "work_task_batch_marker_metadata"
        try h.persistence.saveOrThrow(state, key: key)
        let metadata = OperationsSyncMetadata(key: key, persistence: h.persistence)
        h.capture()
        metadata.clearAcknowledged(upserts: [upsert], deletes: [removed])
        #expect(h.metadataSaves.count == 1)
        metadata.clearAcknowledged(upserts: [upsert, UUID()], deletes: [removed, UUID()])
        metadata.clearAcknowledged(upserts: [], deletes: [])
        #expect(h.metadataSaves.count == 1)
        let restored: OperationsSyncMetadata.State = try #require(PersistenceStore(directory: h.directory).load(key: key))
        #expect(restored.pendingUpserts == [retained: WorkTaskBatchHarness.newer])
        #expect(restored.pendingDeletes == [retained: WorkTaskBatchHarness.newer])
        #expect(restored.failedUpserts == [retained] && restored.failedDeletes == [retained])
        #expect(restored.workTaskCompletionModes == [retained: false])
        #expect(Set(restored.revisionConflicts?.keys ?? Dictionary<UUID, SyncRevisionConflictMark>().keys) == [retained])
        #expect(restored.observedRevisions == state.observedRevisions && restored.lastSyncByVineyard == state.lastSyncByVineyard)
    }

    @Test func failedMetadataSaveIsRetriedByTheNextUnchangedPull() async throws {
        for kind in WorkTaskBatchKind.allCases {
            let h = try WorkTaskBatchHarness()
            defer { h.cleanup() }
            let id = h.firstID(kind)
            h.metadata(kind).markDirty(id, at: WorkTaskBatchHarness.older)
            h.persistence.durableSaveFailureForTesting = { $0 == kind.metadataKey ? CocoaError(.fileWriteUnknown) : nil }
            try await h.pull(kind)
            #expect(h.metadata(kind).pendingUpserts[id] == nil)
            #expect(h.reloadedMetadata(kind).pendingUpserts[id] != nil)
            h.persistence.durableSaveFailureForTesting = nil
            h.capture()
            try await h.pull(kind)
            #expect(h.collectionSaves(kind).isEmpty && h.metadataSaves.count == 1)
            #expect(h.reloadedMetadata(kind).pendingUpserts[id] == nil)
            h.capture()
            try await h.pull(kind)
            #expect(h.collectionSaves(kind).isEmpty && h.metadataSaves.isEmpty)
        }
    }
}

private nonisolated enum WorkTaskBatchKind: CaseIterable, Sendable {
    case tasks, labour
    @MainActor var key: String { self == .tasks ? WorkTaskRepository.storageKey : WorkTaskLabourLineRepository.storageKey }
    var metadataKey: String { self == .tasks ? "work_task_batch_header_metadata" : "work_task_batch_labour_metadata" }
    var dataset: PersistenceDataset { self == .tasks ? .workTasks : .workTaskLabour }
}

@MainActor
private final class WorkTaskBatchHarness {
    nonisolated static let older = Date(timeIntervalSince1970: 1_750_000_000)
    nonisolated static let remoteDate = Date(timeIntervalSince1970: 1_751_000_000)
    nonisolated static let newer = Date(timeIntervalSince1970: 1_752_000_000)
    let directory: URL
    let persistence: PersistenceStore
    let store: MigratedDataStore
    let auth: NewBackendAuthService
    let vineyard: UUID
    let otherVineyard: UUID
    let tasks: [WorkTask]
    let lines: [WorkTaskLabourLine]
    let otherTasks: [WorkTask]
    let otherLines: [WorkTaskLabourLine]
    let taskMetadata: OperationsSyncMetadata
    let labourMetadata: OperationsSyncMetadata
    let taskServer: WorkTaskBatchServer
    let labourServer: WorkTaskLabourBatchServer
    let taskService: WorkTaskSyncService
    let labourService: WorkTaskLabourLineSyncService
    var measurements: [PersistenceMeasurement] = []

    init(count: Int = 1) throws {
        UserDefaults.standard.set(true, forKey: "vinetrack_work_task_sync_reset_v1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-task-batch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let auth = NewBackendAuthService()
        auth.userId = UUID()
        let vineyard = UUID(), otherVineyard = UUID()
        let tasks = (0..<count).map { WorkTask(vineyardId: vineyard, date: Self.older, taskType: "Task \($0)", resources: [WorkTaskResource(hourlyRate: 31.25)], notes: "Local \($0)", syncVersion: 7) }
        let lines = tasks.enumerated().map { index, task in WorkTaskLabourLine(workTaskId: task.id, vineyardId: vineyard, workDate: Self.older, workerType: "Worker", workerCount: 2, hoursPerWorker: 3.5, hourlyRate: 31.25, notes: "Local \(index)") }
        let otherTasks = [WorkTask(vineyardId: otherVineyard, date: Self.older, taskType: "Other vineyard", notes: "Other retained task", syncVersion: 11)]
        let otherLines = [WorkTaskLabourLine(workTaskId: otherTasks[0].id, vineyardId: otherVineyard, workDate: Self.older, notes: "Other retained labour")]
        let taskMetadata = OperationsSyncMetadata(key: WorkTaskBatchKind.tasks.metadataKey, persistence: persistence)
        let labourMetadata = OperationsSyncMetadata(key: WorkTaskBatchKind.labour.metadataKey, persistence: persistence)
        let taskServer = WorkTaskBatchServer(rows: tasks.map { taskRow($0) })
        let labourServer = WorkTaskLabourBatchServer(rows: try lines.map { try labourRow($0) })
        let taskService = WorkTaskSyncService(repository: taskServer, metadata: taskMetadata)
        let labourService = WorkTaskLabourLineSyncService(repository: labourServer, metadata: labourMetadata)
        self.directory = directory; self.persistence = persistence; self.store = store; self.auth = auth
        self.vineyard = vineyard; self.otherVineyard = otherVineyard
        self.tasks = tasks; self.lines = lines; self.otherTasks = otherTasks; self.otherLines = otherLines
        self.taskMetadata = taskMetadata; self.labourMetadata = labourMetadata
        self.taskServer = taskServer; self.labourServer = labourServer
        self.taskService = taskService; self.labourService = labourService
        store.selectedVineyardId = vineyard
        store.workTasks = tasks; store.workTaskLabourLines = lines
        taskService.configure(store: store, auth: auth)
        labourService.configure(store: store, auth: auth)
        taskMetadata.setLastSync(Self.older, for: vineyard)
        labourMetadata.setLastSync(Self.older, for: vineyard)
        try persistVisibleCollections()
    }

    func file(_ kind: WorkTaskBatchKind) -> URL { directory.appendingPathComponent("\(kind.key).json") }
    func metadata(_ kind: WorkTaskBatchKind) -> OperationsSyncMetadata { kind == .tasks ? taskMetadata : labourMetadata }
    func reloadedMetadata(_ kind: WorkTaskBatchKind) -> OperationsSyncMetadata { OperationsSyncMetadata(key: kind.metadataKey, persistence: PersistenceStore(directory: directory)) }
    func firstID(_ kind: WorkTaskBatchKind) -> UUID { kind == .tasks ? tasks[0].id : lines[0].id }
    func visibleIDs(_ kind: WorkTaskBatchKind) -> [UUID] { kind == .tasks ? store.workTasks.map(\.id) : store.workTaskLabourLines.map(\.id) }
    func visibleNotes(_ kind: WorkTaskBatchKind) -> [String] { kind == .tasks ? store.workTasks.map(\.notes) : store.workTaskLabourLines.map(\.notes) }
    func pull(_ kind: WorkTaskBatchKind) async throws {
        if kind == .tasks { try await taskService.pull(vineyardId: vineyard) }
        else { try await labourService.pull(vineyardId: vineyard) }
    }
    func persistVisibleCollections() throws {
        try persistence.saveOrThrow(otherTasks + store.workTasks, key: WorkTaskRepository.storageKey)
        try persistence.saveOrThrow(otherLines + store.workTaskLabourLines, key: WorkTaskLabourLineRepository.storageKey)
    }
    func capture() {
        measurements = []
        persistence.onPersistenceMeasurementForTesting = { [weak self] in self?.measurements.append($0) }
    }
    func collectionSaves(_ kind: WorkTaskBatchKind) -> [PersistenceMeasurement] { measurements.filter { $0.dataset == kind.dataset && ($0.operation == .save || $0.operation == .durableSave) } }
    var metadataSaves: [PersistenceMeasurement] { measurements.filter { $0.dataset == .metadata && ($0.operation == .save || $0.operation == .durableSave) } }
    func beforeFetch(_ kind: WorkTaskBatchKind, action: @escaping () -> Void) {
        if kind == .tasks { taskServer.beforeFetch = action } else { labourServer.beforeFetch = action }
    }
    func beforeSeed(_ kind: WorkTaskBatchKind, action: @escaping () -> Void) {
        if kind == .tasks { taskServer.beforeSeed = action } else { labourServer.beforeSeed = action }
    }
    func setRemoteNote(_ kind: WorkTaskBatchKind, _ note: String) {
        if kind == .tasks {
            var task = tasks[0]; task.notes = note
            taskServer.rows[0] = taskRow(task)
        } else {
            var line = lines[0]; line.notes = note
            labourServer.rows[0] = try! labourRow(line)
        }
    }
    func setVisibleNote(_ kind: WorkTaskBatchKind, _ note: String, persist: Bool) {
        if kind == .tasks {
            var task = store.workTasks[0]; task.notes = note
            if persist { store.updateWorkTask(task) } else { store.workTasks[0] = task }
        } else {
            var line = store.workTaskLabourLines[0]; line.notes = note
            if persist { store.updateWorkTaskLabourLine(line) } else { store.workTaskLabourLines[0] = line }
        }
    }
    func visibleSnapshot(_ kind: WorkTaskBatchKind) throws -> Data {
        if kind == .tasks { return try snapshot(store.workTasks) }
        return try snapshot(store.workTaskLabourLines)
    }
    func persistedVisibleSnapshot(_ kind: WorkTaskBatchKind) throws -> Data {
        let disk = PersistenceStore(directory: directory)
        if kind == .tasks {
            let all: [WorkTask] = try #require(disk.load(key: kind.key))
            return try snapshot(all.filter { $0.vineyardId == vineyard })
        }
        let all: [WorkTaskLabourLine] = try #require(disk.load(key: kind.key))
        return try snapshot(all.filter { $0.vineyardId == vineyard })
    }
    func persistedNotes(_ kind: WorkTaskBatchKind) throws -> [String] {
        let disk = PersistenceStore(directory: directory)
        if kind == .tasks {
            let all: [WorkTask] = try #require(disk.load(key: kind.key))
            return all.filter { $0.vineyardId == vineyard }.map(\.notes)
        }
        let all: [WorkTaskLabourLine] = try #require(disk.load(key: kind.key))
        return all.filter { $0.vineyardId == vineyard }.map(\.notes)
    }
    func expectOtherVineyardUnchanged(_ kind: WorkTaskBatchKind) throws {
        let disk = PersistenceStore(directory: directory)
        if kind == .tasks {
            let all: [WorkTask] = try #require(disk.load(key: kind.key))
            #expect(all.filter { $0.vineyardId == otherVineyard } == otherTasks)
        } else {
            let all: [WorkTaskLabourLine] = try #require(disk.load(key: kind.key))
            #expect(all.filter { $0.vineyardId == otherVineyard } == otherLines)
        }
    }
    func observe(_ kind: WorkTaskBatchKind) -> WorkTaskPublicationFlag {
        let flag = WorkTaskPublicationFlag()
        withObservationTracking {
            if kind == .tasks { _ = store.workTasks } else { _ = store.workTaskLabourLines }
        } onChange: { flag.mark() }
        return flag
    }
    func cleanup() {
        taskServer.beforeFetch = nil; labourServer.beforeFetch = nil
        taskServer.beforeSeed = nil; labourServer.beforeSeed = nil
        persistence.onPersistenceMeasurementForTesting = nil
        persistence.durableSaveFailureForTesting = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private nonisolated final class WorkTaskPublicationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@MainActor
private final class WorkTaskBatchServer: WorkTaskSyncRepositoryProtocol {
    var rows: [BackendWorkTask]
    var cursors: [Date?] = []
    var beforeFetch: (() -> Void)?
    var beforeSeed: (() -> Void)?
    init(rows: [BackendWorkTask]) { self.rows = rows }
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTask] {
        cursors.append(since)
        let response = rows
        let action = beforeFetch; beforeFetch = nil; action?()
        return response
    }
    func upsertMany(_ items: [BackendWorkTaskUpsert]) async throws { let action = beforeSeed; beforeSeed = nil; action?() }
    func softDelete(id: UUID) async throws {}
}

@MainActor
private final class WorkTaskLabourBatchServer: WorkTaskLabourLineSyncRepositoryProtocol {
    var rows: [BackendWorkTaskLabourLine]
    var cursors: [Date?] = []
    var beforeFetch: (() -> Void)?
    var beforeSeed: (() -> Void)?
    init(rows: [BackendWorkTaskLabourLine]) { self.rows = rows }
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskLabourLine] {
        cursors.append(since)
        let response = rows
        let action = beforeFetch; beforeFetch = nil; action?()
        return response
    }
    func upsertMany(_ items: [BackendWorkTaskLabourLineUpsert]) async throws { let action = beforeSeed; beforeSeed = nil; action?() }
    func softDelete(id: UUID) async throws {}
}

@MainActor
private func taskRow(_ task: WorkTask, updated: Date = WorkTaskBatchHarness.remoteDate, deleted: Date? = nil) -> BackendWorkTask {
    var row = BackendWorkTask(id: task.id, vineyardId: task.vineyardId, paddockId: task.paddockId, paddockName: task.paddockName, date: task.date, taskType: task.taskType, durationHours: task.durationHours, resources: task.resources, notes: task.notes, isArchived: task.isArchived, archivedAt: task.archivedAt, archivedBy: task.archivedBy, isFinalized: task.isFinalized, finalizedAt: task.finalizedAt, finalizedBy: task.finalizedBy, startDate: task.startDate, endDate: task.endDate, areaHa: task.areaHa, taskDescription: task.taskDescription, status: task.status, costingMethod: task.costingMethodRaw, pieceRatePerVine: task.pieceRatePerVine, pieceVineCount: task.pieceVineCount, pruningActivityId: task.pruningActivityId, createdBy: task.createdBy.flatMap(UUID.init(uuidString:)), createdAt: nil, updatedAt: updated, deletedAt: deleted, clientUpdatedAt: updated)
    row.assignedTo = task.assignedTo; row.assignedExternalResourceId = task.assignedExternalResourceId
    row.scheduleBasis = task.scheduleBasis; row.targetELStage = task.targetELStage
    row.completedBy = task.completedBy; row.completedAt = task.completedAt; row.syncVersion = task.syncVersion
    return row
}

@MainActor
private func labourRow(_ line: WorkTaskLabourLine, updated: Date = WorkTaskBatchHarness.remoteDate, deleted: Date? = nil) throws -> BackendWorkTaskLabourLine {
    let formatter = ISO8601DateFormatter()
    var object: [String: Any] = ["id": line.id.uuidString, "work_task_id": line.workTaskId.uuidString, "vineyard_id": line.vineyardId.uuidString, "work_date": formatter.string(from: line.workDate), "worker_type": line.workerType, "worker_count": line.workerCount, "hours_per_worker": line.hoursPerWorker, "notes": line.notes, "updated_at": formatter.string(from: updated), "client_updated_at": formatter.string(from: updated)]
    if let rate = line.hourlyRate { object["hourly_rate"] = rate }
    if let category = line.operatorCategoryId { object["worker_type_id"] = category.uuidString }
    if let deleted { object["deleted_at"] = formatter.string(from: deleted) }
    return try JSONDecoder().decode(BackendWorkTaskLabourLine.self, from: JSONSerialization.data(withJSONObject: object))
}

private func snapshot<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}
