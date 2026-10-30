import Foundation
import Testing
@testable import VineTrack

@MainActor struct TripDeletionPersistenceIdentityTests {
    private func fixture() throws -> (PersistenceStore, TripDeletionJournal, TripDeletionJournal.Scope) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = PersistenceStore(directory: directory)
        return (disk, TripDeletionJournal(persistence: disk), .init(account: UUID(), vineyard: UUID(), trip: UUID()))
    }
    @Test func freshFractionalTimestampSurvivesDiskRoundTripAndAcknowledges() async throws {
        let (_, journal, scope) = try fixture()
        try journal.registerCreation(scope)
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100.125), scope: scope, evidence: Data([1]))
        let result = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            Issue.record("Never-sent cancellation must not send a request"); return "unexpected"
        }
        #expect(result)
        let saved = try #require(journal.load().intents[scope.trip])
        #expect(saved.revision == intent.revision && saved.originalEvidence == intent.originalEvidence)
        #expect(saved.acknowledgement == "LOCAL_CREATION_NEVER_SENT_CANCELLED")
        #expect(try journal.isCancelled(scope.trip))
    }
    @Test func establishedFractionalTimestampAcknowledgesOnlyAfterRemoteProof() async throws {
        let (_, journal, scope) = try fixture()
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 101.375), scope: scope, evidence: Data([2]), established: true)
        var calls = 0
        let result = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            calls += 1; return "SERVER_ABSENCE_VERIFIED:synthetic-proof"
        }
        #expect(result && calls == 1)
        #expect(try journal.load().intents[scope.trip]?.acknowledgement != nil)
    }
    @Test func newerHoldDuringRemoteProofIsNotCleared() async throws {
        let (_, journal, scope) = try fixture()
        let intent = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 102), scope: scope, evidence: Data([3]), established: true)
        let result = try await journal.replay(intent, account: scope.account, vineyard: scope.vineyard, isCurrent: { true }) { _ in
            try journal.hold(intent, reason: "TRIP_DELETE_OWNERSHIP_CONFLICT")
            return "SERVER_ABSENCE_VERIFIED:synthetic-proof"
        }
        #expect(!result)
        let saved = try #require(journal.load().intents[scope.trip])
        #expect(saved.reviewReason == "TRIP_DELETE_OWNERSHIP_CONFLICT" && saved.acknowledgement == nil)
    }
    @Test func differentRevisionCannotAcknowledgeOrChangeOriginalEvidence() async throws {
        let (_, journal, scope) = try fixture()
        let first = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 103), scope: scope, evidence: Data([4]), established: true)
        let second = try journal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 104), scope: scope, evidence: Data([5]), established: true)
        #expect(try !journal.acknowledge(first, evidence: "SERVER_TOMBSTONE_OBSERVED"))
        let saved = try #require(journal.load().intents[scope.trip])
        #expect(saved.revision == second.revision && saved.originalEvidence == Data([5]) && saved.acknowledgement == nil)
    }
}
