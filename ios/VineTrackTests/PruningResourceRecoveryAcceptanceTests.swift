import Foundation
import Testing
@testable import VineTrack

/// Runs the actual sync coordinator against a controlled transport, never a live vineyard.
@MainActor
@Suite(.serialized)
struct PruningResourceRecoveryAcceptanceTests {
    @Test func lostResponseRestartAndDuplicateRetryDoNotReplayAllocations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let pruning = PruningStore(persistence: persistence)
        let author = UUID(), vineyard = UUID()
        store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService(); auth.isSignedIn = true; auth.userId = author
        var draft = PruningActivityDraft(vineyardId: vineyard, worker: "Crew", labourHours: 8, hourlyRate: 25)
        draft.serverAcknowledged = true
        let firstBlock = UUID(), secondBlock = UUID()
        draft.allocations[firstBlock] = BlockPruningSelection(paddockId: firstBlock, blockName: "North", segments: [PruningSegment(row: 1, quarter: 1)], estimatedVines: 25)
        draft.allocations[secondBlock] = BlockPruningSelection(paddockId: secondBlock, blockName: "South", segments: [PruningSegment(row: 2, quarter: 4)], estimatedVines: 30)
        let originalAllocations = draft.allocations
        draft.resourceLink = PruningResourceLink(externalResourceId: UUID(), workerUserId: nil, name: "Crew", authoredBy: author)
        pruning.saveActivity(draft)
        let transport = ResourceRecoveryTransport(activity: draft.id, vineyard: vineyard)
        transport.loseFirstResponse = true
        transport.baselineOnDisk = { pruning.activity(id: draft.id)?.resourceLink?.expected != nil }
        let sync = PruningSyncService(repository: transport, pruningStore: pruning)
        sync.configure(store: store, auth: auth)
        await sync.syncForSelectedVineyard()
        #expect(transport.casCalls == 1)
        #expect(transport.baselineWasDurable)
        let captured = try #require(pruning.activity(id: draft.id)?.resourceLink?.expected)
        #expect(pruning.activity(id: draft.id)?.resourceLink?.isPending == true)
        #expect(transport.parentMutationCalls == 0)
        let restarted = PruningStore(persistence: PersistenceStore(directory: directory))
        #expect(restarted.activity(id: draft.id)?.resourceLink?.expected == captured)
        transport.baselineOnDisk = { restarted.activity(id: draft.id)?.resourceLink?.expected == captured }
        let resumed = PruningSyncService(repository: transport, pruningStore: restarted)
        resumed.configure(store: store, auth: auth)
        await resumed.syncForSelectedVineyard()
        #expect(transport.casCalls == 2)
        #expect(transport.receivedBaselines == [captured.clientUpdatedAt, captured.clientUpdatedAt])
        #expect(restarted.activity(id: draft.id)?.resourceLink?.acknowledged == true)
        #expect(restarted.activity(id: draft.id)?.allocations == originalAllocations)
        #expect(restarted.activity(id: draft.id)?.labourCost == 200)
        #expect(transport.parentMutationCalls == 0)
        await resumed.syncForSelectedVineyard()
        #expect(transport.casCalls == 2)
    }

    @Test func resourceReplayWaitsForAcknowledgedParentAndAuthoredAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let pruning = PruningStore(persistence: persistence)
        let author = UUID(), vineyard = UUID()
        store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService(); auth.isSignedIn = true; auth.userId = author
        var draft = PruningActivityDraft(vineyardId: vineyard, worker: "Crew")
        draft.resourceLink = PruningResourceLink(externalResourceId: UUID(), workerUserId: nil, name: "Crew", authoredBy: author)
        pruning.saveActivity(draft)
        let transport = ResourceRecoveryTransport(activity: draft.id, vineyard: vineyard)
        let sync = PruningSyncService(repository: transport, pruningStore: pruning)
        sync.configure(store: store, auth: auth)
        await sync.syncForSelectedVineyard()
        #expect(transport.casCalls == 0)
        #expect(pruning.activity(id: draft.id)?.resourceLink?.isPending == true)
        let restarted = PruningStore(persistence: PersistenceStore(directory: directory))
        var acknowledged = try #require(restarted.activity(id: draft.id))
        acknowledged.serverAcknowledged = true
        restarted.saveActivity(acknowledged)
        auth.userId = UUID()
        let resumed = PruningSyncService(repository: transport, pruningStore: restarted)
        resumed.configure(store: store, auth: auth)
        await resumed.syncForSelectedVineyard()
        #expect(transport.casCalls == 0)
        #expect(transport.parentMutationCalls == 0)
        #expect(restarted.activity(id: draft.id)?.resourceLink?.authoredBy == author)
    }

    @Test func staleConflictSurvivesPullRestartAndRetryWithoutRebase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let pruning = PruningStore(persistence: persistence)
        let author = UUID(), vineyard = UUID(), other = UUID()
        store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService(); auth.isSignedIn = true; auth.userId = author
        var draft = PruningActivityDraft(vineyardId: vineyard, worker: "My operator")
        draft.serverAcknowledged = true
        var link = PruningResourceLink(externalResourceId: nil, workerUserId: author, name: "My operator", authoredBy: author)
        link.expected = PruningResourceSnapshot(id: draft.id, vineyardId: vineyard, clientUpdatedAt: "2026-10-08T01:00:00.123456Z", externalResourceId: nil, workerUserId: nil, deletedAt: nil)
        draft.resourceLink = link
        pruning.saveActivity(draft)
        let transport = ResourceRecoveryTransport(activity: draft.id, vineyard: vineyard)
        transport.conflictingWorker = other
        let sync = PruningSyncService(repository: transport, pruningStore: pruning)
        sync.configure(store: store, auth: auth)
        await sync.syncForSelectedVineyard()
        #expect(transport.casCalls == 1)
        let restarted = PruningStore(persistence: PersistenceStore(directory: directory))
        #expect(restarted.activity(id: draft.id)?.resourceLink?.workerUserId == author)
        #expect(restarted.activity(id: draft.id)?.resourceLink?.name == "My operator")
        #expect(restarted.activity(id: draft.id)?.resourceLink?.conflict?.workerUserId == other)
        #expect(restarted.activity(id: draft.id)?.resourceLink?.expected == link.expected)
        let resumed = PruningSyncService(repository: transport, pruningStore: restarted)
        resumed.configure(store: store, auth: auth)
        await resumed.syncForSelectedVineyard()
        #expect(transport.casCalls == 1)
        #expect(transport.parentMutationCalls == 0)
    }
}

