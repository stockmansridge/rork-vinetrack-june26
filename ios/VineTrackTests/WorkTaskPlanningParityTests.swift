import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskPlanningParityTests {
    @Test func portalOrderSeparatesCompletionStageAndUpcomingDates() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z"))
        let vineyard = UUID()
        let stage35 = WorkTask(vineyardId: vineyard, date: now.addingTimeInterval(999999), scheduleBasis: "el_stage", targetELStage: 35)
        let stage12 = WorkTask(vineyardId: vineyard, date: now.addingTimeInterval(-999999), scheduleBasis: "el_stage", targetELStage: 12)
        let near = WorkTask(vineyardId: vineyard, date: now.addingTimeInterval(86400))
        let later = WorkTask(vineyardId: vineyard, date: now.addingTimeInterval(864000))
        let past = WorkTask(vineyardId: vineyard, date: now.addingTimeInterval(-86400))
        let completed = WorkTask(vineyardId: vineyard, isFinalized: true, scheduleBasis: "el_stage", targetELStage: 43)
        let result = WorkTaskPlanning.ordered([completed, later, past, stage12, near, stage35], now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(result.map(\.id) == [stage35.id, stage12.id, near.id, later.id, past.id, completed.id])
    }

    @Test func inclusiveRangeCombinesWithSearchAndExcludesCompatibilityDateTasks() {
        let low = WorkTask(taskType: "Pruning", scheduleBasis: "el_stage", targetELStage: 12)
        let high = WorkTask(taskType: "Pruning", scheduleBasis: "el_stage", targetELStage: 35)
        let dated = WorkTask(taskType: "Pruning")
        let filtered = [low, high, dated].filter { $0.matchesStageRange(minimum: 12, maximum: 35) && $0.taskType.contains("Pruning") }
        #expect(filtered.map(\.id) == [low.id, high.id])
        #expect(!low.matchesStageRange(minimum: 35, maximum: 12))
        #expect(dated.matchesStageRange(minimum: nil, maximum: nil))
    }

    @Test func catalogueRejectsUnsupportedStagesAndExclusiveAssignments() {
        var draft = WorkTaskPlanningDraft(taskID: nil, vineyardID: UUID(), authorID: UUID(), assignmentName: "", scheduleBasis: "el_stage", targetStage: 35, date: Date(), taskType: "Pruning", blockIDs: [], durationText: "", notes: "")
        #expect(draft.isValid)
        draft.targetStage = 44; #expect(!draft.isValid)
        draft.targetStage = 2; #expect(draft.isValid == WorkTaskPlanning.supportedStages.contains(2))
        draft.targetStage = 35; draft.assignedTo = UUID(); draft.externalID = UUID(); #expect(!draft.isValid)
        draft.externalID = nil; #expect(draft.isValid)
    }

    @Test func localDraftDiskRestartKeepsClearsNamesAndWholeFormSeparateFromCanonical() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let author = UUID(), vineyard = UUID(), taskID = UUID()
        var draft = WorkTaskPlanningDraft(taskID: taskID, vineyardID: vineyard, authorID: author, externalID: UUID(), assignmentName: "Inactive historical crew", scheduleBasis: "el_stage", targetStage: 35, date: Date(timeIntervalSince1970: 1700000000), taskType: "My custom work", blockIDs: [UUID()], durationText: "8", notes: "Unsaved instructions", resources: [WorkTaskResource(workerTypeName: "Frozen", hourlyRate: 25, count: 2)])
        let persistence = PersistenceStore(directory: directory)
        try persistence.saveOrThrow(draft, key: draft.persistenceKey)
        let restarted: WorkTaskPlanningDraft? = PersistenceStore(directory: directory).load(key: draft.persistenceKey)
        #expect(restarted == draft)
        draft.externalID = nil; draft.assignmentName = ""
        try persistence.saveOrThrow(draft, key: draft.persistenceKey)
        let cleared: WorkTaskPlanningDraft? = PersistenceStore(directory: directory).load(key: draft.persistenceKey)
        #expect(cleared?.externalID == nil)
        var differentAccount = draft; differentAccount.authorID = UUID()
        #expect(differentAccount.persistenceKey != draft.persistenceKey)
        var differentVineyard = draft; differentVineyard.vineyardID = UUID()
        #expect(differentVineyard.persistenceKey != draft.persistenceKey)
        let canonical = WorkTask(id: taskID, vineyardId: vineyard)
        #expect(canonical.assignedExternalResourceId == nil && !canonical.isStageScheduled)
    }

    @Test func recordedCompleterIsNotAssigneeCreatorOrTripOperator() {
        let vineyard = UUID(), assignee = UUID(), completer = UUID(), operatorID = UUID()
        let task = WorkTask(vineyardId: vineyard, createdBy: "Creator", isFinalized: true, assignedTo: assignee, completedBy: completer)
        let trip = Trip(vineyardId: vineyard, endTime: Date(), isActive: false, operatorUserId: operatorID, workTaskId: task.id)
        #expect(WorkTaskPlanning.completingUser(task, trips: [trip], verifiedMemberIDs: []) == completer)
        #expect(task.assignedTo == assignee)
    }

    @Test func onlyUnambiguousFinishedSameVineyardTripsAttributeHistoricalCompletion() {
        let vineyard = UUID(), user = UUID(), other = UUID()
        let task = WorkTask(vineyardId: vineyard, createdBy: "A creator", isFinalized: true, finalizedBy: "Unverified free text")
        let trip = Trip(vineyardId: vineyard, endTime: Date(), isActive: false, operatorUserId: user, workTaskId: task.id)
        #expect(WorkTaskPlanning.completingUser(task, trips: [trip], verifiedMemberIDs: []) == user)
        var second = Trip(vineyardId: vineyard, endTime: Date(), isActive: false, operatorUserId: other, workTaskId: task.id)
        #expect(WorkTaskPlanning.completingUser(task, trips: [trip, second], verifiedMemberIDs: []) == nil)
        second.operatorUserId = nil
        #expect(WorkTaskPlanning.completingUser(task, trips: [trip, second], verifiedMemberIDs: []) == nil)
        second = trip; second.vineyardId = UUID()
        #expect(WorkTaskPlanning.completingUser(task, trips: [second], verifiedMemberIDs: []) == nil)
        second = trip; second.isActive = true
        #expect(WorkTaskPlanning.completingUser(task, trips: [second], verifiedMemberIDs: []) == nil)
    }

    @Test func canonicalCompletionInstantUsesVineyardDayAcrossUTCMidnight() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-08T00:30:00Z"))
        let task = WorkTask(isFinalized: true, completedBy: UUID(), completedAt: instant)
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let shown = try #require(WorkTaskCompletion.displayedDate(task))
        let day = WorkTaskCompletion.calendar(zone).component(.day, from: shown)
        #expect(day == 7)
        #expect(task.completedAt == instant)
        let east = try #require(TimeZone(identifier: "Pacific/Auckland"))
        #expect(WorkTaskCompletion.calendar(east).component(.day, from: shown) == 8)
    }

    @Test func draftPermissionAndSelectableResourceScopeFailClosed() {
        let author = UUID(), vineyard = UUID()
        let draft = WorkTaskPlanningDraft(taskID: nil, vineyardID: vineyard, authorID: author, assignmentName: "", scheduleBasis: "date", date: Date(), taskType: "Pruning", blockIDs: [], durationText: "", notes: "")
        #expect(WorkTaskPlanning.canSaveDraft(draft, signedInUser: author, selectedVineyard: vineyard, membershipRole: "operator"))
        #expect(!WorkTaskPlanning.canSaveDraft(draft, signedInUser: author, selectedVineyard: vineyard, membershipRole: "admin"))
        #expect(!WorkTaskPlanning.canSaveDraft(draft, signedInUser: nil, selectedVineyard: vineyard, membershipRole: "owner"))
        #expect(!WorkTaskPlanning.canSaveDraft(draft, signedInUser: author, selectedVineyard: UUID(), membershipRole: "owner"))
        var resource = VineyardExternalResource(id: UUID(), vineyardId: vineyard, name: "Historical crew", kind: "crew", isActive: true)
        #expect(WorkTaskPlanning.canSelect(resource, vineyard: vineyard))
        #expect(!WorkTaskPlanning.canSelect(resource, vineyard: UUID()))
        resource.isActive = false
        #expect(!WorkTaskPlanning.canSelect(resource, vineyard: vineyard))
        #expect(resource.name == "Historical crew")
    }

    @Test func resourcePayloadClearsContactFieldsButCannotWriteAuditOrCostFields() throws {
        let resource = VineyardExternalResource(id: UUID(), vineyardId: UUID(), name: "Crew", kind: "crew", isActive: true)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ResourceWrite(resource))) as? [String: Any])
        #expect(body["phone"] is NSNull && body["contact_name"] is NSNull)
        #expect(body["updated_at"] == nil && body["hourly_rate"] == nil && body["created_by"] == nil)
        var historical = resource; historical.isActive = false
        #expect(ResourceWrite(resource) != ResourceWrite(historical))
    }
}
