import Foundation
import Testing
@testable import VineTrack

@MainActor
struct PruningResourceCASTests {
    @Test func explicitNullsAndTimestampPrecision() throws {
        let activity = UUID(), vineyard = UUID(), user = UUID()
        var link = PruningResourceLink(externalResourceId: nil, workerUserId: nil, name: "Other", authoredBy: user)
        link.expected = PruningResourceSnapshot(id: activity, vineyardId: vineyard, clientUpdatedAt: "2026-10-08T01:02:03.123456+00:00", externalResourceId: nil, workerUserId: user, deletedAt: nil)
        let data = try JSONEncoder().encode(link.request(activityId: activity, vineyardId: vineyard))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body.count == 6)
        #expect(body["p_external_resource_id"] is NSNull)
        #expect(body["p_worker_user_id"] is NSNull)
        #expect(body["p_expected_external_resource_id"] is NSNull)
        #expect(body["p_expected_client_updated_at"] as? String == "2026-10-08T01:02:03.123456+00:00")
    }

    @Test func successfulAndDuplicateAcknowledgements() throws {
        let activity = UUID(), vineyard = UUID(), user = UUID()
        var link = PruningResourceLink(externalResourceId: nil, workerUserId: user, name: "Operator", authoredBy: user)
        link.expected = PruningResourceSnapshot(id: activity, vineyardId: vineyard, clientUpdatedAt: nil, externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        for duplicate in [false, true] {
            let result = try JSONDecoder().decode(PruningResourceCASResult.self, from: Data("{\"activity_id\":\"\(activity)\",\"applied\":true,\"idempotent\":\(duplicate),\"external_resource_id\":null,\"worker_user_id\":\"\(user)\"}".utf8))
            let accepted = try link.accepting(result, activityId: activity)
            #expect(accepted.acknowledged)
            #expect(accepted.expected == link.expected)
            #expect(accepted.generation == link.generation)
        }
    }

    @Test func staleCrossDeviceSelectionRetainsIntentAndBaseline() throws {
        let activity = UUID(), vineyard = UUID(), user = UUID(), other = UUID()
        var link = PruningResourceLink(externalResourceId: nil, workerUserId: user, name: "My operator", authoredBy: user)
        link.expected = PruningResourceSnapshot(id: activity, vineyardId: vineyard, clientUpdatedAt: "2026-10-08T00:00:00.123456Z", externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        let result = try JSONDecoder().decode(PruningResourceCASResult.self, from: Data("{\"activity_id\":\"\(activity)\",\"applied\":false,\"conflict\":true,\"external_resource_id\":null,\"worker_user_id\":\"\(other)\",\"canonical\":{\"id\":\"\(activity)\",\"vineyard_id\":\"\(vineyard)\",\"client_updated_at\":\"2026-10-08T01:00:00Z\",\"external_resource_id\":null,\"worker_user_id\":\"\(other)\",\"deleted_at\":null}}".utf8))
        let conflict = try link.accepting(result, activityId: activity)
        #expect(conflict.isPending)
        #expect(conflict.workerUserId == user)
        #expect(conflict.name == "My operator")
        #expect(conflict.expected == link.expected)
        #expect(conflict.conflict?.workerUserId == other)
        #expect(conflict.message?.contains("conflict") == true)
        #expect(throws: PruningResourceLinkError.self) { try conflict.request(activityId: activity, vineyardId: vineyard) }
    }

    @Test func wrongAcknowledgementAndAbsentKeysAreRejected() throws {
        let activity = UUID(), user = UUID()
        let link = PruningResourceLink(externalResourceId: nil, workerUserId: user, name: "Operator", authoredBy: user)
        let response = Data("{\"activity_id\":\"\(activity)\",\"applied\":true,\"external_resource_id\":null,\"worker_user_id\":null}".utf8)
        let result = try JSONDecoder().decode(PruningResourceCASResult.self, from: response)
        #expect(throws: PruningResourceLinkError.self) { try link.accepting(result, activityId: activity) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PruningResourceCASResult.self, from: Data("{\"activity_id\":\"\(activity)\",\"applied\":true}".utf8))
        }
    }

    @Test func missingBaselineFieldsAreNotAuthoritativeNulls() {
        let payload = Data("{\"id\":\"\(UUID())\",\"vineyard_id\":\"\(UUID())\"}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PruningResourceSnapshot.self, from: payload) }
    }

    @Test func crossVineyardAndMutuallyExclusiveRequestGuards() {
        let activity = UUID(), vineyard = UUID(), user = UUID()
        var link = PruningResourceLink(externalResourceId: UUID(), workerUserId: user, name: "Invalid", authoredBy: user)
        link.expected = PruningResourceSnapshot(id: activity, vineyardId: vineyard, clientUpdatedAt: nil, externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        #expect(throws: PruningResourceLinkError.self) { try link.request(activityId: activity, vineyardId: vineyard) }
        link = PruningResourceLink(externalResourceId: nil, workerUserId: user, name: "Operator", authoredBy: user)
        link.expected = PruningResourceSnapshot(id: activity, vineyardId: vineyard, clientUpdatedAt: nil, externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        #expect(throws: PruningResourceLinkError.self) { try link.request(activityId: activity, vineyardId: UUID()) }
    }

    @Test func diskRestartAndOlderGenerationAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = PruningStore(persistence: persistence)
        let vineyard = UUID(), user = UUID()
        var draft = PruningActivityDraft(vineyardId: vineyard, worker: "Crew", labourHours: 8, hourlyRate: 25)
        var link = PruningResourceLink(externalResourceId: UUID(), workerUserId: nil, name: "Crew", authoredBy: user)
        draft.resourceLink = link
        store.saveActivity(draft)
        link.expected = PruningResourceSnapshot(id: draft.id, vineyardId: vineyard, clientUpdatedAt: "2026-10-08T01:02:03.123456Z", externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        #expect(try store.persistResourceState(id: draft.id, generation: link.generation, link: link, snapshot: link.expected))
        let restarted = PruningStore(persistence: PersistenceStore(directory: directory))
        #expect(restarted.activity(id: draft.id)?.resourceLink == link)
        #expect(restarted.activity(id: draft.id)?.labourCost == 200)
        #expect(try !store.persistResourceState(id: draft.id, generation: UUID(), link: nil, snapshot: nil))
        #expect(store.activity(id: draft.id)?.resourceLink == link)
    }

    @Test func diskFailureDoesNotAdvanceBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = PruningStore(persistence: persistence)
        var draft = PruningActivityDraft(vineyardId: UUID())
        var link = PruningResourceLink(externalResourceId: nil, workerUserId: UUID(), name: "Operator", authoredBy: UUID())
        draft.resourceLink = link
        store.saveActivity(draft)
        link.expected = PruningResourceSnapshot(id: draft.id, vineyardId: draft.vineyardId, clientUpdatedAt: nil, externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try store.persistResourceState(id: draft.id, generation: link.generation, link: link, snapshot: link.expected) }
        #expect(store.activity(id: draft.id)?.resourceLink?.expected == nil)
    }

    @Test func stageCompatibilityDateDoesNotConstrainCompletionOrRange() {
        let now = Date(), future = Date().addingTimeInterval(86400 * 30)
        let task = WorkTask(vineyardId: UUID(), date: future, scheduleBasis: "el_stage", targetELStage: 35)
        #expect(task.plannedDate == nil)
        #expect(task.stageLabel?.contains("EL35") == true)
        #expect(task.matchesStageRange(minimum: 35, maximum: 35))
        #expect(!task.matchesStageRange(minimum: 36, maximum: 43))
        #expect(WorkTaskCompletion.isValid(now, task: task, timeZone: TimeZone(secondsFromGMT: 0)!, now: now))
        let dated = WorkTask(vineyardId: UUID(), date: future)
        #expect(!dated.matchesStageRange(minimum: 1, maximum: 43))
    }
}
