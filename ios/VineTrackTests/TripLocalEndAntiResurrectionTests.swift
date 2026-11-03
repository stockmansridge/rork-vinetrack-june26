import Foundation
import Testing
@testable import VineTrack

/// Build 208 P0: an older server-active pull must not reopen an occurrence Trip
/// that was ended on this installation. Drives the shipping TripSyncService
/// pull path with a retained original journal, End claim and restart.
@MainActor struct TripLocalEndAntiResurrectionTests {
    @Test func staleActivePullRestoresOriginalEndAcrossRestartAndClearsHoldAfterOriginalFinaliseReceipt() async throws {
        let fixture = try EndFixture()
        defer { fixture.cleanUp() }
        let finalise = try fixture.prepareJournalWithPendingFinalise()
        try fixture.recordClaim(owner: fixture.account, vineyard: fixture.vineyard)
        let historyBefore = try #require(try fixture.journal.load()).history

        // Build 208 state: the ended local cache was replaced by the server-active snapshot.
        let (store, metadata, service, auth) = fixture.service()
        _ = auth
        let stale = try fixture.serverTrip(active: true, coverage: #require(try fixture.journal.load()).acknowledged)
        store.trips = [stale.toTrip()]
        store.tripRepo.saveSlice(store.trips, for: fixture.vineyard)
        fixture.remote = [stale]
        fixture.recovery = try fixture.recoveryResponse(active: true, receipts: [])

        try await service.pullRemoteTrips(vineyardId: fixture.vineyard)
        let repaired = try #require(store.trips.first { $0.id == fixture.trip })
        #expect(!repaired.isActive && repaired.endTime == fixture.endedAt)
        #expect(metadata.pendingUpserts[fixture.trip] != nil, "Only the original retained journal is re-admitted")
        #expect(service.receiptReconciliationHolds[fixture.trip] == "TRIP_LOCAL_END_AWAITING_ORIGINAL_FINALISE")
        let afterFirst = try #require(try fixture.journal.load())
        #expect(afterFirst.pending == [finalise], "Same finalise operation ID and body; nothing new minted")
        #expect(afterFirst.history.map(\.id) == historyBefore.map(\.id))
        #expect(store.trips.count == 1)

        // Cold restart over the same disk: the End persists and a repeated stale pull cannot reopen it.
        let (reopened, reopenedMetadata, reopenedService, reopenedAuth) = fixture.service()
        _ = reopenedAuth
        reopened.trips = reopened.tripRepo.load(for: fixture.vineyard)
        let persisted = try #require(reopened.trips.first { $0.id == fixture.trip })
        #expect(!persisted.isActive && persisted.endTime == fixture.endedAt)
        #expect(reopenedMetadata.pendingUpserts[fixture.trip] != nil)
        try await reopenedService.pullRemoteTrips(vineyardId: fixture.vineyard)
        let stillEnded = try #require(reopened.trips.first { $0.id == fixture.trip })
        #expect(!stillEnded.isActive && stillEnded.endTime == fixture.endedAt)
        #expect(try fixture.journal.load()?.pending == [finalise])

        // Server now holds the ORIGINAL finalise receipt: the hold must clear and the Trip stays ended.
        let ended = try fixture.serverTrip(active: false, coverage: finalise.after, end: fixture.endedAt)
        fixture.remote = [ended]
        fixture.recovery = try fixture.recoveryResponse(active: false, coverage: finalise.after,
                                                        receipts: [fixture.receipt(for: finalise)])
        try await reopenedService.pullRemoteTrips(vineyardId: fixture.vineyard)
        let closed = try #require(reopened.trips.first { $0.id == fixture.trip })
        #expect(!closed.isActive && closed.endTime == fixture.endedAt)
        let finalState = try #require(try fixture.journal.load())
        #expect(finalState.pending.isEmpty && finalState.heldReason == nil && finalState.serverActive == false)
        #expect(finalState.history.contains { $0.id == finalise.id })
        #expect(reopenedMetadata.pendingUpserts[fixture.trip] == nil)
        #expect(reopenedService.receiptReconciliationHolds[fixture.trip] == nil,
                "A stale awaiting-finalise hold must not survive the verified original receipt")
    }

    @Test(arguments: ["missingClaim", "foreignOwnerClaim", "foreignVineyardClaim"])
    func repairRequiresIndependentMatchingEndClaim(mode: String) async throws {
        let fixture = try EndFixture()
        defer { fixture.cleanUp() }
        let finalise = try fixture.prepareJournalWithPendingFinalise()
        switch mode {
        case "foreignOwnerClaim": try fixture.recordClaim(owner: UUID(), vineyard: fixture.vineyard)
        case "foreignVineyardClaim": try fixture.recordClaim(owner: fixture.account, vineyard: UUID())
        default: break
        }
        let (store, _, service, auth) = fixture.service()
        _ = auth
        let stale = try fixture.serverTrip(active: true, coverage: #require(try fixture.journal.load()).acknowledged)
        store.trips = [stale.toTrip()]
        fixture.remote = [stale]
        fixture.recovery = try fixture.recoveryResponse(active: true, receipts: [])
        try await service.pullRemoteTrips(vineyardId: fixture.vineyard)
        let trip = try #require(store.trips.first { $0.id == fixture.trip })
        #expect(trip.endTime == nil, "No End may be fabricated without the exact original claim: \(mode)")
        #expect(service.receiptReconciliationHolds[fixture.trip] == nil)
        #expect(try fixture.journal.load()?.pending == [finalise], "Original journal untouched: \(mode)")
    }
}

@MainActor private final class EndFixture {
    let account = UUID(), vineyard = UUID(), trip = UUID()
    let endedAt = Date(timeIntervalSince1970: 1_793_664_000) // whole second, as both writers serialise it
    let disk: PersistenceStore
    let directory: URL
    let authority: VineyardWriteAuthority
    var remote: [BackendTrip] = []
    var recovery: TripOccurrenceCoverage.JSON = .null
    private var retained: [AnyObject] = []
    lazy var journal: TripOccurrenceJournal = try! TripOccurrenceJournal(scope: scope, authority: authority)

