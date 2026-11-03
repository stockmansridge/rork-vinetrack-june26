import Foundation
import XCTest
@testable import VineTrack

@MainActor private final class TankReadbackRepository: TripSyncRepositoryProtocol {
    private(set) var pushed: [BackendTripUpsert] = []
    var serverSessions: Set<String>? = []
    var readbackFails = false

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { pushed += trips }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { try await upsertTrips([trip]) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws {}
    func fetchTankSessionIds(tripId: UUID, vineyardId: UUID) async throws -> Set<String>? {
        if readbackFails { throw URLError(.timedOut) }
        return serverSessions
    }
}

/// P0 3.1.9 Phase B: Trip tank progress and Tank actual dependency verification.
@MainActor
final class TankDependencyVerificationTests: XCTestCase {
    private let vineyardId = UUID(uuidString: "59973CED-1FB9-42EC-A66D-9EAAD3172824")!
    private let userId = UUID(uuidString: "94238371-53C6-472D-975B-48BF98A268A9")!
    private let sessionId = UUID(uuidString: "30259F0A-E2E2-41A2-8FBF-4569028A6F45")!
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func actual(tripId: UUID, session: String? = nil, water: Double? = 400,
                        chemicals: [SprayTankActualChemical]? = nil) throws -> SprayTankActual {
        try SprayTankActual(id: UUID(uuidString: "2B07A0CE-2086-441C-9D36-8A387E3E397D")!, vineyardId: vineyardId,
            sprayRecordId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, tripId: tripId,
            tankSessionId: session ?? sessionId.uuidString, tankNumber: 1, waterVolumeL: water,
            chemicals: try chemicals ?? [chem(2.5)], confirmedAt: Date(timeIntervalSince1970: 1_790_000_000), confirmedBy: userId)
    }

    private func chem(_ amount: Double) throws -> SprayTankActualChemical {
        try SprayTankActualChemical(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, plannedChemicalId: nil,
            savedChemicalId: nil, name: "Copper", actualAmountBase: amount, unit: .kilograms)
    }

    private struct Harness {
        let service: TripSyncService
        let metadata: TripSyncMetadata
        let repository: TankReadbackRepository
        let store: MigratedDataStore
    }

    private func harness(trip: Trip, required: Set<String>) -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tankdep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let persistence = PersistenceStore(directory: directory)
        let metadata = TripSyncMetadata(persistence: persistence)
        let repository = TankReadbackRepository()
        let service = TripSyncService(repository: repository, metadata: metadata)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        store.trips = [trip]
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        auth.userId = userId
        service.configure(store: store, auth: auth)
        service.configureTankDependencies { id in id == trip.id ? required : [] }
        return Harness(service: service, metadata: metadata, repository: repository, store: store)
    }

    private func legacyTrip(sessions: [TankSession]) -> Trip {
        Trip(id: UUID(), vineyardId: vineyardId, startTime: Date(timeIntervalSince1970: 1_790_000_000), endTime: nil,
             isActive: true, tankSessions: sessions)
    }

    // MARK: Pure verification

    func testRequiredSessionsNormaliseCaseAndScopeToTrip() throws {
        let tripId = UUID()
        let required = TankDependencyVerification.requiredSessions(tripId: tripId,
            actuals: [try actual(tripId: tripId, session: sessionId.uuidString.uppercased()), try actual(tripId: UUID(), session: "other")])
        XCTAssertEqual(required, [sessionId.uuidString.lowercased()])
        XCTAssertTrue(TankDependencyVerification.missing(required: required, in: TankDependencyVerification.ids([TankSession(id: sessionId)])).isEmpty)
    }

