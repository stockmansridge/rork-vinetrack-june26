import Foundation
import Testing
@testable import VineTrack

@MainActor
struct YieldCompletionPersistenceTests {
    private func storage() throws -> PersistenceStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PersistenceStore(directory: url)
    }

    @Test func localCompletionAndIntentSurviveRepositoryRestart() throws {
        let disk = try storage()
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date(timeIntervalSince1970: 100))
        try YieldRepository(persistence: disk).saveLocalSession(trip, at: Date(timeIntervalSince1970: 200))
        let reopened = YieldRepository(persistence: disk)
        #expect(reopened.loadAllSessions().first?.isCompleted == true)
        #expect(reopened.loadAllSessions().first?.completedAt == trip.completedAt)
        #expect(reopened.pendingSessionSaves()[trip.id] != nil)
    }

    @Test func olderDraftAcknowledgementCannotConsumeCompletionInSameSecond() throws {
        let repo = YieldRepository(persistence: try storage())
        var trip = YieldEstimationSession(vineyardId: UUID())
        let stamp = Date(timeIntervalSince1970: 200)
        try repo.saveLocalSession(trip, at: stamp)
        let sent = try #require(repo.pendingSessionIntents()[trip.id]?.token)
        trip.isCompleted = true
        trip.completedAt = stamp
        try repo.saveLocalSession(trip, at: stamp)
        try repo.acknowledgeSessionSaves([trip.id: sent])
        #expect(repo.pendingSessionIntents()[trip.id]?.token != sent)
        #expect(repo.loadAllSessions().first?.isCompleted == true)
    }

    @Test func exactAcknowledgementRetainsCompletedRecordForOfflineRestart() throws {
        let disk = try storage()
        let repo = YieldRepository(persistence: disk)
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date(timeIntervalSince1970: 100))
        try repo.saveLocalSession(trip, at: Date())
        let sent = try #require(repo.pendingSessionIntents()[trip.id]?.token)
        try repo.acknowledgeSessionSaves([trip.id: sent])
        let reopened = YieldRepository(persistence: disk)
        #expect(reopened.pendingSessionSaves().isEmpty)
        #expect(reopened.loadAllSessions().first?.isCompleted == true)
    }

    @Test func duplicateAcknowledgementIsIdempotent() throws {
        let repo = YieldRepository(persistence: try storage())
        let trip = YieldEstimationSession(vineyardId: UUID())
        try repo.saveLocalSession(trip, at: Date())
        let sent = try #require(repo.pendingSessionIntents()[trip.id]?.token)
        try repo.acknowledgeSessionSaves([trip.id: sent])
        try repo.acknowledgeSessionSaves([trip.id: sent])
        #expect(repo.loadAllSessions().count == 1)
        #expect(repo.pendingSessionSaves().isEmpty)
    }

    @Test func failedCompletionCommitPreservesOriginalDraftAndIntent() throws {
        let disk = try storage()
        let repo = YieldRepository(persistence: disk)
        var trip = YieldEstimationSession(vineyardId: UUID())
        try repo.saveLocalSession(trip, at: Date())
        let original = repo.pendingSessionIntents()[trip.id]?.token
        trip.isCompleted = true
        trip.completedAt = Date()
        disk.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try repo.saveLocalSession(trip, at: Date()) }
        #expect(repo.loadAllSessions().first?.isCompleted == false)
        #expect(repo.pendingSessionIntents()[trip.id]?.token == original)
    }

    @Test func failedAcknowledgementKeepsReplayIntent() throws {
        let disk = try storage()
        let repo = YieldRepository(persistence: disk)
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date())
        try repo.saveLocalSession(trip, at: Date())
        let token = try #require(repo.pendingSessionIntents()[trip.id]?.token)
        disk.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try repo.acknowledgeSessionSaves([trip.id: token]) }
        #expect(repo.pendingSessionIntents()[trip.id]?.token == token)
    }

    @Test func completedSaveWithoutActualTimestampIsRejected() throws {
        let repo = YieldRepository(persistence: try storage())
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true)
        #expect(throws: (any Error).self) { try repo.saveLocalSession(trip, at: Date()) }
        #expect(repo.loadAllSessions().isEmpty)
    }

    @Test func legacyBareArrayLoadsWithoutInventedPendingCompletion() throws {
        let disk = try storage()
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date(timeIntervalSince1970: 100))
        try disk.saveOrThrow([trip], key: YieldRepository.sessionsKey)
        let repo = YieldRepository(persistence: disk)
        #expect(repo.loadAllSessions().first?.id == trip.id)
        #expect(repo.pendingSessionSaves().isEmpty)
        try repo.saveLocalSession(trip, at: Date())
        #expect(repo.loadAllSessions().count == 1)
    }

    @Test func remoteReplacementCannotOverwritePendingCompletion() throws {
        let repo = YieldRepository(persistence: try storage())
        var trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date())
        try repo.saveLocalSession(trip, at: Date())
        trip.isCompleted = false
        trip.completedAt = nil
        repo.replaceSessions([trip], for: trip.vineyardId)
        #expect(repo.loadAllSessions().count == 1)
        #expect(repo.loadAllSessions().first?.isCompleted == true)
    }

    @Test func otherVineyardReplacementPreservesOriginalPendingTrip() throws {
        let repo = YieldRepository(persistence: try storage())
        let a = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date())
        let b = YieldEstimationSession(vineyardId: UUID())
        try repo.saveLocalSession(a, at: Date())
        repo.replaceSessions([b], for: b.vineyardId)
        #expect(repo.loadSessions(for: a.vineyardId).first?.isCompleted == true)
        #expect(repo.pendingSessionSaves()[a.id] != nil)
    }

    @Test func viewModelRepeatedSavesReuseIdentityAndCreationDate() {
        let vm = YieldEstimationViewModel()
        let vineyard = UUID()
        let a = vm.toSession(vineyardId: vineyard, samplesPerHectare: 20)
        let b = vm.toSession(vineyardId: vineyard, samplesPerHectare: 20)
        #expect(a.id == b.id)
        #expect(a.createdAt == b.createdAt)
    }

    @Test func repeatedCompletionDoesNotRewriteActualTime() {
        let vm = YieldEstimationViewModel()
        vm.startNewTrip()
        vm.markCompleted(paddocks: [])
        let date = vm.completedAt
        vm.markCompleted(paddocks: [])
        #expect(vm.isCompleted)
        #expect(vm.completedAt == date)
    }

    @Test func promotedCompletionOverridesStaleDraftPayloadOnReload() throws {
        let trip = YieldEstimationSession(vineyardId: UUID())
        let row = BackendYieldEstimationSession(id: trip.id, vineyardId: trip.vineyardId,
            payload: trip, isCompleted: true, completedAt: Date(timeIntervalSince1970: 100),
            sessionCreatedAt: trip.createdAt, createdBy: nil, createdAt: nil,
            updatedAt: nil, deletedAt: nil, clientUpdatedAt: nil)
        let loaded = try #require(row.toYieldEstimationSession())
        #expect(loaded.isCompleted)
        #expect(loaded.completedAt == row.completedAt)
        #expect(loaded.id == trip.id)
    }

    @Test func payloadCompletionRemainsCompatibleWithLegacyRows() throws {
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date())
        let row = BackendYieldEstimationSession(id: trip.id, vineyardId: trip.vineyardId,
            payload: trip, isCompleted: nil, completedAt: nil, sessionCreatedAt: nil,
            createdBy: nil, createdAt: nil, updatedAt: nil, deletedAt: nil, clientUpdatedAt: nil)
        #expect(row.toYieldEstimationSession()?.isCompleted == true)
    }

    @Test func hardDeleteReceiptSurvivesRestartAndBlocksStaleSavesAndPulls() throws {
        let disk = try storage()
        let repo = YieldRepository(persistence: disk)
        let trip = YieldEstimationSession(vineyardId: UUID())
        try repo.saveLocalSession(trip, at: Date())
        try repo.applyHardDeletionReceipts([trip.id], vineyardId: trip.vineyardId)
        let restarted = YieldRepository(persistence: disk)
        #expect(restarted.loadAllSessions().isEmpty)
        #expect(restarted.pendingSessionSaves().isEmpty)
        #expect(throws: (any Error).self) { try restarted.saveLocalSession(trip, at: Date()) }
        restarted.replaceSessions([trip], for: trip.vineyardId)
        restarted.saveSessionsSlice([trip], for: trip.vineyardId)
        #expect(restarted.mergeSessions([trip], for: trip.vineyardId).isEmpty)
        #expect(restarted.isHardDeletedSession(trip.id))
    }

    @Test func failedReceiptCommitRetainsDraftAndReplayIntent() throws {
        let disk = try storage()
        let repo = YieldRepository(persistence: disk)
        let trip = YieldEstimationSession(vineyardId: UUID())
        try repo.saveLocalSession(trip, at: Date())
        disk.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try repo.applyHardDeletionReceipts([trip.id], vineyardId: trip.vineyardId) }
        #expect(repo.loadAllSessions().first?.id == trip.id)
        #expect(repo.pendingSessionSaves()[trip.id] != nil)
        #expect(!repo.isHardDeletedSession(trip.id))
    }

    @Test func deletionReceiptsPreserveOtherVineyardAndIndependentHistory() throws {
        let repo = YieldRepository(persistence: try storage())
        let vineyard = UUID(), physical = UUID(), block = UUID()
        let removed = YieldEstimationSession(vineyardId: vineyard)
        let history = YieldEstimationSession(vineyardId: vineyard, sampleSites: [
            SampleSite(id: physical, paddockId: block, rowNumber: 12, latitude: -34, longitude: 149, siteIndex: 1)
        ], isCompleted: true, completedAt: Date())
        let foreign = YieldEstimationSession(vineyardId: UUID())
        for trip in [removed, history, foreign] { try repo.saveLocalSession(trip, at: Date()) }
        try repo.applyHardDeletionReceipts([removed.id], vineyardId: vineyard)
        #expect(repo.loadAllSessions().count == 2)
        #expect(repo.loadSessions(for: vineyard).first?.sampleSites.first?.id == physical)
        #expect(repo.pendingSessionSaves()[foreign.id] != nil)
        #expect(throws: (any Error).self) { try repo.applyHardDeletionReceipts([foreign.id], vineyardId: vineyard) }
        #expect(repo.loadSessions(for: foreign.vineyardId).count == 1)
    }

    @Test func neverUploadedDeletionReceiptBlocksLaterCreation() throws {
        let repo = YieldRepository(persistence: try storage())
        let trip = YieldEstimationSession(vineyardId: UUID())
        try repo.applyHardDeletionReceipts([trip.id], vineyardId: trip.vineyardId)
        #expect(throws: (any Error).self) { try repo.saveLocalSession(trip, at: Date()) }
        #expect(repo.loadAllSessions().isEmpty)
    }

    @Test func encodedCompletionMatchesTopLevelAndPayload() throws {
        let trip = YieldEstimationSession(vineyardId: UUID(), isCompleted: true, completedAt: Date(timeIntervalSince1970: 100))
        let encoded = try JSONEncoder().encode(BackendYieldEstimationSession.upsert(from: trip, createdBy: nil, clientUpdatedAt: Date()))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(object["is_completed"] as? Bool == true)
        #expect(payload["isCompleted"] as? Bool == true)
        #expect(object["completed_at"] as? Double == payload["completedAt"] as? Double)
    }
}
