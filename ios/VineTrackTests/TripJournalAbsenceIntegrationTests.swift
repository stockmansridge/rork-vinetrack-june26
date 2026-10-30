import Foundation
import Testing
@testable import VineTrack

/// Exercises the shipping repository resolver and journal/service, not a replacement receipt helper.
@MainActor struct TripJournalAbsenceIntegrationTests {
    @Test func productionResolverInvokesExactReadOnlyRPCAndKeepsOriginalScope() async throws {
        let fixture = try AbsenceFixture()
        let result = try await fixture.repository.resolveDeletion(fixture.scope, isCurrent: { true })
        #expect(result.hasPrefix("SERVER_ABSENCE_VERIFIED:"))
        #expect(fixture.requests.map { $0.url!.lastPathComponent } == ["trips", "confirm_trip_absence_v1"])
        let request = try #require(fixture.requests.last)
        let body = try JSONDecoder().decode([String: UUID].self, from: #require(request.httpBody))
        #expect(body == ["p_trip_id": fixture.scope.trip])
        #expect(request.httpMethod == "POST" && request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        let bytes = try #require(Data(base64Encoded: String(result.dropFirst("SERVER_ABSENCE_VERIFIED:".count))))
        let proof = try JSONDecoder().decode(TripDeleteAbsenceReceipt.self, from: bytes)
        #expect(proof.tripId == fixture.scope.trip && proof.actorId == fixture.scope.account && proof.schemaVersion == 1 && proof.absent)
    }

    @Test func alreadyHeldOriginalIntentRecoversThroughProductionServiceAfterRestart() async throws {
        let fixture = try AbsenceFixture()
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth // Retain service's weak auth for this operation.
        let before = try #require(store.tripDeletionJournal.load().intents[fixture.scope.trip])
        let unrelatedDelete = UUID(), unrelatedUpload = UUID()
        metadata.markDirty(unrelatedUpload, at: Date(timeIntervalSince1970: 300))
        metadata.markDeleted(unrelatedDelete, at: Date(timeIntervalSince1970: 400))
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(!service.isPendingDelete(fixture.scope.trip))
        #expect(metadata.pendingDeletes[unrelatedDelete] != nil && metadata.pendingUpserts[unrelatedUpload] != nil)
        #expect(fixture.requests.map { $0.url!.lastPathComponent } == ["trips", "confirm_trip_absence_v1"])
        let restored = TripDeletionJournal(persistence: fixture.disk)
        let saved = try #require(restored.load().intents[fixture.scope.trip])
        #expect(saved.revision == before.revision && saved.scope == before.scope && saved.originalEvidence == before.originalEvidence)
        #expect(saved.reviewReason == nil && saved.acknowledgement?.hasPrefix("SERVER_ABSENCE_VERIFIED:") == true)
        #expect(throws: TripDeletionJournal.Held.self) { try restored.beginSend(fixture.scope) }
        #expect(TripSyncMetadata(persistence: fixture.disk).pendingDeletes[fixture.scope.trip] == nil)
    }

    @Test(arguments: ["hidden", "missingRPC", "timeout", "offline", "wrongActor", "wrongTrip", "futureSchema", "present", "malformed", "emptyReceipt", "http401", "http500"])
    func failedVerificationNeverRetiresOriginalDeletion(mode: String) async throws {
        let fixture = try AbsenceFixture(); fixture.mode = mode
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        let before = try #require(store.tripDeletionJournal.load().intents[fixture.scope.trip])
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] == before.queuedAt)
        let restored = try #require(TripDeletionJournal(persistence: fixture.disk).load().intents[fixture.scope.trip])
        #expect(restored.acknowledgement == nil && restored.revision == before.revision && restored.scope == before.scope)
        #expect(restored.originalEvidence == before.originalEvidence)
        #expect(!fixture.requests.contains { $0.url?.lastPathComponent == "soft_delete_trip" })
        #expect(service.errorMessage != nil)
    }

    @Test(arguments: ["switchActor", "sameActorNewIncarnation", "switchSelection", "signedOut"])
    func suspendedProofCannotAcknowledgeChangedAccountOrSelection(mode: String) async throws {
        let fixture = try AbsenceFixture(); fixture.mode = mode
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        fixture.afterProof = {
            if mode == "switchSelection" { store.selectedVineyardId = UUID() }
        }
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] != nil, "Changed scope must stay pending: \(mode)")
        #expect(try store.tripDeletionJournal.load().intents[fixture.scope.trip]?.acknowledgement == nil)
        #expect(fixture.requests.count == 2)
    }

    @Test func writeAuthorityLostDuringProofRetainsOriginalIntent() async throws {
        let fixture = try AbsenceFixture()
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        fixture.afterProof = {
            _ = fixture.authority.handleServerCode("VT_READ_ONLY", vineyardId: fixture.scope.vineyard.uuidString)
        }
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] != nil)
        #expect(try store.tripDeletionJournal.load().intents[fixture.scope.trip]?.acknowledgement == nil)
    }

    @Test(arguments: ["journal", "metadata"])
    func acknowledgementPersistenceFailureStaysPendingAndRestartDoesNotLoseEvidence(target: String) async throws {
        let fixture = try AbsenceFixture()
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        fixture.afterProof = {
            fixture.disk.durableSaveFailureForTesting = { key in
                key == (target == "journal" ? TripDeletionJournal.key : "vinetrack_trip_sync_metadata") ? URLError(.cannotWriteToFile) : nil
            }
        }
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] != nil && service.errorMessage != nil)
        let saved = try #require(store.tripDeletionJournal.load().intents[fixture.scope.trip])
        #expect((saved.acknowledgement != nil) == (target == "metadata"))
        fixture.disk.durableSaveFailureForTesting = nil; fixture.afterProof = nil
        let requestsBefore = fixture.requests.count
        let (_, reopenedMetadata, reopenedService, reopenedAuth) = try fixture.service(held: false, prepare: false)
        _ = reopenedAuth
        try await reopenedService.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(reopenedMetadata.pendingDeletes[fixture.scope.trip] == nil)
        #expect(fixture.requests.count == requestsBefore + (target == "metadata" ? 0 : 2))
        #expect(try store.tripDeletionJournal.isCancelled(fixture.scope.trip))
    }

    @Test func heldReverificationCannotIssueDeleteForVisibleExistingTrip() async throws {
        let fixture = try AbsenceFixture(); fixture.mode = "visible"
        let (_, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] != nil)
        #expect(fixture.requests.count == 1 && fixture.requests[0].httpMethod == "GET")
    }

    @Test func newerHoldDuringProofCannotBeClearedByCapturedResponse() async throws {
        let fixture = try AbsenceFixture()
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        let before = try #require(store.tripDeletionJournal.load().intents[fixture.scope.trip])
        fixture.afterProof = { try store.tripDeletionJournal.hold(before, reason: "TRIP_DELETE_NEWER_LOCAL_WORK_RETAINED") }
        try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
        #expect(metadata.pendingDeletes[fixture.scope.trip] != nil)
        let saved = try #require(store.tripDeletionJournal.load().intents[fixture.scope.trip])
        #expect(saved.acknowledgement == nil && saved.reviewReason == "TRIP_DELETE_NEWER_LOCAL_WORK_RETAINED")
    }

    @Test func currentScopeCountsDistinguishRealHeldSprayFromDeletionAndIgnoreStaleStatus() async throws {
        let fixture = try AbsenceFixture()
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        #expect(service.retainedState.sprays.isEmpty && service.retainedState.deletions == [fixture.scope.trip])
        #expect(service.retainedState.summary?.contains("saved spray job") == false)
        let trip = Trip(vineyardId: fixture.scope.vineyard, paddockName: "Distinct retained spray", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: fixture.scope.vineyard)
        let wal = LegacySpraySaveRecovery(persistence: fixture.disk)
        try wal.prepare(scope: .init(actor: fixture.scope.account, session: UUID(), vineyard: fixture.scope.vineyard), record: record, trip: trip)
        let foreign = Trip(vineyardId: fixture.scope.vineyard, paddockName: "Foreign", isActive: false)
        try wal.prepare(scope: .init(actor: UUID(), session: UUID(), vineyard: fixture.scope.vineyard), record: SprayRecord(tripId: foreign.id, vineyardId: fixture.scope.vineyard), trip: foreign)
        let before = try wal.attempts()
        let snapshot = service.retainedState
        #expect(snapshot.sprays.map(\.record) == [record.id] && snapshot.deletions == [fixture.scope.trip])
        #expect(service.deletionRecoveryDiagnostics.contains("held spray record=\(record.id) trip=\(trip.id)"))
        let center = SyncStatusCenter(); center.syncDidStart()
        center.syncDidFinish(upserts: 0, deletes: metadata.pendingDeletes.count, heldSprayPairs: snapshot.sprays.count, error: nil)
        #expect(!center.isSyncing && center.heldSprayPairs == snapshot.sprays.count && center.hasIncompleteUploads)
        store.selectedVineyardId = UUID()
        #expect(service.retainedState.total == 0)
        store.selectedVineyardId = fixture.scope.vineyard
        store.currentUserIdProvider = { UUID() }
        #expect(service.retainedState.total == 0)
        #expect(try wal.attempts() == before)
    }

    @Test func receiptOnlyReverificationPreservesCostingPinsSpraysAndUnrelatedSuccessfulUpload() async throws {
        let fixture = try AbsenceFixture(); fixture.mode = "hidden"
        let (store, metadata, service, auth) = try fixture.service(held: true)
        _ = auth
        let allocation = TripCostAllocation(vineyardId: fixture.scope.vineyard, tripId: fixture.scope.trip, seasonYear: 2026, labourCost: 5, totalCost: 5)
        store.tripCostAllocations = [allocation]
        store.tripCostAllocationRepo.saveSlice([allocation], for: fixture.scope.vineyard)
        let persistedCostsBefore = store.tripCostAllocationRepo.loadAll()
        #expect(persistedCostsBefore.map(\.id) == [allocation.id])
        let pin = VinePin(vineyardId: fixture.scope.vineyard, latitude: 0, longitude: 0, heading: nil,
            buttonName: "Original observation", buttonColor: "red", side: nil, mode: .repairs, tripId: fixture.scope.trip)
        store.pins = [pin]
        let record = SprayRecord(tripId: fixture.scope.trip, vineyardId: fixture.scope.vineyard)
        store.sprayRecords = [record]
        let upload = Trip(vineyardId: fixture.scope.vineyard, paddockName: "Unrelated", isActive: false)
        store.trips = [upload]; metadata.markDirty(upload.id, at: Date(timeIntervalSince1970: 500))
        var dependentWrites = 0
        store.onTripCostAllocationDeleted = { _ in dependentWrites += 1 }
        store.onPinChanged = { _ in dependentWrites += 1 }
        for mode in ["hidden", "success"] {
            fixture.mode = mode
            // Restore only the eligible historic ambiguity; this is a synthetic fixture, not recovery logic.
            if mode == "success", let intent = try store.tripDeletionJournal.load().intents[fixture.scope.trip] {
                try store.tripDeletionJournal.hold(intent, reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
            }
            try await service.pushLocalTrips(vineyardId: fixture.scope.vineyard)
            #expect(store.tripCostAllocations == [allocation] && store.tripCostAllocationRepo.loadAll() == persistedCostsBefore)
            #expect(store.pins == [pin] && store.sprayRecords == [record] && dependentWrites == 0)
        }
        #expect(metadata.pendingUpserts[upload.id] == nil)
        #expect(metadata.pendingDeletes[fixture.scope.trip] == nil)
    }

    @Test func syncLeavesSpinnerOnHeldFailureAndSuccessWithoutBlockingOtherAreas() async throws {
        for mode in ["success", "hidden", "timeout"] {
            let fixture = try AbsenceFixture(); fixture.mode = mode
            let (_, _, service, auth) = try fixture.service(held: true)
            _ = auth
            await service.sync(vineyardId: fixture.scope.vineyard)
            #expect(!service.isSyncing)
            if mode == "success" { #expect(service.syncStatus == .success) }
            else { #expect(service.syncStatus != .success && service.errorMessage != nil) }
            // Independent service area can finish even when Trips remains held.
            let center = SyncStatusCenter(); center.syncDidStart()
            center.syncDidFinish(upserts: 0, deletes: service.pendingDeleteCount, heldSprayPairs: service.retainedState.sprays.count, error: service.errorMessage)
            #expect(!center.isSyncing)
            #expect((center.lastFullSyncAt != nil) == (mode == "success"))
        }
    }
}

@MainActor private final class AbsenceFixture {
    let disk: PersistenceStore
    let scope = TripDeletionJournal.Scope(account: UUID(), vineyard: UUID(), trip: UUID())
    let authority: VineyardWriteAuthority
    var actor: UUID?
    var mode = "success"
    var requests: [URLRequest] = []
    var afterProof: (() throws -> Void)?
    var retainedStores: [MigratedDataStore] = []
    var retainedAuth: [NewBackendAuthService] = []
    lazy var repository = SupabaseTripSyncRepository(deletionAuthority: authority, deletionSession: {
        guard let actor = self.actor else { throw CancellationError() }
        return .init(actor: actor, token: "synthetic-token", incarnation: self.authority.accountGeneration)
    }, deletionTransport: { request in try self.respond(request) })

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        disk = PersistenceStore(directory: directory)
        authority = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        actor = scope.account; authority.bind(userId: scope.account)
    }

    func service(held: Bool, prepare: Bool = true) throws -> (MigratedDataStore, TripSyncMetadata, TripSyncService, NewBackendAuthService) {
        let store = MigratedDataStore(persistence: disk), metadata = TripSyncMetadata(persistence: disk)
        store.operationalWriteAuthority = authority
        store.currentUserIdProvider = { self.actor }; store.selectedVineyardId = scope.vineyard
        let auth = NewBackendAuthService()
        let service = TripSyncService(repository: AbsenceRepository(delegate: repository), metadata: metadata)
        service.configure(store: store, auth: auth)
        if prepare {
            let intent = try store.tripDeletionJournal.prepare(trip: scope.trip, queuedAt: Date(timeIntervalSince1970: 100), scope: scope, evidence: Data("original cancellation evidence".utf8), established: true)
            if held { try store.tripDeletionJournal.hold(intent, reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED") }
            metadata.markDeleted(scope.trip, at: intent.queuedAt)
        }
        retainedStores.append(store); retainedAuth.append(auth)
        return (store, metadata, service, auth)
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        var status = 200
        var body = "[]"
        if request.httpMethod == "GET" {
            if mode == "visible" { body = "[{\"id\":\"\(scope.trip)\",\"vineyard_id\":\"\(scope.vineyard)\",\"deleted_at\":null}]" }
        } else {
            #expect(url.lastPathComponent == "confirm_trip_absence_v1")
            switch mode {
            case "timeout": throw URLError(.timedOut)
            case "offline": throw URLError(.notConnectedToInternet)
            case "hidden": status = 403; body = "{\"code\":\"42501\",\"message\":\"TRIP_DELETE_SCOPE_UNRESOLVED\"}"
            case "http401": status = 401; body = "{}"
            case "http500": status = 500; body = "{}"
            case "missingRPC": status = 404; body = "{\"code\":\"PGRST202\",\"message\":\"function not found\",\"details\":null,\"hint\":null}"
            case "malformed": body = "not-json"
            case "emptyReceipt": body = "[]"
            default:
                body = "{\"schema_version\":\(mode == "futureSchema" ? 2 : 1),\"trip_id\":\"\(mode == "wrongTrip" ? UUID() : scope.trip)\",\"actor_id\":\"\(mode == "wrongActor" ? UUID() : scope.account)\",\"absent\":\(mode == "present" ? "false" : "true")}"
            }
            if mode == "switchActor" { actor = UUID(); authority.bind(userId: actor) }
            if mode == "sameActorNewIncarnation" { authority.bind(userId: nil); authority.bind(userId: actor) }
            if mode == "signedOut" { actor = nil; authority.bind(userId: nil) }
            try afterProof?()
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor private final class AbsenceRepository: TripSyncRepositoryProtocol {
    let delegate: SupabaseTripSyncRepository
    init(delegate: SupabaseTripSyncRepository) { self.delegate = delegate }
    func resolveDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String { try await delegate.resolveDeletion(scope, isCurrent: isCurrent) }
    func reverifyDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String { try await delegate.reverifyDeletion(scope, isCurrent: isCurrent) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func upsertTrip(_ trip: BackendTripUpsert) async throws {}
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {}
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws { Issue.record("Legacy delete bypassed journal") }
}