    func testActualMatchesRequiresExactEvidence() throws {
        let tripId = UUID()
        let local = try actual(tripId: tripId)
        XCTAssertTrue(TankDependencyVerification.actualMatches(local: local, server: local))
        XCTAssertTrue(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, session: sessionId.uuidString.lowercased())))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: nil))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, water: 399)))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, water: nil)))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, chemicals: [try chem(2.0)])))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, chemicals: [])))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: tripId, session: UUID().uuidString)))
        XCTAssertFalse(TankDependencyVerification.actualMatches(local: local, server: try actual(tripId: UUID())))
    }

    func testParentBootstrapDoesNotReplayOriginalEndOrOtherOperations() async throws {
        XCTAssertTrue(OccurrenceParentBootstrapPolicy.mayReplay(
            "create_trip_with_occurrences_v1", parentOnly: true))
        XCTAssertTrue(OccurrenceParentBootstrapPolicy.mayReplay(
            "activate_trip_occurrences_v1", parentOnly: true))
        XCTAssertFalse(OccurrenceParentBootstrapPolicy.mayReplay(
            "apply_trip_occurrence_action_v1", parentOnly: true))
        XCTAssertFalse(OccurrenceParentBootstrapPolicy.mayReplay(
            "finalize_trip_occurrences_v1", parentOnly: true))
        XCTAssertTrue(OccurrenceParentBootstrapPolicy.mayReplay(
            "finalize_trip_occurrences_v1", parentOnly: false))
        XCTAssertFalse(OccurrenceParentBootstrapPolicy.parentOperationsAcknowledged(
            ["activate_trip_occurrences_v1", "finalize_trip_occurrences_v1"]))
        XCTAssertTrue(OccurrenceParentBootstrapPolicy.parentOperationsAcknowledged(
            ["apply_trip_occurrence_action_v1", "finalize_trip_occurrences_v1"]))
    }

    func testVerifiedParentMarkerAllowsActualWithoutAcknowledgingOriginalEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parent-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let metadata = TripSyncMetadata(persistence: persistence)
        let originalTrip = UUID()
        metadata.markDirty(originalTrip, at: Date())
        XCTAssertFalse(metadata.isParentEstablished(originalTrip))
        XCTAssertNotNil(metadata.pendingUpserts[originalTrip])
        metadata.markParentsEstablished([originalTrip])
        XCTAssertTrue(metadata.isParentEstablished(originalTrip))
        XCTAssertNotNil(metadata.pendingUpserts[originalTrip],
                        "Original End remains pending; no false terminal ACK")
        let gate = SprayTankActualUploadGate.decide(
            parentTripBlocked: metadata.pendingUpserts[originalTrip] != nil &&
                !metadata.isParentEstablished(originalTrip),
            sprayRecordPending: false)
        XCTAssertEqual(gate, .upload)
        let recovered = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        XCTAssertTrue(recovered.isParentEstablished(originalTrip))
        XCTAssertNotNil(recovered.pendingUpserts[originalTrip])
    }

    // MARK: Trip upload acknowledgement

    func testTripWithoutRequiredSessionIsNotUploadedOrAcknowledged() async throws {
        let trip = legacyTrip(sessions: [])
        let h = harness(trip: trip, required: [sessionId.uuidString.lowercased()])
        h.metadata.markDirty(trip.id, at: Date())
        try await h.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertTrue(h.repository.pushed.isEmpty)
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
        XCTAssertEqual(h.service.tankDependencyHolds[trip.id], TankDependencyVerification.requiredSessionMissing)
        XCTAssertTrue(h.store.trips.first { $0.id == trip.id }?.tankSessions.isEmpty == true)
    }

    func testUploadedTripStaysQueuedWhenReadbackLacksSession() async throws {
        let trip = legacyTrip(sessions: [TankSession(id: sessionId)])
        let h = harness(trip: trip, required: [sessionId.uuidString.lowercased()])
        h.repository.serverSessions = []
        h.metadata.markDirty(trip.id, at: Date())
        try await h.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertEqual(h.repository.pushed.map(\.id), [trip.id])
        XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
        XCTAssertEqual(h.service.tankDependencyHolds[trip.id], TankDependencyVerification.patchReadbackMismatch)
    }

    func testUploadedTripStaysQueuedWhenReadbackFailsOrTripAbsent() async throws {
        for failing in [true, false] {
            let trip = legacyTrip(sessions: [TankSession(id: sessionId)])
            let h = harness(trip: trip, required: [sessionId.uuidString.lowercased()])
            h.repository.readbackFails = failing
            h.repository.serverSessions = nil
            h.metadata.markDirty(trip.id, at: Date())
            try await h.service.pushLocalTrips(vineyardId: vineyardId)
            XCTAssertNotNil(h.metadata.pendingUpserts[trip.id])
        }
    }

    func testVerifiedReadbackAcknowledgesTrip() async throws {
        let trip = legacyTrip(sessions: [TankSession(id: sessionId)])
        let h = harness(trip: trip, required: [sessionId.uuidString.lowercased()])
        h.repository.serverSessions = [sessionId.uuidString.lowercased()]
        h.metadata.markDirty(trip.id, at: Date())
        try await h.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertNil(h.metadata.pendingUpserts[trip.id])
        XCTAssertNil(h.service.tankDependencyHolds[trip.id])
    }

    func testTripWithoutActualsIsUnaffected() async throws {
        let trip = legacyTrip(sessions: [])
        let h = harness(trip: trip, required: [])
        h.repository.readbackFails = true
        h.metadata.markDirty(trip.id, at: Date())
        try await h.service.pushLocalTrips(vineyardId: vineyardId)
        XCTAssertNil(h.metadata.pendingUpserts[trip.id])
    }
}
