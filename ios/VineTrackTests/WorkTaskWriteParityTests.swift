import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskWriteParityTests {
    @Test func newELCreateOmitsDateAndVintageAndAcceptsServerVintage() throws {
        let draft = WorkTaskPlanningDraft(taskID: nil, vineyardID: UUID(), authorID: UUID(), assignmentName: "", scheduleBasis: "el_stage", targetStage: 35, date: Date(), taskType: "Pruning", blockIDs: [], durationText: "", notes: "")
        let intent = try WorkTaskWriteContract.planning(draft: draft, id: UUID(), zone: .gmt, now: Date(), paddockID: nil, paddockName: "", area: 0)
        #expect(intent.payload["date"] == nil && intent.payload["vintage_year"] == nil)
        #expect(intent.payload["start_date"] == .null && intent.payload["end_date"] == .null)
        #expect(intent.payload["is_finalized"] == .boolean(false))
        var row = intent.payload; row["date"] = .string("2026-10-09T10:00:00Z"); row["vintage_year"] = .integer(2027)
        try WorkTaskWriteContract.verify(baseline: nil, payload: intent.payload, row: row, observedKeys: [])
    }
    @Test func modeSwitchPreservesAnchorAndNeverOwnsCompletion() throws {
        let stored = WorkTaskWriteValue.string("2025-07-11T22:31:00Z")
        let stage = try WorkTaskWriteContract.schedule(basis: "el_stage", stage: 35, date: Date(), zone: .gmt, existingDate: stored)
        #expect(stage["date"] == stored && stage["start_date"] == .null && stage["end_date"] == nil)
        let dated = try WorkTaskWriteContract.schedule(basis: "date", stage: 35, date: Date(timeIntervalSince1970: 0), zone: .gmt, existingDate: stored)
        #expect(dated["target_el_stage"] == .null && dated["date"] == dated["start_date"])
        #expect(dated["vintage_year"] == nil)
    }
    @Test func completionUsesAuthenticatedPersonAndActualPressTime() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-09T00:30:00Z")!
        let author = UUID(), assigned = UUID()
        let task = WorkTask(date: now, assignedTo: assigned, scheduleBasis: "el_stage", targetELStage: 35)
        let selected = now.addingTimeInterval(-86400 * 5)
        let p = try WorkTaskWriteContract.completion(action: "complete", task: task, selected: selected, zone: .gmt, now: now, author: author)
        #expect(p["completed_by"] == .string(author.uuidString))
        #expect(p["completed_at"] == .string("2026-10-09T00:30:00Z"))
        #expect(p["end_date"] == .string("2026-10-04"))
        #expect(p["assigned_to"] == nil && p["target_el_stage"] == nil && p["status"] == nil)
    }
    @Test func reopenClearsAllAuditAndDateCorrectionOmitsOriginalAudit() throws {
        let task = WorkTask(isFinalized: true, assignedTo: UUID(), scheduleBasis: "el_stage", targetELStage: 35, completedBy: UUID(), completedAt: Date())
        let reopen = try WorkTaskWriteContract.completion(action: "reopen", task: task, selected: nil, zone: .gmt, now: Date(), author: UUID())
        for key in ["end_date", "completed_by", "completed_at", "finalized_at", "finalized_by"] { #expect(reopen[key] == .null) }
        let correction = try WorkTaskWriteContract.completion(action: "completion_date", task: task, selected: Date(), zone: .gmt, now: Date(), author: UUID())
        #expect(Set(correction.keys) == ["is_finalized", "end_date"])
    }
    @Test func timezoneBusinessDayAndAuditFallbackAreSeparate() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-09T00:30:00Z")!
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let task = WorkTask(isFinalized: true, completedAt: instant)
        #expect(WorkTaskWriteContract.businessDate(WorkTaskCompletion.displayedDate(task, timeZone: zone)!, zone: zone) == "2026-10-08")
        var dated = task; dated.endDate = ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z")!
        #expect(WorkTaskWriteContract.businessDate(WorkTaskCompletion.displayedDate(dated, timeZone: zone)!, zone: zone) == "2026-10-07")
        #expect(!WorkTaskCompletion.isValid(instant, task: task, timeZone: zone, now: instant.addingTimeInterval(-86400)))
    }
    @Test func staleVersionOrChangedAuditCannotAcknowledge() throws {
        let baseline: [String: WorkTaskWriteValue] = ["sync_version": .integer(4), "completed_by": .null]
        let patch: [String: WorkTaskWriteValue] = ["sync_version": .integer(5)]
        #expect(throws: WorkTaskPlanningWriteError.self) { try WorkTaskWriteContract.verify(baseline: baseline, payload: patch, row: ["sync_version": .integer(6), "completed_by": .null, "vintage_year": .integer(2027)], observedKeys: Array(baseline.keys)) }
        #expect(throws: WorkTaskPlanningWriteError.self) { try WorkTaskWriteContract.verify(baseline: baseline, payload: patch, row: ["sync_version": .integer(5), "completed_by": .string(UUID().uuidString), "vintage_year": .integer(2027)], observedKeys: Array(baseline.keys)) }
    }
    @Test func predicatesRetainOriginalVersionRawTimestampScopeAndNulls() throws {
        let baseline: [String: WorkTaskWriteValue] = ["id": .string(UUID().uuidString), "vineyard_id": .string(UUID().uuidString), "sync_version": .integer(7), "updated_at": .string("2026-10-09T00:00:00.123456+00:00"), "deleted_at": .null, "assigned_to": .null]
        let result = try WorkTaskWriteContract.predicates(baseline: baseline, observedKeys: Array(baseline.keys))
        #expect(result.first { $0.0 == "sync_version" }?.1 == "7")
        #expect(result.first { $0.0 == "updated_at" }?.1 == "2026-10-09T00:00:00.123456+00:00")
        #expect(result.contains { $0.0 == "assigned_to" && $0.1 == nil })
        #expect(throws: WorkTaskPlanningWriteError.self) { try WorkTaskWriteContract.predicates(baseline: [:], observedKeys: Array(baseline.keys)) }
    }
    @Test func dateScheduledCompletionRejectsBeforeWorkDayAndStageCatalogueRejectsGaps() throws {
        let work = ISO8601DateFormatter().date(from: "2026-10-09T00:00:00Z")!
        let task = WorkTask(date: work, startDate: work)
        #expect(throws: WorkTaskPlanningWriteError.self) { try WorkTaskWriteContract.completion(action: "complete", task: task, selected: work.addingTimeInterval(-86400), zone: .gmt, now: work, author: UUID()) }
        #expect(throws: WorkTaskPlanningWriteError.self) { try WorkTaskWriteContract.schedule(basis: "el_stage", stage: 6, date: work, zone: .gmt, existingDate: nil) }
        let legacyText = WorkTask(status: "completed")
        #expect(WorkTaskPlanning.completingUser(legacyText, trips: [], verifiedMemberIDs: []) == nil)
    }
    @Test func lostResponseSurvivesRestartAndCannotReplayOrReplaceIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let intent = WorkTaskWriteIntent(taskID: UUID(), vineyardID: UUID(), authorID: UUID(), baselineJSON: "original", payload: ["completed_at": .string("2026-10-09T00:30:00Z")])
        let disk = PersistenceStore(directory: directory)
        var calls = 0
        do {
            _ = try await WorkTaskWriteCoordinator(persistence: disk).submit(intent, canWrite: { true }) { request in
                let persisted: WorkTaskWriteIntent? = disk.load(key: request.persistenceKey)
                #expect(persisted?.payload == request.payload)
                calls += 1
                throw WorkTaskPlanningWriteError.conflict
            }
            Issue.record("Lost response must not succeed")
        } catch {}
        do {
            _ = try await WorkTaskWriteCoordinator(persistence: PersistenceStore(directory: directory)).submit(intent, canWrite: { true }) { _ in
                calls += 1; return WorkTask(id: intent.taskID, vineyardId: intent.vineyardID)
            }
            Issue.record("Unknown outcome must be held")
        } catch {}
        #expect(calls == 1)
        let retained: WorkTaskWriteIntent? = disk.load(key: intent.persistenceKey)
        #expect(retained?.baselineJSON == "original" && retained?.acknowledged == false)
    }
    @Test func persistenceFailureStopsBeforeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PersistenceStore(directory: directory)
        disk.durableSaveFailureForTesting = { _ in WorkTaskPlanningWriteError.conflict }
        let intent = WorkTaskWriteIntent(taskID: UUID(), vineyardID: UUID(), authorID: UUID(), baselineJSON: nil, payload: [:])
        var calls = 0
        do {
            _ = try await WorkTaskWriteCoordinator(persistence: disk).submit(intent, canWrite: { true }) { _ in
                calls += 1; return WorkTask(id: intent.taskID, vineyardId: intent.vineyardID)
            }
            Issue.record("Disk failure must prevent initiation")
        } catch {}
        #expect(calls == 0)
    }
    @Test func accountSwitchAfterResponseRetainsUnacknowledgedIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PersistenceStore(directory: directory)
        let intent = WorkTaskWriteIntent(taskID: UUID(), vineyardID: UUID(), authorID: UUID(), baselineJSON: nil, payload: [:])
        var sameAccount = true
        do {
            _ = try await WorkTaskWriteCoordinator(persistence: disk).submit(intent, canWrite: { sameAccount }) { _ in
                sameAccount = false; return WorkTask(id: intent.taskID, vineyardId: intent.vineyardID)
            }
            Issue.record("Account-switched result must not acknowledge")
        } catch {}
        let retained: WorkTaskWriteIntent? = disk.load(key: intent.persistenceKey)
        #expect(retained?.acknowledged == false)
    }
}