    var scope: TripOccurrenceJournal.Scope {
        .init(ownerId: account.uuidString.lowercased(), vineyardId: vineyard.uuidString.lowercased(),
              tripId: trip.uuidString.lowercased())
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        disk = PersistenceStore(directory: directory)
        authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        authority.bind(userId: account)
    }

    func cleanUp() {
        _ = TripLocalEndClaimStore.shared.remove(tripId: trip.uuidString.lowercased())
        if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("TripOccurrenceJournals")
                .appendingPathComponent(scope.ownerId))
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func prepareJournalWithPendingFinalise() throws -> TripOccurrenceJournal.Operation {
        let candidates = [TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "A", label: 38.5, rows: []),
                          TripOccurrencePlanner.Candidate(vineyardId: vineyard, blockId: UUID(), blockName: "B", label: 38.5, rows: [])]
        let coverage = try TripOccurrencePlanner.commit(TripOccurrencePlanner.plan(candidates, pattern: .upAndBack,
            startKey: candidates[0].id, higherFirst: true), vineyardId: vineyard)
        let create = try journal.prepareCreation(trip: .object(["id": .string(scope.tripId),
            "vineyard_id": .string(scope.vineyardId), "is_active": .bool(false)]), coverage: coverage)
        try journal.acknowledge(ack(create))
        let activate = try journal.activate(.object(["startTime": .string("2026-11-03T00:00:00Z")]))
        try journal.acknowledge(ack(activate))
        return try journal.finalize(.object(["endTime": .string(ISO8601DateFormatter().string(from: endedAt))]))
    }

    func recordClaim(owner: UUID, vineyard claimVineyard: UUID) throws {
        let saved = TripLocalEndClaimStore.shared.record(.init(tripId: scope.tripId, ownerId: owner.uuidString.lowercased(),
            vineyardId: claimVineyard.uuidString.lowercased(), endedAt: endedAt, source: "device_claim_at_end"))
        #expect(saved)
    }

    func ack(_ op: TripOccurrenceJournal.Operation) -> TripOccurrenceCoverage.JSON {
        .object(["tripId": .string(scope.tripId), "operationId": .string(op.id), "coverage": op.after])
    }

    func receipt(for op: TripOccurrenceJournal.Operation) -> TripOccurrenceCoverage.JSON {
        .object(["operationId": .string(op.id), "actorId": .string(scope.ownerId), "result": ack(op),
                 "request": .object(["tripId": .string(scope.tripId),
                    "expectedRevision": op.params[occurrence: "p_expected_revision"] ?? .null,
                    "expectedPlanRevision": op.params[occurrence: "p_expected_plan_revision"] ?? .null,
                    "kind": .string("finalize"),
                    "reviewedStates": op.params[occurrence: "p_reviewed_states"] ?? .null,
                    "end": op.params[occurrence: "p_end"] ?? .null])])
    }

    func recoveryResponse(active: Bool, coverage: TripOccurrenceCoverage.JSON? = nil,
                          receipts: [TripOccurrenceCoverage.JSON]) throws -> TripOccurrenceCoverage.JSON {
        let base = try coverage ?? #require(try journal.load()).acknowledged
        return .object(["contract": .string("vinetrack.occurrence-recovery"), "schemaVersion": .number(1),
                        "tripId": .string(scope.tripId), "vineyardId": .string(scope.vineyardId), "coverage": base,
                        "isActive": .bool(active), "reversibleOperations": .array([]), "receipts": .array(receipts)])
    }

    func serverTrip(active: Bool, coverage: TripOccurrenceCoverage.JSON, end: Date? = nil) throws -> BackendTrip {
        var trip = Trip(id: self.trip, vineyardId: vineyard, paddockName: "A, B",
                        startTime: endedAt.addingTimeInterval(-3_600), endTime: end, isActive: active)
        trip.tripFunction = "spraying"
        trip.occurrenceCoverage = coverage
        let payload = BackendTrip.upsert(from: trip, createdBy: account, clientUpdatedAt: Date())
        return try JSONDecoder().decode(BackendTrip.self, from: JSONEncoder().encode(payload))
    }

    func service() -> (MigratedDataStore, TripSyncMetadata, TripSyncService, NewBackendAuthService) {
        let store = MigratedDataStore(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { [account] in account }
        store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService()
        let service = TripSyncService(repository: EndRepository(fixture: self), metadata: metadata)
        service.configure(store: store, auth: auth)
        retained.append(store); retained.append(auth)
        return (store, metadata, service, auth)
    }
}

@MainActor private final class EndRepository: TripSyncRepositoryProtocol {
    let fixture: EndFixture
    init(fixture: EndFixture) { self.fixture = fixture }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { fixture.remote }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { fixture.remote }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { fixture.remote }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { Issue.record("Pull must not upload") }
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { Issue.record("Pull must not upload") }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws { Issue.record("Pull must not delete") }
    func fetchOccurrenceRecovery(tripId: UUID, operationIds: [String]) async throws -> TripOccurrenceCoverage.JSON {
        fixture.recovery
    }
}