@MainActor
private final class ResourceRecoveryTransport: PruningSyncRepositoryProtocol {
    let activity: UUID
    let vineyard: UUID
    var casCalls: Int = 0
    var parentMutationCalls: Int = 0
    var loseFirstResponse: Bool = false
    var conflictingWorker: UUID?
    var receivedBaselines: [String?] = []
    var baselineOnDisk: (() -> Bool)?
    var baselineWasDurable: Bool = false
    var external: UUID?
    var worker: UUID?
    init(activity: UUID, vineyard: UUID) { self.activity = activity; self.vineyard = vineyard }
    func fetchResourceSnapshot(id: UUID, vineyardId: UUID) async throws -> PruningResourceSnapshot {
        PruningResourceSnapshot(id: id, vineyardId: vineyardId, clientUpdatedAt: "2026-10-08T01:00:00.123456Z", externalResourceId: external, workerUserId: conflictingWorker ?? worker, deletedAt: nil)
    }
    func setActivityResourceCAS(_ params: PruningResourceCASParams) async throws -> PruningResourceCASResult {
        casCalls += 1
        baselineWasDurable = baselineOnDisk?() ?? true
        receivedBaselines.append(params.expectedClientUpdatedAt)
        if let conflictingWorker {
            let json = "{\"activity_id\":\"\(activity)\",\"applied\":false,\"conflict\":true,\"external_resource_id\":null,\"worker_user_id\":\"\(conflictingWorker)\",\"canonical\":{\"id\":\"\(activity)\",\"vineyard_id\":\"\(vineyard)\",\"client_updated_at\":\"2026-10-08T02:00:00Z\",\"external_resource_id\":null,\"worker_user_id\":\"\(conflictingWorker)\",\"deleted_at\":null}}"
            return try JSONDecoder().decode(PruningResourceCASResult.self, from: Data(json.utf8))
        }
        external = params.externalResourceId; worker = params.workerUserId
        if loseFirstResponse && casCalls == 1 { throw URLError(.networkConnectionLost) }
        let json: [String: Any] = ["activity_id": activity.uuidString, "applied": true, "idempotent": casCalls > 1, "external_resource_id": external.map { $0.uuidString as Any } ?? NSNull(), "worker_user_id": worker.map { $0.uuidString as Any } ?? NSNull()]
        return try JSONDecoder().decode(PruningResourceCASResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func fetchSeasons(vineyardId: UUID, since: Date?) async throws -> [BackendPruningSeason] { [] }
    func fetchEntries(vineyardId: UUID, since: Date?) async throws -> [BackendPruningEntry] { [] }
    func fetchSegments(vineyardId: UUID) async throws -> [BackendPruningSegment] { [] }
    func fetchActivities(vineyardId: UUID) async throws -> [BackendPruningActivityCanonical] { [] }
    func fetchActivityLabourLines(vineyardId: UUID) async throws -> [BackendPruningActivityLabourLine] { [] }
    func fetchActivity(id: UUID) async throws -> BackendPruningActivityCanonical { throw URLError(.notConnectedToInternet) }
    func fetchVineyardSummary(vineyardId: UUID) async throws -> BackendPruningVineyardSummary { throw URLError(.notConnectedToInternet) }
    func upsertSeason(_ setup: PruningBlockSetup, createdBy: UUID?, clientUpdatedAt: Date) async throws -> VersionedWriteOutcome<PruningBlockSetup> { throw URLError(.unsupportedURL) }
    func recordEntry(_ params: RecordPruningEntryParams) async throws -> RecordPruningEntryResult { throw URLError(.unsupportedURL) }
    func updateEntry(_ params: UpdatePruningEntryParams) async throws -> UpdatePruningEntryResult { throw URLError(.unsupportedURL) }
    func recordSkippedEntry(_ params: RecordSkippedPruningEntryParams) async throws -> RecordPruningEntryResult { throw URLError(.unsupportedURL) }
    func updateSkippedEntry(_ params: UpdateSkippedPruningEntryParams) async throws -> UpdatePruningEntryResult { throw URLError(.unsupportedURL) }
    func deleteEntry(id: UUID) async throws { throw URLError(.unsupportedURL) }
    func softDeleteSeason(id: UUID) async throws { throw URLError(.unsupportedURL) }
    func recordActivity(_ params: RecordPruningActivityParams) async throws -> PruningActivityResult { parentMutationCalls += 1; throw URLError(.unsupportedURL) }
    func updateActivity(_ params: UpdatePruningActivityParams) async throws -> PruningActivityResult { parentMutationCalls += 1; throw URLError(.unsupportedURL) }
    func reverseActivity(id: UUID, reason: String?) async throws -> PruningActivityResult { parentMutationCalls += 1; throw URLError(.unsupportedURL) }
    func saveActivityLabourLines(_ params: SavePruningActivityLabourLinesParams) async throws -> SavePruningActivityLabourLinesResult { throw URLError(.unsupportedURL) }
}
